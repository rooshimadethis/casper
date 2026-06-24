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
* **Activation Policy:** The onboarding window sets activation policy to `.regular`. When dismissed, it restores the policy to `.accessory` so the app runs solely as a status item in the menu bar.

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

---

## 4. Product Roadmap & Future Direction Ideas

1. **Desktop Memex (Local History Search):** Summarize and index text/OCR captures into a local database for natural language history retrieval.
2. **Developer Context Auto-fill:** Auto-generate git commit messages or link active code files with browser ticket context.
3. **Self-Healing Terminal Helper:** Automatically intercept failed command line outputs, run it through the local LLM, and offer a click-to-run resolution.
4. **Idle Task Orchestrator:** Queue heavy LLM work (like meeting transcript cleanups) to execute only when user input is idle.
