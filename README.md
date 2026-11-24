# muse-squad (v0.3.0)

A set of **named squad members, slash commands, and one MCP server** for Muse Code. A single TOML file defines your AI providers and your squad. Every generation or review call is scoped to a named member, and nothing is called "done" until the verification gate passes.

Nothing here is magic. It is files that the installer drops into `~/.config/muse/`.

---

## What you get

| File | What it does |
| --- | --- |
| `AGENTS.md` | Global policy that makes Muse delegate through named members in normal sessions. |
| `muse-squad.toml` | The single config file: AI providers and squad members (`schema = 1`). |
| `squad/team.md` | Human-readable roster generated from the TOML. |
| `agents/<name>.md` | Generated native wrappers, one per member. |
| `mcp/bridge.js` | The `muse-squad` MCP server: member-scoped routing over each member's provider chain. |
| `mcp/config.js` | Reads and validates the TOML, expands `${ENV_VAR}` secrets, and redacts keys. |
| `mcp/doctor.js` | Read-only health-check CLI used by `/squad-doctor`. |
| `mcp/roles.js` | The pinned 20-role catalog, templates, and charter generator. |
| `mcp/register-settings.js` | Adds `muse-squad` to Muse's settings without breaking your other settings. |
| `mcp/sync-team.js` | Regenerates the roster page and member wrappers from the TOML. |
| `mcp/team-wizard.js` | Shared installer wizard for template/role selection and overrides. |
| `skills/squad-team/SKILL.md` | The `/squad-team` command: edits the TOML and regenerates outputs. |
| `skills/squad-doctor/SKILL.md` | The `/squad-doctor` command: diagnoses registration, config, providers, and drift. |
| `skills/squad-plan/SKILL.md` | The `/squad-plan` command: writes `.muse-squad/PLAN.md`. |
| `skills/squad-execute/SKILL.md` | The `/squad-execute` command: runs waves and enforces the verification gate. |

---

## Install

You need **Node 18 or newer** for the MCP server. No npm install, no packages.

**Mac / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install | bash
```

**Windows (PowerShell 7)**

```powershell
irm https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install.ps1 | iex
```

**Windows (older PowerShell 5.1)**

```powershell
Invoke-RestMethod 'https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install.ps1' | iex
```

These URLs point straight at the files in this public repo. The installers are standalone — they carry all the files inside them, so nothing else is downloaded.

### Options

| Option | Meaning |
| --- | --- |
| `--dir PATH` | Install somewhere else instead of `~/.config/muse`. |
| `--update` | Download and run the latest installer, then install. Keeps your config. |
| `--uninstall` | Remove only the files this installer added. Your other stuff stays. |
| `--no-mcp` | Skip adding the `muse-squad` MCP server. |
| `--backup` | Force the backup prompt, even if backup was disabled by environment. |
| `--no-backup` | Skip the backup prompt and backup. |
| `--reconfigure-team` | Rerun the interactive team wizard on an existing install. |
| `--defaults` | Skip the team wizard and use the default roster. |
| `--skip-muse-check` | Skip the Muse install/config discovery preflight. |
| `--help` or `-h` | Show help. |

### Interactive prompts

Prompts work even when the installer is piped in (`curl ... | bash` or `irm ... | iex`). The script never reads user answers from stdin in that case, because stdin carries the installer itself. It reads from the controlling terminal instead: `/dev/tty` on macOS/Linux and `CONIN$` on Windows. If there is no controlling terminal—CI, cron, a detached SSH session without `-t`, or a service manager—prompts are skipped and the safe defaults are used.

On a first install, the interactive flow asks `Customize Squad team members & models now? [Y/n]`, then asks `Create third-party model providers now? [y/N]`. Answer `n` to stay native-only, or `y` and enter provider names one at a time (blank line when done); setup creates minimal HTTP provider stubs from those names and fills them into the role-aware chains. No third-party provider is shipped by default. The next screen is a template picker backed by a pinned catalog of 20 roles. The picker lists the member IDs in each template, for example `@lead, @frontend, @backend, @reviewer, @tester, @devops, @docs` for the default `software` team. Press Enter to accept the suggested team, or answer `N` to enter override mode. Overrides support `add <role>`, `remove <number>`, `rename <number> <name>`, `provider <number>`, `charter <number>`, `list`, `members`, and `done`. Invalid answers are reported immediately and re-asked, so a bad member name or a fallback that repeats the primary provider never gets written to `muse-squad.toml`.

A fresh install seeds a native-only roster only to give the wizard providers to assign; it is not treated as an existing user team, so there is no `keep` / replace prompt. Re-run with `--reconfigure-team` to edit an existing squad, or accept the legacy migration offer; selecting a different template then asks for explicit confirmation before replacing the roster and regenerating charters. Declining keeps the existing TOML roster and charters. Use `--defaults` to skip the wizard entirely.

### Legacy config migration

New configs carry a `# muse-squad-version: 0.3.0` comment. An existing config without that marker is treated as legacy. After the backup step, the installer offers:

