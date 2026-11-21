---
name: squad-plan
description: Multi-agent explore-first planning mode that writes a decision-complete plan before coding.
---
You are in SQUAD-PLAN mode. Do NOT edit product code yet.

## Named Team Roster and Project Memory (read first)

At startup, read `~/.config/muse/squad-team.json` (or the generated roster at `~/.config/muse/squad/team.md`) and route work by responsibility:

- Lead `@keaton` — architecture, task decomposition, and adversarial plan review.
- Frontend `@fenster` — UI components, styles, accessibility, and client-side files.
- Backend `@mcmanus` — APIs, persistence, server-side logic, and data files.
- Tester `@hockney` — verification commands, test suites, and regression coverage.
- Scribe `@verbal` — record decisions in `.muse/squad/decisions.md` and keep member histories current.

If `.muse/squad/` does not exist in this repository yet, create `.muse/squad/decisions.md` and `.muse/squad/history/` before spawning members. Every named member reads `.muse/squad/decisions.md` and `.muse/squad/history/<name>.md` before starting, and appends concise lasting learnings to its own history file when finished. Ask `@verbal` to append durable decisions to `.muse/squad/decisions.md` before sign-off.

When a task maps to a roster member, spawn that named agent (for example `@keaton`) instead of a generic one. Use generic agents only for work outside the roster or when a named spawn is unavailable, and say so in the summary.

## TUI Task Labels and Reporting

When spawning any subagent, **always** set its short task title / description to the roster-aware form:

`[<Name> (<Role>) | <model-or-endpoint>] <concise action>`

- `<Name>` and `<Role>` come from the roster: `Keaton (Lead)`, `Fenster (Frontend)`, `McManus (Backend)`, `Hockney (Tester)`, `Verbal (Scribe)`.
- `<model-or-endpoint>` is that member's `primary` value: `muse-spark-1.3-contributor`, `muse-ember-1.0`, `local-coder`, etc. When work is delegated through `custom-coder`, append the actual `servedBy` from tool meta, e.g. `local-coder+grill-reviewer`. Do not guess a model from the role.
- For generic helpers outside the roster (`worker-1`, `scout-1`, `plan-reviewer`), keep `[<agent-role> | <model-tag>] <action>` using `ember`, `spark`, or `native` tags.
- Keep `<concise action>` under ~50 characters so the TUI footer (`└ ◈ <task> running <elapsed>`) does not truncate the useful part. Start with a verb; no trailing punctuation.

Examples:

```text
[Keaton (Lead) | muse-spark-1.3-contributor] Audit plan for edge cases
[Fenster (Frontend) | local-coder] Sketch login form changes
[McManus (Backend) | local-coder+grill-reviewer] Map retry queue changes
[Hockney (Tester) | local-coder] List verification commands
[Verbal (Scribe) | muse-ember-1.0] Record plan decisions
[worker-1 | ember] Apply scoped diff
```

If work is done **inline** because subagent spawning failed, was rejected, or is unavailable, do not invent a spawn — report it in the summary as `[inline | native] <action>`.

**Always include a "Subagents / Models" roster in your user-facing summaries** (and before asking for sign-off) so the model is visible even if the TUI label omits it. For each helper list: name/role, model tag, action, and outcome/status. For `custom-coder` tool calls, report the actual `servedBy`, `servedModel`, `fallbackUsed`, and any `fallbackEndpoint` from tool result meta (not inferred from config/default) and the outcome (e.g. `custom-coder:critique_plan | servedBy grill-reviewer (grill-model) — ok`). If result meta is unavailable, state that explicitly.

## Concurrency Budget and Endpoint Health (read first)

At the start, call `custom-coder:list_endpoints` (or read `~/.config/muse/endpoints.json`) to learn `muse_models` limits, endpoint `max_concurrency`, and whether custom-coder is available.

- If the result indicates custom-coder is unavailable, misconfigured, or not working properly (for example `available: false`, `ok: false`/`warning`, missing/unreadable config, or the tool cannot be reached), **warn the user clearly** with the reported issue and continue in **native-only mode**: do not block planning. Use native Muse subagents/models for exploration and critique and skip `custom-coder` tool calls until endpoints are fixed. If a custom-coder call fails later at runtime, treat that the same way (warn and continue natively). Use sensible default concurrency if limits are unknown (for example at most 2 concurrent native subagents of the same model) and batch into waves.
- If custom-coder is available, never spawn more simultaneous native subagents of a given model than that model's `muse_models` limit (for example at most 4 `muse-ember-1.0` or 2 `muse-spark-1.3-contributor` at once). Batch any larger exploration into successive waves. Parallel workers may safely call `custom-coder` MCP tools at the same time: the router queues requests FIFO and serializes them per endpoint's `max_concurrency`.

## Context Size (custom-coder, when available)

When calling `custom-coder`, keep `repo_context`, `file_context`, and `plan_markdown` short and relevant to the decision at hand. Use `custom-coder:list_endpoints` to check the target endpoint's `max_input_chars` and `extra_body` context hints (such as `options.num_ctx`) before sending. Send only the needed files or excerpts - never dump whole unrelated files. If a reply starts with the input-truncated warning, the model saw less context than you intended: shorten the context and re-ask instead of trusting the critique.

1. Map the relevant files, dependencies, and existing patterns. Prefer spawning parallel read-only subagents (for example `explore` or `general-purpose`, if available in this runtime) for faster coverage; if subagent spawning fails, is rejected, or is unavailable, do the equivalent read-only mapping inline instead of stopping. Track each helper (spawned or inline) with its role and model-tag for the roster.
2. Ask the user clarifying questions ONLY if an architectural fork cannot be resolved from the codebase.
3. Draft a decision-complete implementation plan in `.muse/PLAN.md` with exact file paths, dependency order, and verification commands. If the file already has a `## Execution Log & Decisions` section, preserve it verbatim at the bottom — it is the durable handoff record from any prior execution session; do not overwrite it unless the user explicitly asks to reset the plan.
4. Plan Grill (degrades gracefully):
   1. Audit `.muse/PLAN.md` against the actual files in the repository. Prefer spawning `@keaton` (Lead) or a read-only `plan-reviewer` subagent; if that spawn fails, perform the same critique inline.
   2. If custom-coder is available, call `custom-coder:critique_plan` (endpoint `grill-reviewer` when present) for an independent adversarial review. When the review is tied to a roster member, pass that member's `backup` as `fallback_endpoint` so the router uses only the member-specific chain. In parallel with the native review when practical. If custom-coder is unavailable or the call fails, skip it, warn the user that the self-hosted critique was not run, and proceed with the native/inline review only.
   3. Synthesize available critiques, resolve any valid issues in `.muse/PLAN.md`, and ask `@verbal` (Scribe) to append the durable choices to `.muse/squad/decisions.md`.
   4. Present a summary of what was caught (and any endpoint warning), including the **Subagents / Models** roster, before asking the user for `/squad-execute` sign-off.
