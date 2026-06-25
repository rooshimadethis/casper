---
date: 2026-06-24
type: refactor
topic: prediction-engine-decoupling
status: active
---

# Plan: Decouple Prediction Engine — UI, Predictor, and Executor Protocols

## Summary

Define protocol interfaces for the prediction engine's three swappable concerns — prediction serving, action execution, and UI — then refactor existing concrete types (`RuntimePredictor`, `PredictionOverlayWindowController`) to depend on protocols instead of each other. The prediction trainer and PPM trie remain internal to the predictor. The result: any layer can be replaced independently (LLM predictor, MCP executor, alternate overlay) without touching the other layers.

## Problem Frame

The current prediction engine (see origin: `docs/brainstorms/2026-06-24-prediction-engine-requirements.md`, `docs/plans/2026-06-24-001-feat-desktop-prediction-engine-v1-plan.md`) has no abstraction boundaries:

```
AppState
 └── creates RuntimePredictor (concrete)
      └── passed to PredictionOverlayWindowController (concrete RuntimePredictor dependency)
           └── handleAction() has NSWorkspace.open baked in
```

Every future addition — an LLM-based predictor via MCP, a paste executor that routes through AXUI, an alternate UI surface — requires modifying the concrete chain. The codebase already has the pattern for this (`TelemetryPowerMonitoring`, `CleanupBackend`, `LocalLLMStreaming` protocols) but the prediction layer has none.

(see origin: `Casper/Prediction/RuntimePredictor.swift`, `Casper/Prediction/PredictionOverlayWindowController.swift`, `Casper/AppState.swift`)

## Scope Boundaries

### In scope
- Define `PredictionProviding` protocol (what the UI needs from any prediction engine)
- Define `ActionExecuting` protocol (what the UI calls to execute a prediction)
- Make `RuntimePredictor` conform to `PredictionProviding`
- Create `DefaultActionExecutor` from the logic currently in `handleAction()`
- Refactor `PredictionOverlayWindowController` to depend on `any PredictionProviding` + `any ActionExecuting`
- Update `AppState` to wire protocols at the composition root
- Move `Prediction` struct out of `RuntimePredictor.swift` into its own file

### Deferred (separate feature)
- Creating an LLM-based or MCP-backed predictor implementation
- Creating an MCP executor or AXUI-paste executor
- Refactoring `PredictionTrainer` — it trains the underlying data, not the runtime interface
- Abstracting `PpmTrie` behind a protocol (internal to predictor)

### Outside scope
- Changing prediction training or persistence flow
- Changing the overlay UI behavior or SwiftUI view hierarchy
- Adding new UI surfaces
- Changing how `TelemetryCollector` fires events into the predictor

## Key Technical Decisions

### Protocol split: PredictionProviding vs ActionExecuting
Two separate protocols rather than one "prediction service". The executor is independently swappable (local NSWorkspace vs MCP tool calls) and has no reason to know about event ingestion.

### PredictionProviding is class-bound (AnyObject)
The window controller holds a weak reference to avoid retain cycles. The protocol must be `AnyObject` for weak references to work.

### Subscriptions via Combine publisher, not @Published conformance requirement
The protocol exposes `var predictionsPublisher: AnyPublisher<[Prediction], Never>` rather than requiring conformers to be `ObservableObject`. This lets any kind of predictor (even a struct or actor) publish predictions without inheriting a specific base class.

### Synchronous predictions access for show()
`PredictionOverlayWindowController.show()` needs to immediately display current predictions on manual toggle. The protocol exposes `var topPredictions: [Prediction] { get }` as a synchronous read.

### CurrentPrediction reset moves to PredictionProviding consumption method
`handleAction()` and `handleDismiss()` currently write `predictor.currentPrediction = nil` — a side effect that couples the window controller to `RuntimePredictor`. The protocol adds `func consumePrediction()` which the window controller calls after action/dismiss. The concrete `RuntimePredictor` clears its internal `currentPrediction` state.

### Persistence and debug info on the protocol
`predictionStateDump()` replaces `runtimePredictor.trie.nodeCount()` and `runtimePredictor.confidenceThreshold` in AppState. `savePredictionState()` replaces `runtimePredictor.trie.save(to:)`. This keeps the trie fully internal to RuntimePredictor.

