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

    @MainActor
    func testTypingSessionDebouncingAndAccumulation() throws {
        let keyEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!

        // Simulate multiple key presses
        collector.handleKeyPress(keyEvent)
        collector.handleKeyPress(keyEvent)
        collector.handleKeyPress(keyEvent)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: Date())

        // Verify that NO typing session is written to disk immediately (debounced)
        var events = try storage.loadEvents(forDateString: dateString)
        let hasTypingSession = events.contains { event in
            if case .typingSession = event { return true }
            return false
        }
        XCTAssertFalse(hasTypingSession, "Typing session should not be written to disk immediately due to debouncing")

        // Force a flush
        collector.flushActiveTypingSession()

        // Verify that exactly ONE typing session with a typedText of "aaa" was logged
        events = try storage.loadEvents(forDateString: dateString)
        let typingEvents = events.compactMap { event -> (String, String, Double)? in
            if case .typingSession(let app, let text, let duration) = event {
                return (app, text, duration)
            }
            return nil
        }

        XCTAssertEqual(typingEvents.count, 1, "Should have exactly one typing session logged")
        XCTAssertEqual(typingEvents.first?.1, "aaa", "Typed text should be 'aaa'")
        XCTAssertFalse(typingEvents.first?.0.isEmpty ?? true, "App name should not be empty")
    }

    @MainActor
    func testTypingSessionFlushesOnAppSwitch() throws {
        let keyEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "b",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 0
        )!

        collector.handleKeyPress(keyEvent)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: Date())

        // Calling pollWorkspaceState triggers a simulated app switch (since lastBundleID is initially empty)
        collector.pollWorkspaceState()

        let events = try storage.loadEvents(forDateString: dateString)
        let typingEvents = events.compactMap { event -> String? in
            if case .typingSession(_, let text, _) = event {
                return text
            }
            return nil
        }

        XCTAssertEqual(typingEvents.count, 1, "App switch should trigger automatic flush")
        XCTAssertEqual(typingEvents.first, "b", "Typed text should be 'b'")
    }

    @MainActor
    func testTypingSessionFlushesOnMouseClick() throws {
        let keyEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 0
        )!

        collector.handleKeyPress(keyEvent)

        let clickEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!

        // Simulate click
        collector.handleMouseClick(clickEvent)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: Date())

        let events = try storage.loadEvents(forDateString: dateString)
        let typingEvents = events.compactMap { event -> String? in
            if case .typingSession(_, let text, _) = event {
                return text
            }
            return nil
        }

        XCTAssertEqual(typingEvents.count, 1, "Mouse click should trigger automatic flush")
        XCTAssertEqual(typingEvents.first, "c", "Typed text should be 'c'")
     }

    @MainActor
    func testTypingSessionCapturesModifiersAndSpecialKeys() throws {
        let cmdAEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!

        let enterEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )!

        collector.handleKeyPress(cmdAEvent)
        collector.handleKeyPress(enterEvent)
        collector.flushActiveTypingSession()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: Date())

        let events = try storage.loadEvents(forDateString: dateString)
        let typingEvents = events.compactMap { event -> String? in
            if case .typingSession(_, let text, _) = event {
                return text
            }
            return nil
        }

        XCTAssertEqual(typingEvents.count, 1)
        XCTAssertEqual(typingEvents.first, "<Cmd+a><Enter>", "Modifiers and special keycodes should be formatted cleanly")
    }
}
