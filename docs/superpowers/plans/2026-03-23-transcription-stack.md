# Transcription Stack Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build configurable recording chords, cleanup backend/model selection, OCR-informed cleanup, and conservative correction learning as a stacked series of feature branches.

**Architecture:** Keep the current app structure, but add four durable seams: chord bindings, cleanup backend selection, OCR context collection, and deterministic corrections/learning. Each branch should ship working software on its own and become the base for the next branch.

**Tech Stack:** Swift, SwiftUI, AppKit, CoreGraphics event taps, Accessibility APIs, Vision OCR, WhisperKit, LLM.swift, optional FoundationModels, XCTest

---

## File Map

### Project Generation Rule

- This repo uses `project.yml` with XcodeGen.
- After any task that creates, deletes, or renames Swift files, run `xcodegen generate` before the next `xcodebuild` command so the new files are included in the project.

### Existing Files To Modify

- `Casper/AppState.swift`
  Wire new chord actions, cleanup pipeline, OCR context, and post-paste learning into the existing app flow.
- `Casper/Input/HotkeyMonitor.swift`
  Convert from Control-only logic into a wrapper around the new chord engine, or replace its internals while preserving the app-facing callback shape.
- `Casper/UI/SettingsWindow.swift`
  Add `Shortcuts`, `Cleanup`, `Context`, and `Corrections` sections.
- `Casper/UI/OnboardingWindow.swift`
  Keep onboarding minimal while pointing advanced users to settings.
- `Casper/Cleanup/TextCleanupManager.swift`
  Move from implicit local-model behavior toward explicit backend/model policy state.
- `Casper/Cleanup/TextCleaner.swift`
  Stop owning all cleanup decisions directly; call the deterministic correction layer, optional OCR context provider, and selected cleanup backend.
- `Casper/PermissionChecker.swift`
  Add Screen Recording status/open-settings helpers.
- `Casper/Input/TextPaster.swift`
  Expose enough paste metadata for the delayed learning branch.
- `.gitignore`
  Keep `docs/superpowers/specs` and `docs/superpowers/plans` tracked.

### New Input Files

- `Casper/Input/PhysicalKey.swift`
- `Casper/Input/KeyChord.swift`
- `Casper/Input/ChordAction.swift`
- `Casper/Input/ChordBindingStore.swift`
- `Casper/Input/ChordEngine.swift`
- `Casper/Input/PasteSession.swift`
- `Casper/UI/ShortcutRecorderView.swift`

### New Cleanup Files

- `Casper/Cleanup/CleanupBackend.swift`
- `Casper/Cleanup/LocalLLMCleanupBackend.swift`
- `Casper/Cleanup/FoundationModelsCleanupBackend.swift`
- `Casper/Cleanup/FoundationModelAvailabilityProvider.swift`
- `Casper/Cleanup/CleanupSettings.swift`
- `Casper/Cleanup/CleanupPromptBuilder.swift`
- `Casper/Cleanup/CorrectionStore.swift`
- `Casper/Cleanup/DeterministicCorrectionEngine.swift`
- `Casper/Cleanup/PostPasteLearningCoordinator.swift`

### New OCR/Context Files

- `Casper/Context/OCRContext.swift`
- `Casper/Context/OCRRequestFactory.swift`
- `Casper/Context/WindowCaptureService.swift`
- `Casper/Context/FrontmostWindowOCRService.swift`
- `Casper/Context/FocusedElementLocator.swift`

### New Test Files

- `CasperTests/KeyChordTests.swift`
- `CasperTests/ChordEngineTests.swift`
- `CasperTests/ChordBindingStoreTests.swift`
- `CasperTests/TextCleanupManagerTests.swift`
- `CasperTests/TextCleanerTests.swift`
- `CasperTests/CleanupPromptBuilderTests.swift`
- `CasperTests/CleanupBackendTests.swift`
- `CasperTests/OCRContextTests.swift`
- `CasperTests/CorrectionStoreTests.swift`
- `CasperTests/PostPasteLearningCoordinatorTests.swift`

## Chunk 1: `codex/chord-actions`

### Task 1: Add the chord domain model and persistence

