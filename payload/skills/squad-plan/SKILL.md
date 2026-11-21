---
name: squad-plan
description: Multi-agent explore-first planning mode that writes a decision-complete plan before coding.
---
You are in SQUAD-PLAN mode. Do NOT edit product code yet.

## Subagent Task Labeling and Reporting (TUI Visibility)

When spawning any subagent, **always** set its short task title / description to:

`[<agent-role> | <model-tag>] <concise action>`

- `<agent-role>` is the role, plus an index when there are peers: `scout-1`, `plan-reviewer`, `worker-2`.
- `<model-tag>` is lowercase and stable: `ember` for `muse-ember-1.0`, `spark` for `muse-spark-1.3`, `wonder` for `muse-wonder-*` if configured, or the `custom-coder` endpoint alias (`local-coder`, `grill-reviewer`) when work goes through that endpoint. Combine with `+` when a native agent delegates to `custom-coder`, e.g. `ember+local-coder`. If the specific native model is unknown but it is a native Muse subagent, use `native`; use `unknown` only as a last resort. **Never omit the tag.** **Do not guess or infer from role defaults** (e.g. do not label a scout/reviewer `ember` or `spark` unless the runtime, spawn result, or session metadata explicitly reports that exact model). If you later learn the actual model, correct the roster/summary and note the correction.
- Keep `<concise action>` under ~50 characters so the TUI footer (`└ ◈ <task> running <elapsed>`) does not truncate the useful part. Start with a verb; no trailing punctuation.
- Use exactly `[role | tag] action`: lowercase tags, one space on each side of `|`, no extra prefix or wrapper.

Examples:

```text
[scout-1 | ember] Map mcp/bridge.js and endpoints.json
[plan-reviewer | spark] Audit .muse/PLAN.md for edge cases
[worker-1 | ember] Implement FIFO semaphore queue
[worker-2 | ember+local-coder] Generate unit tests for fallback
[scout-2 | native] Inspect git state of repos
```

If work is done **inline** because subagent spawning failed, was rejected, or is unavailable, do not invent a spawn — report it in the summary as `[inline | native] <action>`.

**Always include a "Subagents / Models" roster in your user-facing summaries** (and before asking for sign-off) so the model is visible even if the TUI label omits it. For each helper list: role, model-tag, action, and outcome/status. For `custom-coder` tool calls, report the actual `servedBy` endpoint/model and `fallbackUsed` from the tool result meta (not inferred from config/default) and the outcome (e.g. `custom-coder:critique_plan | servedBy local-coder (<model>) — ok`). If result meta is unavailable, state that explicitly.

## Concurrency Budget and Endpoint Health (read first)

At the start, call `custom-coder:list_endpoints` (or read `~/.config/muse/endpoints.json`) to learn `muse_models` limits, endpoint `max_concurrency`, and whether custom-coder is available.

- If the result indicates custom-coder is unavailable, misconfigured, or not working properly (for example `available: false`, `ok: false`/`warning`, missing/unreadable config, or the tool cannot be reached), **warn the user clearly** with the reported issue and continue in **native-only mode**: do not block planning. Use native Muse subagents/models for exploration and critique and skip `custom-coder` tool calls until endpoints are fixed. If a custom-coder call fails later at runtime, treat that the same way (warn and continue natively). Use sensible default concurrency if limits are unknown (for example at most 2 concurrent native subagents of the same model) and batch into waves.
- If custom-coder is available, never spawn more simultaneous native subagents of a given model than that model's `muse_models` limit (for example at most 4 `muse-ember-1.0` or 2 `muse-spark-1.3` at once). Batch any larger exploration into successive waves. Parallel workers may safely call `custom-coder` MCP tools at the same time: the router queues requests FIFO and serializes them per endpoint's `max_concurrency`.

## Context Size (custom-coder, when available)

When calling `custom-coder`, keep `repo_context`, `file_context`, and `plan_markdown` short and relevant to the decision at hand. Use `custom-coder:list_endpoints` to check the target endpoint's `max_input_chars` and `extra_body` context hints (such as `options.num_ctx`) before sending. Send only the needed files or excerpts - never dump whole unrelated files. If a reply starts with the input-truncated warning, the model saw less context than you intended: shorten the context and re-ask instead of trusting the critique.

1. Map the relevant files, dependencies, and existing patterns. Prefer spawning parallel read-only subagents (for example `explore` or `general-purpose`, if available in this runtime) for faster coverage; if subagent spawning fails, is rejected, or is unavailable, do the equivalent read-only mapping inline instead of stopping. Track each helper (spawned or inline) with its role and model-tag for the roster.
2. Ask the user clarifying questions ONLY if an architectural fork cannot be resolved from the codebase.
3. Draft a decision-complete implementation plan in `.muse/PLAN.md` with exact file paths, dependency order, and verification commands. If the file already has a `## Execution Log & Decisions` section, preserve it verbatim at the bottom — it is the durable handoff record from any prior execution session; do not overwrite it unless the user explicitly asks to reset the plan.
4. Plan Grill (degrades gracefully):
   1. Audit `.muse/PLAN.md` against the actual files in the repository. Prefer spawning a read-only `plan-reviewer` subagent if available; if that spawn fails, perform the same critique inline.
   2. If custom-coder is available, call `custom-coder:critique_plan` (endpoint `grill-reviewer` when present) for an independent adversarial review (in parallel with the native review when practical). If custom-coder is unavailable or the call fails, skip it, warn the user that the self-hosted critique was not run, and proceed with the native/inline review only.
   3. Synthesize available critiques, resolve any valid issues in `.muse/PLAN.md`, and present a summary of what was caught (and any endpoint warning), including the **Subagents / Models** roster, before asking the user for `/squad-execute` sign-off.
