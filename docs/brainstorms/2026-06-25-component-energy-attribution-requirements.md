---
date: 2026-06-25
topic: component-energy-attribution
---

# Phase-Based Component Energy Attribution

## Summary

Add per-component energy measurement to Casper using `proc_pid_rusage` energy deltas at async operation boundaries, bridged with IOReport begin/end windows for Apple Silicon SoC-level breakdown. Energy data is written to a dedicated JSONL log alongside component, duration, and thermal context. The system instruments all major components (transcription, LLM inference, OCR, telemetry polling, meeting detection, prediction training) and samples a periodic heartbeat to capture unaccounted background draw.

---

## Problem Frame

Casper runs continuously in the menu bar on laptops, performing local ML inference (WhisperKit, llama.cpp via Metal), screen OCR, and periodic telemetry collection. Users report perceptible heat during use, but the app has no instrumentation to answer the basic question: **which component is responsible?** The only existing power-aware infrastructure (`TelemetryPowerMonitor`) checks AC connection and user idle state — it measures power *source*, not energy *consumption*.

Without component-level energy data, optimization efforts are guesses. The 2-second telemetry poller could be the dominant cost; a single WhisperKit decode could spike GPU to 40W; the LLM cleanup model's idle-gated training could be thrashing the GPU hourly. No current data distinguishes these. The user should be able to look at a log and know which subsystem drew what, on battery vs AC, and under what thermal conditions.

---

## Key Flows

**F1. Event-triggered energy measurement**
- **Trigger:** A known async operation begins (e.g., `llama_decode()`, WhisperKit encode, Vision OCR capture, `pollWorkspaceState()`)
- **Actors:** Casper runtime, EnergyLogger
- **Steps:**
  1. Before the operation starts, snapshot `proc_pid_rusage(RUSAGE_INFO_CURRENT)` for billed energy, instructions, cycles
  2. (Apple Silicon) Open an IOReport begin window tagged with the component name
  3. Run the operation normally
  4. After the operation completes, snapshot `proc_pid_rusage` again and close the IOReport window
  5. Compute deltas for energy, instructions, cycles, and duration
  6. Write a JSONL record with component ID, deltas, thermal state, AC/battery status, and wall-clock timestamp
- **Outcome:** Each operation produces an attributable energy record
- **Covered by:** R1, R2, R3, R4, R5

**F2. Periodic heartbeat sampling**
- **Trigger:** A background timer fires every 10-30 seconds
- **Actors:** EnergyLogger
- **Steps:**
  1. Snapshot `proc_pid_rusage` for billed energy, instructions, cycles
  2. Read `ProcessInfo.thermalState` and `isConnectedToACPower`
  3. Compute delta since last heartbeat
  4. Write a heartbeat JSONL record tagged with component `heartbeat`
- **Outcome:** Captures any energy draw not attributed to a specific component (e.g., SwiftUI rendering, framework overhead)
- **Covered by:** R6

**F3. IOReport energy breakdown (Apple Silicon only)**
- **Trigger:** A GPU-heavy operation begins (transcription, LLM inference, OCR)
- **Actors:** Casper runtime, IOReport bridge, EnergyLogger
- **Steps:**
  1. Before the operation, open IOReport subscription to "Energy Model" group channels
  2. After the operation, close subscription and read per-channel values
  3. Parse channels into per-SoC components: GPU mJ, CPU E-core mJ, CPU P-core mJ, ANE mJ, DRAM mJ
  4. Include SoC breakdown in the JSONL record alongside proc_pid_rusage data
- **Outcome:** Apples-to-apples comparison of GPU vs CPU vs ANE cost per operation type
- **Covered by:** R2, R7

---

## Requirements

**Energy sampling infrastructure**

- R1. The system must measure per-process energy deltas at component operation boundaries using `proc_pid_rusage(RUSAGE_INFO_CURRENT)`, reading `ri_billed_energy`, `ri_instruction_data`, `ri_cycles`, `ri_interrupt_wkups`, and `ri_diskio_bytesread`/`ri_diskio_byteswritten`.

- R2. Apple Silicon IOReport energy breakdown must be captured alongside `proc_pid_rusage` for GPU-heavy operations. The IOReport bridge must subscribe to the "Energy Model" group and parse per-channel values (per-core E/P, GPU, DRAM, ANE). Must degrade gracefully when IOReport channels are unavailable (Intel Mac, future macOS without matching channel names).

- R3. Energy sampling must add negligible overhead — counter reads only, no disk I/O during the hot path. JSONL writes must happen off the measurement thread with a small write buffer (batch every ~30s or 50 records, whichever comes first).

- R4. The energy log must be a separate JSONL file stored alongside existing telemetry data at `~/Library/Application Support/Casper/telemetry/energy/`. Each record must include: timestamp, component ID, operation duration, `proc_pid_rusage` deltas, IOReport breakdown (when available), thermal state, AC/battery status, and wall-clock time.

**Instrumented components**