**Files:**
- Create: `Casper/Input/PhysicalKey.swift`
- Create: `Casper/Input/KeyChord.swift`
- Create: `Casper/Input/ChordAction.swift`
- Create: `Casper/Input/ChordBindingStore.swift`
- Test: `CasperTests/KeyChordTests.swift`
- Test: `CasperTests/ChordBindingStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testPhysicalKeyUsesRawKeyCodesForSideSpecificKeys()
func testKeyChordPreservesSideSpecificModifiers()
func testKeyChordRejectsEmptyChord()
func testBindingStorePersistsPushAndToggleChords()
func testBindingStoreRejectsDuplicateBindings()
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:CasperTests/KeyChordTests -only-testing:CasperTests/ChordBindingStoreTests`
Expected: FAIL because the new types do not exist yet.

- [ ] **Step 3: Write the minimal implementation**

```swift
enum ChordAction: String, Codable {
    case pushToTalk
    case toggleToTalk
}

struct PhysicalKey: Codable, Hashable {
    let keyCode: UInt16
}

struct KeyChord: Codable, Equatable {
    let keys: Set<PhysicalKey>
}
```

Implement `PhysicalKey` as a raw key-code wrapper so side-specific modifiers are encoded by their distinct hardware key codes, non-modifier keys like Space use the same type, and Globe can be recorded if it surfaces as a key code on the running hardware. Implement `ChordBindingStore` with exactly one binding per action, conflict validation, and `AppStorage`/`UserDefaults` persistence.

- [ ] **Step 4: Run the targeted tests to verify they pass**

Run the same command from Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Casper/Input/PhysicalKey.swift Casper/Input/KeyChord.swift Casper/Input/ChordAction.swift Casper/Input/ChordBindingStore.swift CasperTests/KeyChordTests.swift CasperTests/ChordBindingStoreTests.swift
git commit -m "feat: add chord bindings"
```

### Task 2: Replace Control-only matching with a chord engine

**Files:**
- Create: `Casper/Input/ChordEngine.swift`
- Modify: `Casper/Input/HotkeyMonitor.swift`
- Modify: `CasperTests/HotkeyMonitorTests.swift`
- Test: `CasperTests/ChordEngineTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testPrefixChordDoesNotFireEarly()
func testPushToTalkStartsImmediatelyWhenExactChordMatches()
func testToggleToTalkTogglesOnSecondMatch()
func testPushToTalkStopsWhenAnyRequiredKeyReleases()
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:CasperTests/ChordEngineTests -only-testing:CasperTests/HotkeyMonitorTests`
Expected: FAIL because prefix-aware chord matching does not exist.

- [ ] **Step 3: Write the minimal implementation**

```swift
enum ChordMatchResult {
    case none
    case prefix
    case exact(ChordAction)
}
```

Update `HotkeyMonitor` to observe `.flagsChanged`, `.keyDown`, and `.keyUp`, convert them into a small synthetic input event type, and delegate matching to `ChordEngine` instead of using `isControlOnly`. Keep `ChordEngine` testable as a pure reducer over synthetic key events so `HotkeyMonitorTests` do not depend on real Accessibility-backed taps. As part of this task, remove the existing 0.3-second hold timer path (`minimumHoldDuration`, `holdTimer`, `startHoldTimer`, `cancelHoldTimer`) and replace it with immediate exact-match start plus key-release stop semantics for both modifier and non-modifier keys.

- [ ] **Step 4: Run the targeted and full test suites**

Run targeted command from Step 2, then:
`xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Casper/Input/ChordEngine.swift Casper/Input/HotkeyMonitor.swift CasperTests/ChordEngineTests.swift CasperTests/HotkeyMonitorTests.swift
git commit -m "feat: add chord engine"
```

### Task 3: Add settings/onboarding support for push and toggle chords

**Files:**
- Create: `Casper/UI/ShortcutRecorderView.swift`
- Modify: `Casper/UI/SettingsWindow.swift`
- Modify: `Casper/UI/OnboardingWindow.swift`
- Modify: `Casper/AppState.swift`
- Test: `CasperTests/CasperTests.swift`

- [ ] **Step 1: Write the failing tests**

Add app-state-level tests that assert default bindings are loaded and both actions are wired into recording behavior.

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:CasperTests/CasperTests`
Expected: FAIL on missing shortcut defaults or missing recorder wiring.

- [ ] **Step 3: Write the minimal implementation**

Add a `Shortcuts` settings section, keep onboarding focused on the default behavior, and wire `AppState` to separate push/toggle callbacks without changing the rest of the transcription flow yet.

- [ ] **Step 4: Run the full test suite and build**

