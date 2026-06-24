---
date: 2026-06-24
topic: desktop-prediction-engine
---

# Desktop Prediction Engine

## Summary

A layered prediction engine that learns user behavior patterns directly from raw telemetry event files (no LLM at any stage). Uses PPM (Prediction by Partial Matching) for sequence prediction at the macro level and flat frequency dictionaries for specific value retrieval at the micro level. All training is algorithmic — counter insertion, no model weights.

## Problem Frame

Casper's TelemetryCollector captures workspace events (app activations, copies, typing, clicks) into raw JSONL files. These are currently summarized offline into narrative reports, but there's no real-time prediction.

Running a local LLM on every event is too expensive (2B Qwen: 0.5-2s per generation, 20-40 tok/s). TelemetryCollector polls every 2s. A prediction engine must live in the low-overhead regime.

The macro layer (predicting *when* an event type occurs) is a **sequence prediction** problem — order matters, variable-length contexts. The micro layer (predicting *what specific value*) is a **retrieval** problem — flat key-value lookup, not sequential at all. Each needs a different data structure.

## Architecture: Layered Prediction

Two layers. V1 = macro only. V2 adds micro.

### Macro layer: PPM trie (predicts next event type)

Uses Prediction by Partial Matching — a trie of frequency counters with backoff blending. Same underlying tree structure as a plain trie, but the prediction query differs critically.

**Token schema (the critical design decision — what to keep vs discard):**

| Event | Token Format | Rationale |
|---|---|---|
| `appActivated` | `a:{bundleID}` | Bundle ID is stable. Drop window title (too varied). |
| `textCopied` | `c:{appName}:{truncatedText}` | Keep text only if under ~80 chars. Longer text is never repeated. Truncate at first 40 chars. Hash for privacy if desired. |
| `mouseClicked` | `m:{appName}:{AXRole}` | Drop coordinates and any descriptive text or value. Just app + what kind of thing they clicked. |
| `windowTitleChanged` | `t:{appName}` | Drop the title itself. Keep only the app so the sequence knows the title changed. |
| `typingSession` | `k:{appName}` | Drop the typed text entirely. Only record that the user typed in this app. |
| `userHesitated` | `h:{appName}:{durationBucket}` | Bucket durations: short (3-5s), medium (5-10s), long (10s+). |
| `commandExecuted` | `x:{appName}:{exitCode}` | Only if available. Group by success/failure, not exact command. |

**Purpose:** Predicts the category and app of the next event ("user will type in Ghostty" or "user will activate Chrome") — not the specific typed text. Captures app-switch sequences, copy-then-terminal patterns, hesitation-then-switch flows.

**Training:** Batch process raw JSONL files (on idle, AC power). Walk events, normalize to tokens, insert n-gram sequences (n=1 through 5) into trie. Increment counters. No optimization step, no model weights.

**Runtime prediction (PPM backoff):**
1. Maintain sliding window of last 5 event tokens.
2. Try depth 5: walk trie matching the full window. If the path exists, collect child counts.
3. **Backoff** to depth 4: match the 4-token suffix of the window. Collect child counts with an escape penalty (multiply by 0.4).
4. Continue backoff to depth 3, 2, and 1 (unigram), each with increasing escape penalty.
5. Blend all collected children across all depths, weighted by escape penalties.
6. If the top blended prediction exceeds the confidence threshold (default ~50%) → emit suggestion. If not → stay quiet.

**Why PPM over a plain trie:** A plain trie can't gracefully degrade. If your exact 5-event context hasn't been seen but a shorter suffix has, a plain trie drops to unigram (useless). PPM blends all available orders — after 10 hours of usage, even the unigram "user often activates Chrome" is a real fallback.

### Micro layer: flat frequency dictionaries (predicts specific values, V2+)

For event types where the specific value matters (what text was typed, what was copied), this is a retrieval problem — not sequential. No trie needed.

```
// Not a tree. Flat dictionary keyed by macro context hash.
// Value: [(value: String, count: Int)]

microPredictions["a:IDE → c:short → a:Ghostty"]["killall Finder"] = 12
microPredictions["a:IDE → c:short → a:Ghostty"]["brew upgrade"] = 3
```

**How it fires:**
1. Macro layer predicts `k:Ghostty` at 60% confidence.
2. Hash the last N macro tokens + target app → O(1) dict lookup.
3. Return the top entry: "Type `killall Finder` in Ghostty?"

