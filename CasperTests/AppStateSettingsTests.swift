import XCTest
import SwiftUI
@testable import Casper

@MainActor
final class AppStateSettingsTests: XCTestCase {

    override func tearDown() {
        resetPermissionCheckerAfterTest()
        super.tearDown()
    }

    // MARK: - App Status

    func testAppStateInitialStatus() {
        XCTAssertEqual(AppStatus.ready.rawValue, "Ready")
        XCTAssertEqual(AppStatus.recording.rawValue, "Recording...")
        XCTAssertEqual(AppStatus.transcribing.rawValue, "Transcribing...")
        XCTAssertEqual(AppStatus.error.rawValue, "Error")
    }

    func testEmptyTranscriptionDispositionCancelsSubThresholdRecordings() {
        XCTAssertEqual(
            AppState.emptyTranscriptionDisposition(forAudioSampleCount: 7_999),
            .cancel
        )
    }

    func testEmptyTranscriptionDispositionShowsNoSoundDetectedAtThresholdAndAbove() {
        XCTAssertEqual(
            AppState.emptyTranscriptionDisposition(forAudioSampleCount: 8_000),
            .showNoSoundDetected
        )
        XCTAssertEqual(
            AppState.emptyTranscriptionDisposition(forAudioSampleCount: 9_600),
            .showNoSoundDetected
        )
    }

    func testNoSoundDetectedOverlayMessageUsesExpectedCopy() {
        XCTAssertEqual(OverlayMessage.noSoundDetected.primaryText, "No sound detected")
        XCTAssertEqual(
            OverlayMessage.noSoundDetected.secondaryText,
            "Check your mic in Settings \u{2192} Recording"
        )
    }

    func testClipboardFallbackOverlayMessageUsesExpectedCopy() {
        XCTAssertEqual(OverlayMessage.clipboardFallback.primaryText, "Copied to clipboard")
        XCTAssertEqual(OverlayMessage.clipboardFallback.secondaryText, "\u{2318}V to paste")
    }

    func testOverlayHostingViewDoesNotManageWindowSizingConstraints() {
        let overlay = RecordingOverlayController()
        overlay.show(message: .recording)
        defer { overlay.dismiss() }

        let panel: NSPanel? = unwrapPrivateOptional(named: "panel", from: overlay)
        let hostingView: NSHostingView<OverlayPillView>? = unwrapPrivateOptional(
            named: "hostingView",
            from: overlay
        )

        XCTAssertNotNil(panel)
        XCTAssertNotNil(hostingView)
        XCTAssertEqual(hostingView?.sizingOptions, [])
        XCTAssertFalse(panel?.contentView is NSHostingView<OverlayPillView>)
    }

    // MARK: - Hotkey Bindings

    func testAppStateLoadsDefaultShortcutBindingsIntoHotkeyMonitor() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(hotkeyMonitor: monitor, chordBindingStore: ChordBindingStore(defaults: defaults))

        await appState.startHotkeyMonitor()