Run:
- `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test`
- `xcodebuild -project Casper.xcodeproj -scheme Casper -configuration Debug -derivedDataPath build/derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO build`
Expected: PASS / BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Casper/UI/ShortcutRecorderView.swift Casper/UI/SettingsWindow.swift Casper/UI/OnboardingWindow.swift Casper/AppState.swift CasperTests/CasperTests.swift
git commit -m "feat: add shortcut settings"
```

## Chunk 2: `codex/cleanup-model-picker`

### Task 4: Add explicit cleanup settings and local model policy

**Files:**
- Create: `Casper/Cleanup/CleanupSettings.swift`
- Modify: `Casper/Cleanup/TextCleanupManager.swift`
- Test: `CasperTests/TextCleanerTests.swift`
- Test: `CasperTests/TextCleanupManagerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testAutomaticPolicyPrefersFastForShortInput()
func testFastOnlyPolicyAlwaysReturnsFastWhenReady()
func testFullOnlyPolicyAlwaysReturnsFullWhenReady()
func testQuestionSelectionStillFlowsThroughManagerPolicy()
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:CasperTests/TextCleanupManagerTests`
Expected: FAIL because explicit policy types do not exist.

- [ ] **Step 3: Write the minimal implementation**

Add a persisted local policy enum and replace `model(for:)` with a manager-owned selection API that takes both `wordCount` and `isQuestion`, so `TextCleaner` no longer needs to bypass manager policy when it sees a question or long input. Make the manager testable with injected fake model handles or a tiny model-provider seam so the tests do not require real GGUF downloads.

- [ ] **Step 4: Run targeted and full tests**

Run targeted command from Step 2, then:
`xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Casper/Cleanup/CleanupSettings.swift Casper/Cleanup/TextCleanupManager.swift CasperTests/TextCleanupManagerTests.swift CasperTests/TextCleanerTests.swift
git commit -m "feat: add cleanup model policy"
```

### Task 5: Expose cleanup model policy in settings

**Files:**
- Modify: `Casper/UI/SettingsWindow.swift`
- Modify: `Casper/AppState.swift`
- Modify: `Casper/Cleanup/TextCleaner.swift`
- Test: `CasperTests/TextCleanerTests.swift`

- [ ] **Step 1: Write the failing test**

Add `TextCleaner`-level tests that verify the selected manager policy is consulted when cleanup runs, including question input and longer text.

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:CasperTests/TextCleanerTests`
Expected: FAIL because `TextCleaner.clean` still bypasses the selected policy.

- [ ] **Step 3: Write the minimal implementation**

Add a model picker under the `Cleanup` section and update `TextCleaner.clean` to delegate all local-model selection back to `TextCleanupManager`, including question input.

- [ ] **Step 4: Run the full test suite and build**

Run:
- `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test`
- `xcodebuild -project Casper.xcodeproj -scheme Casper -configuration Debug -derivedDataPath build/derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO build`
Expected: PASS / BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Casper/UI/SettingsWindow.swift Casper/AppState.swift Casper/Cleanup/TextCleaner.swift
git commit -m "feat: add cleanup model picker"
```

## Chunk 3: `codex/foundation-model-cleanup`

### Task 6: Introduce a pluggable cleanup backend layer

**Files:**
- Create: `Casper/Cleanup/CleanupBackend.swift`
- Create: `Casper/Cleanup/LocalLLMCleanupBackend.swift`
- Modify: `Casper/Cleanup/TextCleaner.swift`
- Modify: `Casper/Cleanup/TextCleanupManager.swift`
- Test: `CasperTests/CleanupBackendTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testLocalBackendUsesSelectedLocalPolicy()
func testCleanerFallsBackToCorrectedRawTextWhenBackendFails()
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:CasperTests/CleanupBackendTests`
Expected: FAIL because the backend abstraction does not exist.

- [ ] **Step 3: Write the minimal implementation**

```swift
protocol CleanupBackend {
    func clean(text: String, prompt: String) async throws -> String
}
```

Move the current `LLM.swift` cleanup behavior behind `LocalLLMCleanupBackend`, make failure explicit with `throws`, and have `TextCleaner` catch backend failure so it can fall back to the deterministic corrected text. Add an injected backend/model-provider seam so these tests can run against fakes instead of real model downloads.

- [ ] **Step 4: Run targeted and full tests**

Run targeted command from Step 2, then:
`xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Casper/Cleanup/CleanupBackend.swift Casper/Cleanup/LocalLLMCleanupBackend.swift Casper/Cleanup/TextCleaner.swift Casper/Cleanup/TextCleanupManager.swift CasperTests/CleanupBackendTests.swift
git commit -m "refactor: add cleanup backend abstraction"
```

### Task 7: Add the optional Foundation Models backend

**Files:**
- Create: `Casper/Cleanup/FoundationModelsCleanupBackend.swift`
- Create: `Casper/Cleanup/FoundationModelAvailabilityProvider.swift`
- Modify: `Casper/Cleanup/CleanupSettings.swift`
- Modify: `Casper/UI/SettingsWindow.swift`
- Modify: `Casper/AppState.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testFoundationBackendUnavailableFallsBackToLocal()
func testFoundationBackendAvailabilityReasonIsExposed()
func testFoundationAvailabilityCanBeStubbedInTests()
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:CasperTests/CleanupBackendTests`
Expected: FAIL because there is no Foundation Models backend or fallback behavior.

- [ ] **Step 3: Write the minimal implementation**

Guard Foundation Models code with `if #available(macOS 26.0, *)` and `SystemLanguageModel` availability checks so the app still compiles and runs on macOS 14.0+. Put all direct Foundation Models availability reads behind a small injectable provider protocol so the macOS 14-targeted tests can stub available/unavailable states and reasons deterministically, and use a backend factory/provider seam so fallback behavior can be tested without invoking the real system model.

