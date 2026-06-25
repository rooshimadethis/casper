import XCTest
import SwiftUI
@testable import Casper

@MainActor
final class RecordingPipelineTests: XCTestCase {

    override func tearDown() {
        resetPermissionCheckerAfterTest()
        super.tearDown()
    }

    // MARK: - Streaming + Diarization

    func testPrepareRecordingSessionStreamsChunksToDiarizationAndTranscriptionSessions() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let transcriptionSession = FakeRecordingTranscriptionSession(finalTranscript: "streamed transcript")
        var diarizationChunks: [[Float]] = []

        appState.speechModel = SpeechModelCatalog.parakeetV3.id
        appState.ignoreOtherSpeakers = true
        appState.recordingTranscriptionSessionFactory = { descriptor in
            XCTAssertEqual(descriptor, SpeechModelCatalog.parakeetV3)
            return transcriptionSession
        }
        appState.recordingSessionCoordinatorFactory = {
            RecordingSessionCoordinator(
                appendAudioChunk: { samples in
                    diarizationChunks.append(samples)
                },
                finish: {
                    (nil, makeDiarizationSummary(usedFallback: true))
                }
            )
        }

        await appState.prepareRecordingSessionIfNeeded()
        appState.audioRecorder.onConvertedAudioChunk?([1, 2, 3, 4])

