import Foundation
import Combine

/// Protocol definition to decouple local LLM streaming from the concrete manager for testing.
protocol LocalLLMStreaming: AnyObject, Sendable {
    func streamCompletion(
        prompt: String,
        modelKind: LocalCleanupModelKind?
    ) async throws -> AsyncStream<String>
}

/// Periodically checks system idle status and processes raw telemetry event
/// files into session summaries using the local LLM.
final class TelemetrySummarizer: @unchecked Sendable {
    private struct SessionProgress: Codable {
        var processedLineCounts: [String: Int] = [:]
    }

    private struct PendingSessionBatch {
        let dateString: String
        let startLine: Int
        let endLine: Int
        let records: [TelemetryEventRecord]
    }

    private let storage: TelemetryStorage
    private let powerMonitor: any TelemetryPowerMonitoring
    private let cleanupManager: any LocalLLMStreaming
    
    private var processTask: Task<Void, Never>?
    private var timer: Timer?

    init(
        storage: TelemetryStorage,
        powerMonitor: any TelemetryPowerMonitoring,
        cleanupManager: any LocalLLMStreaming
    ) {
        self.storage = storage
        self.powerMonitor = powerMonitor
        self.cleanupManager = cleanupManager
    }

    /// Starts a periodic check (every 5 minutes) to run idle summarizations.
    func start() {
        guard timer == nil else { return }
        
        // Check every 5 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.triggerProcessing()
        }
        
