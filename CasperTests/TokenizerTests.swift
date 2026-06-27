import XCTest
@testable import Casper

final class TokenizerTests: XCTestCase {

    func testAppActivationTokenizesToBundleID() {
        let event = DesktopUserEvent.appActivated(
            appName: "Xcode",
            bundleID: "com.apple.dt.Xcode",
            windowTitle: "main.swift"
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "a:com.apple.dt.Xcode")
    }

    func testTextCopyTokenizesToAppOnly() {
        let event = DesktopUserEvent.textCopied(text: "git commit -m \"fix\"")
        XCTAssertEqual(Tokenizer.tokenize(event, activeAppName: "Xcode"), "c:Xcode")
    }

    func testTextCopyAnyLengthStillTokenizes() {
        let longText = String(repeating: "a", count: 1000)
        let event = DesktopUserEvent.textCopied(text: longText)
        XCTAssertEqual(Tokenizer.tokenize(event, activeAppName: "Xcode"), "c:Xcode")
    }

    func testTextCopyWithNoAppNameDefaultsToUnknown() {
        let event = DesktopUserEvent.textCopied(text: "hello")
        XCTAssertEqual(Tokenizer.tokenize(event), "c:unknown")
    }

    func testMouseClickWithoutSelectionProducesMToken() {
        let event = DesktopUserEvent.mouseClicked(
            appName: "Safari",
            elementClicked: "AXButton (Title: Reload)",
            clickCount: 1,
            selectedText: nil
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "m:Safari:AXButton")
    }

    func testRightMouseClickProducesRToken() {
        let event = DesktopUserEvent.rightMouseClicked(
            appName: "Safari",
            elementClicked: "AXButton (Title: Reload)",
            clickCount: 1
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "r:Safari:AXButton")
    }

    func testMouseClickWithSelectionProducesSToken() {
        let event = DesktopUserEvent.mouseClicked(
            appName: "Safari",
            elementClicked: "AXButton (Title: Reload)",
            clickCount: 1,
            selectedText: "selected text"
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "s:Safari:AXButton")
    }

    func testMouseClickWithEmptySelectionProducesMToken() {
        let event = DesktopUserEvent.mouseClicked(
            appName: "Safari",
            elementClicked: "AXButton (Title: Reload)",
            clickCount: 1,
            selectedText: "   "
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "m:Safari:AXButton")
    }

    func testMouseClickWithUnknownRolePattern() {
        let event = DesktopUserEvent.mouseClicked(
            appName: "Finder",
            elementClicked: "AXUnknown",
            clickCount: 1,
            selectedText: nil
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "m:Finder:AXUnknown")
    }

    func testMouseClickWithNoParentheses() {
        let event = DesktopUserEvent.mouseClicked(
            appName: "Terminal",
            elementClicked: "AXUnknown",
            clickCount: 1,
            selectedText: nil
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "m:Terminal:AXUnknown")
    }

    func testTypingInTerminalTokenizesWithElementType() {
        let event = DesktopUserEvent.typingSession(
            appName: "Ghostty",
            targetElement: "AXTextField (Description: Terminal 12, zsh)",
            typedText: "ls -la",
            durationSeconds: 2.0
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "k:Ghostty:terminal")
    }

    func testTypingWithNilTargetDefaultsToUnknown() {
        let event = DesktopUserEvent.typingSession(
            appName: "Ghostty",
            targetElement: nil,
            typedText: "ls",
            durationSeconds: 2.0
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "k:Ghostty:unknown")
    }

    func testTypingInSourceControlTokenizes() {
        let event = DesktopUserEvent.typingSession(
            appName: "Antigravity IDE",
            targetElement: "AXTextArea (Description: Message (⌘Enter to commit))",
            typedText: "fix bug",
            durationSeconds: 3.0
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "k:Antigravity IDE:source_control")
    }

    func testWindowTitleChangeTokenizes() {
        let event = DesktopUserEvent.windowTitleChanged(
            appName: "Terminal",
            windowTitle: "bash"
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "t:Terminal")
    }

    func testUserHesitatedReturnsTokenForMediumDuration() {
        let event = DesktopUserEvent.userHesitated(
            appName: "Xcode",
            durationSeconds: 4.5
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "h:Xcode:short")
    }

    func testAppStalledReturnsNil() {
        let event = DesktopUserEvent.appStalled(
            appName: "Xcode",
            durationSeconds: 30.0
        )
        XCTAssertNil(Tokenizer.tokenize(event))
    }

    func testCommandExecutedSuccessTokenizes() {
        let event = DesktopUserEvent.commandExecuted(
            command: "ls",
            exitCode: 0,
            output: nil
        )
        XCTAssertEqual(Tokenizer.tokenize(event, activeAppName: "Terminal"), "x:Terminal:success")
    }

    func testCustomInputReturnsNil() {
        let event = DesktopUserEvent.customInput(prompt: "hello")
        XCTAssertNil(Tokenizer.tokenize(event))
    }

    func testScreenOcrCapturedReturnsNil() {
        let event = DesktopUserEvent.screenOcrCaptured(text: "some text")
        XCTAssertNil(Tokenizer.tokenize(event))
    }

    func testUserHesitatedUnder3sReturnsNil() {
        let event = DesktopUserEvent.userHesitated(
            appName: "Xcode",
            durationSeconds: 2.9
        )
        XCTAssertNil(Tokenizer.tokenize(event))
    }

    func testUserHesitatedBoundaryAtExactly3s() {
        let event = DesktopUserEvent.userHesitated(
            appName: "Xcode",
            durationSeconds: 3.0
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "h:Xcode:short")
    }

    func testUserHesitatedBoundaryAtExactly5s() {
        let event = DesktopUserEvent.userHesitated(
            appName: "Xcode",
            durationSeconds: 5.0
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "h:Xcode:medium")
    }

    func testUserHesitatedShortDuration() {
        let event = DesktopUserEvent.userHesitated(
            appName: "Xcode",
            durationSeconds: 3.5
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "h:Xcode:short")
    }

    func testUserHesitatedLongDuration() {
        let event = DesktopUserEvent.userHesitated(
            appName: "Xcode",
            durationSeconds: 10.0
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "h:Xcode:long")
    }

    func testCommandExecutedFailureTokenizes() {
        let event = DesktopUserEvent.commandExecuted(
            command: "ls",
            exitCode: 1,
            output: "error"
        )
        XCTAssertEqual(Tokenizer.tokenize(event, activeAppName: "Terminal"), "x:Terminal:failure")
    }

    func testCommandExecutedWithNoAppNameDefaultsToUnknown() {
        let event = DesktopUserEvent.commandExecuted(
            command: "ls",
            exitCode: 0,
            output: nil
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "x:unknown:success")
    }
}
