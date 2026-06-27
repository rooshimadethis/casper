---
date: 2026-06-25
topic: power-usage-metrics
focus: Component-level energy attribution for the Casper app — identify which subsystem uses the most power
mode: repo-grounded
---

# Ideation: Power Usage Metrics for Casper

## Grounding Context

Casper is a macOS 14.0+ Swift/SwiftUI menu bar app for voice dictation, meeting transcription, and desktop automation. It runs continuously in the background. The user reports heat while running and wants to attribute energy usage to specific components.

### Existing Power Infrastructure
- **`TelemetryPowerMonitor`** — Protocol with `isUserIdle(threshold:)` and `isConnectedToACPower` only. Does NOT measure energy. Injected into all power-aware consumers.
- **PerformanceTrace** — Per-dictation-session in-memory timing, not persisted.
- **DebugLogStore** — Has `DebugLogCategory.performance` enum case, currently underused.

### Active Components

| Component | Tech | Pattern |
|---|---|---|
| Audio/Transcription | AVAudioEngine + WhisperKit (Metal) | On-demand burst |
| LLM Cleanup | LLM.swift / llama.cpp (Metal) | On-demand burst |
| LLM Prediction | LLM.swift | Idle-gated periodic |
| Screen OCR | ScreenCaptureKit + Vision | On-demand burst |
| Telemetry Collector | Timer 2s + event monitors | Continuous polling |
| Meeting Detector | Timer 5s | Continuous polling |
| Telemetry Summarizer | Timer 300s | Idle-gated periodic |
| Report Writer | Timer 3600s | AC-gated periodic |

### Available macOS APIs (from external research)
- `proc_pid_rusage(RUSAGE_INFO_CURRENT)` — `ri_billed_energy`, no sudo, Intel+AS
- IOReport Energy Model — Per-SoC subsystem, private API, Apple Silicon only
- IORegistry GPU counters — `AGXDeviceUserClient` accumulated GPU time
- `PROC_PIDTHREADCOUNTS` — Per-thread P/E core energy
- SMC — Total system power (watts)
- `ProcessInfo.thermalState` — Foundation API

## Topic Axes
1. **Data sources & APIs** — Which macOS APIs to tap
2. **Component attribution** — Separating energy by component
3. **Collection architecture** — Sampling, overhead, persistence, lifecycle
4. **Surface & feedback** — Display to user, alerts
5. **Energy-aware optimization** — Using metrics to throttle/improve

## Ranked Ideas

### 1. Per-Session Energy Trace via `proc_pid_rusage`
**Description:** Sample `ri_billed_energy` at session boundaries to produce per-session energy alongside existing PerformanceTrace timing. No sudo, no private API, works on Intel and Apple Silicon.
**Axis:** Data sources & APIs
**Basis:** `external:` macOS `proc_pid_rusage(RUSAGE_INFO_CURRENT)` — confirmed in external research as the same data Activity Monitor uses for Energy Impact.
**Rationale:** Closes the "zero energy data collected" gap with minimal effort. Everything downstream depends on this.
**Downsides:** Per-process only, not per-component. Needs companion sampling strategy.
**Confidence:** 95%
**Complexity:** Low
**Status:** Unexplored

### 2. Phase-Based Component Energy Attribution
**Description:** Wrap each major async operation (whisper decode, llama.cpp eval, Vision OCR, poll workspaces) with before/after `proc_pid_rusage` diffs to produce per-component energy deltas. Uses IOReport's begin/end window pattern for Apple Silicon.
**Axis:** Component attribution
**Basis:** `direct:` Major components have well-defined async boundaries. `reasoned:` IOReport begin/end window pattern (zeus-apple-silicon, ml.energy) is proven. Per-thread P/E core energy via `PROC_PIDTHREADCOUNTS` (PowerMetricsKit) enables Apple Silicon breakdown.
**Rationale:** Directly answers "which component uses the most energy" — the user's stated question.
**Downsides:** Overlapping async operations cause attribution ambiguity. Requires careful interlock for concurrent work.
**Confidence:** 85%
**Complexity:** Medium
**Status:** Explored

