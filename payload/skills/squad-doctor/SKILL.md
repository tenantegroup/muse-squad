---
name: squad-doctor
description: Diagnose Muse Squad MCP registration, config validity, provider reachability, and roster/wrapper drift.
---
You are in SQUAD-DOCTOR mode. Diagnose only; do not change config or product code unless the user asks.

## Run the check

Resolve the Muse config directory: use `MUSE_CONFIG_DIR` when set, otherwise `~/.config/muse` (`%USERPROFILE%\.config\muse` on Windows). Run the bundled, read-only diagnostic:

```bash
node "$MUSE_CONFIG_DIR/mcp/doctor.js" --config-dir "$MUSE_CONFIG_DIR" --timeout-ms 5000
```

On Windows without `MUSE_CONFIG_DIR`, use `node "$HOME\.config\muse\mcp\doctor.js" --config-dir "$HOME\.config\muse"`. Add `--json` when a machine-readable report is useful. If `doctor.js` is missing, say the installation is incomplete and recommend re-running the installer with `--update`.

The check does not call `muse-squad` generation tools, so it still works when an HTTP provider is down. Never print API keys: report only the provider name, status, redacted hint, and, for HTTP providers, the base URL. An `api_key` read from `${ENV_VAR}` is shown only as the variable name, never its resolved value.

## What it checks

1. `settings.json` — that `mcpServers["muse-squad"]` exists, launches `node`, and points at the bundled `mcp/bridge.js` with this config directory.
2. `muse-squad.toml` — that `schema = 1`, the file parses, every provider has valid settings, and every member has `primary`, an ordered `fallback` array, and a `charter`. Every provider name in every member chain must resolve to a provider table. At least one member is required.
3. HTTP providers — a live `GET /v1/models` (or `GET /models` when `base_url` already ends in `/v1`) with a short timeout. `OK` means reachable, `AUTH` means 401/403, `HTTP` means another error status, `DOWN` / `TIMEOUT` means no answer. Native providers are reported as `native` and are not pinged; the MCP router skips them too. Providers with `enabled = false` are reported as `DISABLED`, are not pinged, and are skipped by routing and wrappers.
4. Roster and wrappers — that `squad/team.md` and every global `agents/<name>.md` match what `sync-team.js` would generate from the TOML, that only current members have generated wrappers, and that no leftover non-member agent files remain.
5. Secrets — every `api_key` is redacted in all output, including `--json`.

Exit code `0` means all checks passed, `1` means at least one check failed, and `2` means the diagnostic itself could not run.

## Recommended follow-ups

- Missing or bad `muse-squad` registration: re-run the installer, or run `node "$MUSE_CONFIG_DIR/mcp/register-settings.js"` with the installer's usual `--settings` and `--bridge` arguments.
- Config parse or cross-reference failure: fix `muse-squad.toml` with `/squad-team`. An unknown provider in a member's chain blocks that member's routing.
- `DOWN` / `TIMEOUT`: check that the HTTP model server is running, `base_url` is correct, and the port is exposed. A native provider needs no ping.
- `DISABLED`: expected when `enabled = false`; the provider is intentionally skipped. Set `enabled = true` when it should serve work again.
- `AUTH`: check that provider's `api_key` or its `${ENV_VAR}` source; never echo the key into chat.
- Roster drift or leftover wrappers: run `node "$MUSE_CONFIG_DIR/mcp/sync-team.js" --config-dir "$MUSE_CONFIG_DIR"`, or use `/squad-team` if the TOML itself needs editing.

Present a short summary table of `Check | Status | Detail`, list failing checks first, and do not claim the installation is healthy unless the diagnostic exited `0`.
