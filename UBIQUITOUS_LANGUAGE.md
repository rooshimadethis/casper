# Ubiquitous Language

## Workspace Events

| Term | Definition | Aliases to avoid |
| ---- | ---------- | ---------------- |
| **Workspace Event** | A discrete user action or system occurrence on macOS captured by the passive monitor | User action, telemetry event, log entry |
| **DesktopUserEvent** | The discriminated union of all workspace event types: app activation, window title change, text copy, OCR capture, command execution, mouse click, app stall, hesitation, typing session | Raw event |
| **App Activation** | A workspace event fired when the user switches focus to a different application | App switch, focus change |
| **Text Copy** | A workspace event capturing text written to the system pasteboard | Clipboard event, copy action |
| **OCR Capture** | A workspace event recording text recognized from the frontmost window's screenshot | Screen read, snapshot text |
| **Command Execution** | A workspace event recording a shell command, its exit code, and optional output | Terminal event, CLI action |
| **App Stall** | A workspace event fired when the frontmost app becomes unresponsive for a detectable duration | Hang, freeze event |
| **User Hesitation** | A workspace event fired when the user pauses in an app without switching focus or typing for several seconds | Pause, idle moment |

## Telemetry Pipeline

| Term | Definition | Aliases to avoid |
| ---- | ---------- | ---------------- |
| **Telemetry Collector** | The passive service that monitors macOS events and writes them as event records to disk | Monitor, tracker, recorder |
| **Telemetry Storage** | The on-disk JSONL event log and session summary store, partitioned by date | Log store, event database |
| **Event Record** | A timestamped serialization of a DesktopUserEvent written to the daily JSONL log | Log line, raw entry |
| **Telemetry Session** | A contiguous block of workspace events bounded by a 10-minute inactivity gap | Active session, work period |
| **Session Summary** | A concise LLM-generated description of a single telemetry session's contents, written during idle time | Batch summary, idle summary |
| **Telemetry Summarizer** | The offline processor that groups raw event records into sessions, triggers local LLM summarization on idle, and persists session summaries | Batch processor, session builder |
| **Daily Report** | A consolidated Markdown document that correlates all session summaries from a single day, identifies recurring patterns, and proposes automations | Day summary, daily analysis |
| **Idle Trigger** | A 10-minute inactivity gap that signals the summarizer to finalise the current session and process it | Inactivity threshold, flush gate |

## Typing & Keyboard

| Term | Definition | Aliases to avoid |
| ---- | ---------- | ---------------- |
| **Typing Token** | A structured representation of a single keyboard action: character, special key, or grouped backspace | Key event, keystroke token |
| **Typing Session** | A contiguous sequence of typing tokens accumulated while the user edits within a single focus context | Input burst, text entry |
| **Shortcut Isolation** | The practice of flushing accumulated typing and recording a keyboard shortcut (Cmd+key) as its own standalone session to prevent modifier keys from corrupting typed text | Modifier separation, shortcut split |
| **Flush** | The act of serialising the active typing session into a DesktopUserEvent and resetting the token buffer | Commit, finalise, release |
| **Backspace Grouping** | The compression of consecutive backspace presses that delete pre-existing text into a single token (e.g. `<Backspace x 5>`) | Backspace coalescing, delete merge |

## Architecture & App Identity

| Term | Definition | Aliases to avoid |
| ---- | ---------- | ---------------- |
| **Desktop Agent Bridge** | The coordinator that receives workspace events, maintains a live workspace context, and queries the local LLM for just-in-time recommendations | Agent bridge, JIT engine |
| **Workspace Context** | The real-time accumulated state of the user's desktop: active app, window title, last copied text, last OCR text, last command | Desktop state, live context |
| **JIT Recommendation** | An action suggested by the local LLM (paste text, run terminal command, create notes, show overlay) that can be executed at the moment it is relevant | Suggestion, action proposal |
| **Local LLM** | An on-device GGUF model (Qwen 0.8B–7B) running via LLM.swift that performs all inference with no network calls | On-device model, local model |
| **Sanitizer** | A privacy filter that transforms sensitive strings within a DesktopUserEvent before persistence | Anonymizer, scrubber |
| **Dogfood Install** | A local build-install-launch workflow that preserves TCC permissions across reinstalls using `scripts/dogfood-install.sh` | Local deploy, dev install |
| **Quiet Install** | A dogfood install variant that suppresses the first-run onboarding window using the `--quiet-install` flag | Silent launch, headless install |

## Relationships

- A **Telemetry Session** contains zero or more **Workspace Events**, and belongs to exactly one calendar day
- A **Workspace Event** is serialised as an **Event Record** by the **Telemetry Storage**
- A **Telemetry Session** produces exactly one **Session Summary**
- A calendar day produces exactly one **Daily Report**, which ingests all **Session Summaries** from that day
- The **Desktop Agent Bridge** maintains a single **Workspace Context** that is updated by each **Workspace Event**
- A **JIT Recommendation** is emitted zero or more times per **Workspace Event**, if evaluation heuristics fire
- A **Typing Session** is a subtype of **Workspace Event** produced by **Flush** when the user switches context or pauses
- An **OCR Capture** is taken from the **Frontmost Window** (not the full screen)

## Example dialogue

> **Dev:** "When I switch apps, does the **Telemetry Collector** fire an **App Activation** event immediately?"

> **Domain expert:** "Yes — every focus change logs an **App Activation** and flushes any active **Typing Session** so typed text is never orphaned."

> **Dev:** "And if I type `git push`, get an error, wait 11 minutes, then fix it — that's two **Telemetry Sessions**?"

> **Domain expert:** "Exactly. The 10-minute **Idle Trigger** splits them. The first **Session Summary** would describe a failed git push attempt; the second would show the fix."

> **Dev:** "What if I copy a URL from an **OCR Capture** of my browser and paste it into Terminal? Does that generate a **JIT Recommendation**?"

> **Domain expert:** "If the pasted command fails, yes — the **Desktop Agent Bridge** evaluates every **Command Execution** with a non-zero exit code and may suggest a corrected shell command."

> **Dev:** "And all of this stays local? The **Daily Report** never leaves the machine?"

> **Domain expert:** "Correct. The **Local LLM** runs entirely on-device. No **Event Record**, **Session Summary**, or **Daily Report** is ever transmitted over a network."

## Flagged ambiguities

- **"Session"** was used to mean both a **Telemetry Session** (inactivity-bounded event group) and a **Typing Session** (contiguous keyboard input) — these are distinct: the former is a time-bounded log partition, the latter is a user input burst that maps to a single workspace event case. Recommendation: use **Telemetry Session** and **Typing Session** unambiguously.
- **"Summary"** applied to both the **Session Summary** (per-session LLM output) and the **Daily Report** (cross-session correlation) — these differ in scope and processing stage. Recommendation: reserve **Summary** for the per-session product and **Report** for the daily product.
- **"Flush"** was used both for serialising a **Typing Session** and for internal buffer resets — this is acceptable since both describe the same semantics (finalise and reset).
- **"Capture"** was used in "OCR Capture" (taking a screenshot and reading text) and general "event capture" (recording workspace events) — these are distinct in mechanism even though both are passive. Recommendation: prefer **OCR Capture** for screen text recognition and **Event Record** for the persistence layer.
- **"Agent"** appears in **Desktop Agent Bridge** (the event→recommendation coordinator), **JIT Recommendation** (the output), and **LLM Analyzer** (the brainstorm's abstract actor) — careful to distinguish the bridge's role from the model's role. The bridge orchestrates; the model infers.