- R5. The following components must be instrumented with per-operation energy measurement:

  - **Transcription pipeline** — WhisperKit decode (per chunk)
  - **LLM cleanup inference** — `llama_decode()` call
  - **LLM prediction training** — training iteration
  - **Screen OCR** — `FrontmostWindowOCRService.captureContext()` call
  - **Telemetry collector** — `pollWorkspaceState()` tick (aggregated per poll cycle)
  - **Meeting detector** — `MeetingDetector` poll tick
  - **Telemetry summarizer** — session summarization LLM call
  - **Report writer** — daily report generation LLM call

- R6. A periodic heartbeat sample (every 10-30 seconds) must capture any energy not attributed to a specific component. The heartbeat records total process energy delta since the last heartbeat and lists which components were active during the window.

**Integration**

- R7. The IOReport bridge must be a minimal C/ObjC wrapper (dlsym-loaded or compiled into a small helper file) that handles channel discovery, subscription lifecycle, and per-generation channel name mapping. Must not prevent app launch on Intel Macs or on Apple Silicon versions where channel names have drifted.

- R8. The energy logger must respect device constraints — skip IOReport subscriptions on battery when thermal state is `.serious` or `.critical`. The `proc_pid_rusage` path should still run.

---

## Acceptance Examples

- AE1. **Covers R1, R5.** Given a dictation session, after the user releases the hotkey, the energy log contains a record for the WhisperKit decode with `ri_billed_energy` delta > 0, operation duration in ms, and thermal state.

- AE2. **Covers R2, R7.** Given an Apple Silicon Mac, after an LLM cleanup inference, the energy record includes an `ioreport` field with GPU mJ and CPU mJ values. On an Intel Mac, the `ioreport` field is absent but the `proc_pid_rusage` fields are present.

- AE3. **Covers R3, R8.** During a 20-minute idle period with no user activity, the heartbeat log shows total process energy draw < baseline. Zero IOReport subscriptions are open during idle (subscription is per-operation, not continuous).

- AE4. **Covers R5.** The telemetry collector's 2-second `pollWorkspaceState()` calls are aggregated: after 60 seconds, the log shows ~30 poll records with accumulated energy, confirming the poller's per-tick cost is measurable.

---

## Success Criteria

- A developer can open the energy log after an hour of mixed use and identify which component consumed the most energy by summing per-component deltas.
- The measurement overhead is below 1% total CPU, verified by running with and without energy logging for 10 minutes.
- Per-component attribution works on both Apple Silicon (with IOReport breakdown) and Intel Macs (proc_pid_rusage only) without crashes or degraded behavior.

---

## Scope Boundaries

- Process-splitting refactor — deferred. Measurement stays in-process; process boundaries may be evaluated based on collected data.
- Energy UI in the menu bar or settings panel — deferred. First iteration is log-only.
- Schema changes to existing `TelemetryEventRecord` — excluded. Energy uses a separate log.
- Carbon-aware scheduling, peripheral power monitoring, and battery health trending — excluded. Out of scope for this work.
- Automated alerting or anomaly detection from energy data — deferred. The log exists for manual analysis.

---

## Key Decisions

- **Mixed API approach (proc_pid_rusage + IOReport):** `proc_pid_rusage` provides cross-platform baseline; IOReport provides SoC breakdown on Apple Silicon. Running both gives richer data while keeping Intel support.
- **Separate energy log:** Avoids schema migration on existing JSONL telemetry events. Energy data has different granularity (sub-second vs event-level) and structure.
- **Event-triggered + heartbeat:** Component boundaries capture attributable work; heartbeat captures residual background draw. Together they account for all process energy.
- **Per-operation IOReport subscription:** Open and close the IOReport window per operation rather than maintaining a continuous subscription. Avoids accumulation drift and keeps measurement scoped.

---

## Dependencies / Assumptions

- `proc_pid_rusage` with `RUSAGE_INFO_CURRENT` provides `ri_billed_energy` on macOS 14.0+ (Casper's deployment target). Assumed stable across minor OS updates.
- IOReport private framework (`libIOReport.dylib`) is available on Apple Silicon Macs running macOS 14+. Channel names may change per M-series generation; the bridge must handle missing channels gracefully.
- `ProcessInfo.thermalState` is available on macOS 14.0+ and fires change notifications.
- GPU-heavy operations (WhisperKit, llama.cpp) have identifiable function boundaries that can be wrapped without modifying the upstream libraries.
- Overlapping async operations (e.g., transcription while OCR fires) can be handled via a simple mutex/lock on the measurement path — only one energy measurement open at a time, or both are recorded with overlapping timestamps and post-hoc heuristics attribute ambiguity.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R2][Needs research] IOReport channel name mapping per M-series generation — the bridge must support M1 through M5+ channel variations. Exact channel name tables to be resolved during implementation.
- [Affects R5][Technical] Exact wrapping strategy for WhisperKit and LLM.swift function boundaries — may need to add measurement hooks at the call site rather than wrapping library internals.
- [Affects R3][Technical] JSONL write buffer implementation details — in-memory ring buffer vs file handle write coalescing, to be decided during planning based on measured I/O overhead.