- [ ] **Step 4: Run the full test suite and build**

Run:
- `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test`
- `xcodebuild -project Casper.xcodeproj -scheme Casper -configuration Debug -derivedDataPath build/derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO build`
Expected: PASS / BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Casper/Cleanup/FoundationModelsCleanupBackend.swift Casper/Cleanup/FoundationModelAvailabilityProvider.swift Casper/Cleanup/CleanupSettings.swift Casper/UI/SettingsWindow.swift Casper/AppState.swift CasperTests/CleanupBackendTests.swift
git commit -m "feat: add foundation models cleanup backend"
```

## Chunk 4: `codex/ocr-context`

Reference implementation notes:

- Use the local ignored reference checkout at `inspo/winby` during implementation.
- Start with:
  - `inspo/winby/Sources/Winby/AppConfig.swift`
  - `inspo/winby/Sources/Winby/WindowManager+Screenshots.swift`
  - `inspo/winby/Sources/Winby/WindowManager+ContentSearch.swift`
  - `inspo/winby/docs/screenshot-capture.md`
- Relevant APIs already exercised there:
  - `CGPreflightScreenCaptureAccess()`
  - Screen Recording settings URL
  - `SCShareableContent`, `SCContentFilter`, `SCScreenshotManager.captureImage`
  - `VNRecognizeTextRequest` in accurate mode

### Task 8: Add permission-aware window capture and OCR services

**Files:**
- Create: `Casper/Context/OCRContext.swift`
- Create: `Casper/Context/OCRRequestFactory.swift`
- Create: `Casper/Context/WindowCaptureService.swift`
- Create: `Casper/Context/FrontmostWindowOCRService.swift`
- Modify: `Casper/PermissionChecker.swift`
- Test: `CasperTests/OCRContextTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testOCRRequestFactoryUsesAccurateRecognitionLevel()
func testOCRRequestFactoryEnablesLanguageCorrection()
func testOCRRequestFactoryAcceptsCustomWords()
func testMissingScreenRecordingPermissionDisablesCapture()
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:CasperTests/OCRContextTests`
Expected: FAIL because capture/OCR services do not exist.

- [ ] **Step 3: Write the minimal implementation**

Add an `OCRRequestFactory` that builds the configured `VNRecognizeTextRequest` so tests can assert request settings directly. The factory should accept `customWords` as input even if the initial caller passes an empty list, so branch 5 can plug preferred words in without refactoring the OCR service. Add Screen Recording helpers to `PermissionChecker`, and keep the OCR service injectable with a permission provider and window-capture source so tests do not require real capture permissions.

- [ ] **Step 4: Run targeted and full tests**

Run targeted command from Step 2, then:
`xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Casper/Context/OCRContext.swift Casper/Context/OCRRequestFactory.swift Casper/Context/WindowCaptureService.swift Casper/Context/FrontmostWindowOCRService.swift Casper/PermissionChecker.swift CasperTests/OCRContextTests.swift
git commit -m "feat: add OCR context services"
```

### Task 9: Inject OCR context into the cleanup prompt

**Files:**
- Create: `Casper/Cleanup/CleanupPromptBuilder.swift`
- Modify: `Casper/AppState.swift`
- Modify: `Casper/Cleanup/TextCleaner.swift`
- Modify: `Casper/UI/SettingsWindow.swift`
- Test: `CasperTests/CleanupPromptBuilderTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testBuilderIncludesWindowContentsWrapperWhenContextEnabled()
func testBuilderOmitsWindowContentsWhenContextUnavailable()
func testBuilderTrimsLongOCRContextBeforePromptAssembly()
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:CasperTests/CleanupPromptBuilderTests`
Expected: FAIL because prompt assembly still lives inline in the cleanup path.

- [ ] **Step 3: Write the minimal implementation**

Move prompt assembly into `CleanupPromptBuilder`, add a `Context` settings section, collect OCR text only when enabled and permitted, and inject it using the exact `<WINDOW CONTENTS>` wrapper from the spec.

- [ ] **Step 4: Run the full test suite and build**

Run:
- `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test`
- `xcodebuild -project Casper.xcodeproj -scheme Casper -configuration Debug -derivedDataPath build/derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO build`
Expected: PASS / BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Casper/Cleanup/CleanupPromptBuilder.swift Casper/AppState.swift Casper/Cleanup/TextCleaner.swift Casper/UI/SettingsWindow.swift CasperTests/CleanupPromptBuilderTests.swift
git commit -m "feat: inject OCR context into cleanup"
```