### 3. Thermal-State Governor with Adaptive Scheduling
**Description:** Register for `ProcessInfo.thermalState` notifications. At `.fair`, clamp GPU work. At `.serious`, defer non-critical background tasks. At `.critical`, disable all non-foreground work. Expose throttle level in menu bar.
**Axis:** Energy-aware optimization
**Basis:** `direct:` "No thermal-state backpressure anywhere" gap. `ProcessInfo.thermalState` with change notifications is documented Foundation API on macOS 14+.
**Rationale:** Breaks the "heat → Casper runs → more heat" positive feedback loop. Addresses user's stated pain point.
**Downsides:** Needs tuning. At `.critical`, may conflict with "always available" expectation for transcription.
**Confidence:** 90%
**Complexity:** Medium
**Status:** Unexplored

### 4. Menu Bar Energy Gauge / Vital Signs Display
**Description:** Live per-component energy gauge in the menu bar (color-coded green/yellow/red). On hover, per-component breakdown for last 60s. Update every 10-15s from ring buffer.
**Axis:** Surface & feedback
**Basis:** `direct:` User wants visibility into component energy. App lives entirely in menu bar. External research confirms silimon and other apps successfully use IOReport-derived data in menu bar.
**Rationale:** Makes energy a visible first-class signal. Without this, data is collected but invisible.
**Downsides:** Menu bar real estate is limited. Depends on data from #1 and #2. Private API for per-component sparkline.
**Confidence:** 80%
**Complexity:** Medium
**Status:** Unexplored

### 5. Foundation Energy Dictionary in Telemetry Pipeline
**Description:** Extend `TelemetryPowerMonitoring` protocol with `currentEnergyMetrics()`. Stamp every telemetry event with power context (billed energy, thermal state, on-AC). Leverages existing injection seam — no new DI wiring.
**Axis:** Collection architecture
**Basis:** `direct:` `TelemetryPowerMonitoring` protocol already injected into all power-aware consumers. Adding energy queries is the natural seam.
**Rationale:** Makes energy a first-class pipeline field alongside timestamps and event types. Downstream analysis becomes trivial.
**Downsides:** Schema migration on existing JSONL events. Storage bloat from per-event snapshots.
**Confidence:** 85%
**Complexity:** Medium
**Status:** Unexplored

### 6. Consumption-Aware Model Routing
**Description:** Route LLM tasks to the smallest viable model (0.8B→7B) using power-per-token cost. Classification tasks → 0.8B, factual extraction → 2B, reasoning → 4B/7B. Router learns from rejection feedback.
**Axis:** Energy-aware optimization
**Basis:** `direct:` Casper maintains 4 models (0.8B–7B, Q4_K_M). Different invocation contexts need different capability. `reasoned:` Classifier-based model routing is established infra for reducing inference cost.
**Rationale:** Compounding savings — small model handling 70% of calls saves 3-5x energy per call on those. Self-improving.
**Downsides:** Requires task-type classification. Quality regression risk on misrouted tasks. Non-trivial tuning.
**Confidence:** 75%
**Complexity:** Medium
**Status:** Unexplored

### 7. Idle Quality Metric
**Description:** Replace binary idle with continuous score from CPU quiescence, display sleep, audio peripheral state, and HID idle time. Enables fewer-but-better execution windows.
**Axis:** Collection architecture
**Basis:** `direct:` `systemIdleTime` already computed but only used for binary threshold. `reasoned:` Continuous idle score improves scheduling decisions without new infrastructure.
**Rationale:** The current 10-minute idle gate conflates "user walked away" with "user reading a PDF." Better signal = better scheduling.
**Downsides:** Adds CPU overhead (low). Binary gate works well enough for most cases.
**Confidence:** 80%
**Complexity:** Low
**Status:** Unexplored

## Rejection Summary

| # | Idea | Reason Rejected |
|---|---|---|
| 1 | Federated Power Baseline Network | Violates privacy-first constraint — app is 100% local |
| 2 | Double-Entry Bookkeeping Power Audit | Overly complex for the value — 10x implementation for 2x benefit |
| 3 | Carbon Intensity Gating | External API dependency + geolocation — scope overrun |
| 4 | Peripheral Power Map (Thunderbolt/USB-C) | Scope overrun — extends to entire desk ecosystem, not Casper |
| 5 | Direct SMC Register Tapping | Too risky — private API, per-generation channel name changes |
| 6 | Remove AC-Power Report Gate | Weakens existing power-aware scheduling |
| 7 | Black Box Flight Recorder | Overlaps with Event-Triggered Snapshots (merged into #1) |
| 8 | Predictive Power Budgeting (battery drain) | Duplicates Battery Budget Scheduler (weaker variant) |
| 9 | Auto-Correlate Battery Drops | Unreliable signal — battery drops have too many confounders |
