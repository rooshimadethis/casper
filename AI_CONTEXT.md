# Casper AI Context

This document contains canonical, project-specific context for developers and AI agents working on Casper.

---

## 1. Project Overview & Tech Stack
* **Platform:** macOS 14.0+
* **Language:** Swift 6 (strict concurrency warnings checked)
* **Framework:** SwiftUI
* **Architecture:** Living in the menu bar (`MenuBarExtra`), utilizing `AppState` as a centralized `@MainActor` state store.

---

## 2. Core Modules & Key Dependencies

### 🎙️ Speech-to-Text & Transcription
* **Library:** [WhisperKit](https://github.com/argmaxinc/WhisperKit) (argmaxinc) & [FluidAudio](https://github.com/FluidInference/FluidAudio).
* **Location:** `Casper/Transcription/`
* **Mechanisms:**
  * Uses `AVAudioEngine` for mic capture.
  * Hold Control to dictate, release to paste.

### 🧠 Local LLM Inference
* **Library:** [LLM.swift](https://github.com/eastriverlee/LLM.swift) (runs GGUF models locally via llama.cpp/Metal).
* **Location:** `Casper/Cleanup/` and `Casper/QA/`
* **Models Cache:** `~/Library/Application Support/Casper/models/`
* **Configured Models:**
  * `Qwen3.5-0.8B-Q4_K_M.gguf` (Compact/Fastest)
  * `Qwen3.5-2B-Q4_K_M.gguf` (Default Fast)
  * `Qwen3.5-4B-Q4_K_M.gguf` (Full Quality)
  * `DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf` (Reasoning/Agent Loops)

### 🖥️ Screen Perception & OCR
* **Location:** `Casper/Context/` and `Casper/Reader/`
* **Mechanisms:**
  * `FrontmostWindowOCRService` takes screenshots of the frontmost window using `ScreenCaptureKit` and performs text recognition locally via Apple's native `Vision` framework.
  * `MeetingDetector` polls window titles to detect active video calls (Zoom, Teams, Slack, FaceTime, Meet) or video pages (Loom, Vimeo, Twitch, Netflix, Dailymotion) to offer transcription.

### ⌨️ Desktop Input & Pasting
* **Location:** `Casper/Input/TextPaster.swift`
* **Mechanisms:**
  * Simulates `Cmd+V` keystrokes via `CGEvent`.
  * Preserves and restores user clipboard state around paste events.
  * Uses Accessibility APIs (`AXUIElement`) to detect editable text fields.

---

## 3. Established Context & Recent Changes

### 🚀 App Launch Behavior
* **Constraint:** The app starts quietly directly in the menu bar. 
* **Details:** Automatic opening of the `MeetingTranscriptWindow` on app launch (or upon onboarding completion) has been **disabled** (modified in `CasperApp.swift`).
* **No launch announcement modal:** The legacy `What's New in Casper` announcement alert in `AppState.initialize()` has been removed. Agents should not restore a startup modal for feature announcements; prefer passive discoverability inside the menu bar UI or explicit user-invoked surfaces.
* **Activation Policy:** The onboarding window sets activation policy to `.regular`. When dismissed, it restores the policy to `.accessory` so the app runs solely as a status item in the menu bar.
* **Brand asset generation:** `scripts/generate_brand_assets.swift` regenerates `AppIcon.appiconset` from `casper-logo.png` and the menu bar icon variants from `casper-plain.png`. The macOS menu bar image sets now intentionally ship only `1x` and `2x` entries to avoid `actool` unassigned-child warnings.

### 🚫 YouTube Transcription Dialogs
* **Constraint:** The app must NOT prompt the user or open dialogs to transcribe YouTube videos.
* **Details:** All YouTube rules have been **removed** from `MeetingDetector.swift`'s `videoSiteRules`, preventing the visual/browser detector from firing events for YouTube pages.

### 🤖 Computer Use / Passive Agent (Laying Foundation)
* **Location:** [DesktopAgentBridge.swift](file:///Users/rooshi/Documents/programming/mac/casper/Casper/QA/DesktopAgentBridge.swift)
* **Design Pattern:**
  * **User Events:** `DesktopUserEvent` models app activation, window title changes, copy buffer modifications, shell execution outputs, and screen OCR captures.
  * **Workspace Context:** `DesktopWorkspaceContext` maintains state.
  * **Evaluation Heuristics:** Filter functions ensure the local LLM is only invoked during high-value events (e.g. CLI failures, manual queries, copy events).
  * **Just-in-Time (JIT) Recommendations:** The agent returns a JSON array of `DesktopAgentRecommendation` objects suggesting JIT actions like pasting context-aware content or executing Terminal scripts.

### 🔮 Prediction Engine Direction
* **Product shape:** Prediction work should optimize toward chain-of-actions suggestions, not isolated next-event hints. The goal is to recognize workflows like deploy/debug/reporting loops and surface the immediate next action with the rest of the likely chain as context.
* **Architecture boundary:** `PpmTrie` should remain a low-level successor model that answers "what tends to happen next?" The product-level direction is `ActionChainPrediction` / `PredictedActionStep`, where chain rollout bridges through context tokens and only surfaces executable or previewable action steps.
* **Micro state role:** `MicroStore` enriches predicted `k:` and `m:` steps with concrete text or click targets. It should support suffix fallback and action-specific thresholds so exact full-context matches are not required while telemetry is sparse.
* **Telemetry weighting:** Prediction training should preserve sparse workflow evidence. Events from the recent month stay full weight; older history contributes fractional nonzero evidence rather than disappearing during integer conversion.

### 📊 Local Telemetry Session Summaries
* **Location:** `Casper/Telemetry/`
* **Storage Shape:** Raw telemetry is written as timestamped `TelemetryEventRecord` JSONL entries, not bare `DesktopUserEvent` values. `TelemetryStorage.loadEventRecords(...)` remains backward-compatible with legacy lines by synthesizing fallback timestamps from file date + line offset.
* **Summarization Behavior:** `TelemetrySummarizer` now batches raw logs into discrete sessions using a 10-minute inactivity gap between adjacent records, writes one summary file per session, and persists processed-line progress in `sessions/session_progress.json` instead of deleting whole daily log files after a single pass.
* **Manual Dogfood Triggers:** Scheduled summarization still runs only when the user has been idle for 10 minutes, and scheduled report generation still runs only on AC power for the previous day. For post-feature dogfooding, Settings → General now exposes manual triggers that bypass those gates: `Summarize telemetry now` forces pending session summarization immediately, and `Generate telemetry report now` writes a same-day report for the current telemetry date.
* **Menu Bar Telemetry Visibility:** The menu bar panel now shows a lightweight telemetry health section with a live status headline, today's event count, today's session-summary count, plus shortcuts to open the raw telemetry folder and the session-summary folder in Finder.
* **Agent Dogfood Flow:** When a user wants a local dogfood build installed after validation, prefer `scripts/dogfood-install.sh` over a bare `xcodebuild test`. That script runs the configured test command first and, only on success, installs the fresh Debug build to the local app path and launches it automatically. Agents should use this flow instead of stopping at test success when the user asks to dogfood or install the latest local build.
* **Dogfood Script Defaults:** `scripts/dogfood-install.sh` reuses an existing installed app path first (`~/Applications/Casper.app` or `/Applications/Casper.app`) so Accessibility/Input Monitoring TCC grants stay attached across reinstalls; otherwise it defaults to `/Applications/Casper.app` (to save it to the applications directory where all applications are usually installed). Unless the caller explicitly passes test selection flags, it also skips `CasperTests/CleanupPromptEvalTests` by default because those live model evals are intentionally slow and are not the right default gate for every dogfood loop. Set `DOGFOOD_APP_PATH` to override the install target, `DOGFOOD_INCLUDE_SLOW_TESTS=1` to re-include the live eval suite, or `DOGFOOD_SKIP_DEFAULT_TEST_FILTERS=1` to fully control test filtering yourself.
* **Quiet Install Launch:** `scripts/dogfood-install.sh` now launches the installed app with `--quiet-install` by default so first-run onboarding does not auto-pop after dogfood installs. `CasperApp` treats that flag as a one-launch suppression of automatic onboarding while still initializing the app and keeping `Show Setup Window` available from the menu bar. Set `QUIET_INSTALL_ON_LAUNCH=0` to restore the normal launch behavior during install automation.
* **Brand Refresh in Dogfood Flow:** `scripts/dogfood-install.sh` now regenerates `AppIcon.appiconset` and menu bar icon assets from `casper-logo.png` and `casper-plain.png` before validation/build, so local installs pick up the latest Casper branding without requiring a separate manual asset-generation step. Set `DOGFOOD_SKIP_BRAND_ASSETS=1` only when intentionally bypassing that refresh.
* **Signed Dogfood Builds Matter:** Do not install the app bundle produced by `xcodebuild test` when validating permission-sensitive behavior. The test command runs with code signing disabled to keep CLI validation reliable, but a freshly replaced unsigned/ad-hoc app can lose effective TCC identity even while System Settings still shows an older Casper row under Accessibility or Input Monitoring. `scripts/dogfood-install.sh` now follows the unsigned test pass with a separate normal `xcodebuild build` and installs that signed app bundle instead.

### 🧪 Targeted Xcode Validation
* **Working command:** For telemetry-targeted validation, use:
  ```bash
  xcodebuild test \
    -project Casper.xcodeproj \
    -scheme Casper \
    -destination 'platform=macOS' \
    -derivedDataPath .deriveddata \
    -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/Casper-hfmhqrbjcvzfnwfbhqzxsdkhcbxk/SourcePackages \
    -disableAutomaticPackageResolution \
    -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY='' \
    -only-testing:CasperTests/TelemetryStorageTests \
    -only-testing:CasperTests/TelemetryAgentTests \
    -only-testing:CasperTests/RuntimeEnvironmentTests
  ```
* **Why this matters:** Casper depends on cached Swift package checkouts outside the repo, the `LLM.swift` package requires `-skipMacroValidation` in CLI builds, and local validation can fail on machines without a matching `Mac Development` signing identity unless code signing is disabled for the test run. Read the logs of previous testing runs for more details on failures if you can instead of rerunning
* **Hosted test guard:** `CasperApp` now treats `XCTestConfigurationFilePath` as a hard signal that the process is running as a hosted test app and skips onboarding plus app initialization side effects in that mode. Reuse `RuntimeEnvironment.isRunningTests` for any future startup behavior that should not run under `xcodebuild test`.
* **Dogfood Install Command:** When finished with testing , install, and launch a fresh local app build in one step, use:
  ```bash
  scripts/dogfood-install.sh \
    -only-testing:CasperTests/TelemetryStorageTests \
    -only-testing:CasperTests/TelemetryAgentTests \
    -only-testing:CasperTests/RuntimeEnvironmentTests
  ```
  The script reuses the same DerivedData/package-cache assumptions as the working test command, then replaces the local installed app bundle and opens it automatically. Override `DOGFOOD_APP_PATH` if the install target should not be `/Applications/Casper.app`.

---

## 4. Product Roadmap & Future Direction Ideas

1. **Desktop Memex (Local History Search):** Summarize and index text/OCR captures into a local database for natural language history retrieval.
2. **Developer Context Auto-fill:** Auto-generate git commit messages or link active code files with browser ticket context.
3. **Self-Healing Terminal Helper:** Automatically intercept failed command line outputs, run it through the local LLM, and offer a click-to-run resolution.
4. **Idle Task Orchestrator:** Queue heavy LLM work (like meeting transcript cleanups) to execute only when user input is idle.
