#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/muse-squad-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

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
    }
  ' "$1"
}

echo "== bash installer: install =="
MUSE_CONFIG_DIR="$TMP/bash-config" bash "$ROOT/install"

echo "== bash installer: verify payload =="
for rel in "${EXPECTED[@]}"; do
  cmp "$ROOT/payload/$rel" "$TMP/bash-config/$rel"
  echo "  ok  $rel"
done

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
cat > "$TMP/merge-config/settings.json" <<'JSON'
{
  "schema_version": 1,
  "theme": "dark",
  "mcp_servers": {
    "other": { "command": "other-cmd", "args": [] }
  }
}
JSON
MUSE_CONFIG_DIR="$TMP/merge-config" bash "$ROOT/install" >/dev/null
verify_entry "$TMP/merge-config/settings.json" "$TMP/merge-config/endpoints.json"
SETTINGS="$TMP/merge-config/settings.json" node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.env.SETTINGS, "utf8"));
  if (s.theme !== "dark") throw new Error("lost theme");
  if (!s.mcp_servers.other) throw new Error("lost other MCP server");
'
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
MUSE_CONFIG_DIR="$TMP/bash-config" bash "$ROOT/install" --uninstall >/dev/null
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
  MUSE_CONFIG_DIR="$TMP/ps-config" pwsh -NoProfile -File "$ROOT/install.ps1"

  echo "== PowerShell installer: verify =="
  for rel in "${EXPECTED[@]}"; do
    cmp "$ROOT/payload/$rel" "$TMP/ps-config/$rel"
    echo "  ok  $rel"
  done
  cmp "$ROOT/payload/mcp/endpoints.default.json" "$TMP/ps-config/endpoints.json"
  verify_entry "$TMP/ps-config/settings.json" "$(cd "$TMP/ps-config" && pwd)/endpoints.json"

  echo "== PowerShell installer: uninstall =="
  MUSE_CONFIG_DIR="$TMP/ps-config" pwsh -NoProfile -File "$ROOT/install.ps1" --uninstall >/dev/null
  for rel in "${EXPECTED[@]}"; do
    [[ ! -e "$TMP/ps-config/$rel" ]] || { echo "FAIL: left behind $rel" >&2; exit 1; }
  done
  echo "  ok"
else
  echo "== PowerShell installer: skipped (pwsh not on PATH) =="
fi

echo "ALL TESTS PASSED"
