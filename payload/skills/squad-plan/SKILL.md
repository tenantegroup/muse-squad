---
name: squad-plan
description: Member-scoped, explore-first planning mode that writes a decision-complete plan before coding.
---
You are in SQUAD-PLAN mode. Do NOT edit product code yet.

## Named members and project memory (read first)

At startup, read `~/.config/muse/muse-squad.toml` (`schema = 1`) and the generated roster at `~/.config/muse/squad/team.md`. Use only the members defined under `[squad.<name>]`; every step goes to a named member. Match each step to that member's `charter`. If no charter fits, ask the user which member should own the step instead of inventing a helper.

If `.muse/squad/` does not exist in this repository yet, create `.muse/squad/decisions.md` and `.muse/squad/history/` before starting. Every named member reads `.muse/squad/decisions.md` and `.muse/squad/history/<name>.md` before starting, and appends concise lasting learnings to its own history file when finished. Ask the `@secretary` member to append durable decisions to `.muse/squad/decisions.md` before sign-off.

## TUI labels and reporting

When spawning any subagent, set its short task label exactly to:

`[<name> | <provider-name>] <concise action>`

- `<name>` is the member's lowercase name from `[squad.<name>]`.
- `<provider-name>` is the provider actually serving the step: the member's `primary` for native work, or the HTTP provider that answered through `muse-squad` for delegated work. Use the provider name exactly as written in the TOML. Never guess it from a charter or invent a model tag.
- Keep the action under ~50 characters; start with a verb; no trailing punctuation.
- Add no parenthetical text and no second field.

Examples:

```text
[team-lead | Muse-Spark] Review architecture
[frontend | Home-Ornith] Sketch login form changes
[backend | DeepSeek-Flash] Map retry queue changes
[tester | Home-Ornith] List verification commands
[secretary | Muse-Ember] Record plan decisions
```

Always include a "Subagents / Providers" roster in user-facing summaries and before asking for sign-off. For each entry list the member name, provider, action, and outcome. For `muse-squad` tool calls, report the member, the provider shown in tool meta, and the outcome; if meta is unavailable, say so explicitly.

## Provider limits and health (read first)

At the start, call `muse-squad:list_providers` (or read `muse-squad.toml`) to learn each provider's `enabled`, `max_concurrency`, `max_input_chars`, and `type`. Native providers are built into Muse and cannot be called by the MCP router; the router skips them and tries that member's HTTP providers in chain order. Providers with `enabled = false` are skipped entirely, including as a configured primary.

- Never spawn more simultaneous native subagents of one native provider than its `max_concurrency`; batch extra exploration into later waves.
- Parallel calls to `muse-squad` are safe: the router queues requests and serializes them per HTTP provider's `max_concurrency`.
- Use `muse-squad:member_status("<name>")` to inspect a member's chain before assigning a large step.

## Member-scoped routing and quota retries

`muse-squad:generate_code` and `muse-squad:critique_plan` are member-scoped:

- `generate_code(member, prompt|task_spec, context|file_context, optional system/temperature/max_tokens)`
- `critique_plan(member, plan_markdown, optional repo_context/temperature/max_tokens)`

The router resolves the named member's `primary` first, then its `fallback` providers in order. Native providers are skipped by the router; HTTP providers are tried in chain order. Disabled providers are skipped entirely, even when listed as `primary`. There is no global fallback and no silent model switching.

- **Native-primary member:** run the native subagent first. If the configured primary is disabled, skip the native turn and follow the generated wrapper's pinned provider. If it fails because of quota, rate limits, or subscription limits, retry that exact step through `muse-squad:critique_plan` (plan and review steps) or `muse-squad:generate_code` (code and diff steps) with `member="<name>"`. The router uses that member's HTTP fallbacks. Do not treat the failed native turn as the member's result.
- **HTTP-primary member:** the generated wrapper pins a lightweight native runner and delegates heavy work to `muse-squad` with `member="<name>"`.

If the member chain cannot serve the request, the tool returns a hard error listing every attempt. Stop planning, report the error and its attempts verbatim, and ask the user to fix that member's chain with `/squad-team`. Do not retry with a different member, a different provider, or inline work.

## Context size

When calling `muse-squad`, keep `repo_context`, `file_context`, and `plan_markdown` short and relevant. Check the target HTTP provider's `max_input_chars` before sending; send only the needed files or excerpts. If a reply starts with the input-truncated warning, shorten the context and re-ask instead of trusting the critique.

## Planning steps

1. Map the relevant files, dependencies, and existing patterns using named members only.
2. Ask the user clarifying questions only if an architectural fork cannot be resolved from the codebase.
3. Draft a decision-complete implementation plan in `.muse/PLAN.md` with exact file paths, dependency order, and verification commands. If the file already has a `## Execution Log & Decisions` section, preserve it verbatim at the bottom.
4. Plan grill: ask the architecture charter member (default `@team-lead`) to audit `.muse/PLAN.md` against the actual files, then request an independent critique through `muse-squad:critique_plan` with `member="<name>"` for that same member. Synthesize valid issues into `.muse/PLAN.md` and ask `@secretary` to append durable choices to `.muse/squad/decisions.md`.
5. Present a summary of what was caught, including the Subagents / Providers roster, before asking the user for `/squad-execute` sign-off.
