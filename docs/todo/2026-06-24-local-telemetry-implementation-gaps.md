# Local Telemetry Implementation Gaps

Date: 2026-06-24
Related plan: `docs/plans/2026-06-24-001-feat-local-telemetry-plan.md`

## Open items

1. Implement end-to-end command execution capture
   The collector exposes `logCommandExecuted(...)`, but there is no shell integration hook, file/socket listener, or fallback history monitor wired into the app yet.

2. Finish session-aware summarization
   Raw daily logs were originally summarized as a single batch per file. This is now being fixed by adding timestamped event records, per-session batching, and persistent processed-line tracking.

3. Make periodic OCR capture reliable
   Current OCR capture depends on a narrow 5-second time window after focus age passes 10 minutes. It needs a durable schedule/guard so normal app switching does not suppress captures or cause duplicate triggers.

4. Expand verification coverage
   Missing tests still include idle deferral, AC-only report gating, clipboard capture, click capture, stall capture, hesitation capture, OCR capture, and report generation into `docs/telemetry/`.