        XCTAssertEqual(monitor.updatedBindings[.pushToTalk], AppState.defaultPushToTalkChord)
        XCTAssertEqual(monitor.updatedBindings[.toggleToTalk], AppState.defaultToggleToTalkChord)
    }

    func testAppStateWiresPushAndToggleCallbacksIntoHotkeyMonitor() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(hotkeyMonitor: monitor, chordBindingStore: ChordBindingStore(defaults: defaults))

        await appState.startHotkeyMonitor()

        XCTAssertNotNil(monitor.onPushToTalkStart)
        XCTAssertNotNil(monitor.onPushToTalkStop)
        XCTAssertNotNil(monitor.onToggleToTalkStart)
        XCTAssertNotNil(monitor.onToggleToTalkStop)
    }

    func testAppStateStartHotkeyMonitorSkipsRepeatedStartAfterSuccess() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(
            hotkeyMonitor: monitor,
            chordBindingStore: ChordBindingStore(defaults: defaults),
            inputMonitoringChecker: { true }
        )

        await appState.startHotkeyMonitor()
        await appState.startHotkeyMonitor()

        XCTAssertEqual(monitor.startCallCount, 1)
    }

    func testAppStateStartHotkeyMonitorPromptsForInputMonitoringButStillStartsWhenMonitorCanRun() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        var requestCount = 0
        let appState = AppState(
            hotkeyMonitor: monitor,
            chordBindingStore: ChordBindingStore(defaults: defaults),
            inputMonitoringChecker: { false },
            inputMonitoringPrompter: { requestCount += 1 }
        )

        await appState.startHotkeyMonitor()

        XCTAssertEqual(monitor.startCallCount, 1)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(appState.status, .ready)
        XCTAssertNil(appState.errorMessage)
    }

    func testAppStateUpdateShortcutRefreshesHotkeyMonitorBindings() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(hotkeyMonitor: monitor, chordBindingStore: ChordBindingStore(defaults: defaults))
        let newChord = try XCTUnwrap(KeyChord(keys: Set([
            PhysicalKey(keyCode: 54),
            PhysicalKey(keyCode: 61),
            PhysicalKey(keyCode: 53)
        ])))

        appState.updateShortcut(newChord, for: .pushToTalk)

        XCTAssertEqual(appState.pushToTalkChord, newChord)
        XCTAssertEqual(monitor.updatedBindings[.pushToTalk], newChord)
    }

    func testAppStateUpdateShortcutRejectsDuplicateBindings() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(hotkeyMonitor: monitor, chordBindingStore: ChordBindingStore(defaults: defaults))
        let originalToggleChord = appState.toggleToTalkChord

        appState.updateShortcut(AppState.defaultPushToTalkChord, for: .toggleToTalk)

        XCTAssertEqual(appState.toggleToTalkChord, originalToggleChord)
        XCTAssertEqual(monitor.updatedBindings[.toggleToTalk], originalToggleChord)
        XCTAssertEqual(appState.shortcutErrorMessage, "That shortcut is already in use.")
    }

    // MARK: - Cleanup Backend

    func testAppStateLoadsPersistedCleanupBackendSelection() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defaults.set("foundationModels", forKey: "cleanupBackend")

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertEqual(appState.cleanupBackend, .localModels)
    }

    func testAppStateUpdateCleanupBackendPersistsAndUpdatesTextCleaner() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.updateCleanupBackend(.localModels)

        XCTAssertEqual(appState.cleanupBackend, .localModels)
        XCTAssertEqual(
            defaults.string(forKey: "cleanupBackend"),
            CleanupBackendOption.localModels.rawValue
        )
    }

    // MARK: - PepperChat

    func testAppStateDefaultsPepperChatToEnabledWhenZoTokenAlreadyStored() throws {
        try withClearedPepperChatAppStorage {
            UserDefaults.standard.set("zo_sk_existing", forKey: "pepperChatApiKey")

            let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
            defaults.removePersistentDomain(forName: #function)
            let appState = AppState(
                hotkeyMonitor: FakeHotkeyMonitor(),
                chordBindingStore: ChordBindingStore(defaults: defaults),
                cleanupSettingsDefaults: defaults
            )

            XCTAssertTrue(appState.pepperChatEnabled)
        }
    }

    func testAppStateDefaultsPepperChatToDisabledWithoutZoToken() throws {
        try withClearedPepperChatAppStorage {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
            defaults.removePersistentDomain(forName: #function)
            let appState = AppState(
                hotkeyMonitor: FakeHotkeyMonitor(),
                chordBindingStore: ChordBindingStore(defaults: defaults),
                cleanupSettingsDefaults: defaults
            )

            XCTAssertFalse(appState.pepperChatEnabled)
        }
    }

    func testAppStateUsesStoredPepperChatToggleOverZoTokenBackCompatDefault() throws {
        try withClearedPepperChatAppStorage {
            UserDefaults.standard.set("zo_sk_existing", forKey: "pepperChatApiKey")
            UserDefaults.standard.set(false, forKey: "pepperChatEnabled")

            let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
            defaults.removePersistentDomain(forName: #function)
            let appState = AppState(
                hotkeyMonitor: FakeHotkeyMonitor(),
                chordBindingStore: ChordBindingStore(defaults: defaults),
                cleanupSettingsDefaults: defaults
            )

            XCTAssertFalse(appState.pepperChatEnabled)
        }
    }

    func testAppStateStartHotkeyMonitorOmitsPepperChatBindingWhenDisabled() async throws {
        try await withClearedPepperChatAppStorage {
            UserDefaults.standard.set(false, forKey: "pepperChatEnabled")

            let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
            defaults.removePersistentDomain(forName: #function)
            let monitor = FakeHotkeyMonitor()
            let appState = AppState(
                hotkeyMonitor: monitor,
                chordBindingStore: ChordBindingStore(defaults: defaults)
            )

            await appState.startHotkeyMonitor()

            XCTAssertNil(monitor.updatedBindings[.pepperChat])
        }
    }

    func testAppStateDoesNotStartPepperChatRecordingWhenDisabled() throws {
        try withClearedPepperChatAppStorage {
            UserDefaults.standard.set(false, forKey: "pepperChatEnabled")
            UserDefaults.standard.set("zo_sk_existing", forKey: "pepperChatApiKey")

            let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
            defaults.removePersistentDomain(forName: #function)
            let appState = AppState(
                hotkeyMonitor: FakeHotkeyMonitor(),
                chordBindingStore: ChordBindingStore(defaults: defaults),
                cleanupSettingsDefaults: defaults
            )

            appState.beginPepperChatRecording()

            XCTAssertFalse(appState.pepperChatSession.isRecording)
        }
    }

    // MARK: - Speech Model

    func testSpeechModelPresentationDoesNotExposeManagerLoadFailureInMenuErrorMessage() {
        let loadError = NSError(
            domain: NSURLErrorDomain,
            code: -1001,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
        )

        let next = AppState.nextSpeechModelPresentation(
            managerState: .error,
            managerError: loadError,
            currentStatus: .ready,
            currentErrorMessage: nil
        )

        XCTAssertEqual(next.status, .error)
        XCTAssertNil(next.errorMessage)
    }

    func testSpeechModelPresentationClearsStaleSpeechModelErrorAfterSuccessfulLoad() {
        let next = AppState.nextSpeechModelPresentation(
            managerState: .ready,
            managerError: nil,
            currentStatus: .error,
            currentErrorMessage: "Failed to load speech model: The request timed out."
        )

        XCTAssertEqual(next.status, .ready)
        XCTAssertNil(next.errorMessage)
    }

    func testSpeechModelPresentationPreservesUnrelatedErrorAfterSuccessfulLoad() {
        let next = AppState.nextSpeechModelPresentation(
            managerState: .ready,
            managerError: nil,
            currentStatus: .error,
            currentErrorMessage: "Accessibility access required \u{2014} grant permission then click Retry"
        )

        XCTAssertEqual(next.status, .error)
        XCTAssertEqual(
            next.errorMessage,
            "Accessibility access required \u{2014} grant permission then click Retry"
        )
    }

    // MARK: - Preferences

    func testAppStatePersistsIgnoreOtherSpeakersPreference() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defaults.set(true, forKey: "ignoreOtherSpeakers")

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertTrue(appState.ignoreOtherSpeakers)

        appState.ignoreOtherSpeakers = false

        XCTAssertEqual(defaults.object(forKey: "ignoreOtherSpeakers") as? Bool, false)
    }

    func testAppStateDefaultsPostPasteLearningToEnabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertTrue(appState.postPasteLearningEnabled)
        XCTAssertTrue(appState.postPasteLearningCoordinator.learningEnabled)
    }

    func testRecordingSettingsDisablesIgnoreOtherSpeakersForWhisperModels() {
        let parakeetState = RecordingSpeakerFilteringToggleState(
            speechModel: SpeechModelCatalog.parakeetV3
        )
        let whisperState = RecordingSpeakerFilteringToggleState(
            speechModel: SpeechModelCatalog.whisperSmallEnglish
        )

        XCTAssertTrue(parakeetState.isVisible)
        XCTAssertTrue(parakeetState.isEnabled)
        XCTAssertTrue(whisperState.isVisible)
        XCTAssertFalse(whisperState.isEnabled)
    }

    func testAppStateUpdatePostPasteLearningPersistsAndUpdatesCoordinator() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.postPasteLearningEnabled = false

        XCTAssertFalse(appState.postPasteLearningEnabled)
        XCTAssertFalse(appState.postPasteLearningCoordinator.learningEnabled)
        XCTAssertEqual(defaults.object(forKey: "postPasteLearningEnabled") as? Bool, false)
    }

    func testAppStateDefaultsSoundsEnabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertTrue(appState.playSounds)
    }

    func testAppStatePersistsSoundPreference() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.playSounds = false

        XCTAssertFalse(appState.playSounds)
        XCTAssertEqual(defaults.object(forKey: "playSounds") as? Bool, false)

        let reloadedAppState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertFalse(reloadedAppState.playSounds)
    }

    func testSoundEffectsSkipPlaybackWhenDisabled() {
        var startPlayCount = 0
        var stopPlayCount = 0
        let soundEffects = SoundEffects(
            isEnabled: { false },
            startPlayer: { startPlayCount += 1 },
            stopPlayer: { stopPlayCount += 1 }
        )

        soundEffects.playStart()
        soundEffects.playStop()

        XCTAssertEqual(startPlayCount, 0)
        XCTAssertEqual(stopPlayCount, 0)
    }

    func testAppStateRelaunchAppUsesConfiguredRelauncher() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let relauncher = FakeAppRelauncher()
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            appRelauncher: relauncher
        )

        appState.relaunchApp()

        XCTAssertEqual(relauncher.relaunchCallCount, 1)
        XCTAssertNil(appState.errorMessage)
    }

    func testAppStateRelaunchAppSurfacesRelaunchFailures() throws {
        struct RelaunchError: LocalizedError {
            var errorDescription: String? { "open failed" }
        }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let relauncher = FakeAppRelauncher()
        relauncher.error = RelaunchError()
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            appRelauncher: relauncher
        )

        appState.relaunchApp()

        XCTAssertEqual(relauncher.relaunchCallCount, 1)
        XCTAssertEqual(appState.errorMessage, "Failed to relaunch Casper: open failed")
    }

    func testAppStateShortcutCaptureSuspendsHotkeyMonitor() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(
            hotkeyMonitor: monitor,
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.setShortcutCaptureActive(true)
        appState.setShortcutCaptureActive(false)

        XCTAssertEqual(monitor.suspendedStates, [true, false])
    }

    // MARK: - Corrections

    func testAppStateLoadsPersistedCorrectionSettingsIntoStore() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let seededStore = CorrectionStore(defaults: defaults)
        seededStore.preferredTranscriptionsText = "Casper\nJesse"
        seededStore.commonlyMisheardText = "just see -> Jesse"

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertEqual(appState.correctionStore.preferredTranscriptions, ["Casper", "Jesse"])
        XCTAssertEqual(
            appState.correctionStore.commonlyMisheard,
            [MisheardReplacement(wrong: "just see", right: "Jesse")]
        )
    }

    func testAppStateUsesPreferredTranscriptionsAsOCRCustomWords() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        appState.correctionStore.preferredTranscriptionsText = "Casper\nJesse"

        XCTAssertEqual(appState.ocrCustomWords, ["Casper", "Jesse"])
    }

    func testAppStateLoadsLocalCleanupModelsWhenCleanupIsEnabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        appState.cleanupEnabled = true

        XCTAssertTrue(appState.shouldLoadLocalCleanupModels)
    }

    func testAppStateRecordsCleanupDebugSnapshotOnlyWhileDebugViewerIsOpen() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let debugLogStore = makeDebugLogStore()
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            debugLogStore: debugLogStore
        )

        appState.recordCleanupDebugSnapshot(
            rawTranscription: "raw text",
            windowContext: OCRContext(windowContents: "window text"),
            cleanedOutput: "cleaned text",
            attemptedCleanup: true
        )
        XCTAssertTrue(debugLogStore.formattedText.isEmpty)

        debugLogStore.beginLiveViewing()
        appState.recordCleanupDebugSnapshot(
            rawTranscription: "raw text",
            windowContext: OCRContext(windowContents: "window text"),
            cleanedOutput: "cleaned text",
            attemptedCleanup: true
        )
        debugLogStore.endLiveViewing()

        let formattedText = debugLogStore.formattedText
        XCTAssertTrue(formattedText.contains("raw text"))
        XCTAssertTrue(formattedText.contains("windowContext=captured"))
        XCTAssertTrue(formattedText.contains("cleaned text"))
    }

    func testAppStateReturnsRawTranscriptionWhenCleanupModelIsUnavailable() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.commonlyMisheardText = "just see -> Jesse"
        let cleanupManager = TextCleanupManager(
            defaults: defaults,
            cleanupModelAvailabilityOverrides: Dictionary(
                uniqueKeysWithValues: LocalCleanupModelKind.allCases.map { ($0, false) }
            )
        )
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            textCleanupManager: cleanupManager,
            correctionStore: correctionStore
        )
        appState.cleanupEnabled = true

        let result = await appState.cleanedTranscription("just see approved it")

        XCTAssertEqual(result, "just see approved it")
    }

    func testAppStatePrepareForTerminationShutsDownCleanupBackend() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        var shutdownCount = 0
        let cleanupManager = TextCleanupManager(
            defaults: defaults,
            backendShutdownOverride: {
                shutdownCount += 1
            }
        )
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            textCleanupManager: cleanupManager
        )

        appState.prepareForTermination()

        XCTAssertEqual(shutdownCount, 1)
    }

    func testAppStateForwardsModelManagerChanges() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(chordBindingStore: ChordBindingStore(defaults: defaults))
        let expectation = expectation(description: "app state forwards speech model changes")
        var cancellable: AnyCancellable? = appState.objectWillChange.sink {
            expectation.fulfill()
        }

        appState.modelManager.objectWillChange.send()

        await fulfillment(of: [expectation], timeout: 1.0)
        withExtendedLifetime(cancellable) {}
        cancellable = nil
    }

    func testAppStateForwardsCleanupManagerChanges() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(chordBindingStore: ChordBindingStore(defaults: defaults))
        let expectation = expectation(description: "app state forwards cleanup model changes")
        var cancellable: AnyCancellable? = appState.objectWillChange.sink {
            expectation.fulfill()
        }

        appState.textCleanupManager.objectWillChange.send()

        await fulfillment(of: [expectation], timeout: 1.0)
        withExtendedLifetime(cancellable) {}
        cancellable = nil
    }

    // MARK: - Permissions

    func testCheckMicrophoneUsesInjectedClientWithoutSystemPrompt() async {
        var requestCount = 0
        PermissionChecker.current = PermissionChecker.Client(
            checkAccessibility: { false },
            promptAccessibility: {},
            microphoneStatus: { .notDetermined },
            requestMicrophoneAccess: {
                requestCount += 1
                return true
            },
            openAccessibilitySettings: {},
            openMicrophoneSettings: {}
        )

        let granted = await PermissionChecker.checkMicrophone()

        XCTAssertTrue(granted)
        XCTAssertEqual(requestCount, 1)
    }

    func testDefaultClientIsNonInteractiveDuringTests() async {
        PermissionChecker.current = PermissionChecker.defaultClient

        let granted = await PermissionChecker.checkMicrophone()

        XCTAssertFalse(granted)
        XCTAssertEqual(PermissionChecker.microphoneStatus(), .denied)
    }

    func testResetAudioEngineClearsLiveRecordingNoInputErrorWhenIdle() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        var resetCallCount = 0
        let appState = AppState(
            chordBindingStore: ChordBindingStore(defaults: defaults),
            selectedInputDeviceIDProvider: { 142 },
            resetAudioRecorder: {
                resetCallCount += 1
            }
        )
        appState.status = .error
        appState.errorMessage = AppState.liveRecordingNoInputErrorMessage

        appState.resetAudioEngine()

        XCTAssertEqual(appState.audioRecorder.targetDeviceID, 142)
        XCTAssertEqual(resetCallCount, 1)
        XCTAssertEqual(appState.status, .ready)
        XCTAssertNil(appState.errorMessage)
    }

    func testResetAudioEngineKeepsUnrelatedErrorState() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        var resetCallCount = 0
        let appState = AppState(
            chordBindingStore: ChordBindingStore(defaults: defaults),
            selectedInputDeviceIDProvider: { nil },
            resetAudioRecorder: {
                resetCallCount += 1
            }
        )
        appState.status = .error
        appState.errorMessage = "Microphone access required"

        appState.resetAudioEngine()

        XCTAssertEqual(resetCallCount, 1)
        XCTAssertEqual(appState.status, .error)
        XCTAssertEqual(appState.errorMessage, "Microphone access required")
    }

    // MARK: - Audio Device Manager

    func testAudioDeviceManagerPersistsSelectedDeviceUID() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        AudioDeviceManager.setSelectedInputDevice(157, defaults: defaults) { deviceID in
            XCTAssertEqual(deviceID, 157)
            return "studio-display"
        }

        XCTAssertEqual(defaults.string(forKey: "selectedInputDeviceUID"), "studio-display")
    }

    func testAudioDeviceManagerMigratesLegacyDeviceIDToUIDAndResolvesCurrentDeviceID() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(157, forKey: "selectedInputDeviceID")

        let migratedID = AudioDeviceManager.selectedInputDeviceID(
            defaults: defaults,
            inputDevices: {
                [AudioInputDevice(id: 157, uid: "studio-display", name: "Studio Display Microphone")]
            }
        )
        let resolvedID = AudioDeviceManager.selectedInputDeviceID(
            defaults: defaults,
            inputDevices: {
                [AudioInputDevice(id: 142, uid: "studio-display", name: "Studio Display Microphone")]
            }
        )

        XCTAssertEqual(migratedID, 157)
        XCTAssertEqual(resolvedID, 142)
        XCTAssertEqual(defaults.string(forKey: "selectedInputDeviceUID"), "studio-display")
    }

    func testAudioDeviceManagerIgnoresStaleLegacyDeviceIDThatIsNotCurrentlyAvailable() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(157, forKey: "selectedInputDeviceID")

        let resolvedID = AudioDeviceManager.selectedInputDeviceID(
            defaults: defaults,
            inputDevices: {
                [AudioInputDevice(id: 142, uid: "studio-display", name: "Studio Display Microphone")]
            }
        )

        XCTAssertNil(resolvedID)
        XCTAssertNil(defaults.string(forKey: "selectedInputDeviceUID"))
    }

    func testAudioDeviceManagerResolvesCurrentDeviceIDFromSavedUID() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set("studio-display", forKey: "selectedInputDeviceUID")

        let resolvedID = AudioDeviceManager.selectedInputDeviceID(
            defaults: defaults,
            inputDevices: {
                [AudioInputDevice(id: 142, uid: "studio-display", name: "Studio Display Microphone")]
            }
        )

        XCTAssertEqual(resolvedID, 142)
    }

    func testAudioDeviceManagerReturnsNilWhenSavedUIDDoesNotResolve() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set("missing-device", forKey: "selectedInputDeviceUID")

        let resolvedID = AudioDeviceManager.selectedInputDeviceID(
            defaults: defaults,
            inputDevices: { [] }
        )

        XCTAssertNil(resolvedID)
    }
}
