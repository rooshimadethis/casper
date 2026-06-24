# Plan: Clean Typing Telemetry with Shortcut Isolation & Defocus/Submission Flushes

Instead of mixing typing and keyboard shortcuts in a single session, we will partition them. Additionally, we will group consecutive backspaces that delete pre-existing text into a single compact representation (e.g. `<Backspace x 5>`), and flush typing sessions immediately upon submission (`Enter`), navigation (`Tab`), mouse clicks, or window/app defocus.

This keeps the telemetry clean, readable, and highly informative for the LLM while retaining 100% backward compatibility with the existing `DesktopUserEvent` schema.

## Proposed Changes

### Casper Telemetry

#### [MODIFY] [TelemetryCollector.swift](file:///Users/rooshi/Documents/programming/mac/casper/Casper/Telemetry/TelemetryCollector.swift)

1. **Define a structured `TypingToken` enum:**
   ```swift
   private enum TypingToken {
       case character(Character)
       case special(String)
       case backspace(count: Int)
   }
   ```

2. **Track tokens in `TelemetryCollector`:**
   Replace `private var activeTypingText = ""` with:
   ```swift
   private var activeTypingTokens: [TypingToken] = []
   ```

3. **Handle Shortcut Isolation and Defocus/Submission Flushes in `handleKeyPress(_:)`:**
   - Detect if a keypress has non-shift modifiers (`Command`, `Control`, or `Option`).
   - If it is a shortcut (e.g., `Cmd+S`, `Cmd+C`, `Cmd+V`, `Cmd+Z`):
     - **Flush the active typing session** immediately to commit any text typed so far.
     - Start a new temporary session containing only this shortcut.
     - **Flush the shortcut session immediately** to ensure it is written as a standalone action.
   - If it is NOT a shortcut:
     - Check if it is a submission key (`Enter` / keycode 36) or navigation key (`Tab` / keycode 48).
     - Append the key representation to the active session.
     - **Flush the active session immediately** after adding the `Enter`/`Tab` key.
     - For other keys (normal typing, Backspace), accumulate in the active session.

4. **Handle Backspaces Locally:**
   - When a `Backspace` key is pressed:
     - Check if the previous token in the session was `<Cmd+a>` or `<Cmd+A>`. If so, remove the command token and clear all `.character` tokens from the current session.
     - Otherwise, search backwards for the last `.character` token and remove it.
     - If no `.character` token exists in the current session (meaning the user is deleting pre-existing text):
       - If the last token in `activeTypingTokens` is `.backspace(let count)`, update it to `.backspace(count: count + 1)`.
       - Otherwise, append `.backspace(count: 1)`.

5. **Serialize Tokens in `flushActiveTypingSession()`:**
   - Construct the output string:
     - `.character(let char)` $\rightarrow$ string representation of `char`.
     - `.special(let str)` $\rightarrow$ `str`.
     - `.backspace(let count)` $\rightarrow$ `count == 1 ? "<Backspace>" : "<Backspace x \(count)>"`.
   - Submit the compiled string under `DesktopUserEvent.typingSession`.
   - Reset the tokens state.

*(Note: Mouse clicks, App switching, and Window title changes already trigger `flushActiveTypingSession()` in the existing codebase).*

### Casper Tests

#### [MODIFY] [TelemetryCollectorTests.swift](file:///Users/rooshi/Documents/programming/mac/casper/CasperTests/TelemetryCollectorTests.swift)
- Update tests to verify:
  1. Hitting `Cmd+S` flushes active typing immediately and logs `<Cmd+s>` in its own separate session.
  2. Hitting `Enter` or `Tab` immediately flushes the typing session.
  3. Hitting multiple backspaces on an empty field groups them as `"<Backspace x 3>"`.
  4. Holding a normal key like `'a'` repeats correctly without splitting or grouping.

## Verification Plan

### Automated Tests
- Run unit tests:
  ```bash
  swift test --filter TelemetryCollectorTests
  ```

### Manual Verification
- Check generated JSONL logs to verify formatting:
  - Typing "hello", saving, typing "world" should yield three events: `"hello"`, `"<Cmd+s>"`, and `"world"`.
  - Hitting backspace 5 times on an empty field should log `"<Backspace x 5>"`.
