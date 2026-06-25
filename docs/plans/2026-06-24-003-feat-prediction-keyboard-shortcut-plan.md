---
date: 2026-06-24
type: feat
topic: desktop-prediction-engine-shortcut
status: active
---

# Plan: Execute Top Prediction with Double-Tap Modifier Shortcut

## Summary

Add a lightweight global monitor that detects a double-tap on a configurable left modifier key and executes the top prediction suggestion — the same action as clicking the "Go" button in the prediction overlay. The detection uses `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`, is separate from the existing chord binding system, and requires no new Accessibility permissions.

## Problem Frame

(see origin: `docs/brainstorms/2026-06-24-prediction-engine-requirements.md`)

The prediction engine V1 (macro PPM trie) and V2 (micro layer) are fully implemented. Predictions appear in a floating overlay with a "Go" action button per suggestion. Executing the top prediction currently requires mouse interaction — clicking the button. There is no keyboard shortcut.

The user wants to execute the top prediction by double-tapping a left modifier key (Left Control, Left Command, Left Option, or Left Shift). This is a fire-and-forget gesture that works globally without opening the overlay.

A chord-based shortcut (via the existing `ChordAction`/`HotkeyMonitor` system) was considered but rejected — the existing system is designed for hold-to-record patterns (push-to-talk, toggle-to-talk). A double-tap modifier is simpler, requires no Accessibility permission beyond what's already granted, and doesn't interact with the recording state machine.

## Scope Boundaries

### In scope
- `ModifierDoubleTapMonitor` — lightweight class using `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` to detect double-tap on a configurable modifier key
- Configurable modifier key selection: Left Command, Left Option, Left Control, Left Shift (via a Picker in the existing Shortcuts settings card)
- Execution: calls through to `PredictionOverlayWindowController.handleAction()` on the top prediction — same code path as the "Go" button
- Persistence: selected modifier stored in UserDefaults
- `PredictionOverlayWindowController` gains a public `executeTopPrediction()` method
- Default modifier: Left Control (keyCode 59) — least likely to conflict with existing macOS or Casper shortcuts

### Deferred
- Configurable double-tap time window (300ms default is reasonable for all users; make tunable if feedback indicates otherwise)
- Visual or audible feedback on detection (could be useful if the user is unsure whether the double-tap registered)
- Caps Lock or Fn/Globe support (these have different `flagsChanged` behavior and are rarely the right choice for a double-tap gesture)

### Outside scope
- Changes to the chord binding system (HotkeyMonitor, ChordEngine, ChordAction)
- Changes to prediction generation, training, or overlay display logic
- New Settings tabs or other UI restructuring

## Key Technical Decisions

### Double-tap detection via flagsChanged global monitor
`NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` fires on every press and release of modifier keys. It reports which key code changed and the new modifier flags state. This monitor is lower-overhead than a CGEvent tap and does not require Accessibility permission (`.flagsChanged` is a safe event type).

Detection state machine per monitored key code:
- Track `isPressed: Bool` and `lastReleaseTime: Date`
- On flagsChanged for the target key:
  - If transitioning from released → pressed: check if `lastReleaseTime` is within 300ms. If so, fire the action callback. Record press time.
  - If transitioning from released → pressed: record press time.
  - If transitioning from pressed → released: record `lastReleaseTime = now`.
- On action fire: reset the press/release tracking to prevent re-firing until a fresh press-release-press cycle.

Press/release state per key is determined by toggling a boolean per keyCode, not by polling `CGEventSource.keyState`. The flagsChanged event toggles reliably.

### Time window
300ms from last release to next press. This is the standard double-click threshold on macOS and feels natural for a double-tap gesture.

### Persistence
UserDefaults key `predictionDoubleTapModifierKeyCode` storing a `UInt16` (the key code). No new persistence infrastructure needed. The existing `ChordBindingStore` is not used because this is a single modifier key, not a chord.

### Separation from HotkeyMonitor
The double-tap monitor runs independently from HotkeyMonitor. This avoids:
- Modifying `ChordEngine`'s hold/release state machine for a fire-once action
- Adding an effect type that would complicate the existing recording flow
- Needing to rework `nonModifierBindingPrefixes` filtering for modifier-only tracking

