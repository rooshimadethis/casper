# Agentic Meeting Q&A — Design

**Status:** Draft for review
**Author:** Claude Code (Opus 4.7) brainstorming session, 2026-04-28
**Companion spec:** `2026-04-28-cross-meeting-qa-claude-api-design.md` (predecessor — single-shot cram-mode Claude API)

## Problem

The current cross-meeting Q&A flow (committed in `1a39495` and refined in the in-progress branch) scores meeting files by keyword overlap, picks the top 5, and crams up to 30 KB of raw markdown into a single Claude API call. It works for keyword-heavy questions ("meetings about Trello") but breaks down on the workload that actually motivates this feature:

- **Multi-hop questions** ("do Quinn and Sam Rivers know each other") need to follow a chain through several files, not score-and-cram one batch.
- **Voice-to-text artifacts** ("He's not a Quinn Adler for 10 years" → "He's known Quinn for 10 years") need the model to reason past noise — this works when it sees enough surrounding context, not when the right line was edged out by the score-truncation.
- **Citations** ("around line 184 of 2026-01-07/team-standup.md") require the model to know exact line numbers, which the cram approach never feeds it.

In an exploratory Claude Code session, the agentic-loop pattern (grep → read → reason → cite) cleanly answered all three of those query archetypes. That's the workload to optimize for.

## Goal

Replace the keyword-scoring + context-cram core of cross-meeting Q&A with a **bounded agentic tool-use loop** over the local meeting archive, while:

- Keeping the existing Q&A bar UI surface in `MeetingTranscriptWindow.swift` — only its internals change.
- Using Anthropic Messages API as the only shipped provider, behind a thin protocol that admits future Ollama / OpenAI / Google providers.
- Keeping prompt caching, streaming, and cost display from the current Claude API integration.
- Surfacing tool calls in an expandable trace so wrong answers can be debugged.

## Decisions made up front (don't relitigate)

These were explicit user decisions in the brainstorming session and the source handoff prompt. Listed here so the implementation plan doesn't re-debate them:

1. **Replace, don't coexist.** The agentic loop is the *only* cross-meeting Q&A path. The keyword-scoring + cram code is removed.
2. **Drop the local backend.** `QABackendKind.local` is removed. Cross-meeting Q&A is cloud-only at ship. Local providers (Ollama, llama.cpp) are a future extension via the same `LLMProvider` protocol.
3. **Anthropic SDK pattern, not vendored SDK.** Direct Messages API calls (`URLSession`), same as the existing `ClaudeAPIClient.swift`. No npm-style "Vercel AI SDK" — that's Node-only.
4. **No RAG, no embeddings.** Exact-match grep is more accurate than semantic search for the name/date/exact-quote workload.
5. **No MCP servers shipped initially.** But the protocol shape leaves room for them as a fourth tool-source later.
6. **Folder root = existing meetings save dir.** Reuse `MeetingTranscriptSettings.effectiveSaveDirectory()` as the agent's archive root. No separate Q&A-folder config.
7. **Iteration cap = 15.** Enough headroom for multi-hop questions; small enough to bound cost and runaway loops.
8. **Tool execution UX = collapsed status line + expandable trace.** One status line above the answer ("Reading 2025-01-29/dana-matt.md..."), with a disclosure triangle for the full event log.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  MeetingTranscriptWindow.swift  (Q&A bar, existing surface)      │
│   - text field "Ask across all meetings..."                      │
│   - streaming answer area                                         │
│   - NEW: status line + expandable trace                          │
└─────────────────────────────────────────────────────────────────┘
                          │ submit
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  MeetingQAAgent  (new — owns the loop)                          │
│   func ask(question) -> AsyncThrowingStream<QAEvent>            │
│                                                                  │
│   while iteration < cap (15):                                    │
│     for try await ev in provider.complete(messages, tools):     │
│       case .text:    forward to UI                               │
│       case .toolUse: emit .toolCall, execute, append result      │
│       case .stop:    if endTurn, return                          │
└─────────────────────────────────────────────────────────────────┘
              │                            │
              ▼                            ▼
