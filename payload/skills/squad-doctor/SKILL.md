---
name: squad-doctor
description: Diagnose Muse Squad MCP registration, endpoint reachability, and roster/wrapper drift.
---
You are in SQUAD-DOCTOR mode. Diagnose only; do not change config or product code unless the user asks.

## Run the check

Resolve the Muse config directory: use `MUSE_CONFIG_DIR` when set, otherwise `~/.config/muse` (`%USERPROFILE%\.config\muse` on Windows). Run the bundled, read-only diagnostic:

```bash
node "$MUSE_CONFIG_DIR/mcp/doctor.js" --config-dir "$MUSE_CONFIG_DIR" --timeout-ms 5000
```

On Windows without `MUSE_CONFIG_DIR`, use `node "$HOME\.config\muse\mcp\doctor.js" --config-dir "$HOME\.config\muse"`. Add `--json` when a machine-readable report is useful. If `doctor.js` is missing, say the installation is incomplete and recommend re-running the installer with `--update`.

The check does not use `custom-coder`, so it still works when the model server is down. Never print API keys; report only the endpoint alias, status, URL, and redacted hint from the tool output.

## What it checks

1. `settings.json` - that `mcpServers["custom-coder"]` exists, launches `node`, points at `mcp/bridge.js`, and uses this config dir's `endpoints.json`.
2. Every `endpoints.json` alias - a live `GET /v1/models` (or `GET /models` when `base_url` already ends in `/v1`) with a short timeout. `OK` means reachable; `AUTH` means 401/403; `HTTP` means another error status; `DOWN` / `TIMEOUT` means no answer.
3. `squad-team.json` - that `squad/team.md` and every global `agents/<name>.md` match what `sync-team.js` would generate, and that no stale generated wrappers remain.

Exit code `0` means all checks passed, `1` means at least one check failed, and `2` means the diagnostic itself could not run.

## Recommended follow-ups

- Missing or bad `custom-coder` registration: re-run the installer, or run `node "$MUSE_CONFIG_DIR/mcp/register-settings.js"` with the installer's usual `--settings`, `--bridge`, and `--config-file` arguments.
- `DOWN` / `TIMEOUT`: check that the local model server is running, the `base_url` is correct, and the port is exposed.
- `AUTH`: check that endpoint's key in `endpoints.json`; never echo the key into chat.
- `HTTP`: inspect the model server logs for the reported status.
- Roster drift: run `node "$MUSE_CONFIG_DIR/mcp/sync-team.js" --config-dir "$MUSE_CONFIG_DIR"`, or use `/squad-team` if the roster itself needs editing.

Present a short summary table of `Check | Status | Detail`, list the failing checks first, and do not claim the installation is healthy unless the diagnostic exited `0`.
