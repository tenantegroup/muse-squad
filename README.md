# muse-squad

A set of extra **agents, slash commands, and one helper server** for Muse Code.
It is inspired by Oh-My-OpenAgent. The big idea: one model plans, cheaper local models write code, and nothing is called "done" until the tests pass.

Nothing here is magic. It is just files that the installer drops into `~/.config/muse/`.

---

## What you get

| File | What it does |
| --- | --- |
| `agents/plan-reviewer.md` | Reads your plan and pokes holes in it. Never edits code. |
| `agents/worker.md` | Does one small coding task, then runs quick checks on the files it touched. |
| `agents/general-purpose.md` | Same worker rules, used when Muse asks for its built-in general-purpose agent. |
| `skills/squad-plan/SKILL.md` | The `/squad-plan` command. Writes `.muse/PLAN.md`. |
| `skills/squad-execute/SKILL.md` | The `/squad-execute` command. Does the work in waves and checks it. |
| `mcp/bridge.js` | The `custom-coder` helper server. Talks to your own models. |
| `mcp/register-settings.js` | Adds `custom-coder` to Muse's settings without breaking your other settings. |

---

## Install

You need **Node 18 or newer** for the helper server. No npm install, no packages.

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
| `--update` | Download and run the latest installer from GitHub, then install (keeps `endpoints.json` and your other settings). |
| `--uninstall` | Remove only the files this installer added. Your other stuff stays. |
| `--no-mcp` | Skip adding the `custom-coder` MCP server. |
| `--backup` | Force the backup prompt, even if backup was disabled by environment. |
| `--no-backup` | Skip the backup prompt and backup. |
| `--help` or `-h` | Show help. |

If you are piping the script straight into bash, use an environment variable instead of `--dir`:

```bash
MUSE_CONFIG_DIR=/tmp/muse-test bash <(curl -fsSL https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install)
```

Running the installer again is safe. Unchanged files are skipped. Files you edited are saved as `<file>.bak.<timestamp>` first.

### Backups

Before **install** or **uninstall**, the script asks:

```text
Back up current Muse config before continuing? [Y/n]
```

Press Enter (or type `Y`) to make a backup. Type `n` to skip. The backup is a plain folder next to your config, like:

```text
~/.config/muse.backup.20261120-143022-12345
```

It copies the **whole** Muse config folder — `endpoints.json`, `settings.json`, agents, skills, MCP files, and any custom files you added. The installer prints the exact path and a restore reminder when it is done.

With `curl | bash` there is no keyboard to read, so it backs up automatically. Use `--no-backup` or `MUSE_SQUAD_NO_BACKUP=1` if you really want to skip that. `--backup` forces it back on.

Backups contain your plaintext API keys from `endpoints.json`. Keep them private. To restore, copy the contents of the backup folder back into `~/.config/muse`.

---

## How to use it

### 1. Make a plan

In Muse Code, type:

```
/squad-plan
```

It will:

1. Read endpoint health/concurrency from `custom-coder` when available. If endpoints are missing or not working, it warns and continues in native-only mode (planning still works).
2. Send out read-only explorers to map the code.
3. Write the plan to `.muse/PLAN.md` with exact files, order, and test commands.
4. Ask the native plan reviewer to critique the plan, and ask `custom-coder` for an extra critique when available; then fix the good points they raise.

It will not change product code. If `.muse/PLAN.md` already has an `## Execution Log & Decisions` section, it leaves that alone.

### 2. Do the work

```
/squad-execute
```

It will:

1. Check endpoint health and concurrency limits again. If `custom-coder` is unavailable or misconfigured, it warns and continues in native-only mode.
2. Split the plan into waves. It never starts more subagents of one model than the limit allows.
3. When `custom-coder` is available, ask the local model for **small diffs**, never whole-file rewrites; otherwise workers implement changes natively. A model with real `Edit` tools applies the diffs/edits.
4. Run quick checks after each patch.
5. Run the full typecheck/test commands from the plan. If they fail, it fixes things and tries again.
6. Add a short entry to `## Execution Log & Decisions` in `.muse/PLAN.md` after every wave.