        // Also run a check shortly after starting
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.triggerProcessing()
        }
    }

    /// Stops periodic checks.
    func stop() {
        timer?.invalidate()
        timer = nil
        processTask?.cancel()
        processTask = nil
    }

    /// Explicitly triggers raw event processing. Scheduled runs still respect
    /// idle gating; manual runs can bypass it.
    func triggerProcessing(force: Bool = false) {
        guard processTask == nil else { return }
        
        processTask = Task(priority: .background) {
            defer { self.processTask = nil }
            
            // R5: Process only if user has been idle for at least 10 minutes (600s)
            guard force || self.powerMonitor.isUserIdle(threshold: 600) else {
                return
            }
            
            await self.processRawLogs()
        }
    }

    // MARK: - Core Processing Logic

    private func processRawLogs() async {
        let fileManager = FileManager.default
        let storageDir = storage.storageDirectory
        
        guard fileManager.fileExists(atPath: storageDir.path) else { return }
        
        do {
            let files = try fileManager.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil)
            let logFiles = files
                .filter { $0.lastPathComponent.hasPrefix("telemetry_events_") && $0.lastPathComponent.hasSuffix(".jsonl") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var progress = loadProgress()
            
            for fileURL in logFiles {
                if Task.isCancelled { break }
                progress = await summarizePendingSessions(in: fileURL, progress: progress)
            }

            try saveProgress(progress)
        } catch {
            print("Failed to read telemetry directory: \(error.localizedDescription)")
        }
    }

    private func summarizePendingSessions(in fileURL: URL, progress: SessionProgress) async -> SessionProgress {
        let filename = fileURL.lastPathComponent
        let datePart = filename
            .replacingOccurrences(of: "telemetry_events_", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")
        var updatedProgress = progress

        do {
            let records = try storage.loadEventRecords(forDateString: datePart)

            guard !records.isEmpty else {
                try? FileManager.default.removeItem(at: fileURL)
                return updatedProgress
            }

            let processedLineCount = updatedProgress.processedLineCounts[datePart] ?? 0
            guard processedLineCount < records.count else {
                return updatedProgress
            }

            let pendingSessions = makePendingSessions(
                from: records,
                dateString: datePart,
                startingAfterLine: processedLineCount
            )

            for session in pendingSessions {
                if Task.isCancelled { break }
                let summary = try await summarizeSession(session.records)
                if try persistSummary(summary, for: session) {
                    updatedProgress.processedLineCounts[datePart] = session.endLine
                }
            }
        } catch {
            print("Failed to summarize telemetry file \(filename): \(error.localizedDescription)")
        }
        return updatedProgress
    }

    private func summarizeSession(_ records: [TelemetryEventRecord]) async throws -> String {
        let formattedSessionData = formatEventsForSummarization(records)

        let prompt = """
        You are Casper's passive Telemetry Summarizer. Your goal is to write a single-paragraph summary of user activity based on the local telemetry events log below.
        Summarize:
        1. The primary applications used.
        2. The user's focus patterns (e.g. switched frequently, focused on one task, copy-paste loops).
        3. Recurrent terminal executions or error outputs if present.
        4. User hesitation or app stalls.
        
        Keep the summary factual, concise, and under 150 words. Do not invent any activity.
        
        Telemetry Log:
        \(formattedSessionData)
        """

        var summary = ""
        let stream = try await cleanupManager.streamCompletion(prompt: prompt, modelKind: .fast)
        for await token in stream {
            if Task.isCancelled { break }
            summary += token
        }

        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persistSummary(_ summary: String, for session: PendingSessionBatch) throws -> Bool {
        guard !summary.isEmpty else { return false }

        let fileManager = FileManager.default
        let sessionsDir = storage.storageDirectory.appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let summaryURL = sessionsDir.appendingPathComponent(
            "session_\(session.dateString)_\(session.startLine)-\(session.endLine).txt"
        )
        try summary.write(to: summaryURL, atomically: true, encoding: .utf8)
        return true
    }

    private func makePendingSessions(
        from records: [TelemetryEventRecord],
        dateString: String,
        startingAfterLine processedLineCount: Int
    ) -> [PendingSessionBatch] {
        guard processedLineCount < records.count else { return [] }

        var sessions: [PendingSessionBatch] = []
        let sessionGapThreshold: TimeInterval = 600

        var currentStartIndex = processedLineCount
        var currentRecords: [TelemetryEventRecord] = [records[processedLineCount]]

        if processedLineCount + 1 < records.count {
            for index in (processedLineCount + 1)..<records.count {
                let record = records[index]
                let previous = records[index - 1]
                let gap = record.recordedAt.timeIntervalSince(previous.recordedAt)

                if gap >= sessionGapThreshold {
                    sessions.append(
                        PendingSessionBatch(
                            dateString: dateString,
                            startLine: currentStartIndex + 1,
                            endLine: index,
                            records: currentRecords
                        )
                    )
                    currentStartIndex = index
                    currentRecords = [record]
                } else {
                    currentRecords.append(record)
                }
            }
        }

        sessions.append(
            PendingSessionBatch(
                dateString: dateString,
                startLine: currentStartIndex + 1,
                endLine: records.count,
                records: currentRecords
            )
        )
        return sessions
    }

    private func loadProgress() -> SessionProgress {
        let url = progressFileURL()
        guard let data = try? Data(contentsOf: url),
              let progress = try? JSONDecoder().decode(SessionProgress.self, from: data) else {
            return SessionProgress()
        }
        return progress
    }

    private func saveProgress(_ progress: SessionProgress) throws {
        let fileManager = FileManager.default
        let sessionsDir = storage.storageDirectory.appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let data = try JSONEncoder().encode(progress)
        try data.write(to: progressFileURL(), options: .atomic)
    }

    private func progressFileURL() -> URL {
        storage.storageDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("session_progress.json")
    }

    private func formatEventsForSummarization(_ records: [TelemetryEventRecord]) -> String {
        var output = ""
        for (index, record) in records.enumerated() {
            let prefix = "[\(index + 1)] "
            let timestamp = Self.summaryTimestampFormatter.string(from: record.recordedAt)
            let event = record.event
            switch event {
            case .appActivated(let name, _, let title):
                output += "\(prefix)\(timestamp) Activated App: \(name) | Window Title: \(title)\n"
            case .windowTitleChanged(let name, let title):
                output += "\(prefix)\(timestamp) Window changed in \(name) to title: \(title)\n"
            case .textCopied(let text):
                let truncated = text.count > 100 ? text.prefix(100) + "..." : text
                output += "\(prefix)\(timestamp) Copied text: \"\(truncated)\"\n"
            case .screenOcrCaptured(let text):
                let truncated = text.count > 100 ? text.prefix(100) + "..." : text
                output += "\(prefix)\(timestamp) OCR captured text: \"\(truncated)\"\n"
            case .commandExecuted(let command, let exitCode, let out):
                let truncatedOut = (out ?? "").count > 100 ? (out ?? "").prefix(100) + "..." : (out ?? "")
                output += "\(prefix)\(timestamp) Executed terminal command: `\(command)` | Exit Code: \(exitCode) | Output: \(truncatedOut)\n"
            case .customInput(let prompt):
                output += "\(prefix)\(timestamp) Custom prompt input: \"\(prompt)\"\n"
            case .mouseClicked(let app, let element, let x, let y):
                output += "\(prefix)\(timestamp) Clicked UI element \"\(element)\" in app \(app) at coordinate (\(x), \(y))\n"
            case .appStalled(let app, let duration):
                output += "\(prefix)\(timestamp) App stalled: \(app) was unresponsive for \(String(format: "%.1f", duration))s\n"
            case .userHesitated(let app, let duration):
                output += "\(prefix)\(timestamp) User paused/hesitated on app: \(app) for \(String(format: "%.1f", duration))s\n"
            case .typingSession(let app, let chars, let duration):
                output += "\(prefix)\(timestamp) Typed \(chars) characters in \(app) over \(String(format: "%.1f", duration))s\n"
            }
        }
        return output
    }

    private static let summaryTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
