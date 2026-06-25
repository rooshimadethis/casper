import XCTest
import SwiftUI
@testable import Casper

// MARK: - Fakes

final class FakeHotkeyMonitor: HotkeyMonitoring {
    var onRecordingStart: (() -> Void)?
    var onRecordingStop: (() -> Void)?
    var onPushToTalkStart: (() -> Void)?
    var onPushToTalkStop: (() -> Void)?
    var onToggleToTalkStart: (() -> Void)?
    var onToggleToTalkStop: (() -> Void)?
    var onPepperChatStart: (() -> Void)?
    var onPepperChatStop: (() -> Void)?
    var onRecordingRestart: (() -> Void)?

    var updatedBindings: [ChordAction: KeyChord] = [:]
    var startResult = true
    var startCallCount = 0
    var suspendedStates: [Bool] = []

    func start() -> Bool {
        startCallCount += 1
        return startResult
    }

    func stop() {}

    func updateBindings(_ bindings: [ChordAction: KeyChord]) {
        updatedBindings = bindings
    }

    func setSuspended(_ suspended: Bool) {
        suspendedStates.append(suspended)
    }
}

final class FakeAppRelauncher: AppRelaunching {
    var relaunchCallCount = 0
    var error: Error?

    func relaunch() throws {
        relaunchCallCount += 1
        if let error {
            throw error
        }
    }
}

final class FakeRecordingTranscriptionSession: RecordingTranscriptionSession {
    private(set) var appendedChunks: [[Float]] = []
    private(set) var finishCallCount = 0
    private(set) var cancelCallCount = 0
    var finalTranscript: String?
    let allowsBatchFallback: Bool
    let supportsConcurrentFinalization = false

    init(finalTranscript: String?, allowsBatchFallback: Bool = false) {
        self.finalTranscript = finalTranscript
        self.allowsBatchFallback = allowsBatchFallback
    }

    func appendAudioChunk(_ samples: [Float]) {
        appendedChunks.append(samples)
    }

    func finishTranscription() async -> String? {
        finishCallCount += 1
        return finalTranscript
    }

    func cancel() {
        cancelCallCount += 1
    }
}

// MARK: - Static test helpers

func closeWindows(titled title: String) {
    NSApp.windows
        .filter { $0.title == title }
        .forEach { window in
            window.delegate = nil
            window.orderOut(nil)
            window.close()
        }
}

func makeDebugLogStore() -> DebugLogStore {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("debug-log.json")
    return DebugLogStore(storageURL: fileURL)
}

func settingsWindowSource() throws -> String {
    let testFileURL = URL(fileURLWithPath: #filePath)
    let repositoryURL = testFileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = repositoryURL
        .appendingPathComponent("Casper")
        .appendingPathComponent("UI")
        .appendingPathComponent("SettingsWindow.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

func unwrapPrivateOptional<T>(named name: String, from object: Any) -> T? {
    let mirror = Mirror(reflecting: object)
    guard let child = mirror.children.first(where: { $0.label == name }) else {
        return nil
    }

    let optionalMirror = Mirror(reflecting: child.value)
    guard optionalMirror.displayStyle == .optional else {
        return child.value as? T
    }

    return optionalMirror.children.first?.value as? T
}

func makeArchiveableAudioBuffer(sampleCount: Int = 1_600) -> [Float] {
    Array(repeating: 0.1, count: sampleCount)
}

func makeDiarizationSummary(usedFallback: Bool) -> DiarizationSummary {
    DiarizationSummary(
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
        usedFallback: usedFallback,
        fallbackReason: usedFallback ? .emptyFilteredTranscription : nil
    )
}

func resetPermissionCheckerAfterTest() {
    PermissionChecker.current = PermissionChecker.defaultClient
}

// MARK: - PepperChat helpers

private let pepperChatAppStorageKeys = [
    "pepperChatEnabled",
    "pepperChatApiKey"
]

func withClearedPepperChatAppStorage<T>(
    _ body: () throws -> T
) rethrows -> T {
    let defaults = UserDefaults.standard
    let originalValues = pepperChatAppStorageKeys.map { key in
        (key, defaults.object(forKey: key))
    }

    for key in pepperChatAppStorageKeys {
        defaults.removeObject(forKey: key)
    }

    defer {
        for (key, value) in originalValues {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    return try body()
}

func withClearedPepperChatAppStorage<T>(
    _ body: () async throws -> T
) async rethrows -> T {
    let defaults = UserDefaults.standard
    let originalValues = pepperChatAppStorageKeys.map { key in
        (key, defaults.object(forKey: key))
    }

    for key in pepperChatAppStorageKeys {
        defaults.removeObject(forKey: key)
    }

    defer {
        for (key, value) in originalValues {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    return try await body()
}