### Prediction struct moves to its own file
`Casper/Prediction/Prediction.swift` so both protocols and both implementations can import it without circular dependencies.

## Implementation Units

### U1. Define Protocols and Prediction.swift

**Goal:** Create the three shared interfaces and move the `Prediction` model to its own file.

**Dependencies:** None

**Files:**
- Create: `Casper/Prediction/Prediction.swift` (moved from `RuntimePredictor.swift`)
- Create: `Casper/Prediction/PredictionProviding.swift`
- Create: `Casper/Prediction/ActionExecuting.swift`

**Approach:**

`Prediction.swift`:
```swift
struct Prediction: Sendable, Equatable {
    let token: String
    let confidence: Double
    let displayTitle: String
    let displayDescription: String
    let suggestedContent: String
}
```

`PredictionProviding.swift`:
```swift
protocol PredictionProviding: AnyObject {
    var predictionsPublisher: AnyPublisher<[Prediction], Never> { get }
    var topPredictions: [Prediction] { get }
    func ingest(event: DesktopUserEvent)
    func consumePrediction()
    func savePredictionState() throws
    var predictionStateDump: String { get }
}
```

`ActionExecuting.swift`:
```swift
protocol ActionExecuting {
    func execute(_ prediction: Prediction) async
    func canExecute(_ prediction: Prediction) -> Bool
}
```

The `canExecute` check lets the UI decide whether to show an action button at all (e.g., an executor that only handles `a:` tokens would return false for `c:` tokens — the UI could disable or hide the button). The window controller uses `async` for `execute()` so future executors (MCP, AXUI) can be async without changing the protocol.

**Patterns to follow:**
- `TelemetryPowerMonitoring` in `Casper/Telemetry/TelemetryPowerMonitor.swift` — single-responsibility protocol with clearly scoped methods
- `CleanupBackend` in `Casper/Cleanup/CleanupBackend.swift` — single-method protocol for swappable execution

**Test scenarios:**

| Scenario | Input | Expected |
|---|---|---|
| Prediction struct Equatable | Two predictions with same fields | `==` returns true |
| Prediction struct Sendable | Prediction passed across actor boundary | Compiler accepts (Sendable conformance) |
| PredictionProviding protocol conformable | A test struct conforms to PredictionProviding | Compiler accepts |
| ActionExecuting protocol conformable | A test struct conforms to ActionExecuting | Compiler accepts |

**Verification:** Project compiles without errors. No regressions in existing prediction behavior.

---

### U2. Conform RuntimePredictor to PredictionProviding

**Goal:** Make `RuntimePredictor` implement `PredictionProviding` and clean up its leaky public API (`trie` and `confidenceThreshold` become internal).

**Dependencies:** U1

**Files:**
- Modify: `Casper/Prediction/RuntimePredictor.swift`

**Approach:**
- Add `PredictionProviding` conformance to the class declaration
- Implement `predictionsPublisher` as a computed property erasing `$topPredictions` to `AnyPublisher`
- Implement `topPredictions` as a simple return of the stored array
- Implement `consumePrediction()`: sets `currentPrediction = nil`, clears `topPredictions` array, resets `lastEmittedPrediction`
- Implement `savePredictionState()`: delegates to `trie.save(to:)` using the existing trieURL construction
- Implement `predictionStateDump`: returns a string like `"trie_nodes: \(trie.nodeCount()), threshold: \(confidenceThreshold)"`
- Change `trie` and `confidenceThreshold` from `let` (public) to `private let` — they are no longer accessed directly by AppState
- The `ingest(event:)` method is already public — it becomes the protocol's ingest implementation

What stays: `debugLogger` closure (cross-cutting concern), `ObservableObject` conformance (Combine publisher requirement), all internal state and logic.

**Patterns to follow:**
- `TelemetryPowerMonitor` in `Casper/Telemetry/TelemetryPowerMonitor.swift` — concrete class conforming to a protocol while keeping internal details private

**Test scenarios:**

