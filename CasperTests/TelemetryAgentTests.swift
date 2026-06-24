import XCTest
@testable import Casper

final class TelemetryAgentTests: XCTestCase {
    private var tempDirectory: URL!
    private var storage: TelemetryStorage!
    private var mockPowerMonitor: MockPowerMonitor!
    private var mockLLM: MockLocalLLM!

    final class MockLocalLLM: LocalLLMStreaming {
        var promptReceived: String?
        var modelKindReceived: LocalCleanupModelKind?
        var responsesToReturn: [String] = ["Mock summary output"]
        var callCount = 0

        func streamCompletion(prompt: String, modelKind: LocalCleanupModelKind?) async throws -> AsyncStream<String> {
            self.promptReceived = prompt
            self.modelKindReceived = modelKind
            self.callCount += 1
            
            let (stream, continuation) = AsyncStream<String>.makeStream()
            let response = responsesToReturn.isEmpty ? "Mock summary output" : responsesToReturn.removeFirst()
            continuation.yield(response)
            continuation.finish()
            return stream
        }
    }

    final class MockPowerMonitor: TelemetryPowerMonitoring {
        var mockIsIdle = true
        var mockIsConnectedToAC = true

        func isUserIdle(threshold: TimeInterval?) -> Bool {
            return mockIsIdle
        }

        var isConnectedToACPower: Bool {
            return mockIsConnectedToAC
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        storage = TelemetryStorage(storageDirectory: tempDirectory)
        mockPowerMonitor = MockPowerMonitor()
        mockLLM = MockLocalLLM()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    func testTelemetrySummarizerCreatesSessionSummariesPerIdleSessionAndSkipsProcessedLines() async throws {
        let summarizer = TelemetrySummarizer(
            storage: storage,
            powerMonitor: mockPowerMonitor,
            cleanupManager: mockLLM,
            targetModels: [.fast]
        )
        
        let baseTime = Date(timeIntervalSince1970: 1_719_225_600)
        try storage.appendEvent(
            .appActivated(appName: "Safari", bundleID: "com.apple.safari", windowTitle: "GitHub"),
            recordedAt: baseTime
        )
        try storage.appendEvent(
            .textCopied(text: "git status"),
            recordedAt: baseTime.addingTimeInterval(60)
        )
        try storage.appendEvent(
            .commandExecuted(command: "swift test", exitCode: 1, output: "failure"),
            recordedAt: baseTime.addingTimeInterval(900)
        )
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: baseTime)
        
        let eventsDir = tempDirectory.appendingPathComponent("events", isDirectory: true)
        let hasRawFile = { (dir: URL) -> Bool in
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.contains { $0.lastPathComponent.hasPrefix("telemetry_events_\(dateString)") }
        }
        XCTAssertTrue(hasRawFile(eventsDir))
        
        mockLLM.responsesToReturn = [
            "Session one summary",
            "Session two summary"
        ]
        
        summarizer.triggerProcessing()
        try await Task.sleep(nanoseconds: 200_000_000)
        
        XCTAssertTrue(hasRawFile(eventsDir))
        
        let sessionsDir = tempDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(LocalCleanupModelKind.fast.rawValue, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionsDir.path))
        
        let sessionFiles = try FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)
        let textSummaries = sessionFiles.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(textSummaries.count, 2)
        XCTAssertEqual(mockLLM.callCount, 2)

        let contents = try textSummaries.map { try String(contentsOf: $0, encoding: .utf8) }
        
        // Match metrics-appended content
        XCTAssertTrue(contents.contains { $0.contains("Session one summary") })
        XCTAssertTrue(contents.contains { $0.contains("Session two summary") })
        XCTAssertTrue(contents.contains { $0.contains("=== METRICS ===") })

        summarizer.triggerProcessing()
        try await Task.sleep(nanoseconds: 200_000_000)