┌──────────────────────────┐   ┌─────────────────────────────────┐
│ LLMProvider (protocol)   │   │ MeetingQATools (new)            │
│  func complete(messages, │   │   grep / readFile / listDir     │
│    tools, system)        │   │   PathSandbox (no escape, no    │
│   -> stream events       │   │     writes)                      │
│                          │   └─────────────────────────────────┘
│  AnthropicProvider       │
│   - SSE parsing           │
│   - tool_use accumulation │
│   - prompt caching        │
└──────────────────────────┘
              │
              ▼
        Anthropic API
```

### Data flow for one question

1. UI calls `MeetingQAAgent.ask(question)`. Agent returns an `AsyncThrowingStream<QAEvent>`.
2. Agent constructs initial messages list: `[{role: user, content: question}]`. System prompt + tool definitions are passed alongside.
3. Agent calls `provider.complete(messages, tools, system)` and forwards `.text` events straight to UI as they stream.
4. When provider yields a complete `tool_use` block, agent:
   - Emits `.toolCall(name, inputSummary)` to UI.
   - Executes the tool via `MeetingQATools` (synchronous; sub-second for these three tools).
   - Emits `.toolResult(name, summary)` to UI.
   - Appends `assistant: [tool_use(...)]` and `user: [tool_result(...)]` blocks to the message list.
   - Increments iteration counter.
5. Provider returns when `stop_reason` arrives. If `end_turn`, agent finishes. If `tool_use`, agent loops to step 3.
6. On `end_turn`, agent emits a final `.usage(QAUsage)` event with cumulative token counts and cost across all iterations.
7. If iteration cap (15) is hit before `end_turn`, agent emits `.status("Hit iteration cap of 15")` and finishes. The partial answer (whatever text the model already streamed) stays visible.

## Components

### New files (all under `GhostPepper/QA/`)

| File | Purpose | Approx LOC |
|---|---|---|
| `LLMProvider.swift` | Protocol + shared types: `LLMMessage`, `LLMTool`, `ProviderEvent`, `ProviderUsage`, `LLMProviderKind` enum (one case for now: `.anthropic`). | ~80 |
| `AnthropicProvider.swift` | Implements `LLMProvider` against Anthropic Messages API. Subsumes the HTTP / SSE / cost-counting code currently in `ClaudeAPIClient.swift`. Adds `tool_use` block streaming and `tool_result` content support. | ~260 |
| `MeetingQAAgent.swift` | Orchestrator. Runs the iteration loop, holds the message list, dispatches tools, enforces the iteration cap, accumulates usage across iterations, owns cancellation. Exposes `func ask(question:) -> AsyncThrowingStream<QAEvent>`. | ~180 |
| `MeetingQATools.swift` | Tool implementations + tool JSON schemas. `grep`, `readFile`, `listDir`. Uses `PathSandbox` for safety. | ~250 |
| `PathSandbox.swift` | Single function `resolveSafe(_:root:) throws -> URL`. Resolves symlinks, blocks `..` escapes and absolute paths, ensures the result is inside the archive root. | ~40 |
| `QAEvent.swift` | UI-facing event enum: `.status`, `.toolCall`, `.toolResult`, `.text`, `.usage`, `.error`. | ~50 |
| `QATranscript.swift` | `ObservableObject` model holding the array of `QAEvent`s for the current question. Stores **full** tool inputs and outputs (not summaries) so the trace UI's tap-to-copy works. Backs the expandable trace UI. Cleared per question. | ~50 |
| `MeetingQASystemPrompt.swift` | The system prompt as a static string + a small builder that interpolates the archive root path. Kept as its own file because (a) it's long, (b) it's the most likely thing to iterate on. | ~80 |

### Modified files

| File | Change |
|---|---|
| `AppState.swift` | Drop the keyword-scoring loop. Wire `MeetingQAAgent` instantiation: build the agent with the configured provider + meetings folder root, expose a single `func askMeetingQA(_ question: String) -> AsyncThrowingStream<QAEvent>`. |
| `MeetingTranscriptWindow.swift` | Rewrite `askAcrossMeetings()` — no more file scoring or context cramming. Just call `appState.askMeetingQA(question)` and render events. Add the status-line + expandable-trace UI. Replace `qaSourceFile` with `qaTranscript: QATranscript`. |
| `SettingsWindow.swift` | Replace "Backend: Local / Claude API" picker with "Provider: Anthropic" (single option for now — the dropdown is the seam for future providers). Keep the Claude model picker (Opus / Sonnet / Haiku) and the API key field. Remove the local-Q&A model row. |

### Deleted files

| File | Reason |
|---|---|
| `ClaudeAPIClient.swift` | Subsumed by `AnthropicProvider.swift`. The single-shot `ask` and `askStream` signatures don't fit the tool loop; the SSE / cost-counting code moves wholesale into the new provider. |

### Renamed / reshaped files

| File | Change |
|---|---|
| `QABackendKind.swift` → `LLMProviderKind.swift` | `.local` removed. `ClaudeAPIModel` enum stays (now lives next to the provider it describes). `QAUsage` and `QAStreamEvent` move out: `QAUsage` becomes part of `QAEvent.swift`; `QAStreamEvent` is replaced entirely by `QAEvent`. |

### Untouched

`MeetingTranscript.swift`, `MeetingMarkdownWriter.swift`, `MeetingSession.swift`, `GranolaImporter.swift`, the dictation / cleanup / summary local-LLM stack — all untouched. The agent reads files directly off disk; it doesn't go through the parsed model. The `LocalCleanupModelKind.qa` reference is dropped; everything else in that family stays.

## Tool definitions

Three tools, all read-only, all path-sandboxed to the archive root.

### `grep`

```json
{
  "name": "grep",
  "description": "Search the meeting archive for a regex pattern. Returns matching lines with file paths and line numbers. Prefer this over read_file when looking for names, dates, or specific phrases — it's much cheaper than reading whole files.",
  "input_schema": {
    "type": "object",
    "properties": {
      "pattern":          {"type": "string", "description": "Regex pattern. Use plain strings for names. Use \\b for word boundaries (e.g., \\bQuinn\\b)."},
      "path":             {"type": "string", "description": "Optional subdirectory or file relative to the archive root. Defaults to whole archive."},
      "case_insensitive": {"type": "boolean", "default": true},
      "max_results":      {"type": "integer", "default": 50, "maximum": 200, "description": "Hard cap on returned matches. Increase to see more matches; narrow `path` or tighten `pattern` to see more relevant ones."}
    },
    "required": ["pattern"]
  }
}
```

**Implementation:** shells out to `/usr/bin/grep -rn` (BSD grep, ships with macOS — no ripgrep dependency). Flags: `-r` (recursive), `-n` (line numbers), `-i` (case-insensitive when set), `--include='*.md'`, `--exclude-dir=.git`. Output piped through `head -n max_results`.

**Output format:** each match on one line as `relative/path.md:LINE:matched text` (path made relative to archive root before returning). At end, append a meta line: either `"(Returned N of N matches.)"` or `"(Returned N matches; max_results was M and was hit. Increase max_results or narrow scope to see more.)"`.

**Why grep over ripgrep:** ripgrep would mean shipping a binary or requiring brew install — friction for users. macOS BSD grep handles ~300 markdown files (low tens of MB) in milliseconds.

**Empty-match case:** if grep exits with status 1 (no match) and no errors, return `"No matches found for pattern: \(pattern)"`. Not an error from the model's perspective — just a fact for it to react to.

### `read_file`

```json
{
  "name": "read_file",
  "description": "Read a slice of a meeting transcript file. Returns the content with line numbers prepended for easy citation. Use after grep narrows you to a candidate file.",
  "input_schema": {
    "type": "object",
    "properties": {
      "path":   {"type": "string",  "description": "Path relative to archive root, e.g., '2025-01-29/dana-matt.md'."},
      "offset": {"type": "integer", "default": 1,   "description": "1-indexed starting line."},
      "limit":  {"type": "integer", "default": 200, "maximum": 1000, "description": "Number of lines to return."}
    },
    "required": ["path"]
  }
}
```

**Implementation:** read the file, slice `[offset-1 ..< offset-1+limit]`, prefix each line with `"\(lineNumber)\t"`. The default of 200 lines is conservative; the model can request up to 1000 in one call when it knows it needs the whole file.

**Output format:**
```
1	---
2	title: Dana <> Matt
3	date: 2025-01-29
...
200	some text
```

After the slice, append a meta line: either `"(Returned lines 1-200 of 4127. Use offset=201 to continue.)"` or `"(End of file at line 4127.)"`.

**No silent truncation.** If the user asks for 200 lines and the file has 4127, the model gets exactly 200 lines plus precise metadata about how to read more. It can decide whether the next 200 lines are worth the round trip.

### `list_dir`

```json
{
  "name": "list_dir",
  "description": "List entries in a directory inside the meeting archive. Use to discover meetings by date — directories are named YYYY-MM-DD.",
  "input_schema": {
    "type": "object",
    "properties": {
      "path": {"type": "string", "description": "Path relative to archive root. Use '.' or empty string for the root."}
    },
    "required": ["path"]
  }
}
```

**Implementation:** `FileManager.default.contentsOfDirectory(at:..., includingPropertiesForKeys: [.isDirectoryKey])`. Sort lexicographically (date order for `YYYY-MM-DD/` falls out for free). Mark directories with a trailing `/`.

**Output format:**
```
2025-01-29/
2025-05-19/
2026-01-07/
2026-04-28/
README.md
```

**No truncation needed in practice** — even with 5 years of daily meetings, a directory listing is ≤ ~2000 short lines and well under a context-budget concern. If the implementation later finds a pathological case (e.g., a directory with 100k entries), revisit then.

### `PathSandbox`

All three tools route paths through one function:

```swift
enum PathSandboxError: LocalizedError {
    case pathOutsideRoot(String)
    case pathDoesNotExist(String)
}