```text
Older squad config detected. Migrate to the role-catalog templates now? [y/N]:
```

Accepting launches the same template/role wizard, including the explicit replacement confirmation before any charter is overwritten. Declining keeps the TOML exactly as it was. The installer records `offered`, `declined`, or `applied` in `.muse-squad-state.json` beside `muse-squad.toml`; a decline is remembered for the current version only, so a future version can offer migration again. The marker is never added to an existing TOML, and the state file is kept on uninstall. `--defaults` counts as a decline for the current version.

You can still use an environment variable with a piped install:

```bash
MUSE_CONFIG_DIR=/tmp/muse-test bash <(curl -fsSL https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install)
```

Advanced environment variables:

| Variable | Meaning |
| --- | --- |
| `MUSE_CONFIG_DIR` | Equivalent to `--dir`. |
| `MUSE_SQUAD_SKIP_MCP` | Set to `1` to skip MCP registration. |
| `MUSE_SQUAD_NO_BACKUP` | Set to `1` to skip backup unless `--backup` is passed. |
| `MUSE_SQUAD_SKIP_MUSE_CHECK` | Set to `1` to skip Muse discovery. |
| `MUSE_SQUAD_FORCE_INTERACTIVE` | Set to `1` to attempt prompts even when no terminal is detected. |
| `MUSE_SQUAD_TTY` | Override the prompt device, e.g. `/dev/tty` or `CONIN$`. Mainly for tests and unusual terminals. |

Running the installer again is safe. Unchanged files are skipped. Files you edited are saved as `<file>.bak.<timestamp>` first.

### Muse preflight

On install and update (not uninstall), the installer checks that Muse Code is available via `muse --version` on `PATH` and in the standard install locations. If it is missing and you are in a terminal, it offers to run the official installer:

```text
curl -fsSL https://dev.meta.ai/install.sh | bash   # macOS / Linux
irm https://dev.meta.ai/install.ps1 | iex          # Windows
```

It then finds the Muse config directory: a path you supplied previously, `$XDG_CONFIG_HOME/muse` when set, otherwise `~/.config/muse`, plus a few platform fallbacks. A directory is accepted when it exists and contains `settings.json`, `auth.json`, `trust.json`, `agents/`, `skills/`, or `mcp/`. An explicit `--dir` or `MUSE_CONFIG_DIR` always wins. If no interactive terminal is available at all, a failed preflight stops before writing anything; use `--skip-muse-check` or `MUSE_SQUAD_SKIP_MUSE_CHECK=1` to bypass it.

### Config, updates, and uninstall

On a fresh install the installer writes the default `muse-squad.toml`, runs `mcp/sync-team.js` to generate `squad/team.md` and one wrapper per member, and registers the `muse-squad` MCP server. Re-runs and `--update` refresh managed files but never overwrite an existing `muse-squad.toml` on their own. The one exception is the optional legacy-config wizard above: only an explicit acceptance may replace roster charters. Uninstall removes the managed files, the generated roster and wrappers, and the MCP registration, but keeps your config file and its migration state file.

The installer manages one marked section in `~/.config/muse/AGENTS.md` (or `MUSE.md` if that is what you use). Text outside the markers is left alone; uninstall removes only the marked section.

### Backups

