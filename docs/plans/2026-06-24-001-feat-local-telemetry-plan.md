---
title: "feat: Local Telemetry & Passive macOS Interaction Framework"
type: feat
status: active
date: 2026-06-24
origin: docs/brainstorms/2026-06-24-local-telemetry-requirements.md
---

# feat: Local Telemetry & Passive macOS Interaction Framework

## Summary

This plan proposes the architecture and implementation details for a local, background-running macOS telemetry collector and summarization framework. It details how Casper will passively capture workspace events (app activations, accessibility UI hierarchies, clipboard copies, command line runs, click actions, application stalls, and OCR screen snapshots) to disk in daily partitioned JSON Lines files, summarize these events locally when the user goes idle, and generate daily friction reports to `docs/telemetry/` using local LLM inference.

---

## Problem Frame

Mac users lose time to repetitive manual sequences (such as command execution loops, copying data between windows, or waiting on slow/stalled processes) without realizing where efficiency degrades. Traditional rules-based automation systems cannot detect these nuanced user-specific patterns, and sending raw user event telemetry to the cloud for analysis is a major privacy violation. By collecting telemetry locally on-device and using Casper's offline local LLM capability to aggregate, summarize, and correlate events, we can safely recommend custom automations.

---

## Requirements

- R1. The system must passively capture `DesktopUserEvent`s including application activations, window title changes, clipboard copies, command line executions, accessibility-based UI interactions, clicked UI elements, application stalls, and OCR text snapshots.
- R2. All captured telemetry events must be stored locally on-device and must never be transmitted over the network.
- R3. Background OCR captures must remain active even when the macOS device is running on battery power.
- R4. Event logs must be rotated or truncated after 7 days to prevent unbounded local disk consumption.
- R5. Raw telemetry events must be compiled into discrete sessions and processed in isolated batches triggered only when the user is idle (e.g., no active activity for 10 minutes) to minimize active background CPU consumption.
- R6. Once daily, the system must analyze the compiled session/batch summaries to identify daily repetitions and correlate actions over time.
- R7. The daily analysis must actively discover novel potential actions and patterns over time, rather than relying exclusively on a predefined, static set of rules and actions.
- R8. The analysis must produce a Markdown report saved to `docs/telemetry/` containing time distributions, failed terminal commands, copy patterns, and proposed shell/agent automations.
- R9. The heavy daily consolidation analysis job must only execute when the macOS device is connected to AC power.
- R10. Batch processing of raw logs must run at low system priority to prevent active user tasks from experiencing CPU lag or UI stutter.

**Origin actors:**
- A1. macOS User (developer or power user)
- A2. Telemetry Collector (passive monitoring service)
- A3. LLM Analyzer (offline local inference engine)

**Origin flows:**
- F1. Event Capture & Logging (monitors user actions and logs to disk)
- F2. Batch Summarization (summarizes sessions during user idle state)
- F3. Daily Correlation & Report Generation (compiles daily friction report when on AC power)

**Origin acceptance examples:**
- AE1 (Covers R3, R9): Raw event logging and background OCR run on battery power; heavy daily consolidation runs only when plugged in.
- AE2 (Covers R5, R6, R7): Multi-session raw events are summarized in batches during idle time, and daily consolidation correlates those session summaries to identify repetitions (e.g. repeated git commands).

---

## Scope Boundaries

- Real-time JIT overlay presentation and active execution of recommended scripts are deferred.
- Web browser URLs (except window titles) and third-party API integrations (such as Gmail or Slack) are out of scope.
- Remote analytics syncing, telemetry uploads, or cloud backups are strictly excluded.

### Deferred to Follow-Up Work

- **Action Execution Engine**: A mechanism to run the proposed shell commands or paste context-aware text recommended by daily reports.
- **Real-Time JIT Overlay Presentation**: In-context menu bar alerts or window prompt overlays prompting users to execute actions immediately.

---

## Context & Research

### Relevant Code and Patterns

- `Casper/QA/DesktopAgentBridge.swift`: Contains definitions for `DesktopUserEvent`, `DesktopWorkspaceContext`, and `DesktopAgentRecommendation`.
- `Casper/Context/FrontmostWindowOCRService.swift`: Performs local screenshot capture of the active window and recognizes text via the native `Vision` framework.
- `Casper/Cleanup/TextCleanupManager.swift`: Accesses local LLM models (Qwen 3.5 2B/4B/DeepSeek R1) and streams text completions via `LLM.swift`.
- `Casper/Meeting/MeetingDetector.swift`: Demonstrates how `NSWorkspace.shared.frontmostApplication` is checked and window titles are queried using accessibility APIs.

