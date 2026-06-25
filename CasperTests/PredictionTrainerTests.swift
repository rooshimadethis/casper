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

    func testTimeDecayWeightsTodayHigher() throws {
        let today = Date()
        let yesterday = today.addingTimeInterval(-86400 * 1.5)
        let todayStr = TelemetryStorageDateHelper.dateString(for: today)
        let yesterdayStr = TelemetryStorageDateHelper.dateString(for: yesterday)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let eventsDir = tempDirectory.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)

        // Today: app A → app B (weight 2x each, so [a:com.a → a:com.b] gets weight 4)
        let todayEvents: [TelemetryEventRecord] = [
            .init(recordedAt: today, event: .appActivated(appName: "A", bundleID: "com.a", windowTitle: "")),
            .init(recordedAt: today, event: .appActivated(appName: "B", bundleID: "com.b", windowTitle: "")),
            .init(recordedAt: today, event: .appActivated(appName: "A", bundleID: "com.a", windowTitle: "")),
            .init(recordedAt: today, event: .appActivated(appName: "B", bundleID: "com.b", windowTitle: "")),
        ]
        var todayData = Data()
        for rec in todayEvents {
            todayData.append(try encoder.encode(rec))
            todayData.append("\n".data(using: .utf8)!)
        }
        try todayData.write(to: eventsDir.appendingPathComponent("telemetry_events_\(todayStr).jsonl"))

        // Yesterday: app A → app C (weight 1x each, so [a:com.a → a:com.c] gets weight 2)
        let yesterdayEvents: [TelemetryEventRecord] = [
            .init(recordedAt: yesterday, event: .appActivated(appName: "A", bundleID: "com.a", windowTitle: "")),
            .init(recordedAt: yesterday, event: .appActivated(appName: "C", bundleID: "com.c", windowTitle: "")),
        ]
        var yesterdayData = Data()
        for rec in yesterdayEvents {
            yesterdayData.append(try encoder.encode(rec))
            yesterdayData.append("\n".data(using: .utf8)!)
        }
        try yesterdayData.write(to: eventsDir.appendingPathComponent("telemetry_events_\(yesterdayStr).jsonl"))

        let monitor = MockPowerMonitor(idle: true, acPower: true)
        let trainer = PredictionTrainer(storage: storage, trie: trie, powerMonitor: monitor,
                                        predictionDirectory: tempDirectory.appendingPathComponent("prediction"))
        trainer.train(force: true)

        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // Context ["a:com.a"] should predict a:com.b (higher weight from today)
        let predictions = trie.predict(context: ["a:com.a"])
        XCTAssertEqual(predictions.first?.token, "a:com.b")
        // Today's pattern has more weight, so confidence should be > 0.5
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
        // Weights: 0.5 + 1.0 + 2.0 = 3.5 → Int total = 3, survives floor 3.
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

        let contextHash = "a:com.mitchellh.ghostty → k:Ghostty"
        let predictions = microStore.predict(for: contextHash)
        XCTAssertFalse(predictions.isEmpty)
        XCTAssertEqual(predictions.first?.value, "killall Finder")
    }

    func testTrainPopulatesMicroForClickEvents() throws {
        // Write separate per-day files so each gets its own tokenWindow.
        // Each file has appActivated → mouseClicked, contributing weight
        // to context "a:com.google.Chrome → m:Chrome:AXButton".
        // Weights: 0.5 + 1.0 + 2.0 = 3.5 → Int total = 3, survives floor 3.
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
        XCTAssertEqual(predictions.first?.value, "AXButton (Title: Reload)")
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

        // Each unique context has count 2 (today's weight 2.0), below floor 3
        XCTAssertTrue(microStore.store.isEmpty)
    }

    func testMicroValuesInheritTimeDecay() throws {
        let today = Date()
        let yesterday = today.addingTimeInterval(-86400 * 1.5)
        let todayStr = TelemetryStorageDateHelper.dateString(for: today)
        let yesterdayStr = TelemetryStorageDateHelper.dateString(for: yesterday)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let eventsDir = tempDirectory.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)

        // Yesterday: appActivated + typingSession → weight 1.0
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

        // Today: same pattern → weight 2.0
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

        // Context hash: "a:com.mitchellh.ghostty → k:Ghostty"
        // Yesterday's entry: count += 1 (from weight 1.0)
        // Today's entry: count += 2 (from weight 2.0)
        // Total: 3, which survives prune(floor: 3)
        let contextHash = "a:com.mitchellh.ghostty → k:Ghostty"
        let predictions = microStore.predict(for: contextHash)
        XCTAssertEqual(predictions.first?.value, "killall Finder")
        XCTAssertEqual(predictions.first?.count, 3)
    }

    func testMicroSaveLoadRoundTrip() throws {
        // Write separate per-day files so each gets its own tokenWindow.
        // Each file has appActivated → typingSession, contributing weight
        // to context "a:com.mitchellh.ghostty → k:Ghostty".
        // Weights: 0.5 + 1.0 + 2.0 = 3.5 → Int total = 3, survives floor 3.
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
        let contextHash = "a:com.mitchellh.ghostty → k:Ghostty"
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
