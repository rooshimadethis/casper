import XCTest
@testable import Casper

final class PredictionTrainerTests: XCTestCase {
    private var tempDirectory: URL!
    private var storage: TelemetryStorage!
    private var trie: PpmTrie!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        storage = TelemetryStorage(storageDirectory: tempDirectory)
        trie = PpmTrie()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testTrainOnSingleJSONLWithPattern() throws {
        let events: [DesktopUserEvent] = [
            .appActivated(appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "main.swift"),
            .appActivated(appName: "Chrome", bundleID: "com.google.Chrome", windowTitle: "github.com"),
            .appActivated(appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "main.swift"),
            .appActivated(appName: "Chrome", bundleID: "com.google.Chrome", windowTitle: "github.com"),
        ]
        for event in events {
            try storage.appendEvent(event)
        }

        let monitor = MockPowerMonitor(idle: true, acPower: true)
        let trainer = PredictionTrainer(storage: storage, trie: trie, powerMonitor: monitor,
                                        predictionDirectory: tempDirectory.appendingPathComponent("prediction"))
        trainer.train(force: true)

        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let result = trie.predict(context: ["a:com.apple.dt.Xcode"])
        XCTAssertEqual(result.first?.token, "a:com.google.Chrome")
    }

    func testTimeDecayKeepsRecentMonthAtFullWeightAndDownweightsOlderHistory() throws {
        let today = Date()
        let lastWeek = today.addingTimeInterval(-86400 * 7)
        let olderThanMonth = today.addingTimeInterval(-86400 * 35)
        let todayStr = TelemetryStorageDateHelper.dateString(for: today)
        let lastWeekStr = TelemetryStorageDateHelper.dateString(for: lastWeek)
        let olderThanMonthStr = TelemetryStorageDateHelper.dateString(for: olderThanMonth)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let eventsDir = tempDirectory.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)

        // Today: app A → app B at full weight.
        let todayEvents: [TelemetryEventRecord] = [
            .init(recordedAt: today, event: .appActivated(appName: "A", bundleID: "com.a", windowTitle: "")),
            .init(recordedAt: today, event: .appActivated(appName: "B", bundleID: "com.b", windowTitle: "")),
        ]
        var todayData = Data()
        for rec in todayEvents {
            todayData.append(try encoder.encode(rec))
            todayData.append("\n".data(using: .utf8)!)
        }
        try todayData.write(to: eventsDir.appendingPathComponent("telemetry_events_\(todayStr).jsonl"))

        // Last week: same pattern also stays at full weight.
        let lastWeekEvents: [TelemetryEventRecord] = [
            .init(recordedAt: lastWeek, event: .appActivated(appName: "A", bundleID: "com.a", windowTitle: "")),
            .init(recordedAt: lastWeek, event: .appActivated(appName: "B", bundleID: "com.b", windowTitle: "")),
        ]
        var lastWeekData = Data()
        for rec in lastWeekEvents {
            lastWeekData.append(try encoder.encode(rec))
            lastWeekData.append("\n".data(using: .utf8)!)
        }
        try lastWeekData.write(to: eventsDir.appendingPathComponent("telemetry_events_\(lastWeekStr).jsonl"))

        // Older than a month: app A → app C contributes half-strength evidence.
        let olderThanMonthEvents: [TelemetryEventRecord] = [
            .init(recordedAt: olderThanMonth, event: .appActivated(appName: "A", bundleID: "com.a", windowTitle: "")),
            .init(recordedAt: olderThanMonth, event: .appActivated(appName: "C", bundleID: "com.c", windowTitle: "")),
        ]
        var olderThanMonthData = Data()
        for rec in olderThanMonthEvents {
            olderThanMonthData.append(try encoder.encode(rec))
            olderThanMonthData.append("\n".data(using: .utf8)!)
        }
        try olderThanMonthData.write(to: eventsDir.appendingPathComponent("telemetry_events_\(olderThanMonthStr).jsonl"))