### External References

- **System Idle Time Check**: `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .any)` provides the duration since the last user input event.
- **Power Source Status**: The Core Foundation `IOPSCopyPowerSourcesInfo` API retrieves power source details, including whether the current source is AC power (`kIOPSACPowerValue`).
- **Coordinate-to-UI-Element**: `AXUIElementCopyElementAtPosition` returns the specific `AXUIElement` located at a mouse coordinate.
- **App Responsiveness**: `NSRunningApplication.isResponding` indicates if a process is frozen/beachballing.

---

## Key Technical Decisions

- **Daily Partitioned JSON Lines Storage**: Telemetry events will be serialized as `DesktopUserEvent` JSON objects and appended to a daily file named `telemetry_events_YYYY-MM-DD.jsonl` within the application's local Support directory. This ensures `O(1)` write overhead and prevents single-file bloat.
- **Log Rotation by Partition Deletion**: Files matching the pattern `telemetry_events_*.jsonl` that have a creation or modification date older than 7 days will be deleted. This satisfies R4 in a lightweight way without needing database vacs.
- **Background Event Poller**: A central timer in a dedicated actor or background thread will poll the active application and pasteboard change count at a low rate (e.g., 2.0s) to register updates.
- **Accessibility API over Pure OCR**: Query the active window's `AXUIElement` hierarchy for structured text and UI labels, falling back to `FrontmostWindowOCRService` when accessibility permissions are missing or if elements are non-native (e.g., canvas-based interfaces).
- **Coordinate-to-Element Resolution**: Map global mouse clicks to UI elements by grabbing click coordinates via `NSEvent` global monitors and resolving them via `AXUIElementCopyElementAtPosition`.
- **Application Stall Detection**: Monitor the response state of the active app via `NSRunningApplication.isResponding` to log app stall duration.
- **User Idle and Hesitation Status Detection**: Casper will use native `CoreGraphics` APIs to query system-wide user inactivity duration. Summarization is deferred until this idle duration exceeds 10 minutes. Short-term pauses (3-8s) immediately following window focus changes will be recorded as hesitation telemetry.
- **Low Priority LLM Runs**: Session summarization and daily analysis tasks will run with Quality of Service (QoS) set to `.utility` or `.background` to avoid interrupting active foreground applications.

---

## Open Questions

### Resolved During Planning

- **How will Casper capture command line executions?**
  *Resolution*: Casper will offer an optional shell integration hook (appended to `~/.zshrc` or `~/.bashrc` via a user prompt in Settings) that writes executed commands, their exit codes, and output to a dedicated local pipe or temp file which Casper's collector reads. Additionally, Casper can monitor `~/.zsh_history` changes as a fallback, though zsh history does not contain exit codes or command output.

### Deferred to Implementation

- **Adjusting GGUF Context Length**: Whether the small local Qwen models (0.8B/2B) will require custom context truncation parameters when summarizing raw event streams consisting of hundreds of JSON entries.

---

## Output Structure

This work introduces a new Telemetry group in Casper's source hierarchy:

```
Casper/
├── Telemetry/
│   ├── TelemetryCollector.swift
│   ├── TelemetryStorage.swift
│   ├── TelemetryPowerMonitor.swift
│   └── TelemetrySummarizer.swift
CasperTests/
└── TelemetryTests/
    ├── TelemetryCollectorTests.swift
    └── TelemetryStorageTests.swift
```

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

The diagram below shows how events are captured, partitioned, batched during user idle time, and daily consolidated into friction reports when the device is plugged into AC power.

```
+-----------------------------------------------------------------------------------+
|                                 TelemetryCollector                                |
|  - App activations, Window title checks, Clipboard copies, OCR scans, Shell hooks |
|  - Accessibility UI tree, Coordinate-to-element clicks, App stall monitoring      |
+------------------------------------+----------------------------------------------+
                                     |
                                     v (Appends event JSON)
+-----------------------------------------------------------------------------------+
|                                  TelemetryStorage                                 |
|  - Writes to daily partitioned file: telemetry_events_YYYY-MM-DD.jsonl            |
|  - Deletes files older than 7 days                                                |
+------------------------------------+----------------------------------------------+
                                     |
                          Is User Idle >= 10m?
                                     v
+-----------------------------------------------------------------------------------+
|                                 TelemetrySummarizer                               |
|  - Generates session summaries using Local GGUF via TextCleanupManager            |
|  - Deletes raw log chunks that have been summarized                               |
+------------------------------------+----------------------------------------------+
                                     |
                         Is Connected to AC Power?
                                     v
+-----------------------------------------------------------------------------------+
|                            Daily Report Generator                                 |
|  - Aggregates daily summaries                                                     |
|  - Correlates patterns -> proposals                                               |
|  - Writes Markdown to docs/telemetry/daily_report_YYYY-MM-DD.md                   |
+-----------------------------------------------------------------------------------+
```

