---
date: 2026-06-24
type: feat
topic: desktop-prediction-engine-v2
status: active
---

# Plan: Desktop Prediction Engine V2 — Micro Layer + New Token Types

## Summary

Add the micro layer (flat frequency dictionaries keyed by macro context hash) to the prediction engine, enabling specific-value predictions ("Type `killall Finder` in Ghostty?" instead of just "Next action in Ghostty"). Enable the four deferred event types (`typingSession`, `windowTitleChanged`, `userHesitated`, `commandExecuted`) for macro-level sequence tokenization. Wire MicroStore population during training, micro lookups during runtime prediction, and enriched suggestion display in the overlay.

## Problem Frame

(see origin: `docs/brainstorms/2026-06-24-prediction-engine-requirements.md`)

V1's macro PPM trie predicts *which event type and app* will happen next ("user will activate Chrome", "user will type in Ghostty") but cannot predict *what specific value* (what text, what target). The micro layer fills this gap using flat dictionaries — a retrieval problem, not sequential.

The four remaining event types (`typingSession`, `windowTitleChanged`, `userHesitated`, `commandExecuted`) currently return `nil` from the Tokenizer and don't participate in sequence prediction. Enabling them enriches the macro trie's signal — hesitation-then-switch patterns, title-change-then-activation patterns, and typing-session endpoints all become part of the learned sequences.

## Scope Boundaries

### In scope for V2
- MicroStore: flat dictionary data structure (`[String: [String: Int]]` keyed by macro context hash) with Codable persistence at `~/Library/Application Support/Casper/prediction/micro_store.json`
- Tokenizer: enable `typingSession` → `k:{appName}`, `windowTitleChanged` → `t:{appName}`, `userHesitated` → `h:{appName}:{durationBucket}`, `commandExecuted` → `x:{appName}:{outcome}`
- PredictionTrainer: populate MicroStore during training for events with specific values (`typingSession` typed text, `mouseClicked` element description)
- RuntimePredictor: when macro predicts `k:` or `m:` above threshold, do micro lookup to retrieve top specific values; enrich prediction display
- PredictionOverlay: show micro-enriched descriptions ("Type `killall Finder` in Ghostty?", "Click `Reload` in Chrome?")
- Micro-overlay action: paste typed text for `k:` predictions, activate app for `m:` predictions

### Deferred (future)
- Time-of-day weighting in PPM
- User feedback loop (accept/reject tracking for threshold tuning)
- Automatic threshold tuning based on acceptance rate
- `DesktopAgentRecommendation` integration (prediction engine producing `DesktopAgentRecommendation` objects alongside LLM-based ones)
- Live context enrichment from `windowTitleChanged` events

### Outside scope for V2
- Cloud-based pattern matching or telemetry upload
- LLM involvement at any stage of prediction
- Predictive typing or auto-completion beyond exact repetition

## Key Technical Decisions

### MicroStore key derivation
The context hash is a string joining the last N macro context tokens with ` → ` separator, followed by ` → ` and the predicted macro token:
```
contextHash = slidingWindow.joined(separator: " → ") + " → " + predictedToken
```
Example: `"a:com.apple.dt.Xcode → c:Xcode:git commit → a:com.google.Chrome → k:Ghostty"`

Raw string keys are fine — the number of distinct keys is bounded by distinct macro contexts (~few thousand). No hashing needed.

### MicroStore value granularity
- `typingSession` → store `typedText` (raw text, unsanitized — this is local-only, never uploaded)
- `mouseClicked` → store `elementClicked` string (the full description like `"AXButton (Title: Reload)"`)
- `textCopied` → no micro entry needed (the copied text is already in the macro `c:` token)
- `appActivated` → no micro entry (no specific value to predict)

### h: token duration buckets
- `< 3s` → nil (too short to be meaningful)
- `3s..<5s` → `short`
- `5s..<10s` → `medium`
- `>= 10s` → `long`

### x: token outcome grouping
- `exitCode == 0` → `success`
- `exitCode != 0` → `failure`

Groups all commands by outcome rather than specific command text, keeping the token space small.

