# Prediction Chain Direction

Date: 2026-06-24

## Current Problem

The prediction engine is currently shaped as a next-event predictor, but the intended product shape is a chain-of-actions predictor.

Today the runtime can say:

```text
Given the last few normalized events, the next token is probably k:Ghostty:text_field.
```

The desired end state is closer to:

```text
You are doing the deploy/debug loop.
Next likely chain:
1. Switch to Ghostty
2. Type the repeated command
3. Copy the output
4. Paste the result into Slack
```

The current trie and micro layer are useful primitives, but they do not yet model workflows.

## Where The Current Design Goes Wrong

### Runtime only emits one step

`RuntimePredictor` calls `trie.predict(context:)`, builds a few single-token predictions, then selects one top prediction. There is no rollout, beam search, chain scoring, terminal state, or workflow-level object.

This makes the product surface inherently reactive: it can suggest the next click or type action, but not the larger action sequence the user was probably trying to complete.

### The PPM trie is a successor model

`PpmTrie` is good at answering:

```text
What token tends to follow this context?
```

It is not designed to answer:

```text
What workflow is the user in?
What chain completes that workflow?
Which steps are executable?
Where should the chain stop?
```

That is fine. The trie should remain a low-level sequence primitive, not become the whole product model.

### Micro state decorates a single token

`MicroStore` currently helps turn a macro prediction like:

```text
k:Ghostty:text_field
```

into a specific suggestion like:

```text
Type "killall Finder" in Ghostty
```

That is valuable, but it only enriches the first predicted token. It does not compose several enriched steps into a chain.

### Token granularity may be too fragmented

The original design described `typingSession` as:

```text
k:{appName}
```

The current tokenizer emits:

```text
k:{appName}:{elementType}
```

That extra specificity may become useful later, but early on it splits repetitions across `terminal`, `text_field`, `search`, and other buckets. For chain learning, this increases sparsity before there is enough usage data.

The same concern applies generally: tokens need to be abstract enough to repeat, but specific enough to be actionable once micro state is applied.

### Execution is not chain-capable

`DefaultActionExecutor` currently only executes `a:` app-switch predictions. Even current `k:` micro predictions can be displayed without being executable by the default executor.

A chain predictor needs action steps with explicit execution semantics, for example:

```swift
activateApp(bundleID:)
pasteText(String)
typeText(String)
clickElement(description:)
runCommand(String)
```

The UI should know which steps are executable, which are preview-only, and which require confirmation.

### Time decay should preserve sparse historical data

The predictor should not aggressively favor only the last day or two while telemetry is sparse. Workflows are expected to be stable enough that recent-month events should retain full weight, with fractional decay reserved for older history.

When fractional weights are used, insertion paths must preserve them instead of converting them to `Int`, because `0.5` would otherwise become `0` and older recurring workflows would disappear.

## Better Direction

Keep the existing trie and micro store, but add a higher-level chain layer.

### 1. Treat PPM as a primitive

Use the trie to answer next-token questions quickly:

```text
current context -> ranked next tokens
```

Do not make it responsible for workflow identity, stopping criteria, or action execution.

### 2. Add an ActionChainPrediction model

Introduce a product-level prediction type:

```swift
struct ActionChainPrediction {
    let title: String
    let confidence: Double
    let steps: [PredictedActionStep]
}

enum PredictedActionStep {
    case activateApp(bundleID: String, appName: String)
    case pasteText(String)
    case typeText(String, appName: String)
    case clickElement(String, appName: String)
    case runCommand(String, appName: String)
    case observe(String)
}
```

The existing `Prediction` struct can remain as the single-step UI surface temporarily, but the product direction should move toward chain predictions.

### 3. Roll predictions forward

At runtime:

1. Start from the current sliding window.
2. Ask the trie for likely next tokens.
3. Append each candidate token hypothetically.
4. Predict the next token again.
5. Keep the top few candidate chains.
6. Enrich each step through `MicroStore`.
7. Stop when confidence drops, the chain reaches a boundary, or a max horizon is reached.

This can be implemented as a small beam search with a horizon of 3-6 steps.

### 4. Store repeated motifs directly

In addition to PPM, train frequent subsequences from telemetry:

```text
a:Xcode -> c:Xcode -> a:Ghostty -> k:Ghostty
a:Chrome -> c:Chrome -> a:Slack -> k:Slack
x:Ghostty:failure -> a:Chrome -> k:Chrome:search
```

These motifs are closer to workflows than raw next-token predictions. They can be mined from session windows separated by idle gaps, app switches, command execution, copy/paste, or hesitation events.

### 5. Use micro enrichment for every step

Micro lookup should enrich each predicted step in the chain, not just the first visible prediction.

Example:

```text
Macro chain:
a:com.mitchellh.ghostty -> k:Ghostty -> a:com.tinyspeck.slackmacgap -> k:Slack

Micro-enriched chain:
1. Switch to Ghostty
2. Type "git push"
3. Switch to Slack
4. Type "pushed the branch"
```

### 6. Design the UI around intent plus next action

The UI should not dump a long automation script on the user. It should show:

```text
Looks like you are finishing the deploy note

Next: Paste "pushed the branch" into Slack
Then: Switch back to Xcode
```

The immediate next action is primary. The rest of the chain is preview/context.

## Near-Term Fixes Before Building Chains

1. Decide whether `typingSession` should be `k:{appName}` or `k:{appName}:{elementType}` for the first dogfoodable chain version.
2. Keep sparse telemetry from being over-decayed; recent-month events should stay full weight and fractional decay must not round to zero.
3. Make `k:` predictions executable through the default executor when they have a micro value.
4. Add a small internal `PredictedActionStep` abstraction before extending the UI.
5. Add a chain rollout method beside the existing single-step predictor instead of replacing it immediately.

## Experiment Learnings

Recent telemetry analysis suggests the trie is healthier than the suggestion surface:

- The trie predicts a diverse mix of `m:`, `a:`, `k:`, `t:`, `h:`, `c:`, and `s:` tokens.
- Most non-`a:` tokens get discarded because `buildPrediction` only maps a few token types to useful suggestions.
- `t:`, `h:`, `s:`, and `x:` should usually be treated as context/bridge tokens during chain rollout, not directly surfaced as user-facing actions.
- The MicroStore is the current bottleneck: exact full-context hashes are too sparse, and the observed store only had a few dozen context keys.
- `k:` and `m:` predictions need suffix fallback, similar in spirit to PPM backoff, so exact six-token context matches are not required.
- Click micro values must be normalized before storage. Structural values like `AXScrollArea`, `AXGroup`, and unlabeled `AXImage` should be rejected or replaced with title/description/value text when available.
- Typed text should be normalized by domain. Terminal commands can often be reduced to command/subcommand forms; long prose and code edits should usually be rejected.
- A single `count >= 3` micro threshold is too blunt. Terminal/search typed text can tolerate lower thresholds than generic text fields or click targets.

## Next Implementation Priorities

1. Add suffix-based MicroStore lookup for `k:` and `m:` predictions.
2. Normalize micro values before storing them during training.
3. Use action-specific micro thresholds rather than one hard threshold.
4. Keep `t:`, `h:`, `s:`, and `x:` as chain context tokens until there is a concrete executable action for them.
5. Use the chain rollout path to bridge through non-action tokens instead of forcing every predicted token to become a UI suggestion.

## Core Principle

The trie should answer:

```text
What tends to happen next?
```

The product should answer:

```text
What is the user trying to finish, and what chain gets them there?
```
