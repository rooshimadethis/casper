import XCTest
@testable import Casper

final class TelemetryCollectorTests: XCTestCase {
    private var tempDirectory: URL!
    private var storage: TelemetryStorage!
    private var powerMonitor: TelemetryPowerMonitor!
    private var ocrService: FrontmostWindowOCRService!
    private var collector: TelemetryCollector!

    @MainActor
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        storage = TelemetryStorage(storageDirectory: tempDirectory)
        powerMonitor = TelemetryPowerMonitor()
        ocrService = FrontmostWindowOCRService()
        
        collector = TelemetryCollector(
            storage: storage,
            powerMonitor: powerMonitor,
            ocrService: ocrService
        )
    }

    @MainActor
    override func tearDownWithError() throws {
        collector.stop()
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    @MainActor
    func testLogCommandExecuted() throws {
        collector.logCommandExecuted(command: "git status", exitCode: 0, output: "On branch main")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: Date())

        let events = try storage.loadEvents(forDateString: dateString)
        XCTAssertEqual(events.count, 1)
        
        if case .commandExecuted(let cmd, let exitCode, let out) = events[0] {
            XCTAssertEqual(cmd, "git status")
            XCTAssertEqual(exitCode, 0)
            XCTAssertEqual(out, "On branch main")
        } else {
            XCTFail("Event is not commandExecuted")
        }
    }

    @MainActor
    func testPollWorkspaceStateCapturesActiveApp() throws {
        // Run pollWorkspaceState; it should fetch the running test host (xcodebuild or Xcode)
        collector.pollWorkspaceState()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: Date())

        let events = try storage.loadEvents(forDateString: dateString)
        // Since we polled, we should have captured at least the active app activation
        XCTAssertGreaterThanOrEqual(events.count, 1)
        
        let appActivatedExists = events.contains { event in
            if case .appActivated = event { return true }
            return false
        }
        XCTAssertTrue(appActivatedExists, "Should have logged an appActivated event")
    }
}