func resolveSafe(_ relative: String, root: URL) throws -> URL {
    let normalized = relative.isEmpty || relative == "." ? root : root.appendingPathComponent(relative)
    let candidate = normalized.standardizedFileURL.resolvingSymlinksInPath()
    let rootResolved = root.resolvingSymlinksInPath()
    let rootPrefix = rootResolved.path.hasSuffix("/") ? rootResolved.path : rootResolved.path + "/"
    guard candidate.path == rootResolved.path || candidate.path.hasPrefix(rootPrefix) else {
        throw PathSandboxError.pathOutsideRoot(relative)
    }
    return candidate
}
```

Blocks `..` escapes, absolute paths that start with `/`, and symlinks pointing outside the archive. No write APIs are ever exposed to the agent — the tool implementations only call read APIs.

If a tool receives a path it can't resolve, the tool returns a `tool_result` with `is_error: true` and the message `"Path '<x>' is outside the meeting archive or does not exist."` — the model sees the error and can correct.

## System prompt

Stored in `MeetingQASystemPrompt.swift`. The full prompt:

```
You are the meeting Q&A assistant for the user's personal meeting archive. You answer
questions about their meetings using three tools: grep, read_file, and list_dir.

# Archive layout

Root: {ARCHIVE_ROOT}

Files are markdown meeting transcripts. The archive is organized as YYYY-MM-DD/ folders,
each containing one or more .md files for meetings on that date. Each file has YAML
frontmatter (title, date, granola_id, attendees, source_type, imported_from) followed
by a Summary section and a Transcript section. Transcripts are often 4,000+ lines.