| Scenario | Input | Expected |
|---|---|---|
| predictionsPublisher emits on topPredictions change | Simulate trie producing predictions | Publisher emits matching array |
| consumePrediction clears state | `currentPrediction` was set | Both `currentPrediction` and `topPredictions` are nil/empty |
| savePredictionState succeeds | Predictor had been trained | Trie file exists at expected path |
| predictionStateDump returns string | Normal state | String contains node count and threshold |
| Protocol conformance without type | Ingest called through `any PredictionProviding` | Same behavior as direct call |
| trie no longer public | Code outside RuntimePredictor accesses `.trie` | Compiler error |

**Verification:** Project compiles. `trie` and `confidenceThreshold` are no longer referenced outside `RuntimePredictor` (verify grep returns only RuntimePredictor.swift matches). Prediction overlay still shows predictions.

---

### U3. Create DefaultActionExecutor

**Goal:** Extract the action execution logic from `PredictionOverlayWindowController.handleAction()` into a standalone class conforming to `ActionExecuting`.

**Dependencies:** U1

**Files:**
- Create: `Casper/Prediction/DefaultActionExecutor.swift`
- Create: `CasperTests/DefaultActionExecutorTests.swift`

**Approach:**

`DefaultActionExecutor`:
- Single class with no state (stateless service)
- `execute(_:)` performs the same logic as `handleAction()`: checks token prefix, calls `NSWorkspace.shared.open()` for `a:` prefix
- `canExecute(_:)` returns `true` if `prediction.token.hasPrefix("a:")` — currently only app-switch actions are executable. Returns `false` for `c:`, `m:`, `k:`, etc.
- Includes the debugLogger closure pattern for consistency
- Add an `executeAction` function-level async method that can be extended later

```swift
final class DefaultActionExecutor: ActionExecuting {
    var debugLogger: ((DebugLogCategory, String) -> Void)?

    func execute(_ prediction: Prediction) async {
        if prediction.token.hasPrefix("a:") {
            let bundleID = prediction.suggestedContent
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open(appURL)
                debugLogger?(.prediction, "Launched app: \(bundleID)")
            } else {
                debugLogger?(.prediction, "Failed to find app for bundle: \(bundleID)")
            }
        }
    }

    func canExecute(_ prediction: Prediction) -> Bool {
        prediction.token.hasPrefix("a:")
    }
}
```

**Patterns to follow:**
- `CleanupBackend` in `Casper/Cleanup/CleanupBackend.swift` — protocol with concrete implementation that wraps an OS call
- Stateless service objects in `Casper/Telemetry/` (e.g., `TelemetrySanitizer`)

**Test scenarios:**

| Scenario | Input | Expected |
|---|---|---|
| Execute app-switch prediction | Prediction with `a:com.apple.Safari` token | NSWorkspace.open called with Safari URL |
| Execute non-app-switch prediction | Prediction with `c:Xcode:fix` token | No NSWorkspace call |
| canExecute returns true for a: | Prediction with `a:` prefix | `true` |
| canExecute returns false for c: | Prediction with `c:` prefix | `false` |
| canExecute returns false for other tokens | Prediction with `m:`, `k:`, `t:`, etc. | `false` |

**Verification:** All test scenarios pass. `DefaultActionExecutor` fully replaces the execution logic previously in `PredictionOverlayWindowController.handleAction()`.

---

### U4. Refactor PredictionOverlayWindowController

**Goal:** Make `PredictionOverlayWindowController` depend on `any PredictionProviding` and `any ActionExecuting` instead of concrete `RuntimePredictor`.

**Dependencies:** U1, U2, U3

**Files:**
- Modify: `Casper/Prediction/PredictionOverlayWindowController.swift`

**Approach:**
- Change init parameter from `predictor: RuntimePredictor` to `predictor: any PredictionProviding, executor: any ActionExecuting`
- Store both as private let references
- Replace `predictor.$topPredictions` subscription with `predictor.predictionsPublisher`
- Replace all `predictor.topPredictions` reads with `predictor.topPredictions` (same via protocol)
- Replace `predictor.currentPrediction = nil` with `predictor.consumePrediction()` in both `handleAction()` and `handleDismiss()`
- Replace `handleAction()` implementation with a call to `await executor.execute(prediction)`
- Check `executor.canExecute(prediction)` to decide whether the action button is enabled
- Remove the `private let predictor: RuntimePredictor` property, replace with `private let predictor: any PredictionProviding` and `private let executor: any ActionExecuting`

