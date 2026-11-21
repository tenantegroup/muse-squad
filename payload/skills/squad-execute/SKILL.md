---
name: squad-execute
description: Executes the approved `.muse/PLAN.md` using parallel subagents in isolated worktrees, with a verification gate that blocks premature completion.
---

## Named Team Roster and Project Memory (read first)

At startup, read `~/.config/muse/squad-team.json` (or the generated roster at `~/.config/muse/squad/team.md`). In this repository, prefer `.agents/squad/team.md` and the project wrappers in `.agents/agents/<name>.md` when present, then route each wave by responsibility:

- Lead `@keaton` — architecture, sequencing, and risk review for the wave.
- Frontend `@fenster` — UI components, styles, accessibility, and client-side files.
- Backend `@mcmanus` — APIs, persistence, server-side logic, and data files.
- Tester `@hockney` — verification commands, test suites, and regression coverage.
- Scribe `@verbal` — append decisions to `.muse/squad/decisions.md` after each wave and maintain history files.

If `.muse/squad/` does not exist in this repository yet, create `.muse/squad/decisions.md` and `.muse/squad/history/` before spawning members. Every named member reads `.muse/squad/decisions.md` and `.muse/squad/history/<name>.md` before starting, and appends concise lasting learnings to its own history file when finished.

Spawn named members for tasks that match their charter; use generic `worker` subagents only for work outside the roster or when the named spawn is unavailable. Keep isolated Git worktrees (`--subagent-worktree-isolation` behavior) for bounded implementation tasks.

## TUI Task Labels and Reporting

When spawning any subagent, **always** set its short task title / description to the roster-aware form:

`[<Name> (<Role>) | <model-or-endpoint>] <concise action>`

- `<Name>` and `<Role>` come from the roster: `Keaton (Lead)`, `Fenster (Frontend)`, `McManus (Backend)`, `Hockney (Tester)`, `Verbal (Scribe)`.
- `<model-or-endpoint>` is that member's `primary` value: `muse-spark-1.3-contributor`, `muse-ember-1.0`, `local-coder`, etc. When work is delegated through `custom-coder`, append the actual `servedBy` from tool meta, e.g. `local-coder+grill-reviewer`. Do not guess a model from the role.
- For generic helpers outside the roster (`worker-1`, `scout-1`, `plan-reviewer`), keep `[<agent-role> | <model-tag>] <action>` using `ember`, `spark`, or `native` tags.
- Keep `<concise action>` under ~50 characters so the TUI footer (`└ ◈ <task> running <elapsed>`) does not truncate the useful part. Start with a verb; no trailing punctuation.

Examples:

```text
[Keaton (Lead) | muse-spark-1.3-contributor] Sequence wave dependencies
[Fenster (Frontend) | local-coder] Build login form
[McManus (Backend) | local-coder+grill-reviewer] Add retry queue
[Hockney (Tester) | local-coder] Run regression suite
[Verbal (Scribe) | muse-ember-1.0] Log wave decisions
[worker-1 | ember] Apply scoped fix in api/
```

If work is done **inline** because subagent spawning failed, was rejected, or is unavailable, do not invent a spawn — report it in the summary as `[inline | native] <action>`.

**Always include a "Subagents / Models" roster in your user-facing wave/progress and completion summaries** so the model is visible even if the TUI label omits it. For each helper list: name/role, model tag, action, and outcome/status. For `custom-coder` tool calls, report the actual `servedBy`, `servedModel`, `fallbackUsed`, and any `fallbackEndpoint` from tool result meta (not inferred from config/default) and the outcome (e.g. `custom-coder:generate_code | servedBy local-coder (<model>) — ok`). If result meta is unavailable, state that explicitly. When practical, include name/role and model tag in execution-log entries.

## Native Quota Fallback for Named Members

If a named member's native primary (for example `@keaton` on `muse-spark-1.3-contributor`) fails with a quota, rate-limit, or subscription error, the orchestrator must retry the same step through `custom-coder` using that member's `backup` as the endpoint: `generate_code` for implementation steps, `critique_plan` for reviews. Pass the backup as both `endpoint` and `fallback_endpoint`. Apply and verify the returned diff exactly as for any other `custom-coder` result. Do not treat the failed native turn as the member's result, silently switch to another native model, or mark the wave done until the retry succeeds or the gap is stated explicitly. If custom-coder is unavailable for that retry, warn clearly before falling back to inline/native work. Record the retry in the Subagents / Models roster and the execution log with the actual `servedBy` / `fallbackUsed` from tool meta.

Read `.muse/PLAN.md`, including any existing `## Execution Log & Decisions` section - that section is the durable handoff record when resuming a long or interrupted session. Group independent tasks into successive waves and track each helper (spawned or inline) with its name/role and model tag for the roster.

## Endpoint Health and Execution Mode (read first)

At the start, call `custom-coder:list_endpoints` (or read `~/.config/muse/endpoints.json`) to learn `muse_models` limits and whether custom-coder is available.

