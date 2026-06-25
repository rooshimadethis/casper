current:
 watcher:
 - mark summary by priority/logicality?
 - will need to split up summaries by groups maybe by timestamp for context control

 predictor:
 - dynamic context to real time llm based on some of the user events for context/speed
 - llm for coming up with the action to run
 - mcp
 - keyboard shortcut to run action


quick suggestions
 - n-gram transition matrix
 - markov chain
can be trained on raw event data and quickly find patterns and suggest them through computation
a matcher will find the pattern and then the llm would take the pattern and output a suggestion. trying to get the llm to constantly run, try to come up with patterns and suggestions would take a lot of power





You should completely clear or reset the model's episodic context window based on three explicit triggers:
 - Logical Idle Boundaries: Wipe the event context after 15 to 30 minutes of user inactivity. A long pause almost always denotes a shift in user focus, meaning previous fine-grained desktop events are no longer active inputs for immediate intent.
 - Workspace/Context Shifts: Track high-level system indicators (e.g., switching to a different repository in your IDE, changing the active project directory in the terminal, or opening a completely different suite of applications). When a baseline shift occurs, dump the event buffer, preserve only a high-level summary of the "previous state," and start fresh.
 - Token High-Water Marks: Set a hard threshold at roughly 25% to 35% of the model’s maximum context window (e.g., 2,048 or 4,096 tokens max for a small model). Once reached, compress the current history block into a single "State Summary" token block, evict the raw timeline, and append the summary as the new baseline context.

[SYSTEM PROMPT]
- Core identity, intent extraction rules, and constraints.
[AUTOMATION REGISTRY / TOOL DEFINITIONS]
- Schema definitions for your executable actions (or MCP tools).
[ENVIRONMENT STATE]
- Active App: Xcode
- Working Directory: /Users/roosh/dev/casper
- Clipboard Type: Code Block (Swift)
[COMPRESSED TIMELINE BUFFER]
- 16:40:02 - Focused Xcode; modified AppRelauncher.swift (added fallback logic)
- 16:41:15 - Focused Terminal; executed `swift build` -> Result: Exit Code 1 (Missing symbol)
- 16:41:22 - Focused Safari; searched "SwiftUI window relaunch fallback behavior"
[CURRENT TRIGGER ACTION]
- 16:42:05 - Focused Xcode; highlighted 12 lines of code in AppRelauncher.swift
[INSTRUCTION]
Predict next high-probability automation from the registry. Output JSON only.


MCP for interacting with the system