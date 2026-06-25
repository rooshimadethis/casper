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
    private let targetModels: [LocalCleanupModelKind]
    private weak var predictionTrainer: PredictionTrainer?
    
    private var processTask: Task<Void, Never>?
    private var timer: Timer?

    init(
        storage: TelemetryStorage,
        powerMonitor: any TelemetryPowerMonitoring,
        cleanupManager: any LocalLLMStreaming,
        predictionTrainer: PredictionTrainer? = nil,
        targetModels: [LocalCleanupModelKind] = LocalCleanupModelKind.allCases
    ) {
        self.storage = storage
        self.powerMonitor = powerMonitor
        self.cleanupManager = cleanupManager
        self.predictionTrainer = predictionTrainer
        self.targetModels = targetModels
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
            self.predictionTrainer?.train(force: force)
        }
    }

    // MARK: - Core Processing Logic

    private func processRawLogs() async {
        storage.rollActiveLog()
        
        let fileManager = FileManager.default
        let eventsDir = storage.eventsDirectory
        
        guard fileManager.fileExists(atPath: eventsDir.path) else { return }
        
        do {
            let files = try fileManager.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil)
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
                
                var anyModelSucceeded = false
                for modelKind in targetModels {
                    do {
                        let summary = try await summarizeSession(session.records, modelKind: modelKind)
                        if try persistSummary(summary, for: session, modelKind: modelKind) {
                            anyModelSucceeded = true
                        }
                    } catch {
                        print("Failed to summarize session using \(modelKind.rawValue): \(error.localizedDescription)")
                    }
                }
                
                if anyModelSucceeded {
                    updatedProgress.processedLineCounts[datePart] = session.endLine
                }
            }
        } catch {
            print("Failed to summarize telemetry file \(filename): \(error.localizedDescription)")
        }
        return updatedProgress
    }

    private func summarizeSession(_ records: [TelemetryEventRecord], modelKind: LocalCleanupModelKind) async throws -> String {
        let formattedSessionData = formatEventsForSummarization(records)

        let prompt = """
        You are Casper's passive Telemetry Summarizer. Your goal is to infer user actions and outcomes based on the local telemetry events log below.
        
        Analyze the log and output a list of inferred activities. For each distinct activity or sequence, format it exactly as:
        - Context: What did the user see? (e.g., app name, window title, command outputs, or starting state)
        - Action: What did the user try to do? (e.g., commands executed, typing patterns, copy-paste loops)
        - Outcome: What was the outcome? (e.g., success, error, app stall duration, or user hesitation)
        
        Keep each point factual and extremely concise. Do not invent any activity. Keep the total output under 150 words.
        
        Telemetry Log:
        \(formattedSessionData)
        """

        let start = Date()
        var summary = ""
        let stream = try await cleanupManager.streamCompletion(prompt: prompt, modelKind: modelKind)
        for await token in stream {
            if Task.isCancelled { break }
            summary += token
        }

        let elapsed = Date().timeIntervalSince(start)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedSummary.isEmpty else { return "" }
        
        let characterCount = trimmedSummary.count
        let throughput = elapsed > 0 ? Double(characterCount) / elapsed : 0.0
        
        let output = """
        \(trimmedSummary)
        
        === METRICS ===
        Model: \(modelKind.rawValue)
        Generation Time: \(String(format: "%.2f", elapsed)) seconds
        Character Count: \(characterCount)
        Throughput: \(String(format: "%.2f", throughput)) chars/sec
        """
        
        return output
    }

    private func persistSummary(_ summary: String, for session: PendingSessionBatch, modelKind: LocalCleanupModelKind) throws -> Bool {
        guard !summary.isEmpty else { return false }

        let fileManager = FileManager.default
        let sessionsDir = storage.storageDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(modelKind.rawValue, isDirectory: true)
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
            case .mouseClicked(let app, let element, let clickCount, let selectedText):
                let clickType = clickCount == 2 ? "Double-clicked" : (clickCount >= 3 ? "Triple-clicked" : "Clicked")
                var msg = "\(prefix)\(timestamp) \(clickType) UI element \"\(element)\" in app \(app)"
                if let selectedText = selectedText, !selectedText.isEmpty {
                    let truncated = selectedText.count > 100 ? selectedText.prefix(100) + "..." : selectedText
                    msg += " (highlighted: \"\(truncated)\")"
                }
                output += msg + "\n"
            case .appStalled(let app, let duration):
                output += "\(prefix)\(timestamp) App stalled: \(app) was unresponsive for \(String(format: "%.1f", duration))s\n"
            case .userHesitated(let app, let duration):
                output += "\(prefix)\(timestamp) User paused/hesitated on app: \(app) for \(String(format: "%.1f", duration))s\n"
            case .typingSession(let app, let targetElement, let text, let duration):
                let truncated = text.count > 100 ? text.prefix(100) + "..." : text
                if let targetElement = targetElement {
                    output += "\(prefix)\(timestamp) Typed \"\(truncated)\" in \"\(targetElement)\" under \(app) over \(String(format: "%.1f", duration))s\n"
                } else {
                    output += "\(prefix)\(timestamp) Typed \"\(truncated)\" in \(app) over \(String(format: "%.1f", duration))s\n"
                }
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
