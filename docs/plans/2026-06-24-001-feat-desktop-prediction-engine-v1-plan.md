---
date: 2026-06-24
type: feat
topic: desktop-prediction-engine-v1
status: active
---

# Plan: Desktop Prediction Engine V1 — Macro Layer (PPM Trie)

## Summary

Implement a near real-time prediction engine that learns user behavior patterns from raw telemetry JSONL files and predicts the next desktop event type using PPM (Prediction by Partial Matching). V1 covers the macro layer only — predicting event category + app (e.g., "user will activate Chrome") — using 3 normalized token types (`a:{bundleID}`, `c:{app}:{shortText}`, `m:{app}:{role}`). All training and inference is algorithmic (counter insertion, no model weights, no LLM). The micro layer (specific value prediction) is deferred to V2.

## Problem Frame

(see origin: `docs/brainstorms/2026-06-24-prediction-engine-requirements.md`)

Casper's `TelemetryCollector` captures workspace events into raw JSONL files. These are summarized offline into narrative reports via `TelemetrySummarizer`, but there's no real-time prediction of what the user is about to do. Running a local LLM on every event costs 0.5-2s per generation — too expensive for the 2s polling loop. An algorithmic prediction engine must live in the low-overhead regime.

The macro layer (predicting *when* an event type occurs) is a **sequence prediction** problem — order matters, variable-length contexts. PPM's escape-weighted backoff blends predictions across all context depths (n=1..5), gracefully degrading when an exact match is absent.

## Scope Boundaries

### In scope for V1
- Macro PPM trie with 3 event token types: `a:{bundleID}`, `c:{app}:{shortText}`, `m:{app}:{role}`
- PPM backoff blending with configurable escape penalties and confidence threshold (default 0.5)
- Training by batch-processing raw JSONL files (reuses telemetry idle-time trigger)
- Suggestion surface: floating on-top overlay window showing the latest prediction, with action and dismiss buttons
- Toggle overlay visibility from menu bar (show/hide)
- Manual retrain button in Casper Settings
- Performance measurement via `os_signpost` to validate <1ms query time

### Deferred (V2)
- Micro layer flat dictionaries for specific value prediction (what text was typed, what was clicked)
- `k:{app}` and `m:{app}:{role}` suggestion support (requires micro layer)
- Live context enrichment — insert active workspace state (current window titles, open URLs) into suggestions using a `LiveContextBuffer` populated from recent events. This is runtime-only and learns nothing; it enriches "Switch to Chrome" into "Switch to Chrome (PR #42)" from the most recent `windowTitleChanged` event.
- Time-of-day weighting in PPM
- `commandExecuted` event wiring and tokenization
- `userHesitated` token and hesitation-triggered predictions
- User feedback loop (accept/reject tracking for threshold tuning)
- Automatic threshold tuning based on acceptance rate

### Outside scope
- Cloud-based pattern matching or telemetry upload
- LLM involvement at any stage of prediction
- Predictive typing or auto-completion beyond exact repetition
- Micro layer (V2)

## Key Technical Decisions

### PPM escape penalties
The escape multiplier sequence: depth 3 → 0.5, depth 2 → 0.3, depth 1 → 0.15. Depth 4 and 5 have no penalty (1.0). These values bias toward longer contexts and are configurable via a constants struct. The blending formula: for each depth d, multiply each child's count by its depth's escape multiplier, sum across depths, sort descending, and normalize to [0, 1] by dividing by the total weighted sum.

### Persistence format: JSON via Codable
The trie nodes form a tree of Codable structs. JSON is simple and debuggable; the estimated trie size (~few thousand nodes across ~15 apps) makes JSON's verbosity irrelevant. Stored at `~/Library/Application Support/Casper/prediction/ppm_trie.json`. The `TelemetryStorage` JSONL pattern and `DebugLogStore`/`RecognizedVoiceStore` Codable pattern are the direct precedents (see origin: `Casper/Telemetry/TelemetryStorage.swift`, `Casper/Debug/DebugLogStore.swift`).

### PredictionTrainer reuses TelemetrySummarizer's idle-gating architecture
Instead of adding a separate timer, extend `TelemetrySummarizer`'s existing 5-minute check to also trigger `PredictionTrainer.train()` when idle and on AC power. This avoids additional system overhead while piggybacking on the proven power-monitoring gate pattern (see origin: `Casper/Telemetry/TelemetrySummarizer.swift`).

