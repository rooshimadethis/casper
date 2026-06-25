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

    func testShortTextCopyTokenizes() {
        let event = DesktopUserEvent.textCopied(text: "git commit -m \"fix\"")
        XCTAssertEqual(Tokenizer.tokenize(event, activeAppName: "Xcode"), "c:Xcode:git commit -m \"fix\"")
    }

    func testTextCopyOver80CharsReturnsNil() {
        let longText = String(repeating: "a", count: 100)
        let event = DesktopUserEvent.textCopied(text: longText)
        XCTAssertNil(Tokenizer.tokenize(event))
    }

    func testTextCopyLongTextIsTruncatedTo40Chars() {
        let text60 = String(repeating: "b", count: 60)
        let event = DesktopUserEvent.textCopied(text: text60)
        let result = Tokenizer.tokenize(event, activeAppName: "Xcode")
        XCTAssertEqual(result, "c:Xcode:" + String(repeating: "b", count: 40))
    }

    func testMouseClickExtractsRoleOnly() {
        let event = DesktopUserEvent.mouseClicked(
            appName: "Safari",
            elementClicked: "AXButton (Title: Reload)",
            clickCount: 1,
            selectedText: nil
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

    func testTypingSessionTokenizes() {
        let event = DesktopUserEvent.typingSession(
            appName: "Ghostty",
            targetElement: nil,
            typedText: "ls -la",
            durationSeconds: 2.0
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "k:Ghostty")
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

    func testMouseClickWithNoParentheses() {
        let event = DesktopUserEvent.mouseClicked(
            appName: "Terminal",
            elementClicked: "AXUnknown",
            clickCount: 1,
            selectedText: nil
        )
        XCTAssertEqual(Tokenizer.tokenize(event), "m:Terminal:AXUnknown")
    }

    func testTextCopyWithNoAppNameDefaultsToUnknown() {
        let event = DesktopUserEvent.textCopied(text: "hello")
        XCTAssertEqual(Tokenizer.tokenize(event), "c:unknown:hello")
    }

    func testTextCopyTruncatedWithWhitespace() {
        let event = DesktopUserEvent.textCopied(text: "  " + String(repeating: "x", count: 50) + "  ")
        let result = Tokenizer.tokenize(event, activeAppName: "Notes")
        XCTAssertEqual(result?.count, "c:Notes:".count + 40)
        XCTAssertTrue(result?.hasPrefix("c:Notes:") ?? false)
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
