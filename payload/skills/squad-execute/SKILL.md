---
name: squad-execute
description: Executes the approved .muse/PLAN.md with named squad members and a verification gate that blocks premature completion.
---

## Named members and project memory (read first)

At startup, read `~/.config/muse/muse-squad.toml` and the generated roster at `~/.config/muse/squad/team.md`. Use only the members defined under `[squad.<name>]`. All implementation and review goes through named members; there are no unnamed helpers. Match each task to a member's `charter`, and ask the user which member owns a step if no charter fits.

If `.muse/squad/` does not exist yet, create `.muse/squad/decisions.md` and `.muse/squad/history/`. Every member reads both files before starting and appends concise lasting learnings when finished. Use isolated Git worktrees for bounded implementation tasks where available.

## TUI labels and reporting

When spawning any subagent, set its short task label exactly to:

`[<name> | <provider-name>] <concise action>`

- `<name>` is the member's lowercase name from `[squad.<name>]`.
- `<provider-name>` is the provider actually serving the step: the member's `primary` for native work, or the HTTP provider that answered through `muse-squad` for delegated work. Use the provider name exactly as written in the TOML; never guess it from a charter or invent a model tag.
- Keep the action under ~50 characters; start with a verb; no trailing punctuation.
- Add no parenthetical text and no second field.

Examples:

```text
[keaton | Muse-Spark] Sequence wave dependencies
[fenster | Home-Ornith] Build login form
[mcmanus | DeepSeek-Flash] Add retry queue
[hockney | Home-Ornith] Run regression suite
[verbal | Muse-Ember] Log wave decisions
```

Always include a "Subagents / Providers" roster in wave, progress, and completion summaries. For each entry list the member name, provider, action, and outcome. For `muse-squad` tool calls, report the member, the provider shown in tool meta, and the outcome; if meta is unavailable, say so explicitly. When practical, include the member name and provider in execution-log entries.

## Provider limits, health, and member-scoped routing (read first)

At the start, call `muse-squad:list_providers` (or read `muse-squad.toml`) to learn each provider's `type`, `max_concurrency`, and `max_input_chars`. Use `muse-squad:member_status("<name>")` to inspect a member's chain before assigning work. Native providers are built into Muse and cannot be called by the MCP router; the router skips them and tries that member's HTTP providers in chain order.

`muse-squad:generate_code` and `muse-squad:critique_plan` are member-scoped:

- `generate_code(member, prompt|task_spec, context|file_context, optional system/temperature/max_tokens)`
- `critique_plan(member, plan_markdown, optional repo_context/temperature/max_tokens)`

The router resolves the named member's `primary` first, then its `fallback` providers in order. There is no global fallback and no silent model switching.

- **Native-primary member:** run the native subagent first. If it fails because of quota, rate limits, or subscription limits, retry that exact step through `muse-squad:generate_code` (implementation steps) or `muse-squad:critique_plan` (reviews) with `member="<name>"`. The router uses that member's HTTP fallbacks. Do not treat the failed native turn as the member's result.
- **HTTP-primary member:** the generated wrapper pins a lightweight native runner and delegates heavy work to `muse-squad` with `member="<name>"`.
- Parallel calls to `muse-squad` are safe: the router queues requests and serializes them per HTTP provider's `max_concurrency`. Do not add separate locking in members.

**Errors stop the wave.** If any member chain returns a hard error, stop the current wave immediately, report the error and every attempted provider verbatim, and ask the user to fix that member's chain with `/squad-team`. Do not retry with a different member, a different provider, or inline work, and do not advance to the next wave.

## Context size

Before each `generate_code` call, check the target HTTP provider's `max_input_chars`. Keep `file_context` (and any `repo_context`) to the smallest excerpts that explain the change — no whole-file dumps, logs, or unrelated tests. If the reply starts with the input-truncated warning, shorten the context and re-ask; do not apply a diff generated from cut-off context.

## Patch discipline (diffs, not full rewrites)

- Ask `generate_code` for a targeted unified diff (`git apply` format) for existing files. A single targeted function or block with its path and line range is acceptable when a diff is impractical; a full-file rewrite is not.
- The orchestrator — the native runner in the wrapper, or any model with native `Edit` tools — applies each hunk surgically, preserving the rest of the file. Do not overwrite whole files with generated output.
- Reject and re-prompt if the result is a full file, truncated content, `...`/placeholders, or an unapplyable diff. Never repair omitted code by guessing.
- Run the fastest incremental check on changed files, then the Verification Gate after applying patches.

## Verification gate (do not stop until verified)

You are not done and must not return control to the user while any `.muse/TODO.md` item is unchecked or while any verification command fails.

Read `.muse/PLAN.md`, including any existing `## Execution Log & Decisions` section; it is the durable handoff record when resuming a long or interrupted session. Group independent tasks into successive waves. After every wave — before advancing and before reporting completion:

1. Update `.muse/TODO.md` (create it from the plan if it does not exist). Check off only items whose changes are applied and verified; leave or add `- [ ]` items for remaining or newly discovered work. Record exact verification commands and results in the checklist.
2. Run every verification command listed in `.muse/PLAN.md` from the repository root — for example `npm test`, `cargo check`, `pytest`, or `go test ./...`. If the plan lists none, detect the project's typechecker and test commands from its manifests, add them to `.muse/TODO.md`, and run them.
3. If any command fails, fix the failure in another bounded wave with the appropriate named member and repeat this gate. Never mark an item done or claim success based on a partial pass.
4. Append a short entry to `## Execution Log & Decisions` at the bottom of `.muse/PLAN.md` (create the section if absent). Record the wave number, what landed, decisions and *why*, gotchas discovered, exact verification commands and results, and any remaining work or blockers. Append only — never rewrite or delete earlier entries. Ask `@verbal` to append durable decisions to `.muse/squad/decisions.md` and each member to append lasting learnings to its own `.muse/squad/history/<name>.md`.
5. Only when all TODO items are checked and all verification commands pass, summarize what was verified and return control to the user, including the Subagents / Providers roster for the run.

## Session handoff notes

The `## Execution Log & Decisions` section in `.muse/PLAN.md` is authoritative state, not chat history. Keep entries short (a few bullets per wave) and append-only:

```markdown
## Execution Log & Decisions

### Wave 2 - 2026-11-21
- Landed: retry/backoff in mcp/bridge.js; TOML defaults refreshed.
- Decision: 4xx is non-retryable - an invalid key must fail fast, not burn chain attempts. Reason: silent auth failures wasted a wave earlier.
- Gotcha: fallback notices belong in MCP `meta`, not tool text, or `git apply` breaks.
- Verified: `node --check mcp/bridge.js` PASS; `npm test` PASS.
- Remaining: Windows installer still untested locally (no pwsh).
```

On resume, read this section first and continue from the last entry instead of re-deriving decisions from scratch. If a later wave reverses a decision, append a new entry saying so with the reason — do not edit history.
