import XCTest
@testable import Casper

final class TelemetryStorageTests: XCTestCase {
    private var tempDirectory: URL!
    private var storage: TelemetryStorage!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        storage = TelemetryStorage(storageDirectory: tempDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    func testAppendAndLoadEvents() throws {
        let event1 = DesktopUserEvent.appActivated(appName: "Finder", bundleID: "com.apple.finder", windowTitle: "Downloads")
        let event2 = DesktopUserEvent.textCopied(text: "Hello telemetry")

        try storage.appendEvent(event1)
        try storage.appendEvent(event2)

        // Get current date string
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: Date())

        let loaded = try storage.loadEvents(forDateString: dateString)
        XCTAssertEqual(loaded.count, 2)

        if case .appActivated(let name, let bundle, let title) = loaded[0] {
            XCTAssertEqual(name, "Finder")
            XCTAssertEqual(bundle, "com.apple.finder")
            XCTAssertEqual(title, "Downloads")
        } else {
            XCTFail("First event is not appActivated")
        }

        if case .textCopied(let text) = loaded[1] {
            XCTAssertEqual(text, "Hello telemetry")
        } else {
            XCTFail("Second event is not textCopied")
        }
    }

    func testLoadEventRecordsPreservesRecordedAt() throws {
        let recordedAt = Date(timeIntervalSince1970: 1_719_225_600)
        let event = DesktopUserEvent.commandExecuted(command: "swift test", exitCode: 1, output: "failure")

        try storage.appendEvent(event, recordedAt: recordedAt)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: recordedAt)

        let records = try storage.loadEventRecords(forDateString: dateString)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].recordedAt, recordedAt)

        if case .commandExecuted(let command, let exitCode, let output) = records[0].event {
            XCTAssertEqual(command, "swift test")
            XCTAssertEqual(exitCode, 1)
            XCTAssertEqual(output, "failure")
        } else {
            XCTFail("Stored record did not round-trip the telemetry event")
        }
    }

    func testRollActiveLogCreatesNewTimestampedFile() throws {
        let baseTime = Date(timeIntervalSince1970: 1_719_225_600)
        let event1 = DesktopUserEvent.textCopied(text: "First event")
        let event2 = DesktopUserEvent.textCopied(text: "Second event")

        try storage.appendEvent(event1, recordedAt: baseTime)
        
        // Roll the log
        storage.rollActiveLog()
        
        // Append another event, which should go to a new timestamped file (time + 1s to ensure distinct timestamp)
        try storage.appendEvent(event2, recordedAt: baseTime.addingTimeInterval(1))

        let eventsDir = tempDirectory.appendingPathComponent("events", isDirectory: true)
        let remainingFiles = try FileManager.default.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil)
        let logFiles = remainingFiles.filter { $0.lastPathComponent.hasPrefix("telemetry_events_") && $0.lastPathComponent.hasSuffix(".jsonl") }
        
        XCTAssertEqual(logFiles.count, 2)
    }

    func testLoadEventRecordsWithDatePrefix() throws {
        let baseTime = Date(timeIntervalSince1970: 1_719_225_600)
        let event1 = DesktopUserEvent.textCopied(text: "Event one")
        let event2 = DesktopUserEvent.textCopied(text: "Event two")

        try storage.appendEvent(event1, recordedAt: baseTime)
        storage.rollActiveLog()
        try storage.appendEvent(event2, recordedAt: baseTime.addingTimeInterval(5))

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: baseTime)

        // Querying using the date prefix YYYY-MM-DD should merge events across both files
        let records = try storage.loadEventRecords(forDateString: dateString)
        XCTAssertEqual(records.count, 2)
        
        if case .textCopied(let text1) = records[0].event {
            XCTAssertEqual(text1, "Event one")
        } else {
            XCTFail("First event is not textCopied")
        }

        if case .textCopied(let text2) = records[1].event {
            XCTAssertEqual(text2, "Event two")
        } else {
            XCTFail("Second event is not textCopied")
        }
    }
}
