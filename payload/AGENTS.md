## Muse Squad Default Delegation Policy

This block is managed by muse-squad. Put durable changes in the muse-squad repo payload and re-run the installer; edits inside this block are replaced on update. Text outside the block is yours and is never overwritten.

### Proactive subagent delegation

In ordinary Muse Code sessions - even without `/squad-plan` or `/squad-execute` - delegate self-contained work to the installed agents:

- `worker` / `general-purpose`: bounded code edits, refactors, bug fixes, and unit-test implementation outside the named roster.
- Read-only exploration helpers: codebase mapping and investigation.
- `plan-reviewer`: review plans, designs, or risky diffs before implementation.
- Named `@team` members: use the persistent roster for recurring roles (see below).

Keep the main session focused on decisions and integration. Delegating scoped work preserves the main context window and subscription quota.

### Persistent named team

Read `~/.config/muse/squad-team.json` (or the generated `~/.config/muse/squad/team.md`) and use `@<name>` for recurring work in normal sessions. In a repository, prefer `.agents/squad/team.md` and `.agents/agents/<name>.md` when present; those project-scoped files override the global roster and wrappers:

- `@keaton` (Lead): architecture, decomposition, and plan review.
- `@fenster` (Frontend): UI components, styles, and client-side files.
- `@mcmanus` (Backend): APIs, persistence, and server-side files.
- `@hockney` (Tester): verification, test suites, and regression coverage.
- `@verbal` (Scribe): durable decisions and handoff notes.

Use `/squad-team` for targeted roster changes; generated wrappers and the roster page are not hand-edited. Each member has a charter, a `primary` model/endpoint, and a `backup`. For `custom-coder` calls, pass the member's `backup` as `fallback_endpoint` so only that member's chain is used. In a repository, initialize `.muse/squad/decisions.md` and `.muse/squad/history/` on first use. Named members read both the shared decisions file and their own history file before work, and append concise lasting learnings when finished. `@verbal` appends decisions after each wave or plan sign-off.

### Cost-saving custom-coder routing

When `custom-coder` is available, prefer it for boilerplate generation, unit-test drafting, and secondary code or plan critiques:

- `generate_code` for small, scoped diffs.
- `critique_plan` for a second opinion on plans and designs.
- `list_endpoints` and `coder_status` to check aliases, limits, and health before batching work.
- `/squad-doctor` when routing looks broken: it checks MCP registration, live `/v1/models` reachability for every alias, and roster/wrapper drift without using `custom-coder` or printing keys.

Use the aliases and limits in `~/.config/muse/endpoints.json`. Treat `servedBy`, `servedModel`, and `fallbackUsed` from tool result `meta` as the source of truth. If the tool reports that it is unavailable or misconfigured, warn once and continue with native tools.

If a named native subagent fails with a quota, rate-limit, or subscription error, the orchestrator retries that exact step through `custom-coder` using that member's `backup` as both `endpoint` and `fallback_endpoint`. Report the retry with the actual `servedBy` / `fallbackUsed`; never treat the failed turn as the member's result or silently switch models. Only fall back to inline/native work if custom-coder cannot serve the retry, and say so explicitly.

### Global guardrails

- Respect the `muse_models` concurrency caps for parallel native subagents. Extra work waits for a later wave.
- Format every spawned subagent's short task description exactly as `[<Name> (<Role>) | <model-or-endpoint>] <concise action>` for named members (for example `[Fenster (Frontend) | local-coder] Build login form`), or `[<agent-role> | <model-tag>] <concise action>` for generic helpers. Keep the action under ~50 characters; never guess a model from the role.
- Include a short Subagents / Models roster in user-facing summaries when delegation is used.
- Apply generated code surgically: a targeted unified diff or a single function/block with native edit tools. Reject full-file rewrites, truncation markers, and unapplyable diffs.
- Run the fastest incremental check on changed files immediately after each patch. Full builds and full test suites belong to the final verification step.
- Never call work done until verification passes or the remaining gaps are stated explicitly.

### Keep normal sessions lightweight

Do not create `.muse/PLAN.md` in a normal session unless `/squad-plan` is invoked or the user explicitly asks for a formal multi-wave plan. Wave batching, execution logs, and the strict verification gate are for the slash commands. In normal sessions, use the guardrails above with a brief task brief instead.
