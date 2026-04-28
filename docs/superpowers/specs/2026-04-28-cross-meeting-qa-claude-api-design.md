# Cross-Meeting Q&A: Claude API Backend, Streaming, Cost Display

## Problem

Commit `1a39495` ("feat: cross-meeting Q&A with Qwen3 8B support") forces the Qwen 3 8B local model (~5 GB, 8B params) for every cross-meeting Q&A request. On Matt's hardware this freezes the machine. The committed change has no escape hatch; reopening the meeting window and submitting any question triggers the freeze again.

In-progress uncommitted work in `AppState.swift` and `SettingsWindow.swift` already adds a backend picker (Local vs. Claude API) and a Settings card for the API key, but the defaults still point at local + 8B, so the freeze ships in the next launch unless the user manually changes settings first.

## Goal

Make cross-meeting Q&A safe, fast, and cheap by default, while keeping a working local fallback for offline use.

## Approach

### 1. Defaults

| Setting | Old default | New default |
|---|---|---|
| `meetingQABackend` | `.local` | `.claudeAPI` |
| `claudeAPIModel` | `claude-opus-4-7` | `claude-sonnet-4-6` |
| `meetingQAModelKind` (local) | `qwen3_8b_q4_k_m` | `qwen35_2b_q4_k_m` |

Drop or repoint `LocalCleanupModelKind.qa` (currently `= .qwen3_8b_q4_k_m`) — it's the only thing that mentions 8B as canonical for Q&A and is the source of the freeze.

### 2. Auto-open Settings on missing API key

When the user submits a question, backend = Claude API, key empty:
- Open Settings window directly to the Meeting Transcript section.
- Place an inline notice in the Q&A bar: "Add your Claude API key to continue — Settings opened."
- Do not run the question; user re-submits after entering the key.

Implementation:
- `SettingsWindowController.show(appState:)` → `show(appState:section:)` with optional initial section.
- Lift `selectedSection` selection via a `NotificationCenter` event `.showSettingsSection` carrying a `SettingsSection`. `SettingsView` subscribes and updates its `@State`. (Avoids invasive refactor of SettingsView's state ownership.)

### 3. Streaming Claude responses

Add a streaming variant on `ClaudeAPIClient`:

```swift
func askStream(systemPrompt: String, meetingContext: String, question: String)
    -> AsyncThrowingStream<QAStreamEvent, Error>
```

- Hits `POST /v1/messages` with `stream: true`.
- Parses SSE event stream: `message_start`, `content_block_delta` (text deltas), `message_delta` (final usage), `message_stop`.
- Yields:
  - `.text(String)` for each token delta.
  - `.usage(QAUsage)` once at end with totals from `message_start.message.usage` + `message_delta.usage`.

Change `MeetingTranscriptDisplayState.onAskQuestion` from:
```swift
((_ question: String, _ context: String) async -> String)?
```
to:
```swift
((_ question: String, _ context: String) -> AsyncThrowingStream<QAStreamEvent, Error>)?
```

The Q&A bar in `MeetingTranscriptWindow` consumes the stream, appends `.text` deltas live to `qaAnswer`, and renders the usage footer when `.usage` arrives.

**Local backend stays non-streaming.** It emits a single `.text(fullAnswer)` followed by a `.usage(...)` event with model name "Qwen 3.5 2B", token estimates (rough word-count heuristic), and `costUSD: 0`.

### 4. Cost / usage display

```swift
struct QAUsage {
    let modelDisplayName: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int      // 0 for local
    let cacheWriteTokens: Int     // 0 for local
    let estimatedCostUSD: Double  // 0 for local
}

enum QAStreamEvent {
    case text(String)
    case usage(QAUsage)
}
```

New `GhostPepper/QA/ClaudePricing.swift` with hardcoded rates (per 1M tokens):

| Model | Input | Output | Cache write | Cache read |
|---|---|---|---|---|
| Opus 4.7 | $15.00 | $75.00 | input × 1.25 | input × 0.10 |
| Sonnet 4.6 | $3.00 | $15.00 | input × 1.25 | input × 0.10 |
| Haiku 4.5 | $1.00 | $5.00 | input × 1.25 | input × 0.10 |

Cost formula:
```
regularInput = input - cacheRead - cacheWrite
cost = regularInput * inputRate
     + cacheRead * inputRate * 0.10
     + cacheWrite * inputRate * 1.25
     + output * outputRate
   (all divided by 1_000_000)
```

The 1M-context tier (Opus over 200k input) is **out of scope for v1**; Q&A context is well under 200k.

UI footer line under each answer:
- Cloud: `Sonnet 4.6 · 12,450 in (8,200 cached) / 487 out · ~$0.0441`
- Local: `Qwen 3.5 2B · ~8,200 in / ~412 out · free`

Pricing constants are hardcoded; a comment in `ClaudePricing.swift` notes they should be reviewed against `https://docs.anthropic.com/en/docs/about-claude/pricing` at each release.

### 5. Other cleanup

- `MeetingTranscriptWindow.swift:508` fallback message: replace "download the Qwen 3 8B model" with "Open Settings → Meeting Transcript → Cross-Meeting Q&A to configure."
- The "Searched: …" source line stays as-is.

## Files

| File | Change |
|---|---|
| `GhostPepper/QA/QABackendKind.swift` | Add `QAStreamEvent`, `QAUsage` |
| `GhostPepper/QA/ClaudeAPIClient.swift` | Add `askStream`; SSE parser; usage extraction |
| `GhostPepper/QA/ClaudePricing.swift` (new) | Pricing rates + cost estimator |
| `GhostPepper/AppState.swift` | Flip defaults; rewire controller to stream; open-settings on missing key |
| `GhostPepper/UI/SettingsWindow.swift` | `show(appState:section:)`; NotificationCenter listener for section selection |
| `GhostPepper/UI/MeetingTranscriptWindow.swift` | Change `onAskQuestion` signature; consume stream; render usage footer; fix fallback message |
| `GhostPepper/Cleanup/TextCleanupManager.swift` | Drop or repoint `static var qa` |
| `GhostPepper.xcodeproj/project.pbxproj` | Register `ClaudePricing.swift` |

## Out of scope

- Streaming for the local backend (could land later).
- Auto-correcting stale pricing (would require remote config or a built-in updater).
- Settings deep-linking to a specific card within a section (just open the right section; user scrolls).
- Pre-existing 1M-context Opus pricing tier above 200k input.
- Cost/usage history aggregation across sessions.

## Risks

- **Pricing accuracy.** Hardcoded rates go stale. Mitigation: comment in source pointing to Anthropic docs; review at each release.
- **Streaming timeout / connection drop.** A long answer that disconnects mid-stream leaves a partial UI state. Mitigation: catch the error in the consumer and append "[stream interrupted]" rather than throwing away what's already displayed.
- **Async signature change is contagious.** `onAskQuestion` is the only consumer; risk is bounded.