That log is the point: if your chat gets long or you come back tomorrow, the "why" is saved on disk.

You do not have to do anything special. Just keep answering its questions until it says it is done.

### Seeing what is running

Subagent titles use a short label so the Muse TUI footer stays readable:

```text
[worker-1 | ember] Implement FIFO semaphore queue
```

The first part is the role. The tag is the model (`ember`, `spark`, `wonder`) or a `custom-coder` endpoint alias (`local-coder`, `grill-reviewer`). Mixed work uses `ember+local-coder`. That whole title is what appears after `└ ◈` in the footer.

---

## The `custom-coder` helper

Muse only lets subagents pick from the models in `/models`. `custom-coder` is a way around that: Muse stays the architect, and your own OpenAI-compatible server does the heavy token work.

On install, the script creates:

- `~/.config/muse/mcp/bridge.js` — the helper server
- `~/.config/muse/endpoints.json` — your model settings (only created if missing)
- an entry in `~/.config/muse/settings.json` that points at those two files

It does not touch your other MCP servers.

The bridge reads `endpoints.json` on **every tool call**. Edit the file and the next call uses the new values. No restart needed.

---

## `endpoints.json` in plain English

```json
{
  "schema_version": 1,
  "default": "local-coder",
  "fallback_order": ["local-coder", "grill-reviewer"],
  "muse_models": { "muse-ember-1.0": 4, "muse-spark-1.3-contributor": 2 },
  "timeout_ms": 600000,
  "queue_timeout_ms": 300000,
  "max_retries": 2,
  "endpoints": {
    "local-coder": {
      "base_url": "http://127.0.0.1:8000/v1",
      "api_key": "local-key",
      "model": "local-llama/Ornith-1.5-35B-A3B-MLX-4bit",
      "temperature": 0.2,
      "max_concurrency": 1,
      "max_tokens": 8192,
      "max_input_chars": 96000,
      "extra_body": { "top_p": 0.9, "options": { "num_ctx": 32768 } },
      "on_context_exceeded": "truncate"
    },
    "grill-reviewer": {
      "base_url": "http://model-host:8000/v1",
      "api_key": "local-key",
      "model": "ornith-1.5-35b",
      "temperature": 0.3,
      "max_concurrency": 1,
      "max_tokens": 4096,
      "max_input_chars": 96000,
      "extra_body": { "top_p": 0.9 },
      "on_context_exceeded": "truncate"
    }
  }
}
```

If you already have an `endpoints.json`, the installer leaves it alone. Add the new fields to your existing endpoint entries by hand; every setting is optional.

| Setting | What it means |
| --- | --- |
| `default` | The endpoint used when a tool call does not name one. (`default_endpoint` also works.) |
| `endpoints` | Your named models. Each needs `base_url`, `api_key`, and `model`. |
| `fallback_order` | If one model fails, try the next one in this list. |
| `max_retries` | How many times to retry a *temporary* problem. Default `2`. Bad keys (`401`) are not retried. |
| `timeout_ms` | Give up on a stuck request after this long. Default 600000 ms (10 minutes). |
| `queue_timeout_ms` | How long to wait in line before trying a fallback. Default 300000 ms (5 minutes). |
| `muse_models` | Max native Muse subagents per model at the same time. The skills obey this. |
| `max_concurrency` | Max calls to that one endpoint at the same time. Keep local ones at `1` so you do not run out of GPU memory. |
| `temperature` | How "creative" the model is. The tool call can override it. |
| `max_tokens` | Max output tokens to ask for. A tool call can override it with `max_tokens`. If `extra_body.max_tokens` is set, that value wins over this one. |
| `max_input_chars` | Safety cap on the combined system + user prompt length. Keeps oversized contexts out of a small local KV-cache. |
| `extra_body` | Extra JSON sent straight to `/chat/completions`, e.g. `top_p`, `min_p`, `reasoning_effort`, or `options.num_ctx`. Core fields (`model`, `messages`, `stream`, and a defined `temperature`) cannot be overwritten by it. |
| `on_context_exceeded` | What to do when `max_input_chars` is exceeded: `"truncate"` (default) cuts the input and prepends a warning, or `"fallback"` skips this endpoint and tries the next one in `fallback_order`. |

