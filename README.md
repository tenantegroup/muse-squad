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
curl -fsSL <url>/v1/install | bash
```

**Windows (PowerShell 7)**

```powershell
irm <url>/v1/install.ps1 | iex
```

**Windows (older PowerShell 5.1)**

```powershell
Invoke-RestMethod '<url>/v1/install.ps1' | iex
```

`<url>` is a placeholder until we pick a host. The installers are standalone — they carry all the files inside them.

### Options

| Option | Meaning |
| --- | --- |
| `--dir PATH` | Install somewhere else instead of `~/.config/muse`. |
| `--uninstall` | Remove only the files this installer added. Your other stuff stays. |
| `--help` or `-h` | Show help. |

If you are piping the script straight into bash, use an environment variable instead of `--dir`:

```bash
MUSE_CONFIG_DIR=/tmp/muse-test bash <(curl -fsSL <url>/v1/install)
```

Running the installer again is safe. Unchanged files are skipped. Files you edited are saved as `<file>.bak.<timestamp>` first.

---

## How to use it

### 1. Make a plan

In Muse Code, type:

```
/squad-plan
```

It will:

1. Read `endpoints.json` to see how many subagents each model may run at once.
2. Send out read-only explorers to map the code.
3. Write the plan to `.muse/PLAN.md` with exact files, order, and test commands.
4. Ask two different models to critique the plan, then fix the good points they raise.

It will not change product code. If `.muse/PLAN.md` already has an `## Execution Log & Decisions` section, it leaves that alone.

### 2. Do the work

```
/squad-execute
```

It will:

1. Check the concurrency limits again.
2. Split the plan into waves. It never starts more subagents of one model than the limit allows.
3. Ask the local model for **small diffs**, never whole-file rewrites. A model with real `Edit` tools applies the diffs.
4. Run quick checks after each patch.
5. Run the full typecheck/test commands from the plan. If they fail, it fixes things and tries again.
6. Add a short entry to `## Execution Log & Decisions` in `.muse/PLAN.md` after every wave.

That log is the point: if your chat gets long or you come back tomorrow, the "why" is saved on disk.

You do not have to do anything special. Just keep answering its questions until it says it is done.

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
  "muse_models": { "muse-ember-1.0": 4, "muse-spark-1.3": 2 },
  "timeout_ms": 600000,
  "queue_timeout_ms": 300000,
  "max_retries": 2,
  "endpoints": {
    "local-coder": {
      "base_url": "http://127.0.0.1:8000/v1",
      "api_key": "local-key",
      "model": "local-llama/Ornith-1.5-35B-A3B-MLX-4bit",
      "temperature": 0.2,
      "max_concurrency": 1
    },
    "grill-reviewer": {
      "base_url": "http://model-host:8000/v1",
      "api_key": "local-key",
      "model": "ornith-1.5-35b",
      "temperature": 0.3,
      "max_concurrency": 1
    }
  }
}
```

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

**About waiting in line:** if `local-coder` is busy, new calls wait their turn (first come, first served). They do not jump to a backup just because the main model is busy. The backup is only used if the call actually fails or waits too long.

**About Muse subagents:** the router cannot see native Muse subagents, so `/squad-plan` and `/squad-execute` read `muse_models` and split work into waves themselves.

> API keys sit in `endpoints.json` as plain text. Use local or limited keys, not a production key.

Uninstalling removes the managed files and unregisters `custom-coder`, but **keeps `endpoints.json`** because it is your config now.

---

## The four tools

| Tool | Use it for |
| --- | --- |
| `generate_code` | Get a small unified diff (or one function). It is told never to return a whole file. `/squad-execute` uses `local-coder` for this. |
| `critique_plan` | Get a grumpy second opinion on the plan. `/squad-plan` uses `grill-reviewer`. |
| `coder_status` | See one endpoint's settings, current queue length, and limits. Keys are hidden. |
| `list_endpoints` | See all endpoints, their `max_concurrency`, `muse_models`, and queue settings. The skills read this at startup. |

`generate_code` also accepts `task_spec` instead of `prompt`, and `file_context` instead of `context`.

When a fallback answers, the reply stays clean (so diffs still apply). The `meta` field tells you who really answered and what failed.

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

Host the generated files at:

- `install` → `<url>/v1/install`
- `install.ps1` → `<url>/v1/install.ps1`

To release: bump `VERSION`, regenerate, run the tests, commit, push.
