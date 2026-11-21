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
| `mcp/register-settings.js` | Adds `muse-squad` to Muse's settings without breaking your other settings. |
| `mcp/sync-team.js` | Regenerates the roster page and member wrappers from the TOML. |
| `skills/squad-team/SKILL.md` | The `/squad-team` command: edits the TOML and regenerates outputs. |
| `skills/squad-doctor/SKILL.md` | The `/squad-doctor` command: diagnoses registration, config, providers, and drift. |
| `skills/squad-plan/SKILL.md` | The `/squad-plan` command: writes `.muse/PLAN.md`. |
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
| `--skip-muse-check` | Skip the Muse install/config discovery preflight. |
| `--help` or `-h` | Show help. |

If you are piping the script straight into bash, use an environment variable instead of `--dir`:

```bash
MUSE_CONFIG_DIR=/tmp/muse-test bash <(curl -fsSL https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install)
```

Running the installer again is safe. Unchanged files are skipped. Files you edited are saved as `<file>.bak.<timestamp>` first.

### Muse preflight

On install and update (not uninstall), the installer checks that Muse Code is available via `muse --version` on `PATH` and in the standard install locations. If it is missing and you are in a terminal, it offers to run the official installer:

```text
curl -fsSL https://dev.meta.ai/install.sh | bash   # macOS / Linux
irm https://dev.meta.ai/install.ps1 | iex          # Windows
```

It then finds the Muse config directory: a path you supplied previously, `$XDG_CONFIG_HOME/muse` when set, otherwise `~/.config/muse`, plus a few platform fallbacks. A directory is accepted when it exists and contains `settings.json`, `auth.json`, `trust.json`, `agents/`, `skills/`, or `mcp/`. An explicit `--dir` or `MUSE_CONFIG_DIR` always wins. Without a TTY, a failed preflight stops before writing anything; use `--skip-muse-check` or `MUSE_SQUAD_SKIP_MUSE_CHECK=1` to bypass it.

### Config, updates, and uninstall

On a fresh install the installer writes the default `muse-squad.toml`, runs `mcp/sync-team.js` to generate `squad/team.md` and one wrapper per member, and registers the `muse-squad` MCP server. Re-runs and `--update` refresh managed files but never overwrite an existing `muse-squad.toml`. Uninstall removes the managed files, the generated roster and wrappers, and the MCP registration, but keeps your config file.

The installer manages one marked section in `~/.config/muse/AGENTS.md` (or `MUSE.md` if that is what you use). Text outside the markers is left alone; uninstall removes only the marked section.

### Backups

Before install or uninstall, the script asks:

```text
Back up current Muse config before continuing? [Y/n]
```

Press Enter (or type `Y`) to make a backup; type `n` to skip. It copies the whole Muse config folder to a sibling directory such as `~/.config/muse.backup.20261120-143022-12345`. With `curl | bash` there is no keyboard, so it backs up automatically. Use `--no-backup` or `MUSE_SQUAD_NO_BACKUP=1` to skip, or `--backup` to force it.

Backups contain plaintext API keys from your config. Keep them private.

---

## The single config file

Everything lives in `~/.config/muse/muse-squad.toml` (or `$MUSE_CONFIG_DIR/muse-squad.toml`). It is TOML, uses `schema = 1`, and is the only config file. There is no migration step: edit it directly or use `/squad-team`. All work goes through the members defined here; there are no unnamed helpers.

A complete example (also the shipped default):

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

[providers.Home-Ornith]
type = "http"
base_url = "http://127.0.0.1:8000/v1"
api_key = "local-key"             # or "${LOCAL_MODEL_API_KEY}"
model = "local-llama/Ornith-1.5-35B-A3B-MLX-4bit"
temperature = 0.2
top_p = 0.9
max_tokens = 8192
max_input_chars = 96000
on_context_exceeded = "truncate"
max_concurrency = 1
timeout_ms = 600000
queue_timeout_ms = 300000
max_retries = 2

[providers.DeepSeek-Flash]
type = "http"
base_url = "https://api.deepseek.com/v1"
api_key = "${DEEPSEEK_API_KEY}"
model = "deepseek-chat"
max_concurrency = 4
timeout_ms = 600000

[providers.Muse-Spark]
type = "native"
model = "muse-spark-1.3-contributor"
max_concurrency = 2

[providers.Muse-Ember]
type = "native"
model = "muse-ember-1.0"
max_concurrency = 4

[providers.Muse-Wonder]
type = "native"
model = "muse-wonder-1.0"
max_concurrency = 2

# ================================== Squad ==================================
# One [squad.<name>] table per member. Names are lowercase slugs.
# Each member has only primary, an ordered fallback array, and a charter.

[squad]

[squad.keaton]
primary = "Muse-Spark"
fallback = ["DeepSeek-Flash"]
charter = """Domain expertise: system architecture, dependency order, risk analysis, and decision-complete planning. Keep plans evidence-first and verification-ready."""

[squad.fenster]
primary = "Home-Ornith"
fallback = ["Muse-Ember"]
charter = """Domain expertise: UI components, styling systems, accessibility, and browser-side state. Preserve existing design tokens and describe visible behavior."""

[squad.mcmanus]
primary = "Home-Ornith"
fallback = ["DeepSeek-Flash"]
charter = """Domain expertise: APIs, persistence layers, server-side logic, and safe data migrations. Name the error path before the happy path."""

[squad.hockney]
primary = "Home-Ornith"
fallback = ["Muse-Ember"]
charter = """Domain expertise: unit and integration tests, regression analysis, and CI verification. Report exact commands and results; never weaken a test."""

