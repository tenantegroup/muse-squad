#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/muse-squad-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
latest_backup() { ls -1dt "$1".backup.* 2>/dev/null | head -n 1 || true; }

EXPECTED=(
  "agents/plan-reviewer.md"
  "agents/general-purpose.md"
  "agents/worker.md"
  "skills/squad-plan/SKILL.md"
  "skills/squad-execute/SKILL.md"
  "mcp/bridge.js"
  "mcp/register-settings.js"
)

verify_entry() {
  SETTINGS="$1" EXPECT_CONFIG="$2" node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.env.SETTINGS, "utf8"));
    const c = s.mcp_servers && s.mcp_servers["custom-coder"];
    if (!c) throw new Error("missing custom-coder");
    if (c.command !== "node") throw new Error("bad command");
    if (!Array.isArray(c.args) || !c.args[0].replace(/\\/g, "/").endsWith("mcp/bridge.js")) {
      throw new Error("bad args");
    }
    if (!c.env || c.env.MODELS_CONFIG_FILE !== process.env.EXPECT_CONFIG) {
      throw new Error("bad MODELS_CONFIG_FILE");
    }
    for (const key of ["OPENAI_BASE_URL", "OPENAI_API_KEY", "MODEL_NAME", "DEFAULT_ENDPOINT"]) {
      if (key in c.env) throw new Error(`unexpected legacy env: ${key}`);
    }
  '
}

verify_endpoints() {
  node -e '
    const fs = require("fs");
    const p = process.argv[1];
    const c = JSON.parse(fs.readFileSync(p, "utf8"));
    if (c.schema_version !== 1) throw new Error("bad schema_version");
    if (c.default !== "local-coder") throw new Error("bad default");
    if (!Array.isArray(c.fallback_order) || c.fallback_order[0] !== "local-coder") {
      throw new Error("bad fallback_order");
    }
    if (c.timeout_ms !== 600000) throw new Error("bad timeout_ms");
    if (c.queue_timeout_ms !== 300000) throw new Error("bad queue_timeout_ms");
    if (c.max_retries !== 2) throw new Error("bad max_retries");
    if (!c.muse_models || c.muse_models["muse-ember-1.0"] !== 4 ||
        c.muse_models["muse-spark-1.3"] !== 2) {
      throw new Error("bad muse_models");
    }
    for (const name of ["local-coder", "grill-reviewer"]) {
      const e = c.endpoints && c.endpoints[name];
      if (!e || !e.base_url || !e.model || typeof e.api_key !== "string") {
        throw new Error(`bad endpoint ${name}`);
      }
      if (e.max_concurrency !== 1) throw new Error(`bad max_concurrency for ${name}`);
      if (typeof e.max_tokens !== "number" || e.max_tokens < 1) {
        throw new Error(`bad max_tokens for ${name}`);
      }
      if (e.max_input_chars !== 96000) throw new Error(`bad max_input_chars for ${name}`);
      if (!e.extra_body || typeof e.extra_body !== "object" || e.extra_body.top_p !== 0.9) {
        throw new Error(`bad extra_body for ${name}`);
      }
      if (e.on_context_exceeded !== "truncate") {
        throw new Error(`bad on_context_exceeded for ${name}`);
      }
    }
  ' "$1"
}

echo "== bash installer: install =="
MUSE_CONFIG_DIR="$TMP/bash-config" bash "$ROOT/install"
[[ -z "$(latest_backup "$TMP/bash-config")" ]] || fail "fresh install created a backup"

echo "== bash installer: verify payload =="
for rel in "${EXPECTED[@]}"; do
  cmp "$ROOT/payload/$rel" "$TMP/bash-config/$rel"
  echo "  ok  $rel"
done

echo "== payload: subagent task labeling rule =="
for skill in skills/squad-plan/SKILL.md skills/squad-execute/SKILL.md; do
  grep -qF '## Subagent Task Labeling (TUI Visibility)' "$ROOT/payload/$skill" || \
    fail "missing labeling section in $skill"
  grep -qF '[<agent-role> | <short-model-name>] <concise action>' "$ROOT/payload/$skill" || \
    fail "missing label format in $skill"
  grep -qF 'ember+local-coder' "$ROOT/payload/$skill" || \
    fail "missing combined model tag in $skill"
  grep -qF '└ ◈ <task> running <elapsed>' "$ROOT/payload/$skill" || \
    fail "missing TUI footer example in $skill"