- If custom-coder is unavailable, misconfigured, or not working properly (for example `available: false`, `ok: false`/`warning`, missing/unreadable config, or unreachable), **warn the user clearly** with the reported issue and continue in **native-only mode**: do not block execution. Have workers implement changes directly with native Muse tools/editing instead of calling `custom-coder:generate_code`, and skip `custom-coder` critiques. If a custom-coder call fails later at runtime, treat that the same way (warn and continue natively). Use sensible default concurrency if limits are unknown (for example at most 2 concurrent native workers of the same model) and batch into waves.
- If custom-coder is available, use `custom-coder:generate_code` (endpoint `local-coder` when present) for heavy code generation when helpful: pass a bounded prompt plus relevant file context, then apply and verify the returned diff locally. For a named member, use that member's `primary` as `endpoint` and its `backup` as `fallback_endpoint` so the router does not traverse an unrelated global chain. Never spawn more simultaneous native subagents of a given model than `muse_models` allows (for example at most 4 `muse-ember-1.0` or 2 `muse-spark-1.3-contributor` workers). Batch waves to respect limits.

Multiple parallel workers may safely call `custom-coder` MCP tools concurrently when available: `bridge.js` queues requests FIFO and serializes them per endpoint's `max_concurrency` (local endpoints default to `1` to avoid GPU/RAM OOM). A queued call waits for a slot rather than failing over; fallback only happens after retries fail or the queue wait exceeds `queue_timeout_ms`. Do not implement separate locking in the workers.

## Context Size (custom-coder, when available)

Before each `generate_code` call, check the target endpoint's `max_input_chars` and `extra_body` context hints (such as `options.num_ctx`). Keep `file_context` (and any `repo_context`) to the smallest excerpts that explain the change - no whole-file dumps, logs, or unrelated tests. If the reply starts with the input-truncated warning, shorten the context and re-ask; do not apply a diff generated from cut-off context.

## Patch Discipline (Diffs, Not Full Rewrites)

- Ask `generate_code` for a targeted unified diff (`git apply` format) for existing files. A single targeted function or block with its path and line range is acceptable when a diff is impractical; a full-file rewrite is not.
- The orchestrator — `muse-ember-1.0`, or any model with native `Edit` tools — applies each hunk surgically with `Edit`, preserving the rest of the file. Do not overwrite whole files with local-model output.
- Reject and re-prompt if the model returns a full file, truncated content, `...`/placeholders, or an unapplyable diff. Never "repair" omitted code by guessing.
- Run Instant Diagnostics and then the Verification Gate after applying patches.

## Verification Gate (Do Not Stop Until Verified)

You are not done and must not return control to the user while any `.muse/TODO.md` item is unchecked or while any verification command fails.

After every wave — before advancing to the next wave and before reporting completion:

1. Update `.muse/TODO.md` (create it from the plan if it does not exist). Check off only items whose changes are applied and verified; leave or add `- [ ]` items for remaining or newly discovered work. Record the exact verification commands and their results in the checklist.
2. Run every verification command listed in `.muse/PLAN.md` from the repository root — for example `npm test`, `cargo check`, `pytest`, or `go test ./...`. If the plan lists none, detect the project's typechecker and test commands from its manifests, add them to `.muse/TODO.md`, and run them.
3. If any command fails, fix the failure in another bounded wave (delegating to a `worker` where appropriate) and repeat this gate. Never mark an item done or claim success based on a partial pass.
4. Append a short entry to the `## Execution Log & Decisions` section at the bottom of `.muse/PLAN.md` (create the section if absent). Record the wave number, what landed, architectural decisions and *why*, gotchas discovered, exact verification commands/results, and any remaining work or blockers. Append only — never rewrite or delete earlier entries — so the on-disk record survives compaction and session restarts. Ask `@verbal` (Scribe) to append durable decisions to `.muse/squad/decisions.md` and each member to append lasting learnings to its own `.muse/squad/history/<name>.md`.
5. Only when all TODO items are checked and all verification commands pass, summarize what was verified and return control to the user, including the **Subagents / Models** roster for the run (per wave where useful).

## Session Handoff Notes

The `## Execution Log & Decisions` section in `.muse/PLAN.md` is authoritative state, not chat history. Keep entries short (a few bullets per wave) and append-only:

```markdown
## Execution Log & Decisions

### Wave 2 — 2026-11-20
- Landed: retry/backoff in mcp/bridge.js; endpoints seed config updated.
- Decision: 4xx is non-retryable — an invalid key must fail fast, not burn fallback attempts. Reason: silent auth failures wasted a wave earlier.
- Gotcha: fallback notice must stay in MCP `meta`, not tool text, or `git apply` breaks.
- Verified: `scripts/test-install.sh` PASS; `node --check mcp/bridge.js` PASS.
- Remaining: PowerShell installer still untested locally (no pwsh).
```

On resume, read this section first and continue from the last entry instead of re-deriving decisions from scratch. If a later wave reverses a decision, append a new entry saying so with the reason — do not edit history.