[squad.verbal]
primary = "Muse-Ember"
fallback = ["Home-Ornith"]
charter = """Domain expertise: decision records, execution logs, and durable project conventions. Append only, and record why a decision was made."""
```

Use `#` for comments. TOML does not use `;`.

### AI Providers

Each `[providers.<Name>]` table has a `type`:

- `type = "native"` — a built-in Muse model. Needs `model` and `max_concurrency`. The MCP router cannot call native providers; it skips them and moves to the member's HTTP providers.
- `type = "http"` — an OpenAI-compatible endpoint. Needs `base_url`, `api_key`, and `model`, plus optional tuning and queue settings.

| Setting | Applies to | Meaning |
| --- | --- | --- |
| `type` | both | `"native"` or `"http"`. |
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

### Squad members

Each `[squad.<name>]` table has exactly three keys:

- `primary` — the first provider to try, by its exact name.
- `fallback` — an ordered array of provider names tried after the primary.
- `charter` — the member's instructions; this is how you describe what the member is good at and how it works.

At least one member is required. There are no extra keys such as display names, responsibilities, or labels, and no per-repository settings. Add, remove, or edit members with `/squad-team`, which validates every provider reference and regenerates the roster and wrappers.

The generated `squad/team.md` is the human-readable roster; `agents/<name>.md` wrappers are generated from the same TOML and should not be hand-edited. A member whose primary is native runs that native model directly. A member whose primary is HTTP gets a wrapper that pins a lightweight native runner and delegates heavy work to the `muse-squad` tools.

### Secrets and environment variables

An `api_key` may be a plaintext string or `${ENV_VAR}`. For example:

```toml
[providers.DeepSeek-Flash]
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

`generate_code` and `critique_plan` are **member-scoped**. The router resolves that member's `primary` first, then its `fallback` providers in order. Native providers cannot be called by the router; it skips them and tries the member's HTTP providers in chain order.

- For a native-primary member, run the native subagent first. If it fails on quota, rate limits, or subscription limits, retry the same step through `muse-squad:generate_code` or `muse-squad:critique_plan` with `member="<name>"`; the router uses that member's HTTP fallbacks.
- For an HTTP-primary member, the generated wrapper pins a lightweight native runner and delegates heavy work to `muse-squad` with `member="<name>"`.
- There is no global fallback and no silent model switching. Every request stays inside the named member's chain.

**Error behavior:** if no provider in the member chain can serve the request, the tool returns a hard error listing each attempted provider and why it failed. Skills stop the current wave or planning step, report the attempts, and ask you to fix that member's chain with `/squad-team`. They do not try another member, another provider, or inline work.

Task labels always use `[<name> | <provider-name>] <action>`, for example `[keaton | Muse-Spark] Review architecture`. The provider shown is the one that actually served the step.

---

## Slash commands

### `/squad-team`

Edits only `muse-squad.toml`, backs it up first, validates that every member's `primary` and `fallback` names match real providers, then runs `node ~/.config/muse/mcp/sync-team.js` to regenerate `squad/team.md` and `agents/<name>.md`. It can add, rename, or remove providers and members, reorder a member's chain, rewrite a charter, or move a secret into `${ENV_VAR}`. It never edits generated files by hand.

### `/squad-plan`

Uses named members only to map the code and draft a decision-complete `.muse/PLAN.md` with exact files, order, and verification commands. It preserves any existing `## Execution Log & Decisions` section. Reviews use `muse-squad:critique_plan` scoped to the reviewing member; native quota failures retry through that member's HTTP chain. If a chain fails completely, planning stops with the attempts listed. It does not change product code.

### `/squad-execute`

Reads the approved plan, groups work into waves, and delegates every implementation and review step to a named member. Generated diffs are applied surgically, incremental checks run after each patch, and the final Verification Gate blocks completion until all `.muse/TODO.md` items are checked and every verification command passes. Member errors stop the wave. A short append-only log is written to `## Execution Log & Decisions` in `.muse/PLAN.md`.

### `/squad-doctor`

Runs the read-only `mcp/doctor.js` and reports:

1. that `settings.json` has `mcpServers["muse-squad"]` pointing at `mcp/bridge.js`;
2. that `muse-squad.toml` parses with `schema = 1`, has at least one member, and every provider reference in every member chain resolves;
3. a live reachability check for each HTTP provider (`OK`, `AUTH`, `HTTP`, `DOWN`, `TIMEOUT`); native providers are reported as `native` and are not pinged;
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

Normal sessions stay lightweight: no `.muse/PLAN.md` unless you invoke `/squad-plan` or explicitly ask for a formal multi-wave plan.

Project memory lives in the repository, not in the global config:

- `.muse/squad/decisions.md` — shared decisions, appended after plans and waves.
- `.muse/squad/history/<name>.md` — per-member conventions, file maps, and gotchas.

The first named-member session creates these paths if missing. Members read them before work and append concise learnings when finished.

---

## Working on this repo

```
payload/                       edit these — they are the real files
  muse-squad.default.toml      seed for ~/.config/muse/muse-squad.toml
  AGENTS.md                    managed policy block (installer adds the markers)
  skills/*/SKILL.md            slash commands
  mcp/                         MCP server, config reader, doctor, materializer
scripts/generate-installers.sh builds the two installers from payload/
scripts/test-install.sh        installer test
scripts/test-mcp-bridge.js     router test with a fake model server
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
