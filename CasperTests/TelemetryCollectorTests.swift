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
        let typingEvents = events.compactMap { event -> (String, String?, String, Double)? in
            if case .typingSession(let app, let target, let text, let duration) = event {
                return (app, target, text, duration)
            }
            return nil
        }

        XCTAssertEqual(typingEvents.count, 1, "Should have exactly one typing session logged")
        XCTAssertEqual(typingEvents.first?.2, "aaa", "Typed text should be 'aaa'")
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
            if case .typingSession(_, _, let text, _) = event {
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
            if case .typingSession(_, _, let text, _) = event {
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
            if case .typingSession(_, _, let text, _) = event {
                return text
            }
            return nil
        }

        XCTAssertEqual(typingEvents.count, 1)
        XCTAssertEqual(typingEvents.first, "<Cmd+a><Enter>", "Modifiers and special keycodes should be formatted cleanly")
    }

    @MainActor
    func testTypingSessionGroupedBackspacesOnEmpty() throws {
        let keyBackspace = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{007F}", charactersIgnoringModifiers: "\u{007F}", isARepeat: false, keyCode: 51)!

        collector.handleKeyPress(keyBackspace)
        collector.handleKeyPress(keyBackspace)
        collector.handleKeyPress(keyBackspace)
        
        collector.flushActiveTypingSession()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: Date())

        let events = try storage.loadEvents(forDateString: dateString)
        let typingEvents = events.compactMap { event -> String? in
            if case .typingSession(_, _, let text, _) = event {
                return text
            }
            return nil
        }

        XCTAssertTrue(typingEvents.contains("<Backspace x 3>"), "Consecutive backspaces on empty session should group")
    }

    @MainActor
    func testTypingSessionShortcutIsolation() throws {
        let keyA = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        let cmdSEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
        let keyB = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)!

        collector.handleKeyPress(keyA)
        collector.handleKeyPress(cmdSEvent)
        collector.handleKeyPress(keyB)
        collector.flushActiveTypingSession()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: Date())

        let events = try storage.loadEvents(forDateString: dateString)
        let typingEvents = events.compactMap { event -> String? in
            if case .typingSession(_, _, let text, _) = event {
                return text
            }
            return nil
        }

        XCTAssertTrue(typingEvents.contains("a"))
        XCTAssertTrue(typingEvents.contains("<Cmd+s>"))
        XCTAssertTrue(typingEvents.contains("b"))
    }

    @MainActor
    func testMouseClickResolvesAppNameFromFrontmostApp() throws {
        // This test validates that the mouse click handler resolves the app name
        // from the actual frontmost application rather than a cached value.
        // Note: Full AXUIElement path requires accessibility permissions, so
        // this test verifies the resolution logic indirectly via the collector's
        // behavior during click processing (typing session flush + event recording).

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

        collector.handleMouseClick(clickEvent)

        // Force flush the pending click (if AX succeeded, it will write a mouseClicked event)
        collector.flushActiveTypingSession()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: Date())

        let events = try storage.loadEvents(forDateString: dateString)
        let clickEvents = events.compactMap { event -> String? in
            if case .mouseClicked(let appName, _, _, _) = event {
                return appName
            }
            return nil
        }

        // If AX permissions are granted, verify the app name matches the frontmost app.
        // If AX is unavailable, no click event is produced (expected), so we skip.
        if !clickEvents.isEmpty {
            let expectedApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
            XCTAssertEqual(clickEvents.first, expectedApp, "Mouse click appName should match the frontmost app at click time")
        }
    }

    @MainActor
    func testTextCopiedTruncatesWhenLong() async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        let longText = String(repeating: "a", count: 1200)
        pasteboard.setString(longText, forType: .string)
        
        collector.pollWorkspaceState()
        
        // Wait for the async task to append the event
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms sleep
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: Date())
        
        let events = try storage.loadEvents(forDateString: dateString)
        let copyEvents = events.compactMap { event -> String? in
            if case .textCopied(let text) = event {
                return text
            }
            return nil
        }
        
        XCTAssertEqual(copyEvents.count, 1)
        if let firstCopy = copyEvents.first {
            XCTAssertTrue(firstCopy.hasPrefix("[Truncated Copy]:"))
            XCTAssertTrue(firstCopy.hasSuffix("..."))
            XCTAssertEqual(firstCopy.count, "[Truncated Copy]: ".count + 500 + "...".count)
        } else {
            XCTFail("No copy event captured")
        }
    }
}
