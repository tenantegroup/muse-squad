## Muse Squad Default Delegation Policy

This block is managed by muse-squad. Put durable changes in the muse-squad repo payload and re-run the installer; edits inside this block are replaced on update. Text outside the block is yours and is never overwritten.

### One config, one roster

`~/.config/muse/muse-squad.toml` is the single source of truth (`schema = 1`). It holds the AI providers and the squad in one TOML file. There is no second config file and no migration step; edit the TOML directly or use `/squad-team`.

- Providers live under `[providers.<Name>]`. `type = "native"` providers are built into Muse; `type = "http"` providers point at an OpenAI-compatible server.
- Members live under `[squad.<name>]` and define only `primary`, an ordered `fallback` array, and a `charter`. At least one member is required.
- The generated roster is `~/.config/muse/squad/team.md`; generated member wrappers are `~/.config/muse/agents/<name>.md`. Do not hand-edit generated files.

### Delegate through named members only

All implementation, exploration, and review work goes to a named squad member invoked with `@<name>`. There are no unnamed helpers to fall back to. Keep the main session focused on decisions and integration.

Match work to the `charter` text in the config, never to a guessed specialty. If no member's charter clearly fits, ask the user which member should own the step instead of inventing a helper.

### Muse MCP routing

The MCP server is `muse-squad`. It exposes:

- `generate_code(member, prompt|task_spec, context|file_context, optional system/temperature/max_tokens)`
- `critique_plan(member, plan_markdown, optional repo_context/temperature/max_tokens)`
- `member_status(member?)` — omit `member` for an overview.
- `list_providers`

`generate_code` and `critique_plan` are member-scoped. The router resolves that member's `primary` first, then its `fallback` providers in order. Native providers cannot be called by the router; they are skipped, and the router tries that member's HTTP providers in chain order. If no provider in the member's chain can serve the request, the tool returns a hard error listing every attempt. There is no global fallback and no silent model switching.

- For a native-primary member, run the native subagent first. If it fails because of quota, rate limits, or subscription limits, retry that same step through `muse-squad:generate_code` or `muse-squad:critique_plan` with `member="<name>"`. The router uses that member's HTTP fallbacks. Do not treat the failed native turn as the member's result.
- For an HTTP-primary member, the generated wrapper pins a lightweight native runner and delegates heavy work to `muse-squad:generate_code` or `muse-squad:critique_plan` with `member="<name>"`.
- Use `member_status` and `list_providers` to inspect limits and health before batching work. API keys are redacted.

### Global guardrails

- Label every spawned subagent exactly as `[<name> | <provider-name>] <action>` — for example `[team-lead | Muse-Spark] Review architecture`. Use the member's lowercase name and the provider name exactly as written in the TOML. Keep the action under ~50 characters, start with a verb, and add no extra parenthetical text.
- Respect each provider's `max_concurrency` for parallel work; queue extra work into a later wave.
- Apply generated code surgically: a targeted unified diff or a single function/block with native edit tools. Reject full-file rewrites, truncation markers, and unapplyable diffs.
- Run the fastest incremental check on changed files immediately after each patch. Full builds and full test suites belong to the final verification step.
- Never call work done until verification passes or the remaining gaps are stated explicitly. If a member chain returns a hard error, stop and report the attempts; do not switch to a provider outside that member's chain.

### Project memory

Initialize `.muse/squad/decisions.md` and `.muse/squad/history/` on first use. Each named member reads both the shared decisions file and its own history file before work and appends concise lasting learnings when finished. Append durable decisions after each wave or plan sign-off.

### Keep normal sessions lightweight

Do not create `.muse/PLAN.md` in a normal session unless `/squad-plan` is invoked or the user explicitly asks for a formal multi-wave plan. Wave batching, execution logs, and the strict verification gate are for the slash commands. In normal sessions, use the guardrails above with a brief task brief instead.
