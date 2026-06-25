import XCTest
import SwiftUI
@testable import Casper

@MainActor
final class WindowControllerTests: XCTestCase {

    override func tearDown() {
        resetPermissionCheckerAfterTest()
        super.tearDown()
    }

    // MARK: - Settings Window

    func testSettingsWindowHostsSwiftUIViaContentViewController() throws {
        closeWindows(titled: "Casper Settings")
        defer { closeWindows(titled: "Casper Settings") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let controller = SettingsWindowController()

        controller.show(appState: appState)

        let window = try XCTUnwrap(NSApp.windows.first(where: { $0.title == "Casper Settings" }))
        defer { window.close() }

        XCTAssertNotNil(window.contentViewController)
    }

    func testSettingsWindowControllerCloseButtonOrdersWindowOutWithoutClosing() throws {
        closeWindows(titled: "Casper Settings")
        defer { closeWindows(titled: "Casper Settings") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let controller = SettingsWindowController()

        controller.show(appState: appState)
        let window = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Casper Settings" && $0.isVisible })
        )

        let shouldClose = window.delegate?.windowShouldClose?(window)

        XCTAssertEqual(shouldClose, false)
        XCTAssertFalse(window.isVisible)

        controller.show(appState: appState)
        let reopenedWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Casper Settings" && $0.isVisible })
        )

        XCTAssertTrue(window === reopenedWindow)
    }

    func testSettingsWindowUsesLargeRoomyFrame() throws {
        closeWindows(titled: "Casper Settings")
        defer { closeWindows(titled: "Casper Settings") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let controller = SettingsWindowController()

        controller.show(appState: appState)

        let window = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Casper Settings" && $0.isVisible })
        )

        XCTAssertGreaterThanOrEqual(window.minSize.width, 900)
        XCTAssertGreaterThanOrEqual(window.minSize.height, 680)
    }

    // MARK: - Prompt Editor

    func testPromptEditorHostsSwiftUIViaContentViewController() throws {
        closeWindows(titled: "Edit Cleanup Prompt")
        defer { closeWindows(titled: "Edit Cleanup Prompt") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let controller = PromptEditorController()

        controller.show(appState: appState)

        let window = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Edit Cleanup Prompt" && $0.isVisible })
        )
        defer { window.close() }

        XCTAssertNotNil(window.contentViewController)
    }

    func testPromptEditorControllerReusesExistingWindow() throws {
        closeWindows(titled: "Edit Cleanup Prompt")
        defer { closeWindows(titled: "Edit Cleanup Prompt") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let controller = PromptEditorController()

        controller.show(appState: appState)
        let firstWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Edit Cleanup Prompt" && $0.isVisible })
        )

        controller.show(appState: appState)
        let secondWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Edit Cleanup Prompt" && $0.isVisible })
        )
        defer { secondWindow.close() }