done
echo "  ok"

echo "== bash installer: verify endpoints config =="
cmp "$ROOT/payload/mcp/endpoints.default.json" "$TMP/bash-config/endpoints.json"
verify_endpoints "$TMP/bash-config/endpoints.json"
node -e '
  const fs = require("fs");
  const mode = fs.statSync(process.argv[1]).mode & 0o777;
  if (mode !== 0o600) throw new Error(`expected 0600, got ${mode.toString(8)}`);
' "$TMP/bash-config/endpoints.json"
echo "  ok"

echo "== bash installer: verify settings registration =="
verify_entry "$TMP/bash-config/settings.json" "$TMP/bash-config/endpoints.json"
echo "  ok"

echo "== bash installer: merge with existing settings =="
mkdir -p "$TMP/merge-config"
printf 'my own note\n' > "$TMP/merge-config/USER-NOTES.txt"
cat > "$TMP/merge-config/settings.json" <<'JSON'
{
  "schema_version": 1,
  "theme": "dark",
  "mcp_servers": {
    "other": { "command": "other-cmd", "args": [] }
  }
}
JSON
merge_output="$(MUSE_CONFIG_DIR="$TMP/merge-config" bash "$ROOT/install")"
grep -q 'backed up' <<<"$merge_output" || fail "backup was not reported"
grep -q 'restore' <<<"$merge_output" || fail "restore path was not printed"
merge_backup="$(latest_backup "$TMP/merge-config")"
[[ -n "$merge_backup" ]] || fail "no backup folder was created"
[[ -f "$merge_backup/USER-NOTES.txt" ]] || fail "backup missed a custom file"
grep -q '"theme": "dark"' "$merge_backup/settings.json" || fail "backup lost original settings"
grep -q '"other"' "$merge_backup/settings.json" || fail "backup lost other MCP server"
if grep -q 'custom-coder' "$merge_backup/settings.json"; then
  fail "backup was taken after MCP registration"
fi
verify_entry "$TMP/merge-config/settings.json" "$TMP/merge-config/endpoints.json"
SETTINGS="$TMP/merge-config/settings.json" node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.env.SETTINGS, "utf8"));
  if (s.theme !== "dark") throw new Error("lost theme");
  if (!s.mcp_servers.other) throw new Error("lost other MCP server");
'
echo "  ok"

echo "== bash installer: --no-backup skips backup =="
mkdir -p "$TMP/no-backup-config"
printf 'keep me\n' > "$TMP/no-backup-config/USER-NOTES.txt"
MUSE_CONFIG_DIR="$TMP/no-backup-config" bash "$ROOT/install" --no-backup >/dev/null
[[ -z "$(latest_backup "$TMP/no-backup-config")" ]] || fail "--no-backup still created a backup"
[[ -f "$TMP/no-backup-config/USER-NOTES.txt" ]] || fail "--no-backup removed a custom file"
echo "  ok"

echo "== bash installer: MUSE_SQUAD_NO_BACKUP skips backup =="
mkdir -p "$TMP/env-skip-config"
printf 'keep me\n' > "$TMP/env-skip-config/USER-NOTES.txt"
MUSE_CONFIG_DIR="$TMP/env-skip-config" MUSE_SQUAD_NO_BACKUP=1 bash "$ROOT/install" >/dev/null
[[ -z "$(latest_backup "$TMP/env-skip-config")" ]] || fail "env skip still created a backup"
echo "  ok"

echo "== bash installer: edited endpoints config is preserved =="
printf '{"schema_version":1,"default":"custom","endpoints":{"custom":{"base_url":"http://x/v1","api_key":"k","model":"m"}}}\n' \
  > "$TMP/bash-config/endpoints.json"
rerun_output="$(MUSE_CONFIG_DIR="$TMP/bash-config" bash "$ROOT/install")"
grep -q 'unchanged.*endpoints.json' <<<"$rerun_output" || {
  echo "FAIL: edited endpoints.json was overwritten or not reported unchanged" >&2
  exit 1
}
verify_endpoints_custom() {
  node -e '
    const fs = require("fs");
    const c = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (c.default !== "custom" || !c.endpoints.custom) throw new Error("edited config lost");
  ' "$1"
}
verify_endpoints_custom "$TMP/bash-config/endpoints.json"
echo "  ok"

