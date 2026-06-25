---
id: 2026-06-25-001
type: feat
title: AX element interaction with persistent identity
status: active
created: 2026-06-25
author: plan
---

# feat: AX element interaction with persistent identity

## Summary

Casper currently observes and describes UI elements through Accessibility APIs but cannot act on them. The prediction engine already predicts click and type actions (`.clickElement`, `.typeText`) but they only display in the overlay — no executor exists. This plan adds the ability to find elements by semantic identity and perform actions (press, set value, focus) on them, then wires execution through the prediction engine.

## Problem Frame

- **Current state:** `TelemetryCollector.resolveElementLabel()` builds a composite string like `"AXButton (Title: Submit)"` for events. The prediction engine's `PredictedActionStep` models `.clickElement(description:)` and `.typeText(text:)` but `DefaultActionExecutor` only handles `.activateApp`. Users see predicted actions they cannot execute.
- **Target state:** Every observed element carries a persistent `ElementID` that survives app restarts. The prediction engine's click/type predictions actually execute. Actions fall back gracefully when `AXPress` is unsupported.
- **Non-goals:** Full MCP server for external AI agents. Interactive element picker overlay. Cross-app workflow scripting. VoiceOver integration.

## Scope Boundaries

- **In scope:** Persistent element identity generation and resolution. Element search and action execution via AX + CGEvent fallback. Prediction engine executor extension. ElementID recording in telemetry events.
- **Deferred for later:** Cross-app workflow execution. Interactive element picker UI.
- **Deferred to follow-up work:** DesktopAgentBridge LLM action types for element interaction (separate from prediction engine).

## Requirements

- R1: Every tracked UI element interaction carries a persistent identity that can be resolved later
- R2: Elements can be found by role + label criteria in the frontmost app's AX tree
- R3: Found elements support press, set value, and focus actions
- R4: Executor automatically falls back to CGEvent coordinate click when AXPress fails
- R5: The existing prediction engine's `.clickElement` and `.typeText` action steps actually execute
- R6: Execution results (success/failure) are visible for debugging
- R7: Existing event logs without ElementID remain readable (backward compat)

## Key Technical Decisions

- **Element Identity:** Ancestor-qualified label chain (bottom-up role:label pairs) as primary scheme, `kAXIdentifierAttribute` as short-circuit when present. More robust than flat labels or index paths.
- **Search scope:** Frontmost application only (extensible to bundle ID later).
- **Fallback strategy:** Auto-fallback to CGEvent click at element frame center when `AXPress` fails. No opt-in flag — failures should not be silent.
- **Concurrency:** All AX entry points stay `@MainActor` (existing pattern from `FocusedElementLocator`, `TelemetryCollector`).
- **Micro store key:** Store ElementID as the micro store value for `m:` and `k:` tokens instead of raw label strings.

---

## Implementation Units

### U1. ElementID — Persistent element identity

**Goal:** Create a stable, resolvable identifier for AX UI elements that survives app restarts and minor UI changes.

**Requirements:** R1, R7

**Dependencies:** None

**Files:**
- `Casper/Context/ElementID.swift` (create)
- `Casper/Context/FocusedElementLocator.swift` (modify — add ElementID generation)
- `CasperTests/ElementIDTests.swift` (create)

**Approach:**
- `ElementID` is a `Codable + Sendable + Equatable` struct with two strategies:
  - **Direct** — `kAXIdentifierAttribute` value when present on the element itself (most stable)
  - **AncestorChain** — ordered list of `(role: String, title: String?)` pairs from element up through 5 ancestor levels
- `ElementID.resolve(in:)` takes a process ID and walks the frontmost app's AX tree top-down matching role+title at each level, returning the leaf AXUIElement
- `ElementID.generate(from:)` takes an AXUIElement and produces the best available identity
- Backward compat: events without ElementID fall back to flat label matching

**Patterns to follow:**
- `resolveElementLabel` ancestor walk in `TelemetryCollector.swift:243-320` (same 7-level max-depth approach)
- `FocusedElementLocator.attributeValue` helper pattern for safe AX reads