        let sessionFilesAfterSecondRun = try FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)
        let textSummariesAfterSecondRun = sessionFilesAfterSecondRun.filter { $0.pathExtension == "txt" }
        XCTAssertEqual(textSummariesAfterSecondRun.count, 2)
        XCTAssertEqual(mockLLM.callCount, 2)
    }

    func testTelemetrySummarizerManualTriggerBypassesIdleRequirement() async throws {
        let summarizer = TelemetrySummarizer(
            storage: storage,
            powerMonitor: mockPowerMonitor,
            cleanupManager: mockLLM,
            targetModels: [.fast]
        )

        mockPowerMonitor.mockIsIdle = false
        let baseTime = Date(timeIntervalSince1970: 1_719_225_600)
        try storage.appendEvent(
            .appActivated(appName: "Terminal", bundleID: "com.apple.Terminal", windowTitle: "zsh"),
            recordedAt: baseTime
        )

        summarizer.triggerProcessing(force: true)
        try await Task.sleep(nanoseconds: 200_000_000)

        let sessionsDir = tempDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(LocalCleanupModelKind.fast.rawValue, isDirectory: true)
        let sessionFiles = try FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(sessionFiles.filter { $0.pathExtension == "txt" }.count, 1)
        XCTAssertEqual(mockLLM.callCount, 1)
    }

    func testTelemetryReportWriterCreatesDailyReport() async throws {
        let writer = TelemetryReportWriter(
            storage: storage,
            powerMonitor: mockPowerMonitor,
            cleanupManager: mockLLM,
            reportsDirectory: tempDirectory,
            targetModels: [.fast]
        )
        
        // 1. Create a dummy session summary dated yesterday
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let yesterdayStr = formatter.string(from: yesterday)
        
        let sessionsDir = tempDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(LocalCleanupModelKind.fast.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let sessionURL = sessionsDir.appendingPathComponent("session_\(yesterdayStr)_12345.txt")
        try "User opened terminal and ran test commands.".write(to: sessionURL, atomically: true, encoding: .utf8)
        
        // 2. Trigger daily report generation (mockIsConnectedToAC is true, should run)
        mockLLM.responsesToReturn = ["# Daily Telemetry Report\n\nExecutive Summary: user focused on terminal."]
        
        writer.triggerDailyReportGeneration()
        
        // Give background tasks a brief moment to run
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // 3. Verify daily report is written
        let reportURL = tempDirectory
            .appendingPathComponent(LocalCleanupModelKind.fast.rawValue, isDirectory: true)
            .appendingPathComponent("daily_report_\(yesterdayStr).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))
        
        let reportContent = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportContent.contains("Daily Telemetry Report"))
        XCTAssertTrue(reportContent.contains("user focused on terminal."))
        XCTAssertTrue(reportContent.contains("=== METRICS ==="))
    }

    func testTelemetryReportWriterManualTriggerBypassesACRequirementForSpecifiedDate() async throws {
        let writer = TelemetryReportWriter(
            storage: storage,
            powerMonitor: mockPowerMonitor,
            cleanupManager: mockLLM,
            reportsDirectory: tempDirectory,
            targetModels: [.fast]
        )

        mockPowerMonitor.mockIsConnectedToAC = false

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let todayStr = formatter.string(from: Date())

        let sessionsDir = tempDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(LocalCleanupModelKind.fast.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let sessionURL = sessionsDir.appendingPathComponent("session_\(todayStr)_1-2.txt")
        try "User validated a new feature and hit one onboarding edge case.".write(to: sessionURL, atomically: true, encoding: .utf8)

        mockLLM.responsesToReturn = ["# Daily Telemetry Report\n\nExecutive Summary: manual dogfood pass completed."]

        writer.triggerDailyReportGeneration(force: true, dateString: todayStr)
        try await Task.sleep(nanoseconds: 200_000_000)

        let reportURL = tempDirectory
            .appendingPathComponent(LocalCleanupModelKind.fast.rawValue, isDirectory: true)
            .appendingPathComponent("daily_report_\(todayStr).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))

        let reportContent = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportContent.contains("manual dogfood pass completed."))
        XCTAssertTrue(reportContent.contains("=== METRICS ==="))
    }
}
