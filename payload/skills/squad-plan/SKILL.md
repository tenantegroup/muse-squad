---
name: squad-plan
description: Multi-agent explore-first planning mode that writes a decision-complete plan before coding.
---
You are in SQUAD-PLAN mode. Do NOT edit product code yet.

## Subagent Task Labeling (TUI Visibility)

When spawning any subagent, set its short task title / description to:

`[<agent-role> | <short-model-name>] <concise action>`

- `<agent-role>` is the role, plus an index when there are peers: `scout-1`, `plan-reviewer`, `worker-2`.
- `<short-model-name>` is lowercase and stable: `ember` for `muse-ember-1.0`, `spark` for `muse-spark-1.3`, `wonder` for `muse-wonder-*` if configured, or the `custom-coder` endpoint alias (`local-coder`, `grill-reviewer`) when the work goes through that endpoint. Combine with `+` when a native agent delegates to `custom-coder`, e.g. `ember+local-coder`.
- Keep `<concise action>` under ~50 characters so the TUI footer (`└ ◈ <task> running <elapsed>`) does not truncate the useful part. Start with a verb; no trailing punctuation.
- Use exactly `[role | tag] action`: lowercase tags, one space on each side of `|`, no extra prefix or wrapper.

Examples:

```text
[scout-1 | ember] Map mcp/bridge.js and endpoints.json
[plan-reviewer | spark] Audit .muse/PLAN.md for edge cases
[worker-1 | ember] Implement FIFO semaphore queue
[worker-2 | ember+local-coder] Generate unit tests for fallback
```

Use this format as the default for every spawn. If a one-off subagent truly has no meaningful role or model, keep the bracketed prefix with a plain tag such as `[helper | ember]` rather than leaving the title unlabeled.

## Concurrency Budget (read first)

Before spawning anything, read `~/.config/muse/endpoints.json` (or call `custom-coder:list_endpoints`) and note the `muse_models` limits and each endpoint's `max_concurrency`. The orchestrator must never spawn more simultaneous native subagents of a given model than that model's `muse_models` limit — for example at most 4 `muse-ember-1.0` or 2 `muse-spark-1.3` subagents at once. Batch any larger exploration into successive waves. Parallel workers may safely call `custom-coder` MCP tools at the same time: the router queues requests FIFO and serializes them per endpoint's `max_concurrency`.

## Context Size (custom-coder)

When calling `custom-coder`, keep `repo_context`, `file_context`, and `plan_markdown` short and relevant to the decision at hand. Use `custom-coder:list_endpoints` to check the target endpoint's `max_input_chars` and `extra_body` context hints (such as `options.num_ctx`) before sending. Send only the needed files or excerpts — never dump whole unrelated files. If a reply starts with the input-truncated warning, the model saw less context than you intended: shorten the context and re-ask instead of trusting the critique.

1. Spawn parallel read-only subagents (`explore` / `general-purpose`) to map the relevant files, dependencies, and existing patterns.
2. Ask the user clarifying questions ONLY if an architectural fork cannot be resolved from the codebase.
3. Draft a decision-complete implementation plan in `.muse/PLAN.md` with exact file paths, dependency order, and verification commands. If the file already has a `## Execution Log & Decisions` section, preserve it verbatim at the bottom — it is the durable handoff record from any prior execution session; do not overwrite it unless the user explicitly asks to reset the plan.
4. Dual-Brain Plan Grill:
   1. Spawn our native `plan-reviewer` subagent (read-only) to audit `.muse/PLAN.md` against the actual files in the repository.
   2. Simultaneously call the `custom-coder:critique_plan` MCP tool with `endpoint: "grill-reviewer"` so your self-hosted model performs an independent adversarial review.
   3. Synthesize both critiques, resolve any valid issues in `.muse/PLAN.md`, and present a summary of what was caught before asking the user for `/squad-execute` sign-off.