### Escape penalty and threshold for micro
Micro predictions don't have their own confidence threshold. The macro confidence threshold (default 0.5) gates whether micro is consulted at all. Within micro results, values are ranked by weighted count. The top result shown to the user is: macro prediction with micro enrichment.

### Persistence format
MicroStore serializes as a flat JSON dictionary via Codable: `[String: [String: Int]]`. Same pattern as `PpmTrie`'s JSON persistence. Saved alongside the trie in the `prediction/` directory.

## Implementation Units

### U1. MicroStore

**Goal:** Flat dictionary keyed by macro context hash, storing ordered specific-value frequencies. Supports weighted insertion, count-floor pruning, and Codable persistence.

**Requirements:** R7-R8 (see origin: `docs/brainstorms/2026-06-24-prediction-engine-requirements.md`)

**Dependencies:** None (standalone data structure)

**Files:**
- Create: `Casper/Prediction/MicroStore.swift`
- Create: `CasperTests/MicroStoreTests.swift`

**Approach:**
- `MicroStore` class with public API:
  - `var store: [String: [String: Int]]` — context hash → (value → count)
  - `func record(value: String, forContext contextHash: String, weight: Int = 1)` — increment counter
  - `func predict(for contextHash: String) -> [(value: String, count: Int)]` — sorted descending by count, limited to top entries
  - `func prune(floor: Int)` — remove values with count < floor, then remove empty context entries
  - `func save(to url: URL)` / `static func load(from url: URL) -> MicroStore` — Codable JSON persistence
- **Thread safety:** `NSRecursiveLock` (follows `PpmTrie` pattern)
- **Persistence:** JSON via `JSONEncoder`/`JSONDecoder` at `prediction/micro_store.json`
- **Maximum entries per context:** Unbounded (naturally bounded by distinct values per app; Ghostty might have 50, Chrome URL bar might have 2000 but 99% below count floor)

**Patterns to follow:**
- `PpmTrie` in `Casper/Prediction/PpmTrie.swift` — `NSRecursiveLock`, `Codable`, `save()`/`load()` pattern
- `PpmTrie.prune(floor:)` — recursive filtering by count threshold

**Test scenarios:**

| Scenario | Input | Expected |
|---|---|---|
| Record and retrieve | `record("killall Finder", forContext: "ctx")` then `predict(for: "ctx")` | Returns `[("killall Finder", 1)]` |
| Multiple values sorted by count | Record "a" x5, "b" x3, "c" x1 for same context | Returns `[("a", 5), ("b", 3), ("c", 1)]` |
| Unknown context returns empty | `predict(for: "nonexistent")` | Empty array |
| Weighted insertion | `record("a", forContext: "ctx", weight: 3)` x1 | Count = 3 |
| Count floor prunes rare values | Record "a" x5, "b" x1, floor=3 | After prune, only "a" remains |
| Prune removes empty context | Record "a" x2 for ctx1, floor=3 | Both entry and ctx1 removed |
| Serialization round-trip | Insert entries, serialize, deserialize, query | Same results before and after |
| Empty store | New MicroStore, any query | Empty array |
| Concurrent writes | Multiple threads recording simultaneously | No data loss (lock protects) |

**Verification:** All test scenarios pass. MicroStore is a pure data structure with no external dependencies.

---

### U2. Tokenizer: Enable Deferred Event Types

**Goal:** Tokenize `typingSession`, `windowTitleChanged`, `userHesitated`, and `commandExecuted` events into compact token strings. Update existing nil-expectation tests.

**Requirements:** R1 token schema for all event types (see origin)

**Dependencies:** None (Tokenizer is a pure function)

**Files:**
- Modify: `Casper/Prediction/Tokenizer.swift`
- Modify: `CasperTests/TokenizerTests.swift`

**Approach:**
Add four new cases to the `tokenize` switch, following the existing pattern:

- `.typingSession(let appName, _, _, _)` → `"k:\(appName)"` — drop `targetElement`, `typedText`, `durationSeconds`. Only the app name.
- `.windowTitleChanged(let appName, _)` → `"t:\(appName)"` — drop `windowTitle`. Only the app name.
- `.userHesitated(let appName, let durationSeconds)` → bucket duration: `< 3s` nil, `3..<5` → `"h:\(appName):short"`, `5..<10` → `"h:\(appName):medium"`, `>= 10` → `"h:\(appName):long"`
- `.commandExecuted(_, let exitCode, _)` → let appName = activeAppName ?? "unknown"; return `"x:\(appName):\(exitCode == 0 ? "success" : "failure")"` (uses `activeAppName` parameter, same pattern as `textCopied`)

**Patterns to follow:**
- Existing `Tokenizer.tokenize()` switch pattern — each case extracts relevant fields, drops the rest
- `DesktopUserEvent` field labels in `Casper/QA/DesktopAgentBridge.swift`

**Test scenarios:**

| Scenario | Input | Expected |
|---|---|---|
| Typing session tokenizes | `typingSession(appName:"Ghostty", targetElement:nil, typedText:"ls", durationSeconds:2.0)` | `"k:Ghostty"` |
| Typing session drops typed text | Same as above | Token is `"k:Ghostty"`, not `"k:Ghostty:ls"` |
| Window title change tokenizes | `windowTitleChanged(appName:"Terminal", windowTitle:"bash")` | `"t:Terminal"` |
| Window title change drops title | Same as above | Token is `"t:Terminal"`, not `"t:Terminal:bash"` |
| Hesitation short bucket (3-5s) | `userHesitated(appName:"Xcode", durationSeconds:4.5)` | `"h:Xcode:short"` |
| Hesitation medium bucket (5-10s) | `userHesitated(appName:"Xcode", durationSeconds:7.2)` | `"h:Xcode:medium"` |
| Hesitation long bucket (10s+) | `userHesitated(appName:"Xcode", durationSeconds:12.0)` | `"h:Xcode:long"` |
| Hesitation under 3s returns nil | `userHesitated(appName:"Xcode", durationSeconds:2.0)` | `nil` |
| Hesitation boundary at exactly 3s | `userHesitated(appName:"Xcode", durationSeconds:3.0)` | `"h:Xcode:short"` |
| Hesitation boundary at exactly 5s | `userHesitated(appName:"Xcode", durationSeconds:5.0)` | `"h:Xcode:medium"` |
| Command succeeded | `commandExecuted(command:"ls", exitCode:0, output:nil)` | `"x:Terminal:success"` |
| Command failed | `commandExecuted(command:"rm -rf /", exitCode:1, output:nil)` | `"x:Terminal:failure"` |
| Existing V1 tokens still work | All V1 test scenarios | Same results as before |

**Verification:** All test scenarios pass. Existing V1 tokenization tests unchanged. Tokenizer remains a pure function.

---

### U3. PredictionTrainer: MicroStore Population

**Goal:** During batch training, populate MicroStore with specific values from events that carry repeatable content (`typingSession` typed text, `mouseClicked` element description).

**Requirements:** R9-R11 extended to MicroStore

**Dependencies:** U1 (MicroStore data structure), U2 (all token types enabled)

**Files:**
- Modify: `Casper/Prediction/PredictionTrainer.swift`
- Modify: `CasperTests/PredictionTrainerTests.swift`

**Approach:**
- Add `let microStore: MicroStore` property to `PredictionTrainer`
- Extend training loop in `processFile(_:progress:)`:

After the existing tokenization and trie insertion, for certain event types:
  - `.typingSession(_, _, let typedText, _)` — compute context hash from `tokenWindow` + `k:{appName}`; `microStore.record(value: typedText, forContext: contextHash, weight: Int(weight))`
  - `.mouseClicked(_, let elementClicked, _, _)` — compute context hash from `tokenWindow` + `m:{appName}:{role}`; `microStore.record(value: elementClicked, forContext: contextHash, weight: Int(weight))`
  - Other event types: no micro entry (the value IS the macro token, or there's no repeatable value)

- **Context hash derivation during training:**
  ```
  let contextTokens = tokenWindow + [currentMacroToken]
  let contextHash = contextTokens.joined(separator: " → ")
  ```
  This matches the runtime derivation. The `tokenWindow` at training time contains the same sliding window of previous tokens as at runtime.

- Save MicroStore after saving the trie: `try microStore.save(to: microStoreURL)`
- Apply `microStore.prune(floor:)` after training (wire up count floor)
- Initialization: accept `MicroStore` reference in init (defaults to empty if nil), load from disk on train start
- Persistence path: `prediction/micro_store.json`

**Integration with existing code:**
- `AppState` wires `MicroStore` alongside `PpmTrie` — loaded on startup, passed to trainer
- `AppState` saves MicroStore on termination alongside trie

**Patterns to follow:**
- Existing `timeDecayWeight` usage — MicroStore `record()` receives `Int(weight)` to stay consistent
- Existing trie save/load pattern in `PredictionTrainer`
- Context hash derivation mirrors the runtime scheme (U4)

**Test scenarios:**

| Scenario | Input | Expected |
|---|---|---|
| Train populates micro for typing events | JSONL with typingSession events | MicroStore has entries keyed by context hash with typed text values |
| Train populates micro for click events | JSONL with mouseClicked events | MicroStore has entries with element descriptions |
| Micro values respect count floor | Insert typingSession with same text < floor times | After prune, those entries removed |
| Micro values inherit time decay | Today's typingSession has higher weight | Today's entries have higher counts than yesterday's |
| Save/load round trip | Train, save, load new MicroStore from disk | Same entries |
| Existing trie training still works | Train with events that have no micro values | Trie populated, MicroStore empty but not broken |
| Empty MicroStore after training with no micro events | Only appActivated events | MicroStore remains empty but valid |

**Verification:** All test scenarios pass. After training, `micro_store.json` exists at the expected path with correct structure. Training without micro-relevant events produces an empty but loadable MicroStore.

---

### U4. RuntimePredictor: Micro Lookups

**Goal:** After macro prediction, query MicroStore for specific values when the predicted token is `k:` or `m:`, and enrich the `Prediction` struct with micro-level detail.

**Requirements:** R7-R8 (micro refines macro), R12-R14 (prediction latency and action mapping)

**Dependencies:** U1 (MicroStore)

**Files:**
- Modify: `Casper/Prediction/RuntimePredictor.swift`
- Modify: `CasperTests/RuntimePredictorTests.swift`

**Approach:**
- Add `let microStore: MicroStore` property to `RuntimePredictor`
- Extend `ingest()` flow: after `trie.predict()` and before `buildPrediction()`:
  - For each raw prediction whose token starts with `k:` or `m:`:
    - Compute context hash from `slidingWindow + [predictedToken]` joined with ` → ` separator
    - Query `microStore.predict(for: contextHash)`
    - If top result has count >= count floor (3): pass the specific value to `buildPrediction()`
    - Otherwise: fall back to macro-only prediction
- Extend `buildPrediction()`:
  - For `k:{appName}`: if micro value exists, `displayTitle = "Type \"\(value)\" in \(appName)?"`, `suggestedContent = value`, `displayDescription = "\(count) times before"`
  - For `m:{appName}:{role}`: if micro value exists, `displayTitle = "Click \"\(value)\" in \(appName)?"`, `suggestedContent = value` (also `appName` for activation fallback)
  - Without micro value: `k:` returns nil (no useful suggestion), `m:` returns nil (too vague)
- Update `bundleIDToAppName` tracking to also store app names from `typingSession` and `mouseClicked` events (currently only populated from `appActivated`)
- Thread safety: MicroStore is read-only at runtime on `@MainActor` — no lock needed

**Micro confidence consideration:**
The macro confidence gates whether micro is consulted. If macro threshold is met, micro results are shown alongside the macro prediction. The user sees: "Type `killall Finder` in Ghostty? (60%)" — the confidence reflects macro confidence. Micro is enrichment, not an independent confidence score.

**Patterns to follow:**
- Existing `buildPrediction()` pattern in `RuntimePredictor.swift` — token prefix matching, `Prediction` struct construction
- Existing `updateContext(from:)` pattern for event state tracking
- Existing `lastEmittedPrediction` deduplication

**Test scenarios:**

| Scenario | Input | Expected |
|---|---|---|
| Macro predicts k: with micro hit | Trie has k:Ghostty pattern, MicroStore has typing text | `displayTitle` shows "Type \"killall Finder\" in Ghostty?" |
| Macro predicts m: with micro hit | Trie has m:Chrome:AXButton pattern, MicroStore has element | `displayTitle` shows "Click \"AXButton (Title: Reload)\" in Chrome?" |
| Macro predicts k: with no micro entry | MicroStore empty for this context | Prediction returns nil (no useful suggestion) |
| Macro predicts m: with no micro entry | MicroStore empty for this context | Prediction returns nil (too vague) |
| Macro predicts a: with micro entries | MicroStore has entries for this context | Prediction unchanged (a: never consults micro) |
| Micro value below count floor | MicroStore has entry with count=1, floor=3 | Fallback to nil (no micro enrichment) |
| Sliding window context hash matches | Same sequence as during training | Micro lookup finds the right entry |
| Micro entry count influences ordering | Multiple values for same context | Sorted by count descending |
| Existing a: and c: predictions still work | No micro entries for a:/c: tokens | Same behavior as V1 |

**Verification:** All test scenarios pass. Runtime predictor with empty MicroStore behaves identically to V1. With populated MicroStore, k: and m: predictions are enriched.

---

### U5. PredictionOverlay: Micro-Enriched Display and Actions

**Goal:** Display micro-level detail in prediction suggestions and wire the action button for k: predictions (paste text) and m: predictions (activate app). Update Prediction struct to carry micro value metadata.

**Requirements:** R14 (suggestion action mapping extended for k: and m:)

**Dependencies:** U4 (RuntimePredictor produces enriched predictions)

**Files:**
- Modify: `Casper/Prediction/PredictionOverlayView.swift`
- Modify: `Casper/Prediction/PredictionOverlayWindowController.swift`

**Approach:**

**Prediction struct extension (no structural change needed):**
The existing `Prediction` struct already has `displayTitle`, `displayDescription`, `suggestedContent`, and `token` fields. Micro-enriched predictions from U4 fill these with the appropriate values. No new fields needed.

**Overlay action handler extension:**
In `PredictionOverlayWindowController.handleAction()`:
- `k:{appName}` with `suggestedContent` = typed text:
  1. Copy the typed text to clipboard (temporarily save existing clipboard)
  2. Simulate Cmd+V via CGEvent post
  3. Restore clipboard after short delay
  4. Hide overlay
- `m:{appName}:{role}` with `suggestedContent` = element description:
  1. Activate the app via `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` — same as `a:` action
  2. (No element-level click simulation — the app activation is the actionable step)
- Existing `a:` and `c:` actions unchanged

**Overlay display:**
The overlay view already renders `prediction.displayTitle` and `prediction.displayDescription`. Micro-enriched predictions from U4 fill these with:
- k: → "Type `killall Finder` in Ghostty?" / "12 times before"
- m: → "Click `Reload` in Chrome?" / "5 times before"

No SwiftUI changes needed in `PredictionOverlayView` — the text rendering is already dynamic.

**Paste action implementation details:**
- Save current clipboard content via `NSPasteboard.general`
- Set new clipboard content to `suggestedContent`
- Post Cmd+V via `CGEventPost(.cgsession, ...)` — see existing `TextPaster` pattern if it exists in the codebase
- After 1 second (async), restore original clipboard
- This follows the UX pattern: user sees "Type X in Ghostty?", clicks Go → text is pasted

**Patterns to follow:**
- Existing `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` in `handleAction` for `a:` tokens
- `CGEvent` posting pattern (search codebase for `CGEventPost` or keyboard simulation)
- Clipboard save/restore for paste actions

**Test scenarios:**

| Scenario | What to verify |
|---|---|
| k: prediction action pastes text | Go button copies suggestion to clipboard, posts Cmd+V, restores original clipboard |
| m: prediction action activates app | Go button activates NSWorkspace for the bundle ID from context |
| Existing a: action unchanged | Go button activates app as before |
| Existing c: action unchanged | Go button performs paste as before |
| Dismiss works for any prediction type | Dismiss clears prediction, overlay hides |

**Verification:** Micro-enriched predictions display correctly. Action button pastes text for `k:` predictions. Existing `a:` and `c:` actions unchanged. Overlay auto-shows and auto-hides with same V1 behavior. No manual UI test — verified by inspection.

## Dependency Graph

```
U1 (MicroStore) ──┐
                   ├──→ U3 (PredictionTrainer: micro population)
U2 (Tokenizer) ────┤        depends: U1, U2
  (new token types)│
                   ├──→ U4 (RuntimePredictor: micro lookups)
                   │        depends: U1
                   │
                   └──→ U5 (Overlay: micro actions)
                            depends: U4
```

U1 and U2 are independent and can be built in parallel. U3 depends on both U1 and U2. U4 depends on U1. U5 depends on U4.

## System-Wide Impact

- **AppState:** Gains `MicroStore` property loaded/saved alongside `PpmTrie`. Passes MicroStore to `PredictionTrainer` and `RuntimePredictor`.
- **PredictionTrainer:** Gains MicroStore population logic. Existing trie training unchanged.
- **RuntimePredictor:** Gains MicroStore reference and micro lookup logic. Sliding window hash derivation matches training. Existing predictions unchanged when MicroStore is empty.
- **PredictionOverlayWindowController:** Gains paste action for `k:` predictions. Clipboard save/restore required.
- **Persistence:** New `micro_store.json` file alongside `ppm_trie.json` in `prediction/` directory. ~1-10KB typical size.
- **Build system:** One new file (`MicroStore.swift`), existing files modified. Already covered by `Casper/**/*.swift` glob in `project.yml`.
- **Memory:** MicroStore with ~100 context keys × ~10 values each ≈ 1KB of stored data, < 100KB in-memory.

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| MicroStore grows unbounded | Low | Memory pressure, slow persistence | Count floor pruning (default 3) keeps only repeating values. Natural per-app bound. |
| Paste action overwrites user clipboard | Medium | User loses clipboard content | Save and restore original clipboard. Small window for data loss if user copies during the 1s restore window — acceptable for V2. |
| k: predictions fire too often | Low | Annoying overlay spam | Macro confidence threshold (0.5) plus micro count floor (3) gate all k: suggestions. Only repeatable patterns (>3 times) produce suggestions. |
| MicroStore key collisions | Low | Wrong value predicted | Context hash includes full sliding window + predicted token. Collision requires identical sequence and same predicted token — effectively impossible. |
| m: prediction with micro hits activates app but user wanted element click | Medium | Wrong action | App activation is the safe default. Element-level click simulation is deferred (complex, fragile). The overlay text clarifies: "Click `Reload` in Chrome?" with Safari becoming active — the user can choose not to click Go. |

## Deferred Implementation Notes

- **`commandExecuted` micro values:** Current V2 tokenizes the outcome (success/failure) but does not store the specific command as a micro value. The schema says "Group by success/failure, not exact command" which is correct for macro-level. If micro is desired later, the command text could be stored similarly to `k:` typed text.
- **`userHesitated` micro values:** No micro-specific value for hesitation — the duration is already captured in the token bucket. Future: store what the user did AFTER hesitating by keying the next event's token as the micro value.
- **Clipboard paste reliability:** The Cmd+V simulation may fail in some contexts (secure input, fullscreen apps, remote desktop). The action button does its best effort and hides the overlay. No retry logic for V2.
- **m: element-level click:** Deferred indefinitely. App activation is the actionable step; simulating clicks at AX element coordinates requires accessibility permissions and is fragile across macOS versions.

## Success Criteria

(see origin: `docs/brainstorms/2026-06-24-prediction-engine-requirements.md`)

- MicroStore `predict()` completes in <0.1ms (measured with `Date().timeIntervalSince`)
- At least one micro prediction per day of use where the user types repeating commands in a terminal
- Zero additional GPU usage from the micro layer
- All test scenarios for each unit pass
- Existing V1 prediction behavior unchanged when MicroStore is empty