        XCTAssertTrue(firstWindow === secondWindow)
    }

    func testPromptEditorControllerDismissKeepsWindowReusable() throws {
        closeWindows(titled: "Edit Cleanup Prompt")
        defer { closeWindows(titled: "Edit Cleanup Prompt") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let controller = PromptEditorController()

        controller.show(appState: appState)
        let firstWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Edit Cleanup Prompt" && $0.isVisible })
        )

        controller.dismiss()
        XCTAssertFalse(firstWindow.isVisible)

        controller.show(appState: appState)
        let secondWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Edit Cleanup Prompt" && $0.isVisible })
        )
        defer { secondWindow.close() }

        XCTAssertTrue(firstWindow === secondWindow)
    }

    func testPromptEditorControllerCloseButtonOrdersWindowOutWithoutClosing() throws {
        closeWindows(titled: "Edit Cleanup Prompt")
        defer { closeWindows(titled: "Edit Cleanup Prompt") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let controller = PromptEditorController()

        controller.show(appState: appState)
        let window = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Edit Cleanup Prompt" && $0.isVisible })
        )

        let shouldClose = controller.windowShouldClose(window)

        XCTAssertFalse(shouldClose)
        XCTAssertFalse(window.isVisible)
    }

    func testPromptEditorControllerDismissResignsFirstResponder() throws {
        closeWindows(titled: "Edit Cleanup Prompt")
        defer { closeWindows(titled: "Edit Cleanup Prompt") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let controller = PromptEditorController()

        controller.show(appState: appState)
        let window = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Edit Cleanup Prompt" && $0.isVisible })
        )
        let textView = NSTextView(frame: .zero)
        window.contentView?.addSubview(textView)
        XCTAssertTrue(window.makeFirstResponder(textView))

        controller.dismiss()

        XCTAssertFalse(window.firstResponder === textView)
    }

    func testAppStateShowPromptEditorReusesSingleWindow() throws {
        closeWindows(titled: "Edit Cleanup Prompt")
        defer { closeWindows(titled: "Edit Cleanup Prompt") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.showPromptEditor()
        appState.showPromptEditor()

        let windows = NSApp.windows.filter { $0.title == "Edit Cleanup Prompt" && $0.isVisible }
        defer { windows.forEach { $0.close() } }

        XCTAssertEqual(windows.count, 1)
    }

    func testAppStateShowSettingsReusesSingleWindow() throws {
        closeWindows(titled: "Casper Settings")
        defer { closeWindows(titled: "Casper Settings") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.showSettings()
        appState.showSettings()

        let windows = NSApp.windows.filter { $0.title == "Casper Settings" }
        defer { windows.forEach { $0.close() } }

        XCTAssertEqual(windows.count, 1)
    }

    // MARK: - Settings Sections

    func testSettingsSectionUsesHistoryTitleForSavedRecordings() {
        XCTAssertEqual(SettingsSection.transcriptionLab.title, "History")
    }

    func testSettingsSectionsUseGeneralAndFoldCorrectionsIntoCleanup() {
        XCTAssertEqual(SettingsSection.allCases.first, .general)
        XCTAssertEqual(SettingsSection.general.title, "General")
        XCTAssertFalse(SettingsSection.allCases.contains { $0.title == "Corrections" })
        XCTAssertEqual(SettingsSection.cleanup.subtitle, "Prompt cleanup, correction hints, OCR context, and learning behavior.")
    }

    // MARK: - Transcription Lab Workshop

    func testTranscriptionLabWorkshopUsesCollapsiblePipelineSections() throws {
        let source = try settingsWindowSource()

        XCTAssertTrue(source.contains("TranscriptionLabWorkshopSummary"))
        XCTAssertTrue(source.contains("TranscriptionLabSourceRecordingSummary"))
        XCTAssertTrue(source.contains("TranscriptionLabStageDisclosure"))
        XCTAssertTrue(source.contains("Rerun transcription"))
        XCTAssertTrue(source.contains("Rerun speaker tagging"))
        XCTAssertTrue(source.contains("Rerun cleanup"))
        XCTAssertFalse(source.contains("TranscriptionLabStageCard(\"Recording\")"))
    }

    func testTranscriptionLabWorkshopUsesSharedOutputComparisonViews() throws {
        let source = try settingsWindowSource()

        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "TranscriptionLabOutputComparison").count - 1, 3)
        XCTAssertTrue(source.contains("Original timeline"))
        XCTAssertTrue(source.contains("New timeline"))
        XCTAssertTrue(source.contains("Matched to"))
    }

    func testTranscriptionLabWorkshopKeepsSummaryMetadataReadable() throws {
        let source = try settingsWindowSource()

        XCTAssertTrue(source.contains("TranscriptionLabMetadataLine"))
        XCTAssertTrue(source.contains("TranscriptionLabMetadataItem"))
        XCTAssertTrue(source.contains(".lineLimit(1)"))
        XCTAssertTrue(source.contains(".fixedSize(horizontal: true, vertical: false)"))
    }

    func testTranscriptionLabStageHeadersUseFullWidthButtons() throws {
        let source = try settingsWindowSource()

        XCTAssertTrue(source.contains("TranscriptionLabStageHeaderButton"))
        XCTAssertTrue(source.contains("isExpanded.toggle()"))
        XCTAssertTrue(source.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(source.contains("DisclosureGroup(isExpanded: $isExpanded)"))
    }

    // MARK: - Debug Log

    func testAppStateShowDebugLogHostsSwiftUIViaContentViewController() throws {
        closeWindows(titled: "Casper Debug Log")
        defer { closeWindows(titled: "Casper Debug Log") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.showDebugLog()

        let window = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Casper Debug Log" && $0.isVisible })
        )
        defer { window.close() }

        XCTAssertNotNil(window.contentViewController)
    }

    func testDebugLogWindowControllerCloseButtonOrdersWindowOutWithoutClosing() throws {
        closeWindows(titled: "Casper Debug Log")
        defer { closeWindows(titled: "Casper Debug Log") }
        let controller = DebugLogWindowController()
        let debugLogStore = makeDebugLogStore()

        controller.show(debugLogStore: debugLogStore)
        let window = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Casper Debug Log" && $0.isVisible })
        )

        let shouldClose = window.delegate?.windowShouldClose?(window)

        XCTAssertEqual(shouldClose, false)
        XCTAssertFalse(window.isVisible)

        controller.show(debugLogStore: debugLogStore)
        let reopenedWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Casper Debug Log" && $0.isVisible })
        )

        XCTAssertTrue(window === reopenedWindow)
    }

    func testAppStateShowDebugLogReusesSingleWindow() throws {
        closeWindows(titled: "Casper Debug Log")
        defer { closeWindows(titled: "Casper Debug Log") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.showDebugLog()
        let firstWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Casper Debug Log" && $0.isVisible })
        )
        appState.showDebugLog()

        let secondWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Casper Debug Log" && $0.isVisible })
        )
        defer { secondWindow.close() }

        XCTAssertTrue(firstWindow === secondWindow)
    }

    // MARK: - Recording Overlay

    func testRecordingOverlayHostsSwiftUIViaContentViewController() throws {
        let overlay = RecordingOverlayController()
        let existingWindowNumbers = Set(NSApp.windows.map(\.windowNumber))

        overlay.show()

        let panel = try XCTUnwrap(
            NSApp.windows
                .filter { !existingWindowNumbers.contains($0.windowNumber) }
                .compactMap { $0 as? NSPanel }
                .first
        )
        defer {
            overlay.dismiss()
            panel.close()
        }

        XCTAssertNotNil(panel.contentViewController)
    }
}