Before install or uninstall, the script asks:

```text
Back up current Muse config before continuing? [Y/n]
```

Press Enter (or type `Y`) to make a backup; type `n` to skip. It copies the whole Muse config folder to a sibling directory such as `~/.config/muse.backup.20261120-143022-12345`. The prompt also works through `curl | bash` because it reads from the controlling terminal; if no terminal is available, the script backs up automatically. Use `--no-backup` or `MUSE_SQUAD_NO_BACKUP=1` to skip, or `--backup` to force it.

Backups contain plaintext API keys from your config. Keep them private.

---

## The single config file

Everything lives in `~/.config/muse/muse-squad.toml` (or `$MUSE_CONFIG_DIR/muse-squad.toml`). It is TOML, uses `schema = 1`, and is the only config file. The installer's optional legacy migration writes only the sidecar `.muse-squad-state.json`; it does not add a second squad config. Edit the TOML directly or use `/squad-team`. All work goes through the members defined here; there are no unnamed helpers.

The provider tables below are the shipped defaults: only built-in Muse providers. Fresh setup can add HTTP provider stubs from names you supply; those stubs start with `replace-me` placeholders for `base_url`, `api_key`, and `model` and take the first HTTP slots in the role-aware chains. The squad tables show the shipped member names and provider chains; the installed file contains the full medium-length charter generated by `mcp/roles.js` for each role, including MIT attribution. The charter text is shortened here only to keep this page readable.

```toml
schema = 1

# =============================== AI Providers ===============================
# Provider names may contain letters, numbers, dot (.), underscore (_), and
# hyphen (-). Members reference them exactly as written here.
#
# type = "native"  Built-in Muse model. The MCP router cannot call native
#                  providers; it skips them and tries the member's HTTP
#                  providers in chain order.
# type = "http"    OpenAI-compatible endpoint the MCP router can call.
#                  api_key accepts a plaintext value or ${ENV_VAR}.
#
# enabled = true   Set false to disable a provider. The router, doctor, and
#                  generated wrappers skip disabled providers.
#
# Fresh setup adds HTTP provider stubs from the names you enter. Edit their
# base_url, api_key, and model before using them; no HTTP provider is shipped.

[providers.Muse-Spark]
enabled = true
type = "native"
model = "muse-spark-1.3-contributor"
max_concurrency = 2

[providers.Muse-Ember]
enabled = true
type = "native"
model = "muse-ember-1.0"
max_concurrency = 4

[providers.Muse-Wonder]
enabled = true
type = "native"
model = "muse-wonder-1.0"
max_concurrency = 2

# ================================== Squad ==================================
# One [squad.<name>] table per member. Names are lowercase slugs and use the
# catalog role IDs by default: @lead, @backend, @reviewer, etc.
# Each member has only primary, an ordered fallback array, and a charter.

[squad]
name = "Muse Squad"
# Project memory always lives at <repo>/.muse-squad. This field is compatibility-only.
memory_dir = ".muse-squad"

[squad.lead]
primary = "Muse-Spark"
fallback = ["Muse-Ember"]
charter = """# @lead — Lead / Architect"""

[squad.frontend]
primary = "Muse-Spark"
fallback = ["Muse-Ember"]
charter = """# @frontend — Frontend Developer"""

[squad.backend]
primary = "Muse-Spark"
fallback = ["Muse-Ember"]
charter = """# @backend — Backend Developer"""

[squad.reviewer]
primary = "Muse-Spark"
fallback = ["Muse-Ember"]
charter = """# @reviewer — Code Reviewer"""

[squad.tester]
primary = "Muse-Spark"
fallback = ["Muse-Ember"]
charter = """# @tester — Test Engineer"""

[squad.devops]
primary = "Muse-Spark"
fallback = ["Muse-Ember"]
charter = """# @devops — DevOps Engineer"""

[squad.docs]
primary = "Muse-Ember"
fallback = ["Muse-Spark"]
charter = """# @docs — Technical Writer"""
```

Use `#` for comments. TOML does not use `;`.

### AI Providers

Each `[providers.<Name>]` table has a `type`:

- `type = "native"` — a built-in Muse model. Needs `model` and `max_concurrency`. The MCP router cannot call native providers; it skips them and moves to the member's HTTP providers.
- `type = "http"` — an OpenAI-compatible endpoint. Needs `base_url`, `api_key`, and `model`, plus optional tuning and queue settings.

| Setting | Applies to | Meaning |
| --- | --- | --- |
| `type` | both | `"native"` or `"http"`. |
| `enabled` | both | Defaults to `true`. Set `false` to disable a provider; the router, doctor, and generated wrappers skip it. Member references may stay as-is, and its other settings (including unset `${ENV_VAR}` keys) will not block config loading. |
| `model` | both | The native model ID or the model name sent to the HTTP server. |
| `max_concurrency` | both | Max simultaneous calls to this provider. Keep local servers at `1` to avoid GPU/RAM pressure. |
| `base_url` | http | The OpenAI-compatible base URL, usually ending in `/v1`. |
| `api_key` | http | Plaintext key or `${ENV_VAR}` reference. |
| `temperature` | http | Sampling temperature. |
| `top_p` | http | Nucleus sampling value. |
| `max_tokens` | http | Max output tokens; a tool call can override it. |
| `max_input_chars` | http | Safety cap on combined system + user prompt length. |
| `on_context_exceeded` | http | `"truncate"` (default) trims input with a warning, or `"fallback"` skips this provider and tries the next one in the member chain. |
| `timeout_ms` | http | Give up on a stuck request after this long. |
| `queue_timeout_ms` | http | How long to wait for a concurrency slot before trying the next provider. |
| `max_retries` | http | Retries for temporary failures; bad keys fail fast. |

Provider names may contain letters, numbers, `.`, `_`, and `-`, and are matched exactly by members.

### Squad members and the role catalog

Each `[squad.<name>]` table has exactly three keys:

- `primary` — the first provider to try, by its exact name.
- `fallback` — an ordered array of provider names tried after the primary.
- `charter` — the member's instructions; this is how you describe what the member is good at and how it works.

At least one member is required. There are no extra keys such as role IDs, display names, responsibilities, or labels, and no per-repository settings. `schema = 1` is unchanged.

`mcp/roles.js` carries a pinned catalog of 20 roles adapted from GitHub Squad and agency-agents (MIT). Four templates are available:

| Template | Roles |
| --- | --- |
| `software` | Default: `lead`, `frontend`, `backend`, `reviewer`, `tester`, `devops`, `docs`. |
| `engineering` | All 13 engineering, quality, operations, product, and design roles. |
| `full` | All 20 roles, including business and category roles. |
| `custom` | No preselected roles; add roles one at a time. |

The full catalog includes `lead`, `frontend`, `backend`, `fullstack`, `reviewer`, `tester`, `devops`, `security`, `data`, `docs`, `ai`, `designer`, `fact-checker`, `marketing-strategist`, `sales-strategist`, `project-manager`, `support-specialist`, `game-developer`, `media-buyer`, and `compliance-legal`. Default member names are the role IDs, so `@lead`, `@backend`, and `@reviewer` work out of the box. You can rename a member; the generated wrapper follows the TOML name, and the charter's explicit `@name` tokens are rewritten with it. After generation, the TOML is the source of truth: installers never rewrite existing member charters. Reapplying a template can replace them only after explicit confirmation.

Role-aware `primary`/`fallback` defaults are suggestions, not locks. Every chain remains editable in the TOML or with `/squad-team`. Add, remove, or edit members with `/squad-team`, which validates every provider reference and regenerates the roster and wrappers.

The generated `squad/team.md` is the human-readable roster; `agents/<name>.md` wrappers are generated from the same TOML and should not be hand-edited. A member whose primary is native runs that native model directly. A member whose primary is HTTP gets a wrapper that pins a lightweight native runner and delegates heavy work to the `muse-squad` tools.

### Secrets and environment variables

An `api_key` may be a plaintext string or `${ENV_VAR}`. For example:

```toml
[providers.DeepSeek-Flash]
enabled = true
type = "http"
base_url = "https://api.deepseek.com/v1"
api_key = "${DEEPSEEK_API_KEY}"
model = "deepseek-chat"
```