        XCTAssertNotNil(appState.activeRecordingSessionCoordinator)
        XCTAssertEqual(diarizationChunks, [[1, 2, 3, 4]])
        XCTAssertEqual(transcriptionSession.appendedChunks, [[1, 2, 3, 4]])
    }

    func testAppStateUsesRecordingTranscriptionSessionBeforeBatchFallback() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let transcriptionSession = FakeRecordingTranscriptionSession(finalTranscript: "streamed transcript")
        let cleanedInputs = LockedValue<[String]>([])
        var batchTranscriptionCallCount = 0

        appState.speechModel = SpeechModelCatalog.parakeetV3.id
        appState.recordingTranscriptionSessionFactory = { descriptor in
            XCTAssertEqual(descriptor, SpeechModelCatalog.parakeetV3)
            return transcriptionSession
        }
        appState.transcribeAudioBufferOverride = { _ in
            batchTranscriptionCallCount += 1
            return "batch transcript"
        }
        appState.cleanedTranscriptionResultOverride = { text, _ in
            await cleanedInputs.append(text)
            return (text: text, prompt: "", attemptedCleanup: false, cleanupUsedFallback: false)
        }

        await appState.prepareRecordingSessionIfNeeded()
        appState.audioRecorder.onConvertedAudioChunk?([1, 2, 3])
        appState.audioRecorder.onConvertedAudioChunk?([4, 5, 6])

        await appState.finishRecordingForTesting(
            audioBuffer: [1, 2, 3, 4, 5, 6],
            recordingSessionCoordinator: nil,
            recordingTranscriptionSession: appState.activeRecordingTranscriptionSession,
            archivedWindowContext: nil
        )

        XCTAssertEqual(transcriptionSession.appendedChunks, [[1, 2, 3], [4, 5, 6]])
        XCTAssertEqual(transcriptionSession.finishCallCount, 1)
        XCTAssertEqual(batchTranscriptionCallCount, 0)
        let recordedCleanupInputs = await cleanedInputs.get()
        XCTAssertEqual(recordedCleanupInputs, ["streamed transcript"])
    }

    func testAppStateSkipsBatchFallbackWhenRecordingSessionDisallowsIt() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let transcriptionSession = FakeRecordingTranscriptionSession(finalTranscript: nil)
        var batchTranscriptionCallCount = 0

        appState.speechModel = SpeechModelCatalog.parakeetV3.id
        appState.recordingTranscriptionSessionFactory = { descriptor in
            XCTAssertEqual(descriptor, SpeechModelCatalog.parakeetV3)
            return transcriptionSession
        }
        appState.transcribeAudioBufferOverride = { _ in
            batchTranscriptionCallCount += 1
            return "batch transcript"
        }

        await appState.prepareRecordingSessionIfNeeded()
        appState.audioRecorder.onConvertedAudioChunk?([1, 2, 3])
        appState.audioRecorder.onConvertedAudioChunk?([4, 5, 6])

        await appState.finishRecordingForTesting(
            audioBuffer: [1, 2, 3, 4, 5, 6],
            recordingSessionCoordinator: nil,
            recordingTranscriptionSession: appState.activeRecordingTranscriptionSession,
            archivedWindowContext: nil
        )

        XCTAssertEqual(transcriptionSession.finishCallCount, 1)
        XCTAssertEqual(batchTranscriptionCallCount, 0)
    }

    func testAppStateFallsBackToBatchTranscriptionWhenRecordingSessionAllowsIt() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let transcriptionSession = FakeRecordingTranscriptionSession(
            finalTranscript: nil,
            allowsBatchFallback: true
        )
        let cleanedInputs = LockedValue<[String]>([])
        var batchTranscriptionCallCount = 0

        appState.speechModel = SpeechModelCatalog.parakeetV3.id
        appState.recordingTranscriptionSessionFactory = { descriptor in
            XCTAssertEqual(descriptor, SpeechModelCatalog.parakeetV3)
            return transcriptionSession
        }
        appState.transcribeAudioBufferOverride = { _ in
            batchTranscriptionCallCount += 1
            return "batch transcript"
        }
        appState.cleanedTranscriptionResultOverride = { text, _ in
            await cleanedInputs.append(text)
            return (text: text, prompt: "", attemptedCleanup: false, cleanupUsedFallback: false)
        }

        await appState.prepareRecordingSessionIfNeeded()
        appState.audioRecorder.onConvertedAudioChunk?([1, 2, 3])
        appState.audioRecorder.onConvertedAudioChunk?([4, 5, 6])

        await appState.finishRecordingForTesting(
            audioBuffer: [1, 2, 3, 4, 5, 6],
            recordingSessionCoordinator: nil,
            recordingTranscriptionSession: appState.activeRecordingTranscriptionSession,
            archivedWindowContext: nil
        )

        XCTAssertEqual(transcriptionSession.finishCallCount, 1)
        XCTAssertEqual(batchTranscriptionCallCount, 1)
        let recordedCleanupInputs = await cleanedInputs.get()
        XCTAssertEqual(recordedCleanupInputs, ["batch transcript"])
    }

    func testAppStateFallsBackToBatchTranscriptionWhenSlidingWindowStreamReturnsNothing() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let streamedChunks = LockedValue<[[Float]]>([])
        let streamingEvents = LockedValue<[String]>([])
        let cleanedInputs = LockedValue<[String]>([])
        var batchTranscriptionCallCount = 0

        appState.speechModel = SpeechModelCatalog.parakeetV3.id
        appState.recordingTranscriptionSessionFactory = { descriptor in
            XCTAssertEqual(descriptor, SpeechModelCatalog.parakeetV3)
            return SlidingWindowRecordingTranscriptionSession {
                StreamingRecordingHandle(
                    appendAudioChunk: { samples in
                        await streamedChunks.append(samples)
                    },
                    finishTranscription: {
                        await streamingEvents.append("finish")
                        return ""
                    },
                    cancel: {
                        await streamingEvents.append("cancel")
                    },
                    cleanup: {
                        await streamingEvents.append("cleanup")
                    }
                )
            }
        }
        appState.transcribeAudioBufferOverride = { _ in
            batchTranscriptionCallCount += 1
            return "batch transcript"
        }
        appState.cleanedTranscriptionResultOverride = { text, _ in
            await cleanedInputs.append(text)
            return (text: text, prompt: "", attemptedCleanup: false, cleanupUsedFallback: false)
        }

        await appState.prepareRecordingSessionIfNeeded()
        appState.audioRecorder.onConvertedAudioChunk?([1, 2, 3])
        appState.audioRecorder.onConvertedAudioChunk?([4, 5, 6])

        await appState.finishRecordingForTesting(
            audioBuffer: [1, 2, 3, 4, 5, 6],
            recordingSessionCoordinator: nil,
            recordingTranscriptionSession: appState.activeRecordingTranscriptionSession,
            archivedWindowContext: nil
        )

        XCTAssertEqual(batchTranscriptionCallCount, 1)
        let recordedChunks = await streamedChunks.get()
        XCTAssertEqual(recordedChunks, [[1, 2, 3], [4, 5, 6]])
        let recordedEvents = await streamingEvents.get()
        XCTAssertEqual(recordedEvents, ["finish", "cleanup"])
        let recordedCleanupInputs = await cleanedInputs.get()
        XCTAssertEqual(recordedCleanupInputs, ["batch transcript"])
    }

    func testAppStateDoesNotRunExternalBatchFallbackWhenSlidingWindowSessionOwnsFinalBatchTranscription() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let streamedChunks = LockedValue<[[Float]]>([])
        let streamingEvents = LockedValue<[String]>([])
        var batchTranscriptionCallCount = 0

        appState.speechModel = SpeechModelCatalog.parakeetV3.id
        appState.recordingTranscriptionSessionFactory = { descriptor in
            XCTAssertEqual(descriptor, SpeechModelCatalog.parakeetV3)
            return SlidingWindowRecordingTranscriptionSession(
                fullBufferTranscription: { _ in nil },
                handleFactory: {
                    StreamingRecordingHandle(
                        appendAudioChunk: { samples in
                            await streamedChunks.append(samples)
                        },
                        finishTranscription: {
                            await streamingEvents.append("finish")
                            return "streamed transcript"
                        },
                        cancel: {
                            await streamingEvents.append("cancel")
                        },
                        cleanup: {
                            await streamingEvents.append("cleanup")
                        }
                    )
                }
            )
        }
        appState.transcribeAudioBufferOverride = { _ in
            batchTranscriptionCallCount += 1
            return "batch transcript"
        }

        await appState.prepareRecordingSessionIfNeeded()
        appState.audioRecorder.onConvertedAudioChunk?([1, 2, 3])
        appState.audioRecorder.onConvertedAudioChunk?([4, 5, 6])

        await appState.finishRecordingForTesting(
            audioBuffer: [1, 2, 3, 4, 5, 6],
            recordingSessionCoordinator: nil,
            recordingTranscriptionSession: appState.activeRecordingTranscriptionSession,
            archivedWindowContext: nil
        )

        XCTAssertEqual(batchTranscriptionCallCount, 0)
        let recordedChunks = await streamedChunks.get()
        XCTAssertEqual(recordedChunks, [[1, 2, 3], [4, 5, 6]])
        let recordedEvents = await streamingEvents.get()
        XCTAssertEqual(recordedEvents, ["finish", "cleanup"])
    }

    func testFinishRecordingForTestingSkipsWindowContextProviderWhenTranscriptIsMissing() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let providerCallCount = LockedValue(0)

        appState.transcribeAudioBufferOverride = { _ in
            nil
        }

        await appState.finishRecordingForTesting(
            audioBuffer: [1, 2, 3, 4],
            recordingSessionCoordinator: nil,
            recordingTranscriptionSession: nil,
            archivedWindowContext: nil,
            windowContextProvider: {
                await providerCallCount.set(1)
                return RecordingOCRPrefetchResult(
                    context: OCRContext(windowContents: "captured"),
                    elapsed: 0.25
                )
            }
        )

        let callCount = await providerCallCount.get()
        XCTAssertEqual(callCount, 0)
    }

    func testAppStatePrefersFilteredSpeakerTranscriptOverStreamedTranscript() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let transcriptionSession = FakeRecordingTranscriptionSession(finalTranscript: "streamed transcript")
        let cleanedInputs = LockedValue<[String]>([])
        var batchTranscriptionCallCount = 0
        let coordinator = RecordingSessionCoordinator(
            appendAudioChunk: { _ in },
            finish: {
                ("speaker filtered transcript", makeDiarizationSummary(usedFallback: false))
            }
        )

        appState.transcribeAudioBufferOverride = { _ in
            batchTranscriptionCallCount += 1
            return "batch transcript"
        }
        appState.cleanedTranscriptionResultOverride = { text, _ in
            await cleanedInputs.append(text)
            return (text: text, prompt: "", attemptedCleanup: false, cleanupUsedFallback: false)
        }

        await appState.finishRecordingForTesting(
            audioBuffer: [1, 2, 3, 4],
            recordingSessionCoordinator: coordinator,
            recordingTranscriptionSession: transcriptionSession,
            archivedWindowContext: nil
        )

        let recordedCleanupInputs = await cleanedInputs.get()
        XCTAssertEqual(recordedCleanupInputs, ["speaker filtered transcript"])
        XCTAssertEqual(transcriptionSession.cancelCallCount, 1)
        XCTAssertEqual(transcriptionSession.finishCallCount, 0)
        XCTAssertEqual(batchTranscriptionCallCount, 0)
    }

    // MARK: - Pipeline Ownership

    func testAppStatePipelineOwnershipAllowsSingleOwnerAtATime() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertTrue(appState.acquirePipeline(for: .transcriptionLab))
        XCTAssertFalse(appState.acquirePipeline(for: .liveRecording))

        appState.releasePipeline(owner: .transcriptionLab)

        XCTAssertTrue(appState.acquirePipeline(for: .liveRecording))
    }

    func testAppStatePipelineReleaseIgnoresWrongOwner() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertTrue(appState.acquirePipeline(for: .transcriptionLab))

        appState.releasePipeline(owner: .liveRecording)

        XCTAssertFalse(appState.acquirePipeline(for: .liveRecording))
        appState.releasePipeline(owner: .transcriptionLab)
        XCTAssertTrue(appState.acquirePipeline(for: .liveRecording))
    }

    // MARK: - Speaker Filtering

    func testWhisperRecordingIgnoresSpeakerFilteringSetting() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        appState.speechModel = SpeechModelCatalog.whisperSmallEnglish.id
        appState.ignoreOtherSpeakers = true

        var factoryCallCount = 0
        appState.recordingSessionCoordinatorFactory = {
            factoryCallCount += 1
            return RecordingSessionCoordinator(
                appendAudioChunk: { _ in },
                finish: {
                    (filteredTranscript: "unused", summary: makeDiarizationSummary(usedFallback: false))
                }
            )
        }

        await appState.prepareRecordingSessionIfNeeded()

        XCTAssertEqual(factoryCallCount, 0)
        XCTAssertNil(appState.audioRecorder.onConvertedAudioChunk)
    }

    func testFluidAudioRecordingUsesSpeakerFilteringSession() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let labStore = TranscriptionLabStore(directoryURL: storeDirectory, maxEntries: 50)
        defer {
            try? FileManager.default.removeItem(at: storeDirectory)
        }

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            transcriptionLabStore: labStore
        )
        appState.transcriptionLabEnabled = true
        appState.speechModel = SpeechModelCatalog.parakeetV3.id
        appState.ignoreOtherSpeakers = true

        let receivedChunks = LockedValue<[[Float]]>([])
        let diarizationSummary = makeDiarizationSummary(usedFallback: false)
        appState.recordingSessionCoordinatorFactory = {
            RecordingSessionCoordinator(
                appendAudioChunk: { samples in
                    Task {
                        await receivedChunks.append(samples)
                    }
                },
                finish: {
                    (filteredTranscript: "filtered speaker transcript", summary: diarizationSummary)
                }
            )
        }

        var fullTranscriptionCalls = 0
        appState.transcribeAudioBufferOverride = { _ in
            fullTranscriptionCalls += 1
            return "full transcript"
        }

        let cleanupInputs = LockedValue<[String]>([])
        appState.cleanedTranscriptionResultOverride = { text, _ in
            await cleanupInputs.append(text)
            return (
                text: "cleaned \(text)",
                prompt: "prompt",
                attemptedCleanup: true,
                cleanupUsedFallback: false
            )
        }

        await appState.prepareRecordingSessionIfNeeded()
        appState.audioRecorder.onConvertedAudioChunk?([0.1, 0.2, 0.3])
        await appState.finishRecordingForTesting(
            audioBuffer: makeArchiveableAudioBuffer(),
            recordingSessionCoordinator: appState.activeRecordingSessionCoordinator,
            archivedWindowContext: OCRContext(windowContents: "context")
        )

        let entries = try labStore.loadEntries()
        let recordedChunks = await receivedChunks.get()
        let cleanupTexts = await cleanupInputs.get()
        XCTAssertEqual(recordedChunks, [[0.1, 0.2, 0.3]])
        XCTAssertEqual(fullTranscriptionCalls, 0)
        XCTAssertEqual(cleanupTexts, ["filtered speaker transcript"])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].diarizationSummary, diarizationSummary)
        XCTAssertTrue(entries[0].speakerFilteringEnabled)
        XCTAssertTrue(entries[0].speakerFilteringRan)
        XCTAssertFalse(entries[0].speakerFilteringUsedFallback)
    }

    func testQwenRecordingUsesSpeakerFilteringSession() async throws {
        guard #available(macOS 15, iOS 18, *) else {
            throw XCTSkip("Qwen3-ASR requires macOS 15 or later.")
        }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let transcriptionSession = FakeRecordingTranscriptionSession(finalTranscript: "streamed transcript")
        var diarizationChunks: [[Float]] = []
        var factoryCallCount = 0

        appState.speechModel = SpeechModelCatalog.qwen3AsrInt8.id
        appState.ignoreOtherSpeakers = true
        appState.recordingTranscriptionSessionFactory = { descriptor in
            XCTAssertEqual(descriptor, SpeechModelCatalog.qwen3AsrInt8)
            return transcriptionSession
        }
        appState.recordingSessionCoordinatorFactory = {
            factoryCallCount += 1
            return RecordingSessionCoordinator(
                appendAudioChunk: { samples in
                    diarizationChunks.append(samples)
                },
                finish: {
                    (nil, makeDiarizationSummary(usedFallback: true))
                }
            )
        }

        await appState.prepareRecordingSessionIfNeeded()
        appState.audioRecorder.onConvertedAudioChunk?([1, 2, 3, 4])

        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertNotNil(appState.activeRecordingSessionCoordinator)
        XCTAssertEqual(diarizationChunks, [[1, 2, 3, 4]])
        XCTAssertEqual(transcriptionSession.appendedChunks, [[1, 2, 3, 4]])
    }

    func testAppStateArchivesDiarizationFallbackState() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let labStore = TranscriptionLabStore(directoryURL: storeDirectory, maxEntries: 50)
        defer {
            try? FileManager.default.removeItem(at: storeDirectory)
        }

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            transcriptionLabStore: labStore
        )
        appState.transcriptionLabEnabled = true
        appState.speechModel = SpeechModelCatalog.parakeetV3.id
        appState.ignoreOtherSpeakers = true

        let diarizationSummary = makeDiarizationSummary(usedFallback: true)
        let coordinator = RecordingSessionCoordinator(
            appendAudioChunk: { _ in },
            finish: {
                (filteredTranscript: nil, summary: diarizationSummary)
            }
        )

        var fullTranscriptionCalls = 0
        appState.transcribeAudioBufferOverride = { _ in
            fullTranscriptionCalls += 1
            return "fallback full transcript"
        }

        let cleanupInputs = LockedValue<[String]>([])
        appState.cleanedTranscriptionResultOverride = { text, _ in
            await cleanupInputs.append(text)
            return (
                text: "cleaned \(text)",
                prompt: "prompt",
                attemptedCleanup: true,
                cleanupUsedFallback: false
            )
        }

        await appState.finishRecordingForTesting(
            audioBuffer: makeArchiveableAudioBuffer(),
            recordingSessionCoordinator: coordinator,
            archivedWindowContext: OCRContext(windowContents: "context")
        )

        let entries = try labStore.loadEntries()
        let cleanupTexts = await cleanupInputs.get()
        XCTAssertEqual(fullTranscriptionCalls, 1)
        XCTAssertEqual(cleanupTexts, ["fallback full transcript"])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].diarizationSummary, diarizationSummary)
        XCTAssertTrue(entries[0].speakerFilteringEnabled)
        XCTAssertTrue(entries[0].speakerFilteringRan)
        XCTAssertTrue(entries[0].speakerFilteringUsedFallback)
    }

    // MARK: - Archiving

    func testAppStateArchivesCompletedRecordingWithOCRAndOutputs() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let labStore = TranscriptionLabStore(directoryURL: storeDirectory, maxEntries: 50)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            transcriptionLabStore: labStore
        )
        appState.transcriptionLabEnabled = true
        defer {
            try? FileManager.default.removeItem(at: storeDirectory)
        }

        await appState.archiveRecordingForLab(
            audioBuffer: makeArchiveableAudioBuffer(),
            windowContext: OCRContext(windowContents: "Qwen 3.5 4B"),
            rawTranscription: "The default should be Quen three point five four b.",
            correctedTranscription: "The default should be Qwen 3.5 4B.",
            cleanupUsedFallback: false
        )

        let entries = try labStore.loadEntries()

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(URL(fileURLWithPath: entries[0].audioFileName).pathExtension, "wav")
        XCTAssertEqual(entries[0].windowContext, OCRContext(windowContents: "Qwen 3.5 4B"))
        XCTAssertEqual(entries[0].rawTranscription, "The default should be Quen three point five four b.")
        XCTAssertEqual(entries[0].correctedTranscription, "The default should be Qwen 3.5 4B.")
        XCTAssertEqual(entries[0].speechModelID, appState.speechModel)
        XCTAssertFalse(entries[0].cleanupUsedFallback)
    }

    func testAppStateArchivesNonEmptyAudioEvenWhenLiveTranscriptionFailed() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let labStore = TranscriptionLabStore(directoryURL: storeDirectory, maxEntries: 50)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            transcriptionLabStore: labStore
        )
        appState.transcriptionLabEnabled = true
        defer {
            try? FileManager.default.removeItem(at: storeDirectory)
        }

        await appState.archiveRecordingForLab(
            audioBuffer: makeArchiveableAudioBuffer(),
            windowContext: nil,
            rawTranscription: nil,
            correctedTranscription: nil,
            cleanupUsedFallback: false
        )

        let entries = try labStore.loadEntries()

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(URL(fileURLWithPath: entries[0].audioFileName).pathExtension, "wav")
        XCTAssertNil(entries[0].rawTranscription)
        XCTAssertNil(entries[0].correctedTranscription)
    }

    func testAppStateSkipsHistoryForRecordingsThatDisplayAsZeroSeconds() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let labStore = TranscriptionLabStore(directoryURL: storeDirectory, maxEntries: 50)
        let debugLogStore = makeDebugLogStore()
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            debugLogStore: debugLogStore,
            transcriptionLabStore: labStore
        )
        appState.transcriptionLabEnabled = true
        defer {
            try? FileManager.default.removeItem(at: storeDirectory)
        }

        await appState.archiveRecordingForLab(
            audioBuffer: Array(repeating: 0.1, count: 799),
            windowContext: OCRContext(windowContents: "too short"),
            rawTranscription: "ignored",
            correctedTranscription: "ignored",
            cleanupUsedFallback: false
        )

        XCTAssertTrue(try labStore.loadEntries().isEmpty)
        XCTAssertTrue(debugLogStore.entries.isEmpty)
    }

    func testAppStateArchivesRecordingWithDiarizationSummary() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let labStore = TranscriptionLabStore(directoryURL: storeDirectory, maxEntries: 50)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            transcriptionLabStore: labStore
        )
        appState.transcriptionLabEnabled = true
        defer {
            try? FileManager.default.removeItem(at: storeDirectory)
        }

        let diarizationSummary = DiarizationSummary(
            spans: [
                DiarizationSummary.Span(speakerID: "speaker-a", startTime: 0.0, endTime: 0.8, isKept: true),
                DiarizationSummary.Span(speakerID: "speaker-b", startTime: 0.9, endTime: 1.2, isKept: false)
            ],
            mergedKeptSpans: [
                DiarizationSummary.MergedSpan(startTime: 0.0, endTime: 0.8)
            ],
            targetSpeakerID: "speaker-a",
            targetSpeakerDuration: 0.8,
            keptAudioDuration: 0.8,
            usedFallback: true,
            fallbackReason: .emptyFilteredTranscription
        )

        await appState.archiveRecordingForLab(
            audioBuffer: makeArchiveableAudioBuffer(),
            windowContext: OCRContext(windowContents: "Casper"),
            rawTranscription: "raw diarized transcription",
            correctedTranscription: "clean diarized transcription",
            cleanupUsedFallback: false,
            speakerFilteringEnabled: true,
            speakerFilteringRan: true,
            diarizationSummary: diarizationSummary
        )

        let entries = try labStore.loadEntries()

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].diarizationSummary, diarizationSummary)
        XCTAssertTrue(entries[0].speakerFilteringEnabled)
        XCTAssertTrue(entries[0].speakerFilteringRan)
        XCTAssertTrue(entries[0].speakerFilteringUsedFallback)
    }
}
