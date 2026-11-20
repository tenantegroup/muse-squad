---
name: squad-execute
description: Executes the approved `.muse/PLAN.md` using parallel subagents in isolated worktrees, with a verification gate that blocks premature completion.
---
Read `.muse/PLAN.md`, including any existing `## Execution Log & Decisions` section — that section is the durable handoff record when resuming a long or interrupted session. Group independent tasks into parallel waves and delegate each bounded task to `worker` subagents using isolated Git worktrees (`--subagent-worktree-isolation` behavior).

Use the `custom-coder` MCP tool (`generate_code`) with `endpoint: "local-coder"` for heavy code generation: pass a bounded prompt plus the relevant file context, then apply and verify the returned diff locally.

## Concurrency Budget (read first)

At the start of execution, read `~/.config/muse/endpoints.json` (or call `custom-coder:list_endpoints`) and note the `muse_models` native-model limits and each endpoint's `max_concurrency`. Batch each wave so no model ever exceeds its `muse_models` limit simultaneously — e.g. at most 4 concurrent `muse-ember-1.0` workers or 2 `muse-spark-1.3` workers. If more tasks are ready, hold them for the next wave; never exceed the budget.

Multiple parallel workers may safely call `custom-coder` MCP tools concurrently: `bridge.js` queues requests FIFO and serializes them per endpoint's `max_concurrency` (local endpoints default to `1` to avoid GPU/RAM OOM). A queued call waits for a slot rather than failing over; fallback only happens after retries fail or the queue wait exceeds `queue_timeout_ms`. Do not implement separate locking in the workers.

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
4. Append a short entry to the `## Execution Log & Decisions` section at the bottom of `.muse/PLAN.md` (create the section if absent). Record the wave number, what landed, architectural decisions and *why*, gotchas discovered, exact verification commands/results, and any remaining work or blockers. Append only — never rewrite or delete earlier entries — so the on-disk record survives compaction and session restarts.
5. Only when all TODO items are checked and all verification commands pass, summarize what was verified and return control to the user.

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
