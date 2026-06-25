import XCTest
@testable import Casper

final class RuntimePredictorTests: XCTestCase {

    func testPredictionAboveThresholdPopulatesCurrentPrediction() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:com.xcode", "a:com.chrome"])
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.3)

        predictor.ingest(event: .appActivated(appName: "Xcode", bundleID: "com.xcode", windowTitle: ""))

        XCTAssertNotNil(predictor.currentPrediction)
        XCTAssertEqual(predictor.currentPrediction?.token, "a:com.chrome")
        XCTAssertGreaterThan(predictor.currentPrediction?.confidence ?? 0, 0.3)
    }

    func testPredictionBelowThresholdClearsPrediction() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:com.a", "a:com.b"])
        trie.insert(tokens: ["a:com.a", "a:com.c"])
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.9)

        predictor.ingest(event: .appActivated(appName: "A", bundleID: "com.a", windowTitle: ""))
        // context ["a:com.a"] → children: a:com.b (1), a:com.c (1) → confidence = 1/2 = 0.5 < 0.9
        XCTAssertNil(predictor.currentPrediction)
    }

    func testTokenNotInV1ScopeDoesNotChangePrediction() {
        let trie = PpmTrie()
        let predictor = RuntimePredictor(trie: trie)

        predictor.ingest(event: .typingSession(appName: "Xcode", targetElement: nil, typedText: "hello", durationSeconds: 1.0))

        XCTAssertNil(predictor.currentPrediction)
    }

    func testSlidingWindowCorrectAfterManyEvents() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:com.a", "a:com.b"])
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0)

        for i in 0..<6 {
            predictor.ingest(event: .appActivated(appName: "App\(i)", bundleID: "com.app\(i)", windowTitle: ""))
        }
    }

    func testSamePredictionNotReEmitted() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:com.a", "a:com.b"])
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0)

        predictor.ingest(event: .appActivated(appName: "A", bundleID: "com.a", windowTitle: ""))
        XCTAssertNotNil(predictor.currentPrediction)
    }

    func testEmptyTrieReturnsNil() {
        let trie = PpmTrie()
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0)

        predictor.ingest(event: .appActivated(appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: ""))

        XCTAssertNil(predictor.currentPrediction)
    }

    func testContextAdvancesWithoutPredictionClearsCurrent() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:com.a", "a:com.b"])
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0)

        predictor.ingest(event: .appActivated(appName: "A", bundleID: "com.a", windowTitle: ""))
        XCTAssertNotNil(predictor.currentPrediction)

        predictor.ingest(event: .mouseClicked(appName: "Finder", elementClicked: "AXButton", clickCount: 1, selectedText: nil))
    }

    func testPastePredictionForCopyToken() {
        let trie = PpmTrie()
        trie.insert(tokens: ["c:Xcode", "a:com.xcode"])
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.3)

        predictor.ingest(event: .textCopied(text: "git commit -m \"wip\""))
        predictor.ingest(event: .appActivated(appName: "Xcode", bundleID: "com.xcode", windowTitle: ""))
    }

    func testBundleIDToAppNameMapping() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:com.prefix", "a:com.editor"])
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0)

        predictor.ingest(event: .appActivated(appName: "MyEditor", bundleID: "com.editor", windowTitle: ""))
        predictor.ingest(event: .appActivated(appName: "Prefix", bundleID: "com.prefix", windowTitle: ""))

        XCTAssertEqual(predictor.currentPrediction?.displayTitle, "Switch to MyEditor")
    }

    // MARK: - U4 Micro Lookup Tests

    func testKTokenWithMicroHit() {
        let trie = PpmTrie()
        trie.insert(tokens: ["k:Ghostty:unknown", "k:Ghostty:unknown"])
        let microStore = MicroStore()
        microStore.record(value: "killall Finder", forContext: "k:Ghostty:unknown → k:Ghostty:unknown", weight: 5)
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0, microStore: microStore)

        predictor.ingest(event: .typingSession(appName: "Ghostty", targetElement: nil, typedText: "killall Finder", durationSeconds: 2.0))

        XCTAssertEqual(predictor.currentPrediction?.displayTitle, "Type \"killall Finder\" in Ghostty?")
        XCTAssertEqual(predictor.currentPrediction?.suggestedContent, "killall Finder")
        XCTAssertEqual(predictor.currentPrediction?.displayDescription, "5 times before")
    }

    func testMTokenWithMicroHit() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:com.chrome", "m:Chrome:AXButton"])
        let microStore = MicroStore()
        microStore.record(value: "AXButton (Title: Reload)", forContext: "a:com.chrome → m:Chrome:AXButton", weight: 3)
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0, microStore: microStore)

        predictor.ingest(event: .appActivated(appName: "Chrome", bundleID: "com.chrome", windowTitle: ""))

        XCTAssertEqual(predictor.currentPrediction?.displayTitle, "Click \"AXButton (Title: Reload)\" in Chrome?")
        XCTAssertEqual(predictor.currentPrediction?.suggestedContent, "AXButton (Title: Reload)")
    }

    func testKTokenWithoutMicroReturnsNil() {
        let trie = PpmTrie()
        trie.insert(tokens: ["k:Ghostty:unknown", "k:Ghostty:unknown"])
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0)

        predictor.ingest(event: .typingSession(appName: "Ghostty", targetElement: nil, typedText: "anything", durationSeconds: 1.0))

        XCTAssertNil(predictor.currentPrediction)
    }

    func testMTokenWithoutMicroReturnsNil() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:com.chrome", "m:Chrome:AXButton"])
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0)

        predictor.ingest(event: .appActivated(appName: "Chrome", bundleID: "com.chrome", windowTitle: ""))

        XCTAssertNil(predictor.currentPrediction)
    }

    func testATokenIgnoresMicroStore() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:com.xcode", "a:com.chrome"])
        let microStore = MicroStore()
        microStore.record(value: "irrelevant", forContext: "any context", weight: 10)
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0, microStore: microStore)

        predictor.ingest(event: .appActivated(appName: "Chrome", bundleID: "com.chrome", windowTitle: ""))
        predictor.ingest(event: .appActivated(appName: "Xcode", bundleID: "com.xcode", windowTitle: ""))

        XCTAssertEqual(predictor.currentPrediction?.displayTitle, "Switch to Chrome")
    }

    func testSpecificActionOutranksBareAppSwitch() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:com.xcode", "a:com.chrome"])
        trie.insert(tokens: ["a:com.xcode", "a:com.chrome"])
        trie.insert(tokens: ["a:com.xcode", "k:Ghostty:terminal"])

        let microStore = MicroStore()
        microStore.record(value: "git status", forContext: "a:com.xcode → k:Ghostty:terminal", weight: 1)
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0, microStore: microStore)

        predictor.ingest(event: .appActivated(appName: "Xcode", bundleID: "com.xcode", windowTitle: ""))

        XCTAssertEqual(predictor.currentPrediction?.token, "k:Ghostty:terminal")
        XCTAssertEqual(predictor.currentPrediction?.suggestedContent, "git status")
    }

    func testSpecificTerminalPredictionCanPassBelowGlobalThreshold() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:com.editor", "m:Editor:AXImage"])
        trie.insert(tokens: ["a:com.editor", "m:Editor:AXImage"])
        trie.insert(tokens: ["a:com.editor", "m:Editor:AXImage"])
        trie.insert(tokens: ["a:com.editor", "m:Editor:AXImage"])
        trie.insert(tokens: ["a:com.editor", "k:Editor:terminal"])

        let microStore = MicroStore()
        microStore.record(value: "git status", forContext: "a:com.editor → k:Editor:terminal", weight: 1)
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.5, microStore: microStore)

        predictor.ingest(event: .appActivated(appName: "Editor", bundleID: "com.editor", windowTitle: ""))

        XCTAssertEqual(predictor.currentPrediction?.token, "k:Editor:terminal")
        XCTAssertEqual(predictor.currentPrediction?.suggestedContent, "git status")
    }

    func testMicroValueBelowCountFloor() {
        let trie = PpmTrie()
        trie.insert(tokens: ["k:Ghostty:unknown", "k:Ghostty:unknown"])
        let microStore = MicroStore()
        microStore.record(value: "ls", forContext: "k:Ghostty:unknown → k:Ghostty:unknown", weight: 2)
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0, microStore: microStore)

        predictor.ingest(event: .typingSession(appName: "Ghostty", targetElement: nil, typedText: "ls", durationSeconds: 1.0))

        XCTAssertNil(predictor.currentPrediction)
    }

    func testMicroLookupUsesFullSlidingWindowContext() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:com.ghostty", "k:Ghostty:unknown", "k:Ghostty:unknown"])
        let microStore = MicroStore()
        microStore.record(value: "vim", forContext: "a:com.ghostty → k:Ghostty:unknown → k:Ghostty:unknown", weight: 5)
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0, microStore: microStore)

        predictor.ingest(event: .appActivated(appName: "Ghostty", bundleID: "com.ghostty", windowTitle: ""))
        predictor.ingest(event: .typingSession(appName: "Ghostty", targetElement: nil, typedText: "vim", durationSeconds: 1.0))

        XCTAssertEqual(predictor.currentPrediction?.displayTitle, "Type \"vim\" in Ghostty?")
        XCTAssertEqual(predictor.currentPrediction?.suggestedContent, "vim")
    }

    func testMicroEntryCountInfluencesOrdering() {
        let trie = PpmTrie()
        trie.insert(tokens: ["k:Ghostty:unknown", "k:Ghostty:unknown"])
        let microStore = MicroStore()
        microStore.record(value: "ls", forContext: "k:Ghostty:unknown → k:Ghostty:unknown", weight: 3)
        microStore.record(value: "vim", forContext: "k:Ghostty:unknown → k:Ghostty:unknown", weight: 5)
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0, microStore: microStore)

        predictor.ingest(event: .typingSession(appName: "Ghostty", targetElement: nil, typedText: "vim", durationSeconds: 1.0))

        XCTAssertEqual(predictor.currentPrediction?.suggestedContent, "vim")
    }

    func testKTokenUsesSuffixMicroLookup() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:com.xcode", "a:com.ghostty", "k:Ghostty:terminal"])
        let microStore = MicroStore()
        microStore.record(value: "git push", forContext: "a:com.ghostty → k:Ghostty:terminal", weight: 1)
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0, microStore: microStore)

        predictor.ingest(event: .appActivated(appName: "Xcode", bundleID: "com.xcode", windowTitle: ""))
        predictor.ingest(event: .appActivated(appName: "Ghostty", bundleID: "com.ghostty", windowTitle: ""))

        XCTAssertEqual(predictor.currentPrediction?.suggestedContent, "git push")
        XCTAssertEqual(predictor.currentPrediction?.displayDescription, "1 times before")
    }

    func testGenericKTokenStillRequiresMoreThanOneMicroHit() {
        let trie = PpmTrie()
        trie.insert(tokens: ["k:Slack:text_field", "k:Slack:text_field"])
        let microStore = MicroStore()
        microStore.record(value: "one-off message", forContext: "k:Slack:text_field → k:Slack:text_field", weight: 1)
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0, microStore: microStore)

        predictor.ingest(event: .typingSession(appName: "Slack", targetElement: "AXTextArea", typedText: "hello", durationSeconds: 1.0))

        XCTAssertNil(predictor.currentPrediction)
    }

    // MARK: - Action Chain Tests

    func testPredictActionChainsRollsForwardFromCurrentContext() {
        let trie = PpmTrie()
        trie.insert(tokens: [
            "a:com.apple.dt.Xcode",
            "a:com.mitchellh.ghostty",
            "k:Ghostty:unknown",
            "a:com.tinyspeck.slackmacgap",
        ])

        let microStore = MicroStore()
        microStore.record(
            value: "git push",
            forContext: "a:com.apple.dt.Xcode → a:com.mitchellh.ghostty → k:Ghostty:unknown",
            weight: 3
        )

        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0, microStore: microStore)
        predictor.ingest(event: .appActivated(appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: ""))

        let chains = predictor.predictActionChains(maxSteps: 3, beamWidth: 1)

        XCTAssertEqual(chains.first?.steps, [
            .activateApp(bundleID: "com.mitchellh.ghostty", appName: "com.mitchellh.ghostty"),
            .typeText(text: "git push", appName: "Ghostty"),
            .activateApp(bundleID: "com.tinyspeck.slackmacgap", appName: "com.tinyspeck.slackmacgap"),
        ])
    }

    func testPredictActionChainsRollsThroughNonActionTokens() {
        let trie = PpmTrie()
        trie.insert(tokens: [
            "a:com.apple.dt.Xcode",
            "t:Xcode",
            "a:com.mitchellh.ghostty",
        ])
        let predictor = RuntimePredictor(trie: trie, confidenceThreshold: 0.0)

        predictor.ingest(event: .appActivated(appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: ""))

        let chains = predictor.predictActionChains(maxSteps: 2, beamWidth: 1)

        XCTAssertTrue(chains.isEmpty)
    }
}