### Floating overlay window for suggestions instead of menu bar or DesktopAgentBridge
Predictions are time-sensitive — the user needs to see "Switch to Chrome?" immediately, not hunt for it in a menu bar dropdown. A small floating `NSPanel` at `.floating` level (always on top, non-focusable) shows the latest prediction with an action button and a dismiss button. It auto-shows when a prediction exceeds threshold and auto-hides after dismissal or when context advances. A menu bar toggle controls overlay visibility. This follows the existing `NSWindowController` + `NSHostingView` pattern (see `SettingsWindowController`, `MeetingTranscriptWindowController`).

## Implementation Units

### U1. Tokenizer

**Goal:** Normalize a `DesktopUserEvent` into a compact token string according to the schema. Strips coordinates, full text, window titles — keeps only the semantically stable fields that repeat.

**Requirements:** R1 (see origin: `docs/brainstorms/2026-06-24-prediction-engine-requirements.md`)

**Dependencies:** None (standalone pure function over `DesktopUserEvent`)

**Files:**
- Create: `Casper/Prediction/Tokenizer.swift`
- Create: `CasperTests/TokenizerTests.swift`

**Approach:**
- Single static method `Tokenizer.tokenize(_ event: DesktopUserEvent) -> String?` returning nil for event types outside V1 scope
- Switch over the enum, extracting only the relevant fields per the schema:
  - `.appActivated(let _, let bundleID, _)` → `"a:\(bundleID)"`
  - `.textCopied(let text)` → if text.count <= 80, `"c:\(appName):\(truncated(text, 40))"`, else nil (long text never repeats)
  - `.mouseClicked(let app, let element, _, _)` → `"m:\(app):\(role)"` extracted from element (parse "AXButton (Title: …)" → keep only "AXButton")
  - `.typingSession`, `.windowTitleChanged`, `.userHesitated`, etc. → nil (V2)
- Text truncation: first 40 characters, whitespace-trimmed
- Role extraction: parse the `elementClicked` string (format from `DesktopAgentBridge.resolveElementLabel`) to extract just the AXRole prefix before the first space or parenthesis

**Patterns to follow:**
- `DesktopUserEvent.sanitized()` pattern in `Casper/QA/DesktopAgentBridge.swift:164-210` — switch-over-enum with field extraction
- `TelemetrySanitizer.sanitize()` in `Casper/Telemetry/TelemetrySanitizer.swift` — the `.sanitized()` method on the same event type shows the exhaustive-case pattern

**Test scenarios:**

| Scenario | Input | Expected |
|---|---|---|
| App activation tokenizes to bundle ID | `appActivated(appName:"Xcode", bundleID:"com.apple.dt.Xcode", windowTitle:"main.swift")` | `"a:com.apple.dt.Xcode"` |
| Short text copy tokenizes | `textCopied(text:"git commit -m \"fix\""")` | `"c:Xcode:git commit -m \"fix\""` (appName = current active) |
| Text copy >80 chars returns nil | `textCopied(text:String(repeating: "a", count: 100))` | `nil` |
| Text copy with text >40 chars is truncated | `textCopied(text: String(repeating: "b", count: 60))` | first 40 chars only |
| Mouse click extracts role only | `mouseClicked(appName:"Safari", elementClicked:"AXButton (Title: Reload)", clickCount:1, selectedText:nil)` | `"m:Safari:AXButton"` |
| Mouse click with unknown role pattern | `mouseClicked(appName:"Finder", elementClicked:"AXUnknown", clickCount:1, selectedText:nil)` | `"m:Finder:AXUnknown"` |
| Typing session returns nil (V2) | `typingSession(appName:"Ghostty", ...)` | `nil` |
| Window title change returns nil (V2) | `windowTitleChanged(appName:"Terminal", windowTitle:"bash")` | `nil` |
| User hesitated returns nil (V2) | `userHesitated(appName:"Xcode", durationSeconds:4.5)` | `nil` |

**Verification:** All above test scenarios pass. Tokenizer is a pure function with no state or side effects — correctness is exhaustively testable.

---

### U2. PpmTrie

**Goal:** In-memory prefix tree of frequency counters supporting n-gram insertion (n=1..5) and PPM query with backoff blending. Serializable via Codable.

**Requirements:** R2-R6