**Test scenarios:**
1. Generate ElementID for an element with `kAXIdentifierAttribute` → returns `.direct` variant
2. Generate ElementID for an element without identifier → returns `.ancestorChain` with correct role:title pairs
3. Resolve an ancestor-chain ElementID on the same app → returns matching AXUIElement
4. Resolve with extra intermediate elements in the chain → still matches (lenient matching)
5. Resolve with a mismatched ancestor role → returns nil
6. Round-trip: generate → serialize to JSON → deserialize → resolve → succeeds
7. Empty AX tree on app not running → resolve returns nil
8. Codable conformance: encode/decode produces same identity

**Verification:** All test scenarios pass. ElementID successfully round-trips through JSON serialization.

---

### U2. AXElementFinder — Semantic element search

**Goal:** Find AXUIElement references by role + label criteria in the frontmost application.

**Requirements:** R2

**Dependencies:** None (standalone, but generates ElementIDs for its results)

**Files:**
- `Casper/Context/AXElementFinder.swift` (create)
- `CasperTests/AXElementFinderTests.swift` (create)

**Approach:**
- `AXElementFinder` with `@MainActor` static/instance methods:
  - `findElement(role: AXRole, label: String, exact: Bool = false) -> AXUIElement?` — DFS through the frontmost app's AX tree
  - `findElements(role: AXRole, label: String, exact: Bool = false) -> [AXUIElement]` — return all matches
  - `findElements(criteria: [(attribute: String, value: String)]) -> [AXUIElement]` — multi-attribute search
- `AXRole` is a type-safe wrapper around role strings (`.button`, `.textField`, `.staticText`, `.group`, `.window`, etc.) with `AXRole(rawValue:)` and static constants
- Label matching defaults to **case-insensitive contains** (real-world labels have "Save (⌘S)", "Save…", etc.)
- Reuses `children(of:)` and `isFocused` patterns from `FocusedElementLocator`
- Maximum search depth: 20 levels (configurable)

**Patterns to follow:**
- Tree walking: `firstFocusedDescendant` and `children(of:)` in `FocusedElementLocator.swift:215-244`
- Attribute reading: `attributeValue(named:of:)` in `FocusedElementLocator.swift:547-563`
- AX tree structure: AXApplication → AXWindow → AXGroup/children → leaf elements

**Test scenarios:**
1. Find a button by exact role + matching title → returns the element
2. Find a button by role + case-insensitive contains (e.g., "save" matches "Save (⌘S)") → returns the element
3. Find a text field by role only → returns first match
4. Find non-existent element → returns nil
5. Multiple elements match role + label → findElements returns all
6. Search with no frontmost application → returns nil gracefully
7. Search on a non-responsive app → returns nil (timeout guard)
8. Custom criteria search with role + identifier → returns matching element

**Verification:** All test scenarios pass. ElementFinder returns valid AXUIElement references for known test elements.

---

### U3. AXActionPerformer — Element action execution

**Goal:** Perform actions on AXUIElement references (press, set value, focus) with automatic CGEvent fallback.

**Requirements:** R3, R4

**Dependencies:** U1 (uses ElementID for logging)

**Files:**
- `Casper/Input/AXActionPerformer.swift` (create)
- `CasperTests/AXActionPerformerTests.swift` (create)

**Approach:**
- `AXActionPerformer` with `@MainActor` methods:
  - `func press(_ element: AXUIElement) async -> Bool` — calls `AXUIElementPerformAction(element, kAXPressAction)`. On failure, reads `frame(for:)` from the element. If `frame(for:)` returns nil, logs the failure and returns false. Otherwise posts `CGEvent` left mouse down/up at the frame center via `CGEventPost(tap: .cghidEventTap)`. Returns true if either succeeds.
  - `func setValue(_ element: AXUIElement, value: String) async -> Bool` — calls `AXUIElementSetAttributeValue(element, kAXValueAttribute, value)`. No CGEvent fallback needed — setValue is already an attribute write.
  - `func focus(_ element: AXUIElement) async -> Bool` — calls `AXUIElementSetAttributeValue(element, kAXFocusedAttribute, kCFBooleanTrue)`.
  - `func availableActions(_ element: AXUIElement) -> [String]` — uses `AXUIElementCopyActionNames` for introspection.