Native subagents normally inherit the model you have selected in the main Muse CLI. `muse_models` keys must match those exact model IDs (for example `muse-spark-1.3-contributor`), or the limit will not apply to that model.

**About context limits:** `/squad-plan` and `/squad-execute` call `list_endpoints` first and keep `file_context` / `repo_context` small enough for the target endpoint. If you see a `> *[Warning: Input truncated ...]*` line, the model did not see the full input — shorten the context and try again. Normal fallback replies stay clean so diffs still apply; the `meta` field says who answered.

**About waiting in line:** if `local-coder` is busy, new calls wait their turn (first come, first served). They do not jump to a backup just because the main model is busy. The backup is only used if the call actually fails or waits too long.

**About Muse subagents:** the router cannot see native Muse subagents, so `/squad-plan` and `/squad-execute` read `muse_models` and split work into waves themselves.

**If endpoints are missing or not working:** muse-squad should still be usable. `/squad-plan` and `/squad-execute` check endpoint health up front, warn you, and fall back to native Muse models/subagents (no custom-coder generation/critique) instead of blocking. Fix `endpoints.json` and make sure the configured OpenAI-compatible server is reachable to re-enable `custom-coder` tools.

> API keys sit in `endpoints.json` as plain text. Use local or limited keys, not a production key.

Uninstalling removes the managed files and unregisters `custom-coder`, but **keeps `endpoints.json`** because it is your config now.

---

## The four tools

| Tool | Use it for |
| --- | --- |
| `generate_code` | Get a small unified diff (or one function). It is told never to return a whole file. `/squad-execute` uses `local-coder` for this. |
| `critique_plan` | Get a grumpy second opinion on the plan. `/squad-plan` uses `grill-reviewer`. |
| `coder_status` | See one endpoint's settings, current queue length, and limits. Keys are hidden. |
| `list_endpoints` | See each endpoint's `max_concurrency`, `max_tokens`, `max_input_chars`, and `extra_body` keys (secrets hidden), plus `muse_models` and queue settings. The skills read this at startup. |

If endpoints are not configured or unreadable, `coder_status`/`list_endpoints` return a warning payload (`available:false`) instead of failing so callers can fall back to native Muse models. `generate_code`/`critique_plan` will report a clear error until endpoints are fixed. |

`generate_code` and `critique_plan` also accept an optional `max_tokens` override. `generate_code` accepts `task_spec` instead of `prompt`, and `file_context` instead of `context`.

Normal fallback replies stay clean (so diffs still apply). The `meta` field tells you who really answered and what failed; only an actual context truncation adds a warning line to the reply text.

Optional environment variables: `MODELS_CONFIG_FILE` (config path), `MUSE_CODER_TIMEOUT_MS` (default timeout), and `MUSE_SQUAD_SKIP_MCP=1` (skip registration).

---

## Working on this repo

```
payload/                     edit these — they are the real files
  mcp/endpoints.default.json seed for endpoints.json (only created if missing)
scripts/generate-installers.sh  builds the two installers from payload/
install                      generated Mac/Linux installer
install.ps1                  generated Windows installer
VERSION                      version number stamped into both installers
scripts/test-install.sh      installer test
scripts/test-mcp-bridge.js   router test with a fake model server
```

Edit something in `payload/`, then:

```bash
scripts/generate-installers.sh
scripts/test-install.sh
```

Do not edit `install` or `install.ps1` by hand — they get overwritten.

If `pwsh` is installed, the test also checks the Windows installer.

## Publishing

The install URLs are just the raw files on `main`:

- `install` → `https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install`
- `install.ps1` → `https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install.ps1`

Pushing to `main` makes the new version live immediately. To release: bump `VERSION`, regenerate, run the tests, commit, push.