## Chunk 5: `codex/preferred-transcriptions`

### Task 10: Add the correction store and deterministic correction engine

**Files:**
- Create: `Casper/Cleanup/CorrectionStore.swift`
- Create: `Casper/Cleanup/DeterministicCorrectionEngine.swift`
- Modify: `Casper/Cleanup/TextCleaner.swift`
- Test: `CasperTests/TextCleanerTests.swift`
- Test: `CasperTests/CorrectionStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testPreferredTranscriptionsPreserveConfiguredPhrase()
func testCommonlyMisheardReplacementAppliesBeforeCleanup()
func testPreferredTranscriptionsWinOverBroadReplacement()
func testDeterministicCorrectionsStillApplyWhenNoCleanupBackendIsAvailable()
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:CasperTests/CorrectionStoreTests`
Expected: FAIL because the store and deterministic correction engine do not exist.

- [ ] **Step 3: Write the minimal implementation**

Persist both lists locally, apply them deterministically before any backend call, re-apply protected preferred phrases after cleanup when necessary, and keep the deterministic correction layer active even when no cleanup backend/model is available.

- [ ] **Step 4: Run targeted and full tests**

Run targeted command from Step 2, then:
`xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Casper/Cleanup/CorrectionStore.swift Casper/Cleanup/DeterministicCorrectionEngine.swift Casper/Cleanup/TextCleaner.swift CasperTests/CorrectionStoreTests.swift CasperTests/TextCleanerTests.swift
git commit -m "feat: add deterministic transcription corrections"
```

### Task 11: Add corrections UI and feed preferred words into OCR

**Files:**
- Modify: `Casper/UI/SettingsWindow.swift`
- Modify: `Casper/Context/FrontmostWindowOCRService.swift`
- Modify: `Casper/AppState.swift`
- Modify: `Casper/Cleanup/CorrectionStore.swift`
- Modify: `CasperTests/CasperTests.swift`

- [ ] **Step 1: Write the failing tests**

Add `CorrectionStoreTests` and `CasperTests` coverage that preferred words are forwarded into the OCR configuration and that correction settings round-trip through app state/store persistence.

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:CasperTests/CorrectionStoreTests -only-testing:CasperTests/CasperTests`
Expected: FAIL because the UI wiring and OCR custom words integration do not exist.

- [ ] **Step 3: Write the minimal implementation**

Add a `Corrections` settings section with editor affordances for both lists and route preferred words into OCR `customWords`.

- [ ] **Step 4: Run the full test suite and build**

Run:
- `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test`
- `xcodebuild -project Casper.xcodeproj -scheme Casper -configuration Debug -derivedDataPath build/derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO build`
Expected: PASS / BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Casper/UI/SettingsWindow.swift Casper/Context/FrontmostWindowOCRService.swift Casper/AppState.swift Casper/Cleanup/CorrectionStore.swift CasperTests/CorrectionStoreTests.swift CasperTests/CasperTests.swift
git commit -m "feat: add corrections settings"
```