The variable is resolved when the config is read. If it is unset or empty, config loading fails with a clear error naming the variable. Prefer local or limited keys; never commit a real key. `/squad-doctor`, `list_providers`, and all diagnostics redact key values (an env-var reference is reported by name only).

---

## The `muse-squad` MCP server

On install, `mcp/register-settings.js` adds a server named `muse-squad` to `settings.json` without touching your other servers. The server re-reads `muse-squad.toml` on every tool call, so edits take effect immediately.

| Tool | Signature | Use |
| --- | --- | --- |
| `generate_code` | `generate_code(member, prompt\|task_spec, context\|file_context, optional system/temperature/max_tokens)` | Get a small, targeted diff from a named member. |
| `critique_plan` | `critique_plan(member, plan_markdown, optional repo_context/temperature/max_tokens)` | Get an adversarial review from a named member. |
| `member_status` | `member_status(member?)` | Inspect one member's chain, or all members when omitted. |
| `list_providers` | `list_providers` | See providers, types, limits, and queue settings. Keys are redacted. |
| `memory_status` | `memory_status(repo_root)` | Read-only report of repository-local `.muse-squad/` memory, legacy files, and ignore rules. |
| `memory_init` | `memory_init(repo_root, include_plan?)` | Create `.muse-squad/` and copy legacy `.muse/` or `.muse/squad/` memory without deleting originals. |

`generate_code` and `critique_plan` are **member-scoped**. The router resolves that member's `primary` first, then its `fallback` providers in order. Native providers cannot be called by the router; it skips them and tries the member's HTTP providers in chain order. Providers with `enabled = false` are skipped entirely, including in native wrappers; no chain edit is needed.

- For a native-primary member, run the native subagent first. If it fails on quota, rate limits, or subscription limits, retry the same step through `muse-squad:generate_code` or `muse-squad:critique_plan` with `member="<name>"`; the router uses that member's HTTP fallbacks.
- For an HTTP-primary member, the generated wrapper pins a lightweight native runner and delegates heavy work to `muse-squad` with `member="<name>"`.
- There is no global fallback and no silent model switching. Every request stays inside the named member's chain.

**Error behavior:** if no provider in the member chain can serve the request, the tool returns a hard error listing each attempted provider and why it failed. Skills stop the current wave or planning step, report the attempts, and ask you to fix that member's chain with `/squad-team`. They do not try another member, another provider, or inline work.

Task labels always use `[<name> | <provider-name>] <action>`, for example `[lead | Muse-Spark] Review architecture`. The provider shown is the one that actually served the step.

---

## Slash commands

### `/squad-team`

Edits only `muse-squad.toml`, backs it up first, validates that every member's `primary` and `fallback` names match real providers, then runs `node ~/.config/muse/mcp/sync-team.js` to regenerate `squad/team.md` and `agents/<name>.md`. It can add, rename, or remove providers and members, reorder a member's chain, rewrite a charter, or move a secret into `${ENV_VAR}`. It never edits generated files by hand.

For role-derived changes it reads `mcp/roles.js`: list roles with `node ~/.config/muse/mcp/roles.js --list`, inspect one with `--show <role-id>`, generate a charter with `--charter <role-id> <member-name>`, and expand a template with `--template <template-id> --json`. It can apply a template, add a single role by ID/category/number, rename a member while rewriting charter `@name` tokens, and customize provider chains. Reapplying a template or regenerating a charter asks for confirmation before overwriting existing charter text.

### `/squad-plan`

Uses named members only to map the code and draft a decision-complete `.muse-squad/PLAN.md` with exact files, order, and verification commands. It preserves any existing `## Execution Log & Decisions` section. Reviews use `muse-squad:critique_plan` scoped to the reviewing member; native quota failures retry through that member's HTTP chain. If a chain fails completely, planning stops with the attempts listed. It does not change product code.

### `/squad-execute`

Reads the approved plan, groups work into waves, and delegates every implementation and review step to a named member. Generated diffs are applied surgically, incremental checks run after each patch, and the final Verification Gate blocks completion until all `.muse-squad/TODO.md` items are checked and every verification command passes. Member errors stop the wave. A short append-only log is written to `## Execution Log & Decisions` in `.muse-squad/PLAN.md`.