# How to answer

1. Always cite your sources as `path:line` or `path:start-end`. Every factual claim
   needs a citation. If you can't cite it, don't claim it.
2. Prefer grep for names, dates, and exact strings. It's much cheaper than read_file.
3. Use read_file with a small offset/limit to confirm context around a grep match.
   Read more (up to 1000 lines) only when you need the full meeting.
4. Use list_dir to discover meetings on a specific date or to find date-named folders.
5. Stop searching when you have enough to answer. Don't read every file.

# Voice-to-text reasoning

Transcripts are voice-to-text with frequent artifacts: misheard names, run-on
fragments, dropped words. When a phrase looks garbled, reason about the likely
intended meaning from surrounding context.

Examples of artifacts you should interpret, not take literally:
- "He's not a Quinn Adler for 10 years" almost certainly means
  "He's known Quinn for 10 years."
- "Robin" addressed in a "Dana <> Matt" meeting is most likely Dana being
  addressed informally — note the discrepancy in your answer.
- Names with similar phonemes are often the same person across files.

When you interpret an artifact, say so explicitly: "The transcript reads X, which I
read as Y because [reason]."

# Multi-hop questions

For "do X and Y know each other" or similar relationship questions:
1. Search for both names independently.
2. Look for direct co-attendance (both names appearing in the same file's
   attendees field or transcript).