- CGEvent fallback uses the existing `CGEvent` patterns from `TextPaster.swift`
- Reports success/failure for caller logging
- Frame resolution reuses `FocusedElementLocator.frame(for:)` pattern

**Patterns to follow:**
- CGEvent posting: `TextPaster.swift` Cmd+V simulation via `CGEventPost(tap: .cghidEventTap)`
- Frame reading: `FocusedElementLocator.frame(for:)` at `FocusedElementLocator.swift:407-440`
- AX action names: `AXUIElementCopyActionNames` (standard API, not yet used in codebase)

**Test scenarios:**
1. Press a button that supports `kAXPressAction` → succeeds via AX path
2. Press an element that does not advertise `kAXPressAction` → falls back to CGEvent click
3. Set value on a text field → value is set via `kAXValueAttribute`
4. Focus an element → `kAXFocusedAttribute` is set to true
5. Query available actions on a button → returns list containing "AXPress"
6. Query available actions on a static text → returns empty or non-press actions
7. Press on an invisible/disabled element → returns false (both AX and CGEvent fail)
8. setValue on a non-settable element → returns false

**Verification:** All test scenarios pass. ActionPerformer successfully presses buttons in known cooperative apps (Calculator, TextEdit) and falls back gracefully for uncooperative targets.

---

### U4. DefaultActionExecutor integration — Execute predicted click/type

**Goal:** Wire the prediction engine's `.clickElement` and `.typeText` action steps through `DefaultActionExecutor` so they actually execute.

**Requirements:** R5, R6

**Dependencies:** U1, U2, U3

**Files:**
- `Casper/Prediction/DefaultActionExecutor.swift` (modify)
- `Casper/QA/DesktopAgentBridge.swift` (modify — add `clickElement` and `typeText` to ActionType)
- `CasperTests/DefaultActionExecutorTests.swift` (modify or create)

**Approach:**
- Extend `DefaultActionExecutor.canExecute` to handle `m:` (click) and `k:` (type) token prefixes
- Extend `DefaultActionExecutor.execute`:
  - For `.clickElement(description:, appName:)`:
    1. Find the frontmost app by appName
    2. Use `ElementID.resolve(in:)` to locate the target element
    3. Fall back to `AXElementFinder.findElement(role:label:)` if ElementID resolution fails
    4. Call `AXActionPerformer.press(element)`
  - For `.typeText(text:, appName:)`:
    1. Find the frontmost app by appName
    2. Use `ElementID.resolve` or `AXElementFinder` to find the text field
    3. Call `AXActionPerformer.focus(element)` then `AXActionPerformer.setValue(element, value: text)`
- Execution results are logged via `debugLogger` with success/failure
- `DesktopAgentBridge.ActionType` gains `clickElement` and `typeText` cases for the LLM agent path (stub for now — LLM agent integration deferred)

**Patterns to follow:**
- Existing `canExecute`/`execute` protocol pattern in `DefaultActionExecutor.swift:7-22`
- `Prediction.token.hasPrefix("a:")` dispatch pattern — extend to `m:`, `k:`, `c:` (paste already works)

**Test scenarios:**
1. `canExecute` returns true for `m:` and `k:` prefixed predictions
2. `execute` with `.clickElement(description: "Submit", appName: "Calculator")` — finds and presses the button
3. `execute` with `.typeText(text: "42", appName: "Calculator")` — focuses field and sets value
4. `execute` with unknown token prefix → no-op (graceful skip)
5. Element not found → logged as failure, no crash
6. Element found but action fails → logged as failure, no crash

**Verification:** All test scenarios pass. Existing prediction for `.clickElement` and `.typeText` actually triggers the element interaction and logs results.