---

## Implementation Units

### U1. Storage & Logging Infrastructure

**Goal:** Establish local file storage for raw telemetry events with daily partitioning and 7-day auto-rotation.

**Requirements:** R2, R4

**Dependencies:** None

**Files:**
- Create: `Casper/Telemetry/TelemetryStorage.swift`
- Create: `CasperTests/TelemetryTests/TelemetryStorageTests.swift`

**Approach:**
- Implement `TelemetryStorage` with functions to append a `DesktopUserEvent` as a JSON line to the current day's log file (`telemetry_events_YYYY-MM-DD.jsonl` under App Support).
- Implement a cleanup routine that scans files matching `telemetry_events_*.jsonl` and deletes any file with a date key older than 7 days.
- Ensure all file operations are fully isolated to the local disk and utilize safe atomic writing constraints.

**Patterns to follow:**
- `Casper/QA/DesktopAgentBridge.swift` for event codability.
- `Casper/Context/FrontmostWindowOCRService.swift` for disk write logging.

**Test scenarios:**
- Happy path: Appending multiple events write successfully as sequential JSON lines.
- Edge case: Write events spanning a midnight boundary, verifying it writes to the new partition.
- Happy path: Rotation removes files older than 7 days and leaves recent ones intact.

**Verification:**
- Run storage test suite; verify `telemetry_events_*.jsonl` files are correctly formatted and rotated in test workspaces.

---

### U2. Passive Workspace Collector

**Goal:** Capture app activations, window titles, clipboard text, clicked UI elements, and application stalls.

**Requirements:** R1, R3

**Dependencies:** U1

**Files:**
- Create: `Casper/Telemetry/TelemetryCollector.swift`
- Create: `CasperTests/TelemetryTests/TelemetryCollectorTests.swift`
- Modify: `Casper/Context/FrontmostWindowOCRService.swift`

**Approach:**
- Setup a background polling timer (2s interval) in `TelemetryCollector` monitoring:
  - App changes (`NSWorkspace.didActivateApplicationNotification`)
  - App responsiveness (`NSRunningApplication.isResponding` to detect app stalls)
  - Active window title (using AXUIElement of frontmost app)
  - Clipboard copy events (tracking `NSPasteboard.general.changeCount`)
  - Periodically (every 10m) trigger OCR captures via `FrontmostWindowOCRService` (active even on battery).
- Register a global click event monitor (`NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown])`):
  - Capture mouse coordinates, map them to UI elements using `AXUIElementCopyElementAtPosition`, and write `.mouseClicked` events with button labels.
- Maintain a local shell listener that monitors a dedicated command execution socket or temporary file generated by shell integrations.

**Patterns to follow:**
- `Casper/Meeting/MeetingDetector.swift` for workspace/window title queries.
- `Casper/Context/FocusedElementLocator.swift` for application observation.

**Test scenarios:**
- Happy path: App activation triggers `.appActivated` event.
- Happy path: Clipboard changes write `.textCopied` event.
- Happy path: Click on accessibility-compliant buttons registers element labels.
- Edge case: Unresponsive application triggers app stall event.

**Verification:**
- Verify collector accurately populates events to storage when switching apps, clicking UI items, and copying text.

---

### U3. System Activity & Power Monitoring Services

**Goal:** Implement helpers to check if the user is idle, track short-term hesitations, and verify AC power.

**Requirements:** R5, R9

**Dependencies:** None

**Files:**
- Create: `Casper/Telemetry/TelemetryPowerMonitor.swift`

**Approach:**
- Expose a property `isIdle` by calling `CGEventSource.secondsSinceLastEventType` and comparing it to the 10-minute threshold.
- Record user hesitation metrics when user activity ceases for more than 3 seconds immediately after a window or application focus change.
- Implement `isConnectedToACPower` in `TelemetryPowerMonitor` using `IOPSCopyPowerSourcesInfo` and `IOPSGetPowerSourceDescription` to query if charger is connected.

**Patterns to follow:**
- Native CoreGraphics and IOKit imports.

**Test scenarios:**
- Happy path: Returns true/false for AC power status.
- Happy path: Accurately reports idle status when no events occur for the threshold duration.
- Happy path: Identifies hesitation pauses and records them.