**Per-app behavior naturally self-selects:**
- Ghostty: ~15 repeating commands → dict has entries → suggestions fire
- Chrome URL bar: thousands of unique URLs → dict has 0-2 entries → stays silent
- IDE editor: unique code text → stays silent

No special-casing. If an app doesn't produce repeating specific values, its context key has zero or one entry and nothing gets suggested.

## Approaches Considered and Discarded

### Markov chain (discarded)

Tracked `P(nextApp | currentApp, hour)`. Simple but can't capture multi-step sequences like copy → switch → paste, and only predicts app switches. No backoff blending.

### Heuristic-only engine (discarded)

Hand-coded rules for copy-repeat, hesitation, app ping-pong. No learning over time — every new pattern requires a code change.

### LLM-based pattern mining (deferred)

TelemetryReportWriter could be extended to emit structured patterns from session data. Not needed for V1 — algorithmic training covers the same ground with less complexity and no hallucination risk.

### Plain trie (discarded for macro)

A plain trie without backoff blending degrades to useless when the exact context hasn't been seen. PPM's escape-weighted blending provides graceful fallback with the same insertion code.

### Trie for micro layer (discarded)

Micro predictions don't involve variable-length sequences — they're a `context → value` lookup. A trie adds complexity for no benefit. A flat dictionary is simpler and faster.

## Requirements

**Tokenization (R1)**
- R1. Each captured `DesktopUserEvent` must be normalized into a compact token string per the schema above. Raw event fields (coordinates, full text, window titles) must be stripped or truncated before insertion.

**Macro Layer: PPM Trie (R2-R6)**
- R2. Token sequences must be inserted into an in-memory trie with frequency counters at each node. The trie must support n-gram insertion for n=1 through n=5.
- R3. The prediction query must implement PPM backoff: try depth 5, back off to 4, 3, 2, then 1, applying increasing escape penalties at each backoff step.
- R4. All depths' predictions must be blended into a single ranked list sorted by weighted frequency.
- R5. The trie must persist to disk (binary serialization or compressed JSON) in `~/Library/Application Support/Casper/prediction/`. Must survive app restarts.
- R6. A sliding window of the last 5 event tokens must be maintained in memory for runtime prediction queries.

**Micro Layer: Flat Dictionaries (R7-R8, V2+)**
- R7. For each event type where specific values repeat (text input, click targets), maintain a flat dictionary keyed by a hash of the last N macro context tokens + target app.
- R8. Micro predictions must only fire when the macro layer has already predicted the corresponding event type above threshold. The micro layer is a refinement, not an independent predictor.

**Training (R9-R11)**
- R9. Training must be batchable against raw JSONL telemetry files. Runs during idle time or on AC power. A manual retrain trigger must be available from Settings.
- R10. Training must apply a count floor: token sequences and micro values seen fewer than N times (configurable, default 3) are excluded. Prevents one-off behavior from bloating the data structures.
- R11. Older sessions must be decayed. When inserting from today, increment counters by 2; from yesterday by 1; from older than 48h by 0.5. This decays stale patterns naturally without explicit garbage collection.

**Prediction at Runtime (R12-R14)**
- R12. The macro PPM query must complete in <1ms on every new event.
- R13. Predictions below a configurable confidence threshold (default 0.5) must be suppressed. Below-threshold predictions must not produce suggestions.
- R14. The predicted token must be mappable to a `DesktopAgentRecommendation` action:
  - `a:{bundleID}` → activate app
  - `c:{app}:{text}` → paste text
  - `k:{app}` → (skip if no micro hit — "type in X" is not useful alone)
  - `m:{app}:{role}` → (skip — too vague without micro hit)

## Actors

- A1. macOS User: generates events through normal computer use.
- A2. TelemetryCollector: produces raw events (unchanged).
- A3. Tokenizer: normalizes raw `DesktopUserEvent` values into compact token strings.
- A4. PpmTrie: in-memory prefix tree with PPM query and backoff. Handles insertion, blended prediction, serialization.
- A5. MicroStore: collection of flat dictionaries keyed by macro context hash. Handles insertion and O(1) lookup.
- A6. SuggestionController: maps predicted tokens to `DesktopAgentRecommendation` and surfaces them (menu bar chip, transient notification).

## Key Flows