The two monitors coexist: HotkeyMonitor handles chords (Cmd+P, Cmd+Shift+R), ModifierDoubleTapMonitor handles rapid modifier taps. They don't conflict because the double-tap only fires on a clean press-release-press sequence — holding a chord down would not trigger it.

## Implementation Units

### U1. ModifierDoubleTapMonitor + Settings + Wiring

**Goal:** Create the double-tap detection monitor, wire it to execute the top prediction, and add the configuration UI in Settings. This is the only implementation unit — the feature is tightly scoped.

**Requirements:** Carries forward the Suggestion Action goal from the origin requirements doc (F4 — execute prediction) but replaces click-triggered execution with a keyboard shortcut.

**Dependencies:** None (standalone; calls into existing `PredictionOverlayWindowController`)

**Files:**
- Create: `Casper/Prediction/ModifierDoubleTapMonitor.swift`
- Create: `CasperTests/ModifierDoubleTapMonitorTests.swift`
- Modify: `Casper/Prediction/PredictionOverlayWindowController.swift`
- Modify: `Casper/AppState.swift`
- Modify: `Casper/UI/SettingsWindow.swift`

**Approach:**

**ModifierDoubleTapMonitor:**
```swift
final class ModifierDoubleTapMonitor {
    var onDoubleTap: (() -> Void)?
    var doubleTapWindow: TimeInterval = 0.3
    var monitoredKeyCode: UInt16 {
        didSet { resetState() }
    }

    private var monitor: Any?
    private var isPressed = false
    private var lastReleaseTime: Date?
    private var keyStates: [UInt16: (isPressed: Bool, lastRelease: Date?)]

    func start()
    func stop()
}
```

- `start()` registers the global flagsChanged monitor
- `stop()` removes it
- `handleEvent(_:)` toggles `keyStates[keyCode].isPressed` on each flagsChanged
  - On press transition (was false → true): if `lastReleaseTime` != nil and time since < `doubleTapWindow` → fire `onDoubleTap`
  - On release transition (was true → false): record `lastReleaseTime`

**PredictionOverlayWindowController addition:**
- Add `func executeTopPrediction()` as an `@objc` or plain internal method:
  - Guard `topPredictions.first` exists, otherwise log and return
  - Call `handleAction(topPredictions.first!)`
  - This reuses the existing action logic (app activation for `a:`, paste for `c:`/`k:`, etc.)
  - After action, clear state and hide overlay (already done in `handleAction`)

**AppState wiring:**
- Add `@Published private(set) var predictionDoubleTapModifierKeyCode: UInt16` with default `59` (Left Control)
- Load from UserDefaults in `init()`
- Create `ModifierDoubleTapMonitor` instance and start it
- Wire `onDoubleTap` callback: `predictionOverlayController.executeTopPrediction()`
- Add `updatePredictionDoubleTapModifier(_ keyCode: UInt16)` method that updates the stored value and calls `monitor.monitoredKeyCode = keyCode`
- Persist to UserDefaults on change
- Stop monitor on deinit

**SettingsWindow addition:**
- In the existing `SettingsCard("Shortcuts")` below the ShortcutRecorderView entries, add a Picker:

```swift
Picker("Double-tap modifier", selection: $appState.predictionDoubleTapModifierKeyCode) {
    Text("Left Control").tag(UInt16(59))
    Text("Left Command").tag(UInt16(55))
    Text("Left Option").tag(UInt16(58))
    Text("Left Shift").tag(UInt16(56))
}
.pickerStyle(.menu)
```

- Add explanatory text: "Double-tap to execute the top prediction"

**Patterns to follow:**
- `TelemetryCollector`'s global monitor management (`start()`/`stop()`, `NSEvent.addGlobalMonitorForEvents`) in `Casper/Telemetry/TelemetryCollector.swift` — the pattern for creating and removing a global event monitor is identical. The key difference: TelemetryCollector's keyboard monitor requires Input Monitoring permission; the `.flagsChanged` monitor does not.
- `PredictionOverlayWindowController.handleAction()` in `Casper/Prediction/PredictionOverlayWindowController.swift:160-174` — the existing action execution logic that `executeTopPrediction()` wraps
- `@Published` pattern in `Casper/AppState.swift` for persisted user preferences
- Settings `Picker` in `Casper/UI/SettingsWindow.swift` — look at any existing `.pickerStyle(.menu)` usage for the correct SwiftUI pattern