```swift
final class PredictionOverlayWindowController: NSObject {
    private let predictor: any PredictionProviding
    private let executor: any ActionExecuting

    init(predictor: any PredictionProviding, executor: any ActionExecuting) {
        self.predictor = predictor
        self.executor = executor
        super.init()
        subscribe()
    }

    // Subscribes to predictor.predictionsPublisher instead of predictor.$topPredictions
    private func subscribe() {
        predictor.predictionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { ... }
            .store(in: &cancellables)
    }

    // handleAction uses executor
    private func handleAction(_ prediction: Prediction) {
        Task { await executor.execute(prediction) }
        predictor.consumePrediction()
        currentPredictions = []
        hidePanel()
    }

    private func handleDismiss() {
        predictor.consumePrediction()
        currentPredictions = []
        hidePanel()
    }
}
```

**Patterns to follow:**
- Existing `PredictionOverlayWindowController.swift` structure — only the init signature and handleAction/handleDismiss internals change. The panel creation, positioning, animation, and SwiftUI view hosting stay identical.

**Test scenarios:**

| Scenario | Input | Expected |
|---|---|---|
| Init with protocol dependencies | `any PredictionProviding` + `any ActionExecuting` | No compiler error, window controller functions |
| Predictions flow through protocol | Mock PredictionProviding publishes predictions | Overlay shows predictions from mock |
| Handle action calls executor | User clicks action button | `executor.execute()` called with correct prediction |
| Handle dismiss calls consumePrediction | User clicks dismiss | `predictor.consumePrediction()` called |
| canExecute controls action button | Executor returns false for prediction | Action button disabled or hidden |

**Verification:** All existing overlay behaviors (show/hide, auto-hide on context change, animation, positioning, menu bar toggle) work identically. Project compiles.

---

### U5. Update AppState Wiring

**Goal:** Update `AppState` to create implementations and wire them through the new protocols at the composition root.

**Dependencies:** U1, U2, U3, U4

**Files:**
- Modify: `Casper/AppState.swift`

**Approach:**
- Create `RuntimePredictor` (already exists, now also `PredictionProviding`) unchanged
- Create `DefaultActionExecutor`
- Pass both to `PredictionOverlayWindowController` as `any PredictionProviding` and `any ActionExecuting`
- Replace `runtimePredictor.trie.save(to:)` in `prepareForTermination()` with `runtimePredictor.savePredictionState()`
- Replace `runtimePredictor.trie.nodeCount()` and `runtimePredictor.confidenceThreshold` in initialization logging with `runtimePredictor.predictionStateDump`

Current wiring (lines 269-277):
```swift
let predictor = RuntimePredictor(trie: predictionTrie)
self.runtimePredictor = predictor
// ...
self.predictionOverlayController = PredictionOverlayWindowController(predictor: predictor)
```

New wiring:
```swift
let predictor = RuntimePredictor(trie: predictionTrie)
self.runtimePredictor = predictor
let executor = DefaultActionExecutor()
self.defaultActionExecutor = executor
// ...
self.predictionOverlayController = PredictionOverlayWindowController(
    predictor: predictor,
    executor: executor
)
```

Replace termination persistence (around line 1936):
```swift
// Before:
try? runtimePredictor.trie.save(to: trieURL)
// After:
try? runtimePredictor.savePredictionState()
```

Replace initialization logging (around lines 579-580):
```swift
// Before:
let trieNodeCount = runtimePredictor.trie.nodeCount()
debugLogStore.record(category: .prediction, message: "Prediction system initialized (trie nodes: \(trieNodeCount), threshold: \(runtimePredictor.confidenceThreshold))")
// After:
debugLogStore.record(category: .prediction, message: "Prediction system initialized (\(runtimePredictor.predictionStateDump))")
```