---

### U5. ElementID recording in telemetry events

**Goal:** Record `ElementID` alongside existing element descriptions in telemetry events and train the micro store with structured identities.

**Requirements:** R1, R7

**Dependencies:** U1

**Files:**
- `Casper/Telemetry/TelemetryCollector.swift` (modify)
- `Casper/Telemetry/TelemetryStorage.swift` (check — verify backward compat)
- `Casper/Prediction/Tokenizer.swift` (modify — update micro store training)
- `Casper/Prediction/MicroStore.swift` (verify — check key format)
- `CasperTests/TelemetryCollectorTests.swift` (modify)

**Approach:**
- Add `elementID: String?` field to `DesktopUserEvent.mouseClicked` case (preserves existing labeled tuple pattern)
- After resolving label in `resolveElementLabel`, also generate and attach `ElementID`
- `Tokenizer.tokenize` for `m:` events: include `ElementID` in the micro store value alongside the label
- Micro store key format changes: store as `role:ElementID_serialized` instead of just the flat label
- Backward compat: old log lines without elementID field are read gracefully (JSONDecoder with missing key)
- Existing `normalizeClickTarget` still works — ElementID is an enrichment, not a replacement

**Patterns to follow:**
- `TelemetryCollector.resolveElementLabel` pattern at `TelemetryCollector.swift:243-320`
- Event deserialization in `TelemetryStorage` (uses JSONDecoder, gently handles unknown keys)

**Test scenarios:**
1. `mouseClicked` event includes `elementID` field when element has identifier
2. `mouseClicked` event includes `elementID` field when element uses ancestor chain
3. Old log line without `elementID` field deserializes without error
4. Micro store records ElementID as part of the value for `m:` tokens
5. Prediction engine resolves `m:` token using ElementID instead of flat label
6. Multiple clicks on the same button produce the same ElementID

**Verification:** All test scenarios pass. Telemetry events carry ElementID, backward-compat loading works, micro store keys include structured identities.

---

### Deferred to Follow-Up Work

- **`DesktopAgentBridge` LLM action types** — Add `clickElement` and `typeText` to `ActionType` and wire through the LLM agent evaluation path. The prediction engine integration comes first; the LLM agent path is a separate concern.
- **Bundle-ID-scoped element search** — Currently frontmost app only. Extending to search by `bundleID` or `pid` will be a single parameter addition to `AXElementFinder`.
- **Interactive element picker** — A UI overlay that lets users manually select elements to add to a watched list. Not needed for the prediction-driven use case.

---

## Dependencies / Prerequisites

- Accessibility permission granted in System Settings (already required for existing features)
- Existing `PermissionChecker.checkAccessibility()` utility
- Existing `@MainActor` patterns for AXUIElement calls

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| AXPress silently fails on some apps (Electron, Catalyst) | High | Medium | CGEvent fallback covers the majority of failures |
| ElementID ancestor chain becomes stale after app update | Medium | Low | Lenient matching — tolerate extra/missing intermediate elements |
| AXUIElement messaging timeout blocks main thread | Medium | High | Use `AXUIElementSetMessagingTimeout` (0.5s) for all reads, matching existing stall-detection pattern |
| Swift 6 concurrency warnings on AXUIElement | Low | Medium | All AX entry points stay `@MainActor` (existing pattern) |

## Phased Delivery

1. **U1 + U2** (ElementID + Finder) — Foundation. Can be tested independently with unit tests.
2. **U3** (ActionPerformer) — Action execution. Test manually against Calculator, TextEdit.
3. **U4** (Executor integration) — Prediction engine actually works. User-facing value.
4. **U5** (Telemetry recording) — Enrichment. Backward-compatible, can ship separately.

## Operational Notes

- All new code follows the existing `@MainActor` convention for AX operations
- CGEvent fallback uses `CGEventPost(tap: .cghidEventTap)` — same tap as `TextPaster`, no additional permissions needed
- Debug logging via existing `debugLogger` closure pattern