3. Look for one mentioning the other in a third party's meeting (often the
   strongest signal in this archive).
4. Cite the strongest evidence. Be honest about what you can and can't conclude.

# Iteration budget

You have at most 15 tool calls per question. Plan accordingly. Front-load grep
calls (cheap, narrow the search), then read selectively.
```

The `{ARCHIVE_ROOT}` placeholder is replaced at agent construction with the absolute path returned by `MeetingTranscriptSettings.effectiveSaveDirectory()`.

The system prompt + tool definitions are placed in a single `cache_control: {type: "ephemeral"}` block so they hit the prompt cache across iterations within one question and across questions in one session.

## Provider abstraction

### `LLMProvider` protocol

```swift
protocol LLMProvider {
    func complete(
        system: String,
        messages: [LLMMessage],
        tools: [LLMTool]
    ) -> AsyncThrowingStream<ProviderEvent, Error>
}

struct LLMMessage {
    let role: Role  // .user, .assistant
    let content: [LLMContentBlock]
}

enum LLMContentBlock {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    case toolResult(toolUseId: String, content: String, isError: Bool)
}

struct LLMTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]   // JSON schema
}

enum ProviderEvent {
    case textDelta(String)
    case toolUse(id: String, name: String, input: [String: Any])  // emitted on block_stop
    case stop(reason: StopReason, usage: ProviderUsage)
}

enum StopReason {
    case endTurn
    case toolUse
    case maxTokens
    case other(String)
}