- **F1. Training.** TelemetrySummarizer detects idle → Trainer loads unprocessed JSONL files → Tokenizer normalizes each event → PpmTrie inserts n-gram sequences → MicroStore inserts value frequencies → persists both to disk.
- **F2. Runtime Prediction (macro only).** TelemetryCollector fires an event → Tokenizer normalizes it → SequencePredictor shifts sliding window → PpmTrie.predict(window) blends depths → returns top (token, confidence) → if above threshold, SuggestionController emits action.
- **F3. Runtime Prediction (macro + micro, V2).** Macro layer predicts `k:Ghostty` at 60% → MicroStore.lookup(contextHash) returns ["killall Finder": 12, "brew upgrade": 3] → SuggestionController emits "Type `killall Finder` in Ghostty?"
- **F4. Suggestion Action.** User clicks suggestion → action executes (activate app via NSWorkspace, paste text via TextPaster).
- **F5. Suggestion Dismiss.** User ignores or dismisses → prediction is consumed (not re-shown until context advances).

## Scope Boundaries

### In scope for V1
- Macro PPM trie with 3 event token types: `a:{bundleID}`, `c:{app}:{shortText}`, `m:{app}:{role}`
- PPM backoff blending with configurable escape penalties and confidence threshold
- Training by batch-processing raw JSONL files (reuses telemetry idle-time trigger)
- Suggestion surface: menu bar chip or transient notification
- Manual retrain button in Casper Settings

### Deferred for later
- Micro layer flat dictionaries (V2)
- `k:{app}` and `m:{app}:{role}` suggestion support (requires micro layer, V2)
- Time-of-day weighting in PPM (weight transitions differently by hour/day)
- `commandExecuted` event wiring and tokenization
- `userHesitated` token and hesitation-triggered predictions
- User feedback loop (accept/reject tracking to tune thresholds)
- Automatic threshold tuning based on acceptance rate

### Outside this product's identity
- Cloud-based pattern matching or telemetry upload
- LLM involvement at any stage of prediction
- Predictive typing or text auto-completion beyond exact sequence repetition

## Key Decisions
- **No LLM anywhere.** All training and inference is algorithmic. The TelemetryReportWriter continues to use LLMs for narrative reports, but the prediction engine is fully independent.
- **Algorithmic training from raw events.** Both the PPM trie and micro dictionaries are built by walking raw JSONL files and incrementing counters. No prompt engineering, no structured output parsing, no hallucination risk.
- **PPM over plain trie for macro.** Same insertion code, but prediction blends all context depths with escape-weighted probabilities instead of failing on unseen exact matches. Produces useful predictions from day one.
- **Flat dicts over tries for micro.** The micro problem is retrieval, not sequence prediction. A hash-keyed frequency dictionary is simpler, faster, and naturally self-selects for apps with repetitive text (terminals) vs unique text (IDEs).
- **Token normalization is the hardest design decision.** The value of the entire system depends on choosing the right abstraction level for each event type. Too much detail → trie explodes. Too little → predictions are useless. The schema above is the starting point and will need tuning based on real usage.

## Dependencies / Assumptions
- TelemetryCollector continues producing `DesktopUserEvent`s with the current event types.
- Raw JSONL files are retained long enough for batch training (7-day rotation is fine).
- PPM trie size: with normalized tokens and ~15 distinct apps, estimated at a few thousand nodes after a month of use. Fits in memory trivially.
- Micro dictionary size: bounded by distinct typed commands per app. Ghostty might have 50, Chrome URL bar might have 2000 (but mostly unique → below count floor → excluded).
- Time decay weights are good enough without explicit garbage collection.

## Acceptance Examples
- AE1. **Macro PPM backoff.** Given a user who has 20 instances of `a:IDE → a:Chrome` and 5 instances of `a:IDE → c:short → a:Ghostty`, when the context is `[a:IDE, c:short]` the plain trie has no 2-gram match, but PPM backs off to 1-gram `a:IDE` and predicts `a:Chrome` (20) blended with a penalty. The blended prediction still hits threshold.
- AE2. **Micro dict.** Given a user who types `killall Finder` in Ghostty 12 times and `brew upgrade` 3 times, when the macro layer predicts `k:Ghostty` at 60%, MicroStore returns `"killall Finder"` as the top value.

## Success Criteria
- PPM query (all 5 backoff depths) completes in <1ms (measured with os_signpost).
- At least one prediction per 2 hours of active use exceeds the 50% confidence threshold.
- Zero additional GPU usage from the prediction engine.
