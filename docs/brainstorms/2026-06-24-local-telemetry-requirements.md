---
date: 2026-06-24
topic: local-telemetry-interaction-framework
---

# Local Telemetry & Passive Interaction Framework

## Summary

Proposing a local telemetry and offline summarization framework that passively captures macOS workspace events and aggregates them into daily Markdown reports detailing user friction points and potential custom automations.

---

## Problem Frame

Users perform repetitive daily tasks and encounter recurrent terminal errors or clipboard copy-paste sequences on macOS without realizing where time is lost. Building hardcoded rule-based automations is brittle and misses complex, non-obvious workflows that could otherwise be automated.

---

## Actors

- A1. macOS User: The developer or power user interacting with macOS applications, terminal windows, and the clipboard.
- A2. Telemetry Collector: The passive system service in Casper that monitors and records workspace events.
- A3. LLM Analyzer: The offline processing agent that runs local model inference to detect patterns and generate reports.

---

## Key Flows

- F1. Event Capture & Logging
  - **Trigger:** A1 performs an action (e.g., switches apps, copies text, runs a CLI command, or triggers OCR).
  - **Actors:** A1, A2
  - **Steps:**
    1. A1 triggers a workspace event.
    2. A2 captures the event parameters locally.
    3. A2 appends the event details to the local raw event log.
  - **Outcome:** The event is durably recorded on disk.
  - **Covered by:** R1, R2, R4

- F2. Batch Summarization
  - **Trigger:** User idle trigger (no active user activity detected for a specified period, e.g., 10 minutes).
  - **Actors:** A2, A3
  - **Steps:**
    1. A2 detects user inactivity exceeding the threshold.
    2. A2 compiles the raw events recorded during the active session.
    3. A3 feeds the compiled batch to the local LLM with a summarization template.
    4. A3 saves the concise batch summary and deletes the processed raw log chunk.
  - **Outcome:** A high-level text summary of the completed active session is generated during idle time.
  - **Covered by:** R5

- F3. Daily Correlation & Report Generation
  - **Trigger:** Daily cron schedule, executing only when connected to AC power.
  - **Actors:** A2, A3
  - **Steps:**
    1. A2 checks system power status to verify the device is plugged in.
    2. A3 reads the compiled session/batch summaries for the past day.
    3. A3 runs local inference to correlate actions across the day, identifying novel repetitions.
    4. A3 writes a Markdown report recommending JIT automations.
  - **Outcome:** A daily friction report is written to `docs/telemetry/`.
  - **Covered by:** R6, R7, R8, R9, R10

---

## Requirements

**Event Collection**
- R1. The system must passively capture [DesktopUserEvent](file:///Users/rooshi/Documents/programming/mac/casper/Casper/QA/DesktopAgentBridge.swift#L4)s including application activations, window title changes, clipboard copies, command line executions, and OCR text snapshots.
- R2. All captured telemetry events must be stored locally on-device and must never be transmitted over the network.
- R3. Background OCR captures must remain active even when the macOS device is running on battery power.
- R4. Event logs must be rotated or truncated after 7 days to prevent unbounded local disk consumption.

**Summarization & Analysis**
- R5. Raw telemetry events must be compiled into discrete sessions and processed in isolated batches triggered only when the user is idle (e.g., no active activity for 10 minutes) to minimize active background CPU consumption.
- R6. Once daily, the system must analyze the compiled session/batch summaries to identify daily repetitions and correlate actions over time.
- R7. The daily analysis must actively discover novel potential actions and patterns over time, rather than relying exclusively on a predefined, static set of rules and actions.
- R8. The analysis must produce a Markdown report saved to `docs/telemetry/` containing time distributions, failed terminal commands, copy patterns, and proposed shell/agent automations.

**Power & Resource Management**
- R9. The heavy daily consolidation analysis job must only execute when the macOS device is connected to AC power.
- R10. Batch processing of raw logs must run at low system priority to prevent active user tasks from experiencing CPU lag or UI stutter.

---

## Acceptance Examples

- AE1. **Covers R3, R9.** Given the Mac is running on battery, when clipboard copy events or OCR capture triggers occur, they are recorded to the raw log, but the daily consolidation analysis is postponed until the charger is connected.
- AE2. **Covers R5, R6, R7.** Given the raw telemetry log contains 500 events over a 24-hour period split into multiple active sessions, when the daily analysis runs, it reads the idle-time batch summaries rather than re-ingesting all raw events directly, producing a single consolidated report identifying that the user repeatedly ran a git branch command.

---

## Success Criteria

- Telemetry logs are successfully compressed into daily Markdown reports that accurately identify at least one recurring friction point or manual task sequence.
- Downstream planners can ingest the generated suggestions programmatically to execute the proposed automations.

---

## Scope Boundaries

### Deferred for later

- A flexible action execution engine capable of running the proposed shell scripts, creating notes, or pasting text contextually.
- Active real-time JIT overlays, notifications, and hotkeys.
- Passive email monitoring (Gmail triage) and browser video/YouTube PiP extension triggers.

### Outside this product's identity

- Remote analytics reporting, cloud sync databases, or cross-device telemetry backup (must remain strictly local).

---

## Key Decisions

- **Multi-stage Summarization:** Batching raw events and summarizing summaries at the daily level solves the context window and compute limitations of small local models (Qwen 0.8B/2B) running on-device.
- **Local Telemetry Privacy:** Storing all raw logs locally and performing on-device LLM analysis aligns with Casper's 100% offline commitment.

---

## Dependencies / Assumptions

- Assumes the local LLM.swift provider is configured and capable of running standard chat completions efficiently under GGUF formats.
- Assumes macOS power status APIs (`IOPowerSources`) are accessible to verify AC power connection.

---

## Outstanding Questions

### Resolve Before Planning

- None.

### Deferred to Planning

- [Affects R4][Technical] What is the most efficient local file format for appending hundreds of passive events daily without high disk write overhead?