## Chunk 6: `codex/learn-misheard`

### Task 12: Add paste metadata capture and the delayed learning coordinator

**Files:**
- Create: `Casper/Input/PasteSession.swift`
- Create: `Casper/Context/FocusedElementLocator.swift`
- Create: `Casper/Cleanup/PostPasteLearningCoordinator.swift`
- Modify: `Casper/Input/TextPaster.swift`
- Modify: `Casper/AppState.swift`
- Test: `CasperTests/PostPasteLearningCoordinatorTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testCoordinatorStartsLearningPassAfterPasteDelay()
func testCoordinatorRejectsLargeRewriteDiffs()
func testCoordinatorStoresHighConfidenceNarrowReplacement()
func testCoordinatorUsesInjectedSchedulerInsteadOfRealSleep()
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:CasperTests/PostPasteLearningCoordinatorTests`
Expected: FAIL because the learning coordinator does not exist.

- [ ] **Step 3: Write the minimal implementation**

Introduce a `PasteSession` contract that captures pasted text, timestamp, frontmost app bundle identifier, frontmost window identifier if available, window frame, and focused-element frame snapshot at paste time. Have `TextPaster` expose a completion hook that hands off a `PasteSession`, and give `PostPasteLearningCoordinator` an injected scheduler/clock so the 15-second delay is testable without real sleeps. Use that session to revisit the destination, prefer OCR on the saved focused-element region when it still makes sense, fall back to the saved window region when focus has moved, and only persist narrow, high-confidence replacements.

- [ ] **Step 4: Run targeted and full tests**

Run targeted command from Step 2, then:
`xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Casper/Input/PasteSession.swift Casper/Context/FocusedElementLocator.swift Casper/Cleanup/PostPasteLearningCoordinator.swift Casper/Input/TextPaster.swift Casper/AppState.swift CasperTests/PostPasteLearningCoordinatorTests.swift
git commit -m "feat: add post-paste learning"
```

### Task 13: Add user-facing learning controls and final verification

**Files:**
- Modify: `Casper/UI/SettingsWindow.swift`
- Modify: `Casper/Cleanup/CorrectionStore.swift`
- Modify: `Casper/Cleanup/PostPasteLearningCoordinator.swift`
- Modify: `Casper/AppState.swift`
- Modify: `CasperTests/CasperTests.swift`

- [ ] **Step 1: Write the failing tests**

Add `CasperTests` and `PostPasteLearningCoordinatorTests` coverage for learning enablement/disablement and rejection of ambiguous OCR corrections even when learning is on.

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:CasperTests/PostPasteLearningCoordinatorTests -only-testing:CasperTests/CasperTests`
Expected: FAIL because learning controls are not wired into the coordinator.

- [ ] **Step 3: Write the minimal implementation**

Add settings for learning behavior, keep automatic learning conservative, and default to discarding ambiguous candidates.

- [ ] **Step 4: Run the complete verification suite**

Run:
- `xcodebuild -project Casper.xcodeproj -scheme Casper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test`
- `xcodebuild -project Casper.xcodeproj -scheme Casper -configuration Debug -derivedDataPath build/derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO build`

Smoke-check:
- launch the built app
- verify push-to-talk and toggle-to-talk both trigger
- verify Screen Recording status messaging
- verify cleanup backend/model switching
- verify OCR context injection and delayed learning flow on a manual correction

Expected: PASS / BUILD SUCCEEDED / manual smoke path works.

- [ ] **Step 5: Commit**

```bash
git add Casper/UI/SettingsWindow.swift Casper/Cleanup/CorrectionStore.swift Casper/Cleanup/PostPasteLearningCoordinator.swift Casper/AppState.swift CasperTests/CasperTests.swift
git commit -m "feat: finalize transcription learning controls"
```

## Execution Notes

- Run `xcodegen generate` after every task that creates, deletes, or renames Swift files.
- Create a fresh implementation worktree before branch 1 execution.
- Stack branches in order:
  - `codex/chord-actions`
  - `codex/cleanup-model-picker`
  - `codex/foundation-model-cleanup`
  - `codex/ocr-context`
  - `codex/preferred-transcriptions`
  - `codex/learn-misheard`
- After each chunk, request review before moving to the next chunk.
- Keep commits narrow. Do not mix branch-N work into branch-(N+1).