**Verification:**
- Manually run tests by plugging/unplugging the charger to verify correct status detection.

---

### U4. Local Session Summarizer Agent

**Goal:** Compile session batches during idle periods and summarize them via local LLM at low priority.

**Requirements:** R5, R10

**Dependencies:** U1, U3

**Files:**
- Create: `Casper/Telemetry/TelemetrySummarizer.swift`

**Approach:**
- Query storage for new raw events since last processed index.
- If user is idle >= 10m, aggregate these events as a single session batch.
- Dispatch a low QoS (.utility) task to query the local LLM via `TextCleanupManager` with a structured summarization prompt, compressing the events into a text paragraph.
- Save the session summary to disk and remove or mark the processed raw events.

**Patterns to follow:**
- `Casper/QA/LocalLLMProvider.swift` for prompt templates.

**Test scenarios:**
- Happy path: Summarization runs when user is idle, producing structured summaries.
- Edge case: Summarization task is deferred if user returns before idle timeout is reached.
- Edge case: Local model is not downloaded or ready; logs error and retries later.

**Verification:**
- Verify session summaries are written locally to the app support folder during simulated idle periods.

---

### U5. Daily Correlation and Report Writer

**Goal:** Consolidate session summaries daily and output Markdown reports to workspace `docs/telemetry/`.

**Requirements:** R6, R7, R8, R9

**Dependencies:** U3, U4

**Files:**
- Create: `Casper/Telemetry/TelemetryReportWriter.swift`

**Approach:**
- Check power status; if plugged into AC power, load the session summaries written in the past 24 hours.
- Construct a prompt asking the local LLM to correlate events, extract recurring shell command errors, copy patterns, and propose JIT automations.
- Write output to `docs/telemetry/daily_report_YYYY-MM-DD.md`.

**Patterns to follow:**
- `Casper/QA/DesktopAgentBridge.swift` for JSON parsing and recommendation models.

**Test scenarios:**
- Happy path: plugged into AC power, reads session summaries, generates report.
- Edge case: device on battery power; daily task is postponed.
- Edge case: No sessions recorded in past day; creates a brief empty-activity report.

**Verification:**
- Run simulated correlation run, checking formatting of output report in `docs/telemetry/`.

---

### U6. Integration & Wiring

**Goal:** Wire the telemetry collector and summarization subsystem into the app lifecycle.

**Requirements:** R1, R2

**Dependencies:** U2, U4, U5

**Files:**
- Modify: `Casper/AppState.swift`
- Modify: `Casper/CasperApp.swift`

**Approach:**
- Instantiate `TelemetryCollector` and `TelemetrySummarizer` in `AppState` initialization.
- Start monitoring when `AppState` transitions to `.ready`.
- Ensure all resources are properly disposed of or paused when the app terminates.

**Patterns to follow:**
- AppState lifecycle management.

**Test scenarios:**
- Happy path: Subsystems boot correctly on app launch.
- Happy path: App state transitions from background to foreground safely.

**Verification:**
- Confirm telemetry collector starts silently on app run.

---

## System-Wide Impact

- **Interaction graph**: `TelemetryCollector` runs continuously on background actors, capturing events. `TelemetrySummarizer` runs periodically on user-idle triggers.
- **Error propagation**: File I/O errors or LLM generation issues in background telemetry tasks must be logged silently to `DebugLogStore` and must never pop up UI errors or crash the app.
- **State lifecycle risks**: Low QoS configuration prevents CPU spikes from lag-locking the main UI thread.
- **Unchanged invariants**: Meeting detector and speech recording subsystems remain completely decoupled from passive telemetry.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| High disk write frequency wearing SSDs | Use memory buffering or low-frequency flushing for JSONL writes; limit polls. |
| CPU spikes from background LLM inference | Run summarization and correlation only when user is idle and priority set to `.background`. |
| Sandbox/Access permission blocks | Fallback gracefully if Screen Capture or Accessibility API permissions are disabled. |

---

## Sources & References

- **Origin document**: [docs/brainstorms/2026-06-24-local-telemetry-requirements.md](file:///Users/rooshi/Documents/programming/mac/casper/docs/brainstorms/2026-06-24-local-telemetry-requirements.md)
- Related code: [DesktopAgentBridge.swift](file:///Users/rooshi/Documents/programming/mac/casper/Casper/QA/DesktopAgentBridge.swift)
- LLM streaming manager: [TextCleanupManager.swift](file:///Users/rooshi/Documents/programming/mac/casper/Casper/Cleanup/TextCleanupManager.swift)
