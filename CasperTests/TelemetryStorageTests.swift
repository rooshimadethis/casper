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

    func testRotateLogsDeletesFilesOlderThan7Days() throws {
        let fileManager = FileManager.default
        let calendar = Calendar.current
        let now = Date()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        // Create 3 files: 10 days ago (should delete), 6 days ago (should keep), today (should keep)
        let dates = [
            (calendar.date(byAdding: .day, value: -10, to: now)!, true),
            (calendar.date(byAdding: .day, value: -6, to: now)!, false),
            (now, false)
        ]

        for (date, _) in dates {
            let dateStr = formatter.string(from: date)
            let fileURL = tempDirectory.appendingPathComponent("telemetry_events_\(dateStr).jsonl")
            try "dummy content\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        try storage.rotateLogs()

        let remainingFiles = try fileManager.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(remainingFiles.count, 2)

        for fileURL in remainingFiles {
            let filename = fileURL.lastPathComponent
            XCTAssertFalse(filename.contains(formatter.string(from: dates[0].0)))
            XCTAssertTrue(
                filename.contains(formatter.string(from: dates[1].0)) ||
                filename.contains(formatter.string(from: dates[2].0))
            )
        }
    }
}
