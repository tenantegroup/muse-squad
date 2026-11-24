## Muse Squad Default Delegation Policy

This block is managed by muse-squad. Put durable changes in the muse-squad repo payload and re-run the installer; edits inside this block are replaced on update. Text outside the block is yours and is never overwritten.

### One config, one roster

`~/.config/muse/muse-squad.toml` is the single source of truth (`schema = 1`). It holds the AI providers and the squad in one TOML file. The installer keeps its own version state in `.muse-squad-state.json` beside it and never adds settings here; edit the TOML directly or use `/squad-team`.

The Muse config directory is outside the workspace, so file tools cannot `Read` these paths from a project session. Inspect the squad with `muse-squad:member_status` and `muse-squad:list_providers`; use `/squad-team` for config changes.

- Providers live under `[providers.<Name>]`. `type = "native"` providers are built into Muse; `type = "http"` providers point at an OpenAI-compatible server. Every provider has `enabled = true` by default; set `enabled = false` to disable one without removing it from member chains.
- Members live under `[squad.<name>]` and define only `primary`, an ordered `fallback` array, and a `charter`. At least one member is required. Default names are role IDs from the pinned `mcp/roles.js` catalog (`@lead`, `@backend`, `@reviewer`, ...); renamed members keep their TOML name, and installers never rewrite existing charters.
- The generated roster is `~/.config/muse/squad/team.md`; generated member wrappers are `~/.config/muse/agents/<name>.md`. Do not hand-edit generated files.

### Delegate through named members only

All implementation, exploration, and review work goes to a named squad member invoked with `@<name>`. There are no unnamed helpers to fall back to. Keep the main session focused on decisions and integration.

Match work to the `charter` text returned by `muse-squad:member_status`, never to a guessed specialty. If no member's charter clearly fits, ask the user which member should own the step instead of inventing a helper.

### Muse MCP routing

The MCP server is `muse-squad`. It exposes:

- `generate_code(member, prompt|task_spec, context|file_context, optional system/temperature/max_tokens)`
- `critique_plan(member, plan_markdown, optional repo_context/temperature/max_tokens)`
- `member_status(member?)` — omit `member` for an overview.
- `list_providers`
- `memory_status(repo_root)` — read-only report of repository-local `.muse-squad/` memory.
- `memory_init(repo_root, include_plan?)` — idempotently create `.muse-squad/` and copy legacy `.muse/` and `.muse/squad/` memory. `include_plan: true` is only for `/squad-plan` and `/squad-execute`.

`generate_code` and `critique_plan` are member-scoped. The router resolves that member's `primary` first, then its `fallback` providers in order. Native providers cannot be called by the router; they are skipped, and the router tries that member's HTTP providers in chain order. Providers with `enabled = false` are skipped entirely, even when listed as `primary`, and the next enabled provider in that member's chain serves the work. If no enabled provider in the member's chain can serve the request, the tool returns a hard error listing every attempt. There is no global fallback and no silent model switching.

- For a native-primary member, run the native subagent first. If the configured primary is disabled, skip that native turn and follow the generated wrapper's pinned provider. If the native turn fails because of quota, rate limits, or subscription limits, retry that same step through `muse-squad:generate_code` or `muse-squad:critique_plan` with `member="<name>"`. The router uses that member's HTTP fallbacks. Do not treat the failed native turn as the member's result.
- For an HTTP-primary member, the generated wrapper pins a lightweight native runner and delegates heavy work to `muse-squad:generate_code` or `muse-squad:critique_plan` with `member="<name>"`.
- Use `member_status` and `list_providers` to inspect limits and health before batching work. API keys are redacted.

### Global guardrails

- Label every spawned subagent exactly as `[<name> | <provider-name>] <action>` — for example `[lead | Muse-Spark] Review architecture`. Use the member's lowercase name and the provider name exactly as written in the TOML. Keep the action under ~50 characters, start with a verb, and add no extra parenthetical text.
- Respect each provider's `max_concurrency` for parallel work; queue extra work into a later wave.
- Apply generated code surgically: a targeted unified diff or a single function/block with native edit tools. Reject full-file rewrites, truncation markers, and unapplyable diffs.
- Run the fastest incremental check on changed files immediately after each patch. Full builds and full test suites belong to the final verification step.
- Never call work done until verification passes or the remaining gaps are stated explicitly. If a member chain returns a hard error, stop and report the attempts; do not switch to a provider outside that member's chain.

### Project memory

Project memory is repository-local at `<repo>/.muse-squad/` and travels with the repository. Resolve the repo root with `git rev-parse --show-toplevel`, call `muse-squad:memory_status` with that `repo_root`, then call `muse-squad:memory_init` when the layout is missing. Ordinary member runs create the minimal layout; `/squad-plan` and `/squad-execute` pass `include_plan: true`. Legacy `.muse/` and `.muse/squad/` memory is copied into `.muse-squad/` without deleting the originals.

Each named member reads `.muse-squad/decisions.md` and `.muse-squad/history/<name>.md` before work and appends concise lasting learnings when finished. Append durable decisions after each wave or plan sign-off. Commit the canonical `.muse-squad/` files so other machines start from the same state; never put API keys, absolute paths, or machine-specific provider details in them.

### Keep normal sessions lightweight

Do not create `.muse-squad/PLAN.md` in a normal session unless `/squad-plan` is invoked or the user explicitly asks for a formal multi-wave plan. Wave batching, execution logs, and the strict verification gate are for the slash commands. In normal sessions, use the guardrails above with a brief task brief instead.