Keep the `let runtimePredictor: RuntimePredictor` stored property for `PredictionTrainer` and `AppState.readPredictionTrieNodeCount()` (debug UI in Settings). The predictionTrainer still needs the concrete `RuntimePredictor` because it shares the `PpmTrie` reference. When the decoupling is complete, AppState has:
- `let runtimePredictor: RuntimePredictor` (concrete — for trainer and Settings debug info)
- `let defaultActionExecutor: DefaultActionExecutor` (concrete — kept for potential future configuration)
- `let predictionOverlayController: PredictionOverlayWindowController` (uses protocols via init — details hidden)

**Patterns to follow:**
- Existing `AppState` composition root pattern — all dependencies created in init, wired together, stored as `let` properties

**Test scenarios:**

| Scenario | Input | Expected |
|---|---|---|
| App initializes without error | Normal launch | Prediction overlay appears on predictions |
| Termination saves state | App terminates | `savePredictionState()` called |
| Debug log contains prediction info | App initializes | Log entry contains node count + threshold |
| PredictionTrainer still works | Trainer trains | Trie is updated, predictions reflect new data |

**Verification:** App launches, prediction overlay works identically to before. `grep -r "runtimePredictor\.trie" Casper/` returns zero results. `grep -r "runtimePredictor\.confidenceThreshold" Casper/` returns zero results.

## Dependency Graph

```
U1 (Protocols + Prediction.swift) ──→ U2 (RuntimePredictor conformance)
                                   ──→ U3 (DefaultActionExecutor)
                                   ──→ U4 (WindowController refactor)
                                         ↑
                                   U2 ───┤
                                   U3 ───┤
                                         │
                                   U5 (AppState wiring)
                                     depends: U2, U3, U4
```

U1 is the foundation — no units can start before it. U2 and U3 are independent of each other and can be built in parallel. U4 depends on U1, U2, U3. U5 depends on all previous.

## System-Wide Impact

- **AppState:** Gains `defaultActionExecutor` property. The init method's prediction-related section changes wiring calls but not the overall shape.
- **PredictionOverlayWindowController:** Init signature changes — any code creating this controller directly (only AppState currently) must pass the new parameter.
- **RuntimePredictor:** Public API surface shrinks — `trie` and `confidenceThreshold` become private. No downstream impacts because only AppState accessed them.
- **Persistence:** `prepareForTermination()` still saves the trie, just through the protocol method instead of direct trie access.
- **Build system:** Three new files (`Prediction.swift`, `PredictionProviding.swift`, `ActionExecuting.swift`, plus `DefaultActionExecutor.swift`) — auto-included by the existing `Casper/**/*.swift` glob in `project.yml`.
- **No impact on:** TelemetryCollector (still fires events via closure), PredictionTrainer (still accesses PpmTrie directly), SwiftUI overlay views (unchanged), Settings window.

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Protocol abstraction adds indirection cost | Low | Minimal runtime overhead | The protocols are thin — the publisher is already an AnyPublisher, the additional method calls are negligible. No hot-path changes. |
| consumePrediction replaces currentPrediction = nil but misses a reset path | Low | Stale prediction shown | grep all references to `currentPrediction` after refactor to verify every reset goes through `consumePrediction()`. |
| Window controller refactor breaks overlay behavior | Low | Overlay misbehaves | Manual verification of show/hide/animation/auto-hide after refactor. The test scenarios in U4 cover the critical paths. |
| Future executor needs synchronous execution | Low | Must change protocol | The protocol uses `async` from the start so all future executors are naturally async. The current DefaultActionExecutor wraps a synchronous NSWorkspace call in an `async` context — fine. |

## Success Criteria

- Prediction overlay appears and functions identically before and after refactor
- All existing prediction tests continue to pass
- `grep -r "runtimePredictor\.trie" Casper/AppState.swift` returns zero matches
- A new test struct conforming to `PredictionProviding` can be used in place of `RuntimePredictor` in `PredictionOverlayWindowController` without modifying the controller
- A new test struct conforming to `ActionExecuting` can be used in place of `DefaultActionExecutor` in `PredictionOverlayWindowController` without modifying the controller
- `PredictionTrainer` continues to access `PpmTrie` directly — no regressions in training