**Dependencies:** U1 (token strings are the trie's input values)

**Files:**
- Create: `Casper/Prediction/PpmTrie.swift`
- Create: `CasperTests/PpmTrieTests.swift`

**Approach:**
- `PpmTrieNode` (internal): `var children: [String: PpmTrieNode]`, `var count: Int`. Codable.
- `PpmTrie` (public): `var root: PpmTrieNode`.
- **Insertion:** `insert(tokens: [String])`. Walk each suffix of the token array (lengths 1..5), traversing/creating nodes, incrementing `count` at each visited node and each child node. This records n-gram frequencies.
- **PPM query:** `predict(context: [String]) -> [(token: String, confidence: Double)]`.
  1. Try depths 5, 4, 3, 2, 1 (shortening suffix of `context` each step).
  2. At each depth: walk the trie matching the suffix. If the path exists, collect all child tokens and their counts at that node, multiply by the depth's escape multiplier.
  3. Merge children across depths: sum weighted counts for the same token.
  4. Sort descending by weighted count. Normalize to [0,1] by dividing by total weighted sum.
- **Escape multipliers** (constants): depth 5: 1.0, depth 4: 1.0, depth 3: 0.5, depth 2: 0.3, depth 1: 0.15
- **Persistence:** Serialize `PpmTrie` via `JSONEncoder`/`JSONDecoder`. Save path: `~/Library/Application Support/Casper/prediction/ppm_trie.json`
- **Thread safety:** The trie is read during runtime prediction (on event) and written during training (background). Use `os_unfair_lock` or `pthread_rwlock_t` for concurrent read / exclusive write. (The codebase uses `NSRecursiveLock` in `TelemetryStorage` — use the same pattern for familiarity.)

**Patterns to follow:**
- `TelemetryStorage`'s JSON persistence pattern in `Casper/Telemetry/TelemetryStorage.swift` — Codable structs, `JSONEncoder`/`JSONDecoder`, `storageURL` from `FileManager.default.urls(for:.applicationSupportDirectory, in:.userDomainMask)`
- `DebugLogStore` in `Casper/Debug/DebugLogStore.swift` — JSON file persistence with atomic write

**Test scenarios:**

| Scenario | Input | Expected |
|---|---|---|
| Insert single n-gram and query matching context | Insert `["a:com.apple.dt.Xcode", "a:com.google.Chrome"]`, query context `["a:com.apple.dt.Xcode"]` | Top prediction is `"a:com.google.Chrome"` with confidence > 0 |
| PPM backoff to shorter context | Insert `["a:A", "a:B"]` x10 and `["a:A", "a:C", "a:D"]` x5. Query context `["a:A", "a:C"]` — no exact 2-gram, backs off to unigram `"a:A"` | Top prediction is `"a:B"` (higher count from 1-gram context) |
| PPM blending across depths | Insert `["a:A", "a:B"]` x10 and `["a:A", "a:C", "a:B"]` x1. Query context `["a:A", "a:C"]` — depth 3 has no match, depth 2 has no 2-gram `["a:A", "a:C"]`, depth 1 unigram has `a:B` x11 from both insertions | Top prediction `"a:B"` at >0.5 confidence |
| Empty context query | No context tokens | Returns unigram predictions from root's children |
| Context shorter than max depth | Context has 2 tokens | Backs off from 5→4→3→2 naturally, depth 2 matches if available |
| No tokens in trie at all | Query `["a:X"]` | Empty array |
| Serialization round-trip | Insert some tokens, serialize to data, deserialize, query same context | Same predictions before and after |
| Insert with time decay (tokens scaled by weight) | Insert `["a:A", "a:B"]` with weight=2.0 | Node counts = 2 |

**Verification:** All above test scenarios pass. PPM query completes <1ms for a trie with ~5000 nodes and context window of 5 tokens (measured with `Date().timeIntervalSince` or `os_signpost`).

---

### U3. PredictionTrainer

**Goal:** Batch-process raw JSONL telemetry files through the Tokenizer into the PpmTrie, applying count floor and time decay. Reuses TelemetrySummarizer's idle-gating and progress-tracking architecture.

**Requirements:** R9-R11

**Dependencies:** U1 (Tokenizer), U2 (PpmTrie)

**Files:**
- Create: `Casper/Prediction/PredictionTrainer.swift`
- Create: `CasperTests/PredictionTrainerTests.swift`

**Approach:**
- `PredictionTrainer` class with:
  - Reference to `TelemetryStorage` (to load JSONL files)
  - Reference to `PpmTrie` (to insert into)
  - `train(force: Bool = false)` method
  - Progress tracking: `prediction_progress.json` dict mapping date strings to last-processed line count (follows `TelemetrySummarizer`'s `session_progress.json` pattern exactly)
- **Training loop:**
  1. Skip if idle gate not met (unless `force: true`)
  2. Load unprocessed date files since last progress marker
  3. For each file, read lines, decode as `TelemetryEventRecord`
  4. For each event: call `Tokenizer.tokenize()`, build n-gram sequences from sliding window of tokens
  5. Insert into `PpmTrie.insert()` with time-decay weight: today=2.0, yesterday=1.0, older=0.5
  6. Persist progress after each file
  7. On completion: persist trie to disk
- **Count floor:** After inserting, prune tokens seen fewer than 3 times (or configurable threshold). Run as a compaction pass on the trie after insertion.
- **Event source:** `TelemetryStorage.loadEventRecords(forDateString:)` — already loads all events for a date

**Integration with existing systems:**
- No new timer. The existing `TelemetrySummarizer` 5-minute check calls `PredictionTrainer.train()` alongside its own processing.
- Manual retrain: `TelemetrySummarizer.triggerProcessing(force: true)` already exists. A new `triggerTraining(force: true)` follows the same pattern.

**Patterns to follow:**
- `TelemetrySummarizer.processRawLogs()` in `Casper/Telemetry/TelemetrySummarizer.swift` — idle gating, JSONL file loading, session progress tracking
- `TelemetryStorage.loadEventRecords(forDateString:)` in `Casper/Telemetry/TelemetryStorage.swift` — batch loading pattern

**Test scenarios:**

| Scenario | Input | Expected |
|---|---|---|
| Train on single JSONL with known events | Write test JSONL with 10 events forming a pattern | Trie contains the correct n-gram counts |
| Count floor excludes rare sequences | Insert 2 identical sequences, count floor=3 | Those sequences pruned from trie |
| Time decay weights today higher | Events with today's date | Counts incremented by 2 |
| Time decay weights older lower | Events with date >48h ago | Counts incremented by 0.5 (floor of 1) |
| Progress persistence across calls | Train on file1, save progress, train again | Skips already-processed lines in file1, processes file2 |
| Manual retrain with force bypasses idle gate | Call `train(force: true)` | Processes regardless of idle state |

**Verification:** All test scenarios pass. Post-training, the trie file exists at the expected path. Re-training is idempotent — second run skips already-processed lines.

---

### U4. RuntimePredictor

**Goal:** Hold the sliding window of the last 5 event tokens, call `PpmTrie.predict()` on each new event, and emit predictions via a Combine publisher when confidence exceeds the threshold.

**Requirements:** R6 (sliding window), R12-R13 (prediction latency and threshold), partial R3-R4 (PPM query routed through trie)

**Dependencies:** U1 (Tokenizer), U2 (PpmTrie)

**Files:**
- Create: `Casper/Prediction/RuntimePredictor.swift`
- Create: `CasperTests/RuntimePredictorTests.swift`

**Approach:**
- `RuntimePredictor`: `ObservableObject` with `@Published var currentPrediction: Prediction?`
  - `var slidingWindow: [String]` (max 5, maintained with `Array.suffix(5)`)
  - `let trie: PpmTrie` (reference, read-only at runtime)
  - `let confidenceThreshold: Double` (default 0.5)
  - `func ingest(event: DesktopUserEvent)` — called on each event
- **`Prediction` struct:**
  - `token: String` — the raw prediction token e.g. `"a:com.google.Chrome"`
  - `confidence: Double`
  - `displayTitle: String` — e.g. `"Switch to Chrome"`
  - `displayDescription: String` — e.g. `"Based on your recent pattern"`
  - `suggestedContent: String` — bundle ID or copied text to use if action is taken
- **`ingest()` flow:**
  1. Call `Tokenizer.tokenize(event)`. If nil, return.
  2. Append token to sliding window, trim to last 5.
  3. Call `trie.predict(context: slidingWindow)`.
  4. If top prediction's confidence >= `confidenceThreshold` and differs from last emitted prediction:
     - Build `Prediction` struct
     - Set `currentPrediction` (triggers publisher)
  5. Else: set `currentPrediction = nil` if context changed (hides overlay).
- **Token-to-display mapping:**
  - `"a:{bundleID}"` → displayTitle: `"Switch to {appName}"`, suggestedContent: bundleID
  - `"c:{app}:{text}"` → displayTitle: `"Paste copied text?"`, suggestedContent: the original copied text (fetch from last known copy event context)
  - `"m:{app}:{role}"` → skip (V2)
- **Thread safety:** `@MainActor` (called from TelemetryCollector's event loop). Trie is read-only at runtime.

**Patterns to follow:**
- `ObservableObject` + `@Published` pattern used throughout AppState and subsystems
- `PerformanceTrace` in `Casper/Debug/PerformanceTrace.swift`

**Test scenarios:**

| Scenario | Input | Expected |
|---|---|---|
| Prediction above threshold populates currentPrediction | Trie has `a:Chrome` at 0.6. Ingest event. | `currentPrediction` is non-nil with matching token |
| Prediction below threshold clears prediction | `currentPrediction` was set, new context yields 0.3 | `currentPrediction` becomes nil |
| Token not in V1 scope | Ingest `typingSession` | No change to window or prediction |
| Sliding window correct | 6 events ingested | Window has 5 newest tokens |
| Same prediction not re-emitted | Ingest same context twice | Second call does not change `currentPrediction` |
| Empty trie | Clean trie, ingest event | `currentPrediction` stays nil |

**Verification:** All test scenarios pass. `ingest()` completes <1ms.

---

### U5. PredictionOverlayWindow

**Goal:** A small floating window that shows the latest prediction with action/dismiss buttons. Auto-shows on new prediction, auto-hides on dismissal or context advance, togglable from menu bar.

**Requirements:** R14 (suggestion display)

**Dependencies:** U4 (subscribes to `RuntimePredictor.currentPrediction` publisher)

**Files:**
- Create: `Casper/Prediction/PredictionOverlayWindowController.swift`
- Create: `Casper/Prediction/PredictionOverlayView.swift`
- No dedicated test file — UI behavior verified through `Verification` notes below and manual testing

**Approach:**
- **`PredictionOverlayWindowController`: `NSWindowController` subclass**
  - Creates an `NSPanel` with:
    - Style: `.nonactivatingPanel` (doesn't steal focus)
    - Level: `.floating` (always on top of other windows)
    - Collection behavior: `.canJoinAllSpaces`, `.fullScreenAuxiliary`
    - Title bar: hidden or minimal (thin title bar with no close/minimize)
    - Size: compact (~300×80pt), positioned bottom-right or near active app window
  - Hosts `PredictionOverlayView` via `NSHostingController`
  - Listens to `RuntimePredictor.$currentPrediction`:
    - Non-nil → show window with fade-in animation. Set content from prediction.
    - Nil → hide window with fade-out (unless overlay visibility is toggled on in menu bar)
  - Provides `show()` and `hide()` for menu bar toggle
- **`PredictionOverlayView`: SwiftUI view**
  - Rounded rectangle background with shadow
  - Displays: action title (e.g. "Switch to Chrome"), confidence percentage, brief description
  - Two buttons:
    - **Action** (primary): executes the prediction — activate app via NSWorkspace (for `a:{bundleID}`), paste text (for `c:{app}:{text}`)
    - **Dismiss** (secondary): hides this prediction, sets `currentPrediction = nil` so same prediction isn't re-shown until context advances
  - Compact layout — no larger than needed, no chrome
- **Menu bar toggle:** Add "Show Prediction Overlay" menu item in `MenuBarView` (follows existing telemetry section pattern) to call `overlayController.show()`/`hide()`

**Patterns to follow:**
- `SettingsWindowController` in `Casper/UI/Settings/SettingsWindowController.swift` — `NSWindowController` + `NSHostingController` pattern for hosting SwiftUI in AppKit windows
- `MenuBarView` in `Casper/CasperApp.swift` — menu bar items for toggling features
- The overlay should be lightweight — it shares the window controller pattern but is much simpler than the Settings window

**Test scenarios:**

| Scenario | What to verify |
|---|---|
| Prediction published → overlay shows | Simulate RuntimePredictor emitting a prediction. Overlay window appears with correct title/description. |
| Dismiss button pressed | Overlay hides, prediction is consumed (not re-shown for same context) |
| Action button pressed | Target app activated (NSWorkspace) or text pasted. Overlay hides. |
| Menu bar toggle shows/hides overlay | Menu item toggles overlay visibility regardless of prediction state |
| Context advances without prediction | Overlay hides (currentPrediction becomes nil) |
| Overlay does not steal focus | Clicking elsewhere while overlay is visible works normally (verified by `.nonactivatingPanel` style) |

**Verification:** The overlay appears/disappears in response to prediction state. Action and dismiss buttons work. The overlay stays on top of all windows without stealing focus.

## Dependency Graph

```
U1 (Tokenizer) ──→ U2 (PpmTrie)
                      ↑
U1 ───────────────────┤
                      │
U3 (PredictionTrainer) │
  depends: U1, U2     │
                      │
U4 (RuntimePredictor)  │
  depends: U1, U2     │
                      │
U5 (System Integration)
  depends: U3, U4
```

U1 and U2 can be built in parallel (U2 doesn't technically depend on U1 — the trie works with arbitrary strings — but integrating U2 test scenarios is easier with the tokenizer available). U3 and U4 depend on U1+U2. U5 depends on all previous units.

## System-Wide Impact

- **AppState:** Gains two new properties and one new `@Published` state (`isTraining` or similar). Memory impact: PpmTrie (~few thousand nodes, <1MB). Startup impact: deserialize JSON file (~microseconds).
- **TelemetryCollector:** Gains one method call per event (`runtimePredictor?.ingest(event:)`). Must complete <1ms — if the trie query drifts, the 2s polling cycle is unaffected (wall-clock time), only event handling latency matters.
- **TelemetrySummarizer:** Gains one method call per idle check. Training runs on background priority in idle/AC-power windows — zero user-facing impact.
- **DesktopAgentBridge:** Gains a suggestion source from the prediction engine alongside the existing LLM-based recommendations. Suggestion deduplication: the prediction engine recommendations have a different source origin and can coexist with LLM recs. The existing `@Published recommendations` array can hold both.
- **Build system:** New files in `Casper/Prediction/` — must be added to `project.yml`'s glob for sources (follows existing convention: `Casper/**/*.swift` in the XcodeGen sources glob already covers new subdirectories).
- **Persistence:** New `prediction/` directory under `~/Library/Application Support/Casper/`. Must be created on first trie save. Follows the existing pattern where each subsystem manages its own subdirectory.

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Trie query exceeds 1ms with real data | Low | Event handling latency | Measure with os_signpost in CI. The trie is bounded by distinct token count (~50 tokens across 15 apps); query time is O(depth × branching factor). |
| Token normalization produces too many distinct tokens | Medium | Trie bloat, predictions too specific | Start with the schema in the origin doc. If the trie exceeds 10K nodes after a month, add token hashing or merge similar bundle IDs (e.g., all Apple system apps → `a:com.apple.*`). |
| Training on idle is never triggered (user is rarely idle 10 min) | Low | Stale predictions | The manual retrain button and AC-power-only path both bypass idle gate. Future: reduce idle threshold for training-only (5 min instead of 10). |
| Training conflicts with runtime reads | Low | Corrupted trie during query | Use existing `NSRecursiveLock` pattern. Training is background, queries are main thread. The lock is held briefly (<1ms). |
| Prediction engine produces too many noisy suggestions | Medium | User annoyance, ignored UI | Confidence threshold defaults to 0.5 and is configurable. Suggestions are already consumed after one show (not re-shown until context advances). |

## Deferred Implementation Notes

- **Micro layer data structures:** When V2 adds the micro layer, `PpmTrie` will need a companion `MicroStore` class (flat `[String: [String: Int]]` keyed by macro context hash). The `PredictionTrainer` will be extended to populate the micro store during training.
- **`commandExecuted` tokenization:** The schema defines `x:{appName}:{exitCode}` but V1 has zero data for this event type (shell integration not wired). Adding it later is a one-line Tokenizer case and the trie auto-adapts.
- **Time-of-day weighting:** Future work could weight training insertions by hour (e.g., 5pm transitions weighted higher for after-work patterns). This is a training-time change only — the trie data model doesn't need modification.
- **User feedback loop:** Tracking accept/reject on suggestions for automatic threshold tuning requires UI instrumentation (tap-through analytics) not present in V1. The threshold is manually configurable.
- **Prediction score metric:** A validation pass that checks whether a prediction actually matched the user's next action within N subsequent events. This requires the RuntimePredictor to retain predictions for N events and compare them against the actual tokenized events that followed, producing a hit rate / precision score over time. Deferred to V2 because the gain is marginal before the micro layer is also in place — predictions are inherently macro-level and scoring them against macro ground truth would overcount misses when the user's next *specific value* differs even though the *category and app* match.

## Success Criteria

(see origin: `docs/brainstorms/2026-06-24-prediction-engine-requirements.md`)

- PPM query (all 5 backoff depths) completes in <1ms (measured with `os_signpost`)
- At least one prediction per 2 hours of active use exceeds the 50% confidence threshold
- Zero additional GPU usage from the prediction engine
- All test scenarios for each unit pass