**Test scenarios:**

| Scenario | Input | Expected |
|---|---|---|
| Double-tap detected fires callback | Press → release → press Left Control within 300ms | `onDoubleTap` fires once |
| Single press does not fire | Press Left Control, hold for 1s | `onDoubleTap` does not fire |
| Slow double-tap does not fire | Press → release → wait 500ms → press Left Control | `onDoubleTap` does not fire |
| Wrong modifier ignored | Double-tap Left Option, monitored key is Left Control | `onDoubleTap` does not fire |
| Action fires exactly once per double-tap | Press → release → press → release → press → release (double-tap twice) | `onDoubleTap` fires twice, once per clean cycle |
| Start/stop lifecycle | `stop()` then new events arrive | No callback, no crash |
| Switch monitored key at runtime | Change monitoredKeyCode from 59 to 55, then press Left Command | Double-tap detected for new key |
| executeTopPrediction with no predictions | `topPredictions` is empty | No crash, debug log "no prediction available" |
| executeTopPrediction with prediction | `topPredictions` has one entry | `handleAction` called with the top prediction, overlay hides |

**Verification:** All test scenarios pass. Double-tap Left Control fires the same action as clicking "Go" in the overlay. Settings Picker changes the monitored key immediately. Running `xcodebuild test -only-testing:CasperTests/ModifierDoubleTapMonitorTests` passes.

## System-Wide Impact

- **AppState:** Gains one `@Published` property (`predictionDoubleTapModifierKeyCode`), one optional `ModifierDoubleTapMonitor` instance, one UserDefaults key. The monitor is created in `init()` and stopped in `deinit`.
- **PredictionOverlayWindowController:** One new public method (`executeTopPrediction()`). Private `handleAction` unchanged.
- **SettingsWindow:** One Picker added to the existing Shortcuts card. No new sections or tabs.
- **Persistence:** One new UserDefaults key (`predictionDoubleTapModifierKeyCode`) — no new files.
- **Permissions:** No new permissions required. Global `.flagsChanged` monitor does not require Accessibility or Input Monitoring permissions.
- **Build system:** One new Swift file (`ModifierDoubleTapMonitor.swift`) automatically picked up by the existing `Casper/**/*.swift` glob in `project.yml`.
- **Startup sequence:** Monitor is created and started after prediction engine initialization. If the monitor start fails (unlikely for flagsChanged), it degrades gracefully — feature just doesn't work.

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Double-tap Left Control conflicts with macOS Ctrl+Cmd+Q (lock screen) or other system shortcuts | Low | Accidental action firing | Left Control is not part of common double-tap gestures. The 300ms window is tight enough that accidental double-taps during normal typing are rare. |
| Global flagsChanged monitor doesn't work without Accessibility permission | Very Low | Feature doesn't work | Apple's docs confirm flagsChanged global monitors don't require Accessibility. If testing proves otherwise, fallback: add detection to the existing `HotkeyMonitor`'s CGEvent tap (which already has permission). |
| Double-tap fires when typing rapidly (pressing and releasing modifier during keyboard shortcuts like Cmd+C) | Low | Brief flashes of prediction | The release press must be within 300ms, which is tighter than most modifier+key shortcuts (where the modifier is held through the press and released after). Cmd+C: hold Cmd, press C, release both → the first modifier release starts the timer, but the subsequent press doesn't happen within 300ms because the user already released Cmd with C. |
| Multiple double-taps in quick succession multiple-fire | Low | Repeated prediction execution | The state machine resets after each detection. A clean press-release-press sequence is required for each fire. Holding the key down doesn't re-trigger. |

## Success Criteria

- Double-tap the configured modifier executes the top prediction (same as clicking "Go")
- The selected modifier persists across app restarts
- Changing the modifier in Settings takes effect immediately without restart
- No new system permission prompts
- All test scenarios pass