echo "== bash installer: idempotent re-run =="
grep -q 'unchanged' <<<"$rerun_output" || {
  echo "FAIL: re-run did not report unchanged files" >&2
  exit 1
}
echo "  ok"

echo "== bash installer: uninstall =="
printf 'keep me\n' > "$TMP/bash-config/USER-NOTES.txt"
uninstall_output="$(MUSE_CONFIG_DIR="$TMP/bash-config" bash "$ROOT/install" --uninstall)"
grep -q 'backed up' <<<"$uninstall_output" || fail "uninstall did not report a backup"
uninstall_backup="$(latest_backup "$TMP/bash-config")"
[[ -n "$uninstall_backup" ]] || fail "uninstall did not create a backup"
[[ -f "$uninstall_backup/USER-NOTES.txt" ]] || fail "uninstall backup missed a custom file"
[[ -f "$uninstall_backup/agents/worker.md" ]] || fail "uninstall backup missed managed files"
grep -q '"default":"custom"' "$uninstall_backup/endpoints.json" || fail "uninstall backup lost edited endpoints"
for rel in "${EXPECTED[@]}"; do
  [[ ! -e "$TMP/bash-config/$rel" ]] || { echo "FAIL: left behind $rel" >&2; exit 1; }
done
SETTINGS="$TMP/bash-config/settings.json" node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.env.SETTINGS, "utf8"));
  if (s.mcp_servers["custom-coder"]) throw new Error("custom-coder not unregistered");
'
[[ -f "$TMP/bash-config/endpoints.json" ]] || { echo "FAIL: endpoints.json was removed" >&2; exit 1; }
echo "  ok"

echo "== bash installer: uninstall preserves other settings =="
MUSE_CONFIG_DIR="$TMP/merge-config" bash "$ROOT/install" --uninstall >/dev/null
SETTINGS="$TMP/merge-config/settings.json" node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.env.SETTINGS, "utf8"));
  if (s.mcp_servers["custom-coder"]) throw new Error("custom-coder not unregistered");
  if (s.theme !== "dark" || !s.mcp_servers.other) throw new Error("lost unrelated settings");
'
echo "  ok"

echo "== MCP bridge routing =="
node "$ROOT/scripts/test-mcp-bridge.js"

if command -v pwsh >/dev/null 2>&1; then
  echo "== PowerShell installer: install =="
  mkdir -p "$TMP/ps-config"
  printf 'ps user file\n' > "$TMP/ps-config/USER-NOTES.txt"
  MUSE_CONFIG_DIR="$TMP/ps-config" pwsh -NoProfile -File "$ROOT/install.ps1"

  echo "== PowerShell installer: verify =="
  for rel in "${EXPECTED[@]}"; do
    cmp "$ROOT/payload/$rel" "$TMP/ps-config/$rel"
    echo "  ok  $rel"
  done
  cmp "$ROOT/payload/mcp/endpoints.default.json" "$TMP/ps-config/endpoints.json"
  verify_entry "$TMP/ps-config/settings.json" "$(cd "$TMP/ps-config" && pwd)/endpoints.json"
  ps_backup="$(latest_backup "$TMP/ps-config")"
  [[ -n "$ps_backup" ]] || fail "PowerShell install did not create a backup"
  [[ -f "$ps_backup/USER-NOTES.txt" ]] || fail "PowerShell backup missed a custom file"

  echo "== PowerShell installer: uninstall =="
  MUSE_CONFIG_DIR="$TMP/ps-config" pwsh -NoProfile -File "$ROOT/install.ps1" --uninstall >/dev/null
  ps_uninstall_backup="$(latest_backup "$TMP/ps-config")"
  [[ -n "$ps_uninstall_backup" ]] || fail "PowerShell uninstall did not create a backup"
  [[ -f "$ps_uninstall_backup/agents/worker.md" ]] || fail "PowerShell uninstall backup missed managed files"
  for rel in "${EXPECTED[@]}"; do
    [[ ! -e "$TMP/ps-config/$rel" ]] || { echo "FAIL: left behind $rel" >&2; exit 1; }
  done
  echo "  ok"
else
  echo "== PowerShell installer: skipped (pwsh not on PATH) =="
fi

echo "ALL TESTS PASSED"