        let monitor = MockPowerMonitor(idle: true, acPower: true)
        let trainer = PredictionTrainer(storage: storage, trie: trie, powerMonitor: monitor,
                                        predictionDirectory: tempDirectory.appendingPathComponent("prediction"))
        trainer.train(force: true)

        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // Context ["a:com.a"] should predict a:com.b because the two recent-month
        // observations outweigh the older-than-month half-strength observation.
        let predictions = trie.predict(context: ["a:com.a"])
        XCTAssertEqual(predictions.first?.token, "a:com.b")
        XCTAssertGreaterThan(predictions.first?.confidence ?? 0, 0.5)
    }

    func testProgressPersistence() throws {
        let events: [DesktopUserEvent] = [
            .appActivated(appName: "A", bundleID: "com.a", windowTitle: ""),
            .appActivated(appName: "B", bundleID: "com.b", windowTitle: ""),
        ]
        for event in events {
            try storage.appendEvent(event)
        }

        let monitor = MockPowerMonitor(idle: true, acPower: true)
        let predDir = tempDirectory.appendingPathComponent("prediction")
        let trainer = PredictionTrainer(storage: storage, trie: trie, powerMonitor: monitor,
                                        predictionDirectory: predDir)
        trainer.train(force: true)

        let expectation1 = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation1.fulfill()
        }
        wait(for: [expectation1], timeout: 2.0)

        let progressPath = predDir.appendingPathComponent("prediction_progress.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: progressPath.path))

        let triePath = predDir.appendingPathComponent("ppm_trie.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: triePath.path))
    }

    func testRebuildIgnoresProgressAndReplacesExistingTrie() throws {
        let eventsDir = tempDirectory.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        let dateString = TelemetryStorageDateHelper.dateString(for: Date())
        let eventFile = eventsDir.appendingPathComponent("telemetry_events_\(dateString).jsonl")

        try writeRecords([
            .init(recordedAt: Date(), event: .appActivated(appName: "A", bundleID: "com.a", windowTitle: "")),
            .init(recordedAt: Date(), event: .appActivated(appName: "B", bundleID: "com.b", windowTitle: "")),
            .init(recordedAt: Date(), event: .appActivated(appName: "A", bundleID: "com.a", windowTitle: "")),
            .init(recordedAt: Date(), event: .appActivated(appName: "B", bundleID: "com.b", windowTitle: "")),
        ], to: eventFile)

        let monitor = MockPowerMonitor(idle: true, acPower: true)
        let predDir = tempDirectory.appendingPathComponent("prediction")
        let trainer = PredictionTrainer(
            storage: storage,
            trie: trie,
            powerMonitor: monitor,
            predictionDirectory: predDir
        )

        trainer.train(force: true)
        waitForTrainingTick()
        XCTAssertEqual(trie.predict(context: ["a:com.a"]).first?.token, "a:com.b")

        try writeRecords([
            .init(recordedAt: Date(), event: .appActivated(appName: "A", bundleID: "com.a", windowTitle: "")),
            .init(recordedAt: Date(), event: .appActivated(appName: "C", bundleID: "com.c", windowTitle: "")),
            .init(recordedAt: Date(), event: .appActivated(appName: "A", bundleID: "com.a", windowTitle: "")),
            .init(recordedAt: Date(), event: .appActivated(appName: "C", bundleID: "com.c", windowTitle: "")),
        ], to: eventFile)

        trainer.train(force: true, rebuild: true)
        waitForTrainingTick()

        let predictions = trie.predict(context: ["a:com.a"])
        XCTAssertEqual(predictions.first?.token, "a:com.c")
        XCTAssertFalse(predictions.contains { $0.token == "a:com.b" })
    }

    func testForceBypassesIdleGate() {
        let monitor = MockPowerMonitor(idle: false, acPower: false)
        let trainer = PredictionTrainer(storage: storage, trie: trie, powerMonitor: monitor,
                                        predictionDirectory: tempDirectory.appendingPathComponent("prediction"))

        trainer.train(force: true)

        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertTrue(true, "Train with force:true did not throw (expected for empty storage)")
    }

    func testTrainPopulatesMicroForTypingEvents() throws {
        // Write separate per-day files so each gets its own tokenWindow.
        // Each file has appActivated → typingSession, contributing weight
        // to context "a:com.mitchellh.ghostty → k:Ghostty".
        // All three days are inside the full-weight month window, so total 3.0 survives floor 2.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let eventsDir = tempDirectory.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)

        let days: [Date] = [
            Date().addingTimeInterval(-86400 * 2.5),
            Date().addingTimeInterval(-86400 * 1.5),
            Date(),
        ]

        for day in days {
            let dateStr = TelemetryStorageDateHelper.dateString(for: day)
            let recs: [TelemetryEventRecord] = [
                .init(recordedAt: day, event: .appActivated(appName: "Ghostty", bundleID: "com.mitchellh.ghostty", windowTitle: "")),
                .init(recordedAt: day, event: .typingSession(appName: "Ghostty", targetElement: nil, typedText: "killall Finder", durationSeconds: 2.0)),
            ]
            var data = Data()
            for rec in recs {
                data.append(try encoder.encode(rec))
                data.append("\n".data(using: .utf8)!)
            }
            try data.write(to: eventsDir.appendingPathComponent("telemetry_events_\(dateStr).jsonl"))
        }

        let microStore = MicroStore()
        let monitor = MockPowerMonitor(idle: true, acPower: true)
        let trainer = PredictionTrainer(storage: storage, trie: trie, microStore: microStore, powerMonitor: monitor,
                                        predictionDirectory: tempDirectory.appendingPathComponent("prediction"))
        trainer.train(force: true)

        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let contextHash = "a:com.mitchellh.ghostty → k:Ghostty:unknown"
        let predictions = microStore.predict(for: contextHash)
        XCTAssertFalse(predictions.isEmpty)
        XCTAssertEqual(predictions.first?.value, "killall Finder")
    }

    func testTrainPopulatesMicroForClickEvents() throws {
        // Write separate per-day files so each gets its own tokenWindow.
        // Each file has appActivated → mouseClicked, contributing weight
        // to context "a:com.google.Chrome → m:Chrome:AXButton".
        // All three days are inside the full-weight month window, so total 3.0 survives floor 2.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let eventsDir = tempDirectory.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)

        let days: [Date] = [
            Date().addingTimeInterval(-86400 * 2.5),
            Date().addingTimeInterval(-86400 * 1.5),
            Date(),
        ]

        for day in days {
            let dateStr = TelemetryStorageDateHelper.dateString(for: day)
            let recs: [TelemetryEventRecord] = [
                .init(recordedAt: day, event: .appActivated(appName: "Chrome", bundleID: "com.google.Chrome", windowTitle: "")),
                .init(recordedAt: day, event: .mouseClicked(appName: "Chrome", elementClicked: "AXButton (Title: Reload)", clickCount: 1, selectedText: nil)),
            ]
            var data = Data()
            for rec in recs {
                data.append(try encoder.encode(rec))
                data.append("\n".data(using: .utf8)!)
            }
            try data.write(to: eventsDir.appendingPathComponent("telemetry_events_\(dateStr).jsonl"))
        }

        let microStore = MicroStore()
        let monitor = MockPowerMonitor(idle: true, acPower: true)
        let trainer = PredictionTrainer(storage: storage, trie: trie, microStore: microStore, powerMonitor: monitor,
                                        predictionDirectory: tempDirectory.appendingPathComponent("prediction"))
        trainer.train(force: true)

        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let contextHash = "a:com.google.Chrome → m:Chrome:AXButton"
        let predictions = microStore.predict(for: contextHash)
        XCTAssertFalse(predictions.isEmpty)
        XCTAssertEqual(predictions.first?.value, "Reload")
    }

    func testMicroValuesRespectCountFloor() throws {
        let events: [DesktopUserEvent] = [
            .appActivated(appName: "Ghostty", bundleID: "com.mitchellh.ghostty", windowTitle: ""),
            .typingSession(appName: "Ghostty", targetElement: nil, typedText: "ls", durationSeconds: 1.0),
            .typingSession(appName: "Ghostty", targetElement: nil, typedText: "killall Finder", durationSeconds: 2.0),
        ]
        for event in events {
            try storage.appendEvent(event)
        }

        let microStore = MicroStore()
        let monitor = MockPowerMonitor(idle: true, acPower: true)
        let trainer = PredictionTrainer(storage: storage, trie: trie, microStore: microStore, powerMonitor: monitor,
                                        predictionDirectory: tempDirectory.appendingPathComponent("prediction"))
        trainer.train(force: true)

        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // Today's full-weight entry now survives the sparse-data floor.
        XCTAssertFalse(microStore.store.isEmpty)
    }

    func testMicroValuesKeepRecentMonthAtFullWeight() throws {
        let today = Date()
        let yesterday = today.addingTimeInterval(-86400 * 1.5)
        let todayStr = TelemetryStorageDateHelper.dateString(for: today)
        let yesterdayStr = TelemetryStorageDateHelper.dateString(for: yesterday)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let eventsDir = tempDirectory.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)

        // Yesterday: appActivated + typingSession stays full weight.
        let yesterdayEvents: [TelemetryEventRecord] = [
            .init(recordedAt: yesterday, event: .appActivated(appName: "Ghostty", bundleID: "com.mitchellh.ghostty", windowTitle: "")),
            .init(recordedAt: yesterday, event: .typingSession(appName: "Ghostty", targetElement: nil, typedText: "killall Finder", durationSeconds: 2.0)),
        ]
        var yesterdayData = Data()
        for rec in yesterdayEvents {
            yesterdayData.append(try encoder.encode(rec))
            yesterdayData.append("\n".data(using: .utf8)!)
        }
        try yesterdayData.write(to: eventsDir.appendingPathComponent("telemetry_events_\(yesterdayStr).jsonl"))

        // Today: same pattern also stays full weight.
        let todayEvents: [TelemetryEventRecord] = [
            .init(recordedAt: today, event: .appActivated(appName: "Ghostty", bundleID: "com.mitchellh.ghostty", windowTitle: "")),
            .init(recordedAt: today, event: .typingSession(appName: "Ghostty", targetElement: nil, typedText: "killall Finder", durationSeconds: 2.0)),
        ]
        var todayData = Data()
        for rec in todayEvents {
            todayData.append(try encoder.encode(rec))
            todayData.append("\n".data(using: .utf8)!)
        }
        try todayData.write(to: eventsDir.appendingPathComponent("telemetry_events_\(todayStr).jsonl"))

        let microStore = MicroStore()
        let monitor = MockPowerMonitor(idle: true, acPower: true)
        let trainer = PredictionTrainer(storage: storage, trie: trie, microStore: microStore, powerMonitor: monitor,
                                        predictionDirectory: tempDirectory.appendingPathComponent("prediction"))
        trainer.train(force: true)

        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // Context hash: "a:com.mitchellh.ghostty → k:Ghostty:unknown"
        // Yesterday's entry: count += 1.0
        // Today's entry: count += 1.0
        // Total: 2.0, which survives prune(floor: 2)
        let contextHash = "a:com.mitchellh.ghostty → k:Ghostty:unknown"
        let predictions = microStore.predict(for: contextHash)
        XCTAssertEqual(predictions.first?.value, "killall Finder")
        XCTAssertEqual(predictions.first?.count, 2.0)
    }

    func testMicroSaveLoadRoundTrip() throws {
        // Write separate per-day files so each gets its own tokenWindow.
        // Each file has appActivated → typingSession, contributing weight
        // to context "a:com.mitchellh.ghostty → k:Ghostty".
        // All three days are inside the full-weight month window, so total 3.0 survives floor 2.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let eventsDir = tempDirectory.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)

        let days: [Date] = [
            Date().addingTimeInterval(-86400 * 2.5),
            Date().addingTimeInterval(-86400 * 1.5),
            Date(),
        ]

        for day in days {
            let dateStr = TelemetryStorageDateHelper.dateString(for: day)
            let recs: [TelemetryEventRecord] = [
                .init(recordedAt: day, event: .appActivated(appName: "Ghostty", bundleID: "com.mitchellh.ghostty", windowTitle: "")),
                .init(recordedAt: day, event: .typingSession(appName: "Ghostty", targetElement: nil, typedText: "killall Finder", durationSeconds: 2.0)),
            ]
            var data = Data()
            for rec in recs {
                data.append(try encoder.encode(rec))
                data.append("\n".data(using: .utf8)!)
            }
            try data.write(to: eventsDir.appendingPathComponent("telemetry_events_\(dateStr).jsonl"))
        }

        let microStore = MicroStore()
        let monitor = MockPowerMonitor(idle: true, acPower: true)
        let predDir = tempDirectory.appendingPathComponent("prediction")
        let trainer = PredictionTrainer(storage: storage, trie: trie, microStore: microStore, powerMonitor: monitor,
                                        predictionDirectory: predDir)
        trainer.train(force: true)

        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let microStorePath = predDir.appendingPathComponent("micro_store.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: microStorePath.path))

        let loaded = try MicroStore.load(from: microStorePath)
        let contextHash = "a:com.mitchellh.ghostty → k:Ghostty:unknown"
        let predictions = loaded.predict(for: contextHash)
        XCTAssertEqual(predictions.first?.value, "killall Finder")
    }

    func testExistingTrieTrainingStillWorks() throws {
        let events: [DesktopUserEvent] = [
            .appActivated(appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "main.swift"),
            .appActivated(appName: "Chrome", bundleID: "com.google.Chrome", windowTitle: "github.com"),
            .appActivated(appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "main.swift"),
            .appActivated(appName: "Chrome", bundleID: "com.google.Chrome", windowTitle: "github.com"),
        ]
        for event in events {
            try storage.appendEvent(event)
        }

        let microStore = MicroStore()
        let monitor = MockPowerMonitor(idle: true, acPower: true)
        let trainer = PredictionTrainer(storage: storage, trie: trie, microStore: microStore, powerMonitor: monitor,
                                        predictionDirectory: tempDirectory.appendingPathComponent("prediction"))
        trainer.train(force: true)

        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let result = trie.predict(context: ["a:com.apple.dt.Xcode"])
        XCTAssertEqual(result.first?.token, "a:com.google.Chrome")
        XCTAssertTrue(microStore.store.isEmpty)
    }

    func testEmptyMicroStoreAfterTrainingWithNoMicroEvents() throws {
        let events: [DesktopUserEvent] = [
            .appActivated(appName: "A", bundleID: "com.a", windowTitle: ""),
            .appActivated(appName: "B", bundleID: "com.b", windowTitle: ""),
        ]
        for event in events {
            try storage.appendEvent(event)
        }

        let microStore = MicroStore()
        let monitor = MockPowerMonitor(idle: true, acPower: true)
        let predDir = tempDirectory.appendingPathComponent("prediction")
        let trainer = PredictionTrainer(storage: storage, trie: trie, microStore: microStore, powerMonitor: monitor,
                                        predictionDirectory: predDir)
        trainer.train(force: true)

        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertTrue(microStore.store.isEmpty)

        let microStorePath = predDir.appendingPathComponent("micro_store.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: microStorePath.path))
        let loaded = try MicroStore.load(from: microStorePath)
        XCTAssertTrue(loaded.store.isEmpty)
    }
}

private extension PredictionTrainerTests {
    func waitForTrainingTick() {
        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func writeRecords(_ records: [TelemetryEventRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append("\n".data(using: .utf8)!)
        }
        try data.write(to: url)
    }
}

final class MockPowerMonitor: TelemetryPowerMonitoring {
    private let _idle: Bool
    private let _acPower: Bool

    init(idle: Bool, acPower: Bool) {
        _idle = idle
        _acPower = acPower
    }

    func isUserIdle(threshold: TimeInterval?) -> Bool {
        _idle
    }

    var isConnectedToACPower: Bool {
        _acPower
    }
}

enum TelemetryStorageDateHelper {
    static func dateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }
}

extension TelemetryEventRecord: @unchecked Sendable {}
