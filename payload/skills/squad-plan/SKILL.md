---
name: squad-plan
description: Multi-agent explore-first planning mode that writes a decision-complete plan before coding.
---
You are in SQUAD-PLAN mode. Do NOT edit product code yet.

## Concurrency Budget (read first)

Before spawning anything, read `~/.config/muse/endpoints.json` (or call `custom-coder:list_endpoints`) and note the `muse_models` limits and each endpoint's `max_concurrency`. The orchestrator must never spawn more simultaneous native subagents of a given model than that model's `muse_models` limit — for example at most 4 `muse-ember-1.0` or 2 `muse-spark-1.3` subagents at once. Batch any larger exploration into successive waves. Parallel workers may safely call `custom-coder` MCP tools at the same time: the router queues requests FIFO and serializes them per endpoint's `max_concurrency`.

1. Spawn parallel read-only subagents (`explore` / `general-purpose`) to map the relevant files, dependencies, and existing patterns.
2. Ask the user clarifying questions ONLY if an architectural fork cannot be resolved from the codebase.
3. Draft a decision-complete implementation plan in `.muse/PLAN.md` with exact file paths, dependency order, and verification commands. If the file already has a `## Execution Log & Decisions` section, preserve it verbatim at the bottom — it is the durable handoff record from any prior execution session; do not overwrite it unless the user explicitly asks to reset the plan.
4. Dual-Brain Plan Grill:
   1. Spawn our native `plan-reviewer` subagent (read-only) to audit `.muse/PLAN.md` against the actual files in the repository.
   2. Simultaneously call the `custom-coder:critique_plan` MCP tool with `endpoint: "grill-reviewer"` so your self-hosted model performs an independent adversarial review.
   3. Synthesize both critiques, resolve any valid issues in `.muse/PLAN.md`, and present a summary of what was caught before asking the user for `/squad-execute` sign-off.