### `/squad-doctor`

Runs the read-only `mcp/doctor.js` and reports:

1. that `settings.json` has `mcpServers["muse-squad"]` pointing at `mcp/bridge.js`;
2. that `muse-squad.toml` parses with `schema = 1`, has at least one member, and every provider reference in every member chain resolves;
3. a live reachability check for each HTTP provider (`OK`, `AUTH`, `HTTP`, `DOWN`, `TIMEOUT`); native providers are reported as `native` and are not pinged, while `enabled = false` providers are reported as `DISABLED` and are not pinged;
4. that `squad/team.md` and the generated `agents/<name>.md` wrappers match the TOML, with no leftover wrappers;
5. that keys are redacted, including under `--json`.

Exit code `0` means healthy, `1` means a check failed, and `2` means the diagnostic could not run. Use it first when generation fails or a local model server stops responding.

---

## Normal CLI sessions (no slash command)

You do not need a slash command to get help. The installed `AGENTS.md` / `MUSE.md` block tells Muse to delegate through named members in ordinary sessions:

- Match each bounded task to a member's charter and mention it as `@<name>`.
- Prefer `muse-squad:generate_code` for small diffs and `muse-squad:critique_plan` for secondary reviews, always with `member="<name>"`.
- Check `list_providers` / `member_status` first; respect each provider's `max_concurrency` and batch into waves.
- Label each subagent `[<name> | <provider-name>] <action>`, apply surgical edits, and run incremental checks after patches.

Normal sessions stay lightweight: no `.muse-squad/PLAN.md` unless you invoke `/squad-plan` or explicitly ask for a formal multi-wave plan.

Project memory lives in each repository, not in the global config:

```text
.muse-squad/
  README.md          # what to commit and how to sync
  PLAN.md            # current approved implementation plan
  TODO.md            # checklist with verification commands and results
  decisions.md       # append-only durable decisions
  history/<name>.md  # append-only per-member learnings
  local/             # machine-only scratch, ignored
```

Active paths are `.muse-squad/PLAN.md`, `.muse-squad/TODO.md`, `.muse-squad/decisions.md`, and `.muse-squad/history/<name>.md`.

The first squad skill run in a repository resolves `git rev-parse --show-toplevel`, calls `muse-squad:memory_status`, then calls `muse-squad:memory_init` if anything is missing. `/squad-plan` and `/squad-execute` also pass `include_plan: true`; ordinary member runs create the minimal layout only. Legacy `.muse/` and `.muse/squad/` files are copied into `.muse-squad/` without deleting the originals.

Commit the canonical `.muse-squad/` files and pull them on other machines before resuming squad work. Never put API keys, absolute paths, or machine-specific provider details in them. A root `.gitignore` rule that ignores `.muse-squad/` must be removed or narrowed, or these files will not sync. Legacy `.muse/` and `.muse/squad/` should stay ignored.

---

## Working on this repo

```
payload/                       edit these — they are the real files
  muse-squad.default.toml      seed for ~/.config/muse/muse-squad.toml
  AGENTS.md                    managed policy block (installer adds the markers)
  skills/*/SKILL.md            slash commands
  mcp/                         MCP server, config reader, doctor, role catalog, wizard, materializer
scripts/generate-installers.sh builds the two installers from payload/
scripts/test-install.sh        installer test
scripts/test-roles.js          role catalog and charter test
scripts/test-mcp-bridge.js     router test with a fake model server
scripts/test-memory.js         repository memory layout and migration test
install                        generated Mac/Linux installer
install.ps1                    generated Windows installer
VERSION                        version number stamped into both installers
```

Edit something in `payload/`, then regenerate the installers with `scripts/generate-installers.sh`. Do not edit `install` or `install.ps1` by hand — they get overwritten.

## Publishing

The install URLs are raw files on `main`:

- `install` → `https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install`
- `install.ps1` → `https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install.ps1`

Pushing to `main` makes the new version live immediately. To release: bump `VERSION`, regenerate, run the tests, commit, push.
