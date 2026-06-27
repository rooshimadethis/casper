import XCTest
@testable import Casper

final class TelemetrySanitizerTests: XCTestCase {
    
    func testTelemetrySanitizerWithKnownIcons() {
        // U+EA60 -> add
        let input1 = "\u{EA60}"
        XCTAssertEqual(TelemetrySanitizer.sanitize(input1), "[Icon: add]")
        
        // U+EA61 -> lightbulb
        let input2 = "\u{EA61}"
        XCTAssertEqual(TelemetrySanitizer.sanitize(input2), "[Icon: lightbulb]")
        
        // U+EC10 -> sparkle
        let input3 = "\u{EC10}"
        XCTAssertEqual(TelemetrySanitizer.sanitize(input3), "[Icon: sparkle]")
        
        // U+EC1E -> copilot
        let input4 = "\u{EC1E}"
        XCTAssertEqual(TelemetrySanitizer.sanitize(input4), "[Icon: copilot]")
    }
    
    func testTelemetrySanitizerWithUnknownIcons() {
        // U+E001 -> PUA range but not in codicons map
        let input = "\u{E001}"
        XCTAssertEqual(TelemetrySanitizer.sanitize(input), "[Icon: U+E001]")
    }
    
    func testTelemetrySanitizerMixedStrings() {
        let input = "AXStaticText (Value: \u{EA60})"
        XCTAssertEqual(TelemetrySanitizer.sanitize(input), "AXStaticText (Value: [Icon: add])")
        
        let inputNoIcon = "Standard Text without icons"
        XCTAssertEqual(TelemetrySanitizer.sanitize(inputNoIcon), "Standard Text without icons")
    }
    
    func testDesktopUserEventSanitized() {
        let event = DesktopUserEvent.mouseClicked(
            appName: "Antigravity IDE",
            elementClicked: "AXStaticText (Value: \u{EA60})",
            clickCount: 1,
            selectedText: "\u{EA61}"
        )
        
        let sanitizedEvent = event.sanitized()
        
        if case .mouseClicked(let appName, let elementClicked, let clickCount, let selectedText) = sanitizedEvent {
            XCTAssertEqual(appName, "Antigravity IDE")
            XCTAssertEqual(elementClicked, "AXStaticText (Value: [Icon: add])")
            XCTAssertEqual(clickCount, 1)
            XCTAssertEqual(selectedText, "[Icon: lightbulb]")
        } else {
            XCTFail("Sanitized event case mismatch")
        }
    }

    func testDesktopUserEventSanitizedRightClick() {
        let event = DesktopUserEvent.rightMouseClicked(
            appName: "Antigravity IDE",
            elementClicked: "AXStaticText (Value: \u{EA60})",
            clickCount: 1
        )
        
        let sanitizedEvent = event.sanitized()
        
        if case .rightMouseClicked(let appName, let elementClicked, let clickCount) = sanitizedEvent {
            XCTAssertEqual(appName, "Antigravity IDE")
            XCTAssertEqual(elementClicked, "AXStaticText (Value: [Icon: add])")
            XCTAssertEqual(clickCount, 1)
        } else {
            XCTFail("Sanitized event case mismatch")
        }
    }
        
    func testTypingEventSanitized() {
        let typingEvent = DesktopUserEvent.typingSession(
            appName: "VS Code \u{EC1E}",
            targetElement: "Editor \u{EC10}",
            typedText: "Hello \u{EA60}",
            durationSeconds: 1.5
        )
        
        if case .typingSession(let appName, let targetElement, let typedText, let durationSeconds) = typingEvent.sanitized() {
            XCTAssertEqual(appName, "VS Code [Icon: copilot]")
            XCTAssertEqual(targetElement, "Editor [Icon: sparkle]")
            XCTAssertEqual(typedText, "Hello [Icon: add]")
            XCTAssertEqual(durationSeconds, 1.5)
        } else {
            XCTFail("Sanitized typing event case mismatch")
        }
    }
    
    func testTelemetryStorageAutoSanitizes() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        
        let storage = TelemetryStorage(storageDirectory: tempDirectory)
        let event = DesktopUserEvent.textCopied(text: "Copied \u{EC10}")
        try storage.appendEvent(event)
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: Date())
        
        let loaded = try storage.loadEvents(forDateString: dateString)
        XCTAssertEqual(loaded.count, 1)
        
        if case .textCopied(let text) = loaded[0] {
            XCTAssertEqual(text, "Copied [Icon: sparkle]")
        } else {
            XCTFail("Saved event was not textCopied or did not roundtrip")
        }
    }
}