struct ProviderUsage {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
}
```

### `AnthropicProvider` notes

- Endpoint, headers, and SSE parsing reuse the existing `ClaudeAPIClient.swift` implementation pattern.
- `tools` is sent as the standard Anthropic `tools` array.
- The system prompt is sent as a system block with `cache_control: {type: "ephemeral"}`.
- `tool_use` blocks stream their `input` field as `input_json_delta` events. The provider must accumulate JSON fragments per block and emit a single `ProviderEvent.toolUse` once the block's `content_block_stop` arrives. (This is non-trivial — calls out as an explicit requirement here so the implementation plan tests it.)
- `tool_result` blocks (in the user-role message after tool execution) are sent as content blocks with `tool_use_id` linking back to the originating `tool_use`. Errors set `is_error: true`.
- Cost is computed per response and summed across iterations by the agent.

### Future providers

Adding `OllamaProvider` or `OpenAIProvider` later means: implement `complete(...)`, translate the unified message/tool model into provider-native shapes, parse provider-native streaming. The agent loop, the tools, the path sandbox, the system prompt, and the UI all stay the same.

The `LLMProviderKind` enum gains a new case; the Settings UI grows a new dropdown row; the `LLMProvider` instance is constructed from settings at agent-creation time.

**MCP placeholder.** The Anthropic SDK supports MCP server configuration alongside `tools`. The `LLMProvider.complete` signature does not currently take MCP server configs — when MCP is added, it joins the `tools` parameter shape (e.g., a sibling `mcpServers: [MCPServerConfig]` parameter). No MCP servers are shipped now, but the protocol won't need to be reshaped to add them.

## UI changes

### Q&A bar — `MeetingTranscriptWindow.swift`

Existing layout (text field, answer area, usage footer) is preserved. Two new elements:

1. **Status line** — one row above the answer text. Shows the latest tool activity.
   - While streaming an `assistant` text response: `"Thinking..."`
   - While a tool is being dispatched: `"Searching for 'Quinn'..."` (grep) / `"Reading 2025-01-29/dana-matt.md (lines 1–200)..."` (read_file) / `"Listing 2026-01-07..."` (list_dir)
   - After the answer arrives: hidden.

2. **Expandable trace** — a disclosure triangle next to the status line. Collapsed by default. When expanded, shows the full event log for the current question:

   ```
   ▼ Trace (8 events)
     [grep]      pattern="Quinn", case_insensitive=true → 7 matches in 3 files
     [read_file] 2025-01-29/dana-matt.md offset=1 limit=200 → returned lines 1–200 of 312
     [grep]      pattern="Sam Rivers" → 2 matches in 1 file
     [read_file] 2026-01-07/team-standup.md offset=170 limit=50 → returned lines 170–219 of 580
     ...
   ```

   Each row shows tool name, brief input summary, and result summary. Rows are tappable to copy the full input or output to clipboard (debugging aid). Trace clears when the user submits a new question.

3. **Cancellation.** A "Stop" button appears next to the spinner while the agent is running. Cancels the underlying `Task`, which cancels the `AsyncThrowingStream`, which causes `URLSession.shared.bytes(for:)` to throw `URLError(.cancelled)` — caught and emitted as `.status("Stopped")`.

### Settings — `SettingsWindow.swift`

Old row in Meeting Transcript section:
```
Backend:  [ Local      | Claude API  ]
Local model:  [ Qwen 3.5 2B  ▼ ]
Claude model: [ Sonnet 4.6   ▼ ]
API key:      [ ********************    ]
```

New row in Meeting Transcript section:
```
Provider:     [ Anthropic   ▼ ]   (only one option for now)
Model:        [ Sonnet 4.6  ▼ ]   (Opus 4.7 / Sonnet 4.6 / Haiku 4.5)
API key:      [ ********************    ]   (stored in Keychain via existing KeychainHelper)
```

The "Provider" dropdown exists even with one option so the seam is visible to the user and no further UI work is needed when a second provider lands.

## Error handling

| Failure | Behavior |
|---|---|
| Missing API key when user submits | Same as the predecessor spec: open Settings to the Meeting Transcript section, show inline notice in Q&A bar ("Add your Claude API key to continue"). Agent doesn't run. |
| API HTTP 4xx / 5xx | Stream emits `.error("Claude API error 429: ...")`. Status line shows error. Trace shows the iteration where it failed. Partial answer (if any) stays. |
| Stream cancelled by user | `URLError(.cancelled)` caught at the agent level, emit `.status("Stopped")`, finish stream cleanly. |
| Tool returns error (path outside root, file not found, regex compile error) | Tool emits a `tool_result` with `is_error: true`. The agent sends it back to the model on the next iteration. Model will typically self-correct (ask for a different path). The trace shows the error so debugging is possible. |
| Iteration cap (15) reached | Emit `.status("Hit iteration cap of 15")` and finish. Whatever assistant text streamed before the cap stays visible. The trace reveals where it got stuck. |
| Model returns empty answer | UI shows `"No answer returned. Check the trace for what was searched."` |
| Provider stream throws mid-iteration | `.error(localized)` event, finish. No retry — the user retries by re-submitting. |

**Specific anti-pattern to avoid:** silently truncating tool results. Every tool call returns either complete data within its requested input limits, or precise pagination metadata indicating exactly what's missing. The model is never lied to about what it received.

## Verification

The system ships when all three of these queries (real content from the user's archive at `/Users/matthewhartman/Projects/granolatest/Ghost Pepper Meetings/`) return correct, cited answers end-to-end via the Q&A bar:

### Test 1 — Timeline

> "Give me a quick timeline of my meetings with Quinn."

**Expected behavior:**
- Agent issues `grep("Quinn")`.
- Finds matches in `2025-01-29/dana-matt.md`, `2025-05-19/team-standup.md`, `2026-01-07/team-standup.md`.
- Reads enough of each to extract one-line context.
- Answer: a chronological list with each date, file, and one-line excerpt with `path:line` citation.
- Bonus: notes that Quinn is *mentioned* but never appears as an attendee.

**Pass criteria:** all three files cited; dates correct; line citations resolve to actual matches.

### Test 2 — Single-meeting summary

> "Tell me about the Dana-Matt meeting."

**Expected behavior:**
- Agent issues `grep("Dana")` or `list_dir("2025-01-29")`.
- Identifies `2025-01-29/dana-matt.md`.
- Reads the file (likely in chunks: frontmatter+summary first, then transcript slices).
- Answer: a multi-section summary (background, fund details, AI investment philosophy, Quinn Adler connection) with line-range citations.
- Bonus: notes that the file title is "Dana <> Matt" but the other speaker is addressed as "Robin" later in the transcript.

**Pass criteria:** summary covers ≥ 3 substantive topics from the transcript; each section has a `path:start-end` citation; the title vs "Robin" discrepancy is mentioned.

### Test 3 — Multi-hop with voice-to-text artifact

> "Does Quinn know Sam Rivers?"

**Expected behavior:**
- Agent issues `grep("Sam Rivers")`.
- Finds matches in `2026-01-07/team-standup.md`.
- Reads context around line 184: "He's not a Quinn Adler for 10 years. Trade ideas. He runs wealth."
- Interprets the voice-to-text glitch: "He's known Quinn [Shaw] for ~10 years; they trade ideas."
- Answer: yes, Sam Rivers appears to know Quinn for ~10 years (per `2026-01-07/team-standup.md:184`), with the artifact called out explicitly.

**Pass criteria:** correct conclusion; cites the right file:line; explicitly flags the voice-to-text artifact and explains the interpretation.

If Test 3 fails (model takes the literal text at face value), the system prompt's "Voice-to-text reasoning" section needs more concrete examples or a sharper directive — adjust before adding fallback heuristics.

### Smoke tests

In addition to the three end-to-end tests, the implementation plan should include:

- **Path sandbox unit tests:** `PathSandbox.resolveSafe` rejects `../`, absolute paths, and symlinks pointing outside root.
- **Tool result format tests:** grep output, read_file output, list_dir output all parse as expected when given canned inputs.
- **Iteration cap test:** agent terminates cleanly when forced to hit 15 iterations (mock provider that always returns a `tool_use`).
- **Cancellation test:** cancelling the consumer task on the agent stream finishes the stream within ~1 second.
- **Tool-use accumulation test:** `AnthropicProvider` correctly assembles a `tool_use` block from streamed `input_json_delta` fragments.

## Out-of-scope follow-ups

Tracked here so they don't sneak into the implementation:

- **Embedding-based recall** as a fourth tool (e.g., `semantic_search(query)`). Revisit if the workload shifts toward "find meetings where I sounded frustrated."
- **`summarize_file(path)` higher-order tool** that runs a separate LLM call to pre-summarize a long transcript and returns the summary. Lower latency on "tell me about X" queries but adds a second model call per use.
- **MCP server config UI** — let users connect external MCP servers from Settings. Protocol shape supports it; UI work is the only thing missing.
- **Multi-archive support** — currently assumes one `MeetingTranscriptSettings.effectiveSaveDirectory()`. If the user wants to query across multiple archives, the agent would need a list of roots and the tools would need to disambiguate.
- **MCP server exposing the same three tools** so external agents (e.g., Claude Desktop) can read this archive.
- **Streaming visualization in the trace** — show grep results filling in as they arrive rather than batch on tool completion.
- **Cost cap** — abort if cumulative cost exceeds a configurable USD limit per question.

## Open questions

These came up during brainstorming and are deliberately deferred to implementation:

1. **Read-file default `limit` of 200 vs 500.** 200 is conservative (good for multi-hop, more round trips for "tell me about X"). 500 reduces round trips but can waste tokens on irrelevant content. Default 200; if Test 2 needs three+ rounds of read_file calls to summarize a single meeting, raise to 500.
2. **Whether to send a "previous tool calls" reminder in the system prompt** if the agent appears to be re-running grep with the same pattern. Probably unnecessary — Claude is good at this — but worth verifying during the verification runs.
3. **Whether `grep` should default to `--include='*.md'`** or also include other file types. Current archive is markdown-only, so the include is a no-op safety net. If the archive grows file types later, the model may want to opt out.
