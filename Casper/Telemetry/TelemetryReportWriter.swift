import Foundation

/// Consolidates session summaries daily and generates Markdown reports detailing
/// time distributions, failed terminal commands, and proposed automations.
final class TelemetryReportWriter: @unchecked Sendable {
    private let storage: TelemetryStorage
    private let powerMonitor: any TelemetryPowerMonitoring
    private let cleanupManager: any LocalLLMStreaming
    private let reportsDirectory: URL
    
    private var processTask: Task<Void, Never>?
    private var timer: Timer?

    init(
        storage: TelemetryStorage,
        powerMonitor: any TelemetryPowerMonitoring,
        cleanupManager: any LocalLLMStreaming,
        reportsDirectory: URL? = nil
    ) {
        self.storage = storage
        self.powerMonitor = powerMonitor
        self.cleanupManager = cleanupManager
        
        if let customDir = reportsDirectory {
            self.reportsDirectory = customDir
        } else {
            // Check if workspace repository exists locally at rooshi's document path
            let workspaceDocsURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/programming/mac/casper/docs/telemetry")
            
            if FileManager.default.fileExists(atPath: workspaceDocsURL.deletingLastPathComponent().path) {
                self.reportsDirectory = workspaceDocsURL
            } else {
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                self.reportsDirectory = appSupport
                    .appendingPathComponent("Casper", isDirectory: true)
                    .appendingPathComponent("telemetry", isDirectory: true)
                    .appendingPathComponent("reports", isDirectory: true)
            }
        }
    }

    /// Starts a daily check timer (every 1 hour) to see if we should write a daily report.
    func start() {
        guard timer == nil else { return }
        
        timer = Timer.scheduledTimer(withTimeInterval: 3600.0, repeats: true) { [weak self] _ in
            self?.triggerDailyReportGeneration()
        }
        
        // Trigger a check shortly after starting
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15.0) { [weak self] in
            self?.triggerDailyReportGeneration()
        }
    }

    /// Stops the timer.
    func stop() {
        timer?.invalidate()
        timer = nil
        processTask?.cancel()
        processTask = nil
    }

    /// Explicitly triggers report generation. Scheduled runs still require AC
    /// power and target yesterday; manual runs can bypass those defaults.
    func triggerDailyReportGeneration(force: Bool = false, dateString: String? = nil) {
        guard processTask == nil else { return }
        
        processTask = Task(priority: .background) {
            defer { self.processTask = nil }
            
            // R9: Daily consolidation only runs when connected to AC power
            guard force || self.powerMonitor.isConnectedToACPower else {
                return
            }
            
            let dateStr = dateString ?? Self.yesterdayDateString()
            let reportURL = self.reportsDirectory.appendingPathComponent("daily_report_\(dateStr).md")
            
            // Check if report was already written
            guard !FileManager.default.fileExists(atPath: reportURL.path) else {
                return
            }
            
            await self.generateReport(forDateString: dateStr, outputURL: reportURL)
        }
    }

    // MARK: - Core Report Generation

    private func generateReport(forDateString dateStr: String, outputURL: URL) async {
        let fileManager = FileManager.default
        let sessionsDir = storage.storageDirectory.appendingPathComponent("sessions", isDirectory: true)
        
        guard fileManager.fileExists(atPath: sessionsDir.path) else {
            writeEmptyReport(forDateString: dateStr, outputURL: outputURL)
            return
        }
        
        do {
            let files = try fileManager.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)
            
            // Load session summaries from yesterday
            let yesterdaySummaries = files.filter { fileURL in
                let filename = fileURL.lastPathComponent
                return filename.hasPrefix("session_\(dateStr)_") && filename.hasSuffix(".txt")
            }
            
            guard !yesterdaySummaries.isEmpty else {
                writeEmptyReport(forDateString: dateStr, outputURL: outputURL)
                return
            }
            
            var combinedSummaries = ""
            for (idx, fileURL) in yesterdaySummaries.enumerated() {
                if let summaryText = try? String(contentsOf: fileURL, encoding: .utf8) {
                    combinedSummaries += "### Session \(idx + 1)\n\(summaryText)\n\n"
                }
            }
            
            let prompt = """
            You are Casper's local Telemetry Report Writer. Correlate the following session summaries captured from the user's workspace over the past day. Identify daily repetitions, recurrent terminal command errors, copy-paste patterns, and propose JIT automations.
            
            Format your output strictly as a Markdown report containing:
            1. An Executive Summary.
            2. Time Distribution across applications (formatted as a Markdown table with App, Focus Duration, and General Activity).
            3. Failed Terminal Commands & Fixes (if any occurred; list the command and proposed correct command).
            4. Proposed Automations (shell scripts, keyboard shortcuts, or keystroke sequences that would save the user time).
            
            Keep the report concise, professional, and action-oriented. Do not include user PII or raw logs.
            
            Session Summaries:
            \(combinedSummaries)
            """
            
            var reportContent = ""
            let stream = try await cleanupManager.streamCompletion(prompt: prompt, modelKind: .full)
            for await token in stream {
                if Task.isCancelled { break }
                reportContent += token
            }
            
            let trimmedReport = reportContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedReport.isEmpty {
                try fileManager.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
                try trimmedReport.write(to: outputURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("Failed to generate daily report: \(error.localizedDescription)")
        }
    }

    private func writeEmptyReport(forDateString dateStr: String, outputURL: URL) {
        let emptyReport = """
        # Casper Daily Telemetry Report - \(dateStr)
        
        ## Summary
        No user workspace sessions were recorded yesterday. Telemetry monitoring is active and will generate insights as soon as system activity is captured.
        
        ## Automations
        None proposed.
        """
        try? FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        try? emptyReport.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private static func yesterdayDateString() -> String {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: yesterday)
    }
}
