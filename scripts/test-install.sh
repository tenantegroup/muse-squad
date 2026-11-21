#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/muse-squad-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Existing behavior tests are not preflight tests; dedicated cases below opt in.
export MUSE_SQUAD_SKIP_MUSE_CHECK=1

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
  "mcp/sync-team.js"
)

verify_entry() {
  SETTINGS="$1" EXPECT_CONFIG="$2" node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.env.SETTINGS, "utf8"));
    const c = s.mcpServers && s.mcpServers["custom-coder"];
    if (!c) throw new Error("missing custom-coder");
    if (c.transport !== "stdio") throw new Error("bad transport");
    if (c.command !== "node") throw new Error("bad command");
    if (!Array.isArray(c.args) || !c.args[0].replace(/\\/g, "/").endsWith("mcp/bridge.js")) {
      throw new Error("bad args");
    }
    if (!c.env || c.env.MODELS_CONFIG_FILE !== process.env.EXPECT_CONFIG) {
      throw new Error("bad MODELS_CONFIG_FILE");
    }
    if (c.mode !== "optional") throw new Error("bad mode");
    for (const key of ["OPENAI_BASE_URL", "OPENAI_API_KEY", "MODEL_NAME", "DEFAULT_ENDPOINT"]) {
      if (key in c.env) throw new Error(`unexpected legacy env: ${key}`);
    }
    if (s.mcp_servers && s.mcp_servers["custom-coder"]) {
      throw new Error("legacy mcp_servers.custom-coder still present");
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
        c.muse_models["muse-spark-1.3-contributor"] !== 2) {
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
install_output="$(MUSE_CONFIG_DIR="$TMP/bash-config" bash "$ROOT/install")"
printf '%s\n' "$install_output"
[[ -z "$(latest_backup "$TMP/bash-config")" ]] || fail "fresh install created a backup"
grep -q 'created.*squad-team.json' <<<"$install_output" || \
  fail "non-interactive install did not seed squad-team.json"
grep -q 'sync-team: 5 members' <<<"$install_output" || \
  fail "non-interactive install did not run sync-team.js"

echo "== bash installer: verify payload =="
for rel in "${EXPECTED[@]}"; do
  diff -q --strip-trailing-cr "$ROOT/payload/$rel" "$TMP/bash-config/$rel"
  echo "  ok  $rel"
done

echo "== payload: default delegation policy =="
for phrase in \
  '## Muse Squad Default Delegation Policy' \
  '### Proactive subagent delegation' \
  '### Persistent named team' \
  '### Cost-saving custom-coder routing' \
  '### Global guardrails' \
  '### Keep normal sessions lightweight' \
  '[<Name> (<Role>) | <model-or-endpoint>] <concise action>' \
  '`muse_models`' \
  'Do not create `.muse/PLAN.md`'; do
  grep -qF "$phrase" "$ROOT/payload/AGENTS.md" || fail "missing policy phrase: $phrase"
done
for agent in worker general-purpose plan-reviewer; do
  DESCRIPTION="$(awk 'NR == 1 && $0 == "---" { front = 1; next } front && $0 == "---" { exit } front { print }' "$ROOT/payload/agents/$agent.md" | grep '^description:' || true)"
  grep -qF 'Use proactively in normal sessions' <<<"$DESCRIPTION" || \
    fail "$agent description does not say when to trigger proactively"
  if grep -q 'muse-' <<<"$DESCRIPTION"; then
    fail "$agent description pins a specific model"
  fi
done
echo "  ok"

echo "== bash installer: verify delegation policy file =="
{
  printf '%s\n' '<!-- muse-squad:begin -->'
  cat "$ROOT/payload/AGENTS.md"
  printf '%s\n' '<!-- muse-squad:end -->'
} > "$TMP/expected-agents.md"
diff -q --strip-trailing-cr "$TMP/expected-agents.md" "$TMP/bash-config/AGENTS.md"
echo "  ok"

echo "== bash installer: verify persistent team =="
diff -q --strip-trailing-cr "$ROOT/payload/squad-team.default.json" "$TMP/bash-config/squad-team.json"
grep -qF '| @keaton | Lead |' "$TMP/bash-config/squad/team.md" || fail "team.md is missing @keaton"
grep -qF '| @verbal | Scribe |' "$TMP/bash-config/squad/team.md" || fail "team.md is missing @verbal"
for name in keaton fenster mcmanus hockney verbal; do
  [[ -f "$TMP/bash-config/agents/$name.md" ]] || fail "missing generated agent @$name"
  grep -qF 'Generated by muse-squad sync-team.js' "$TMP/bash-config/agents/$name.md" || \
    fail "@$name wrapper is missing generated marker"
done
echo "  ok"

echo "== bash installer: interactive team wizard =="
interactive_dir="$TMP/interactive-config"
mkdir -p "$interactive_dir"
cat > "$TMP/interactive-input.txt" <<'INPUT'
y
oracle
Architect
2
grill-reviewer
nova
UI
4
muse-wonder-1.0
atlas
Backend
local-coder
2
prism
Tester
5
local-coder
quill
Scribe
1
3
y
scout
Scout
4
1
n
INPUT
interactive_output="$(
  MUSE_CONFIG_DIR="$interactive_dir" MUSE_SQUAD_FORCE_INTERACTIVE=1 \
    bash "$ROOT/install" --no-backup < "$TMP/interactive-input.txt" 2>&1
)"
grep -qF 'Customize Squad team members & models now?' <<<"$interactive_output" || \
  fail "interactive install did not ask the team wizard question"
grep -qF 'Member 1 [Lead] name [keaton]:' <<<"$interactive_output" || \
  fail "interactive install did not prompt for the Lead member"
grep -qF 'Primary model/endpoint for oracle (1: muse-spark-1.3-contributor, 2: muse-ember-1.0, 3: muse-wonder-1.0, 4: local-coder, 5: grill-reviewer)' <<<"$interactive_output" || \
  fail "interactive install did not build the model menu from endpoints.json"
grep -qF 'Add another team member? [y/N]:' <<<"$interactive_output" || \
  fail "interactive install did not offer extra members"

INTERACTIVE_TEAM="$interactive_dir/squad-team.json" node -e '
  const fs = require("fs");
  const team = JSON.parse(fs.readFileSync(process.env.INTERACTIVE_TEAM, "utf8"));
  const expected = [
    ["oracle", "Architect", "muse-ember-1.0", "grill-reviewer"],
    ["nova", "UI", "local-coder", "muse-wonder-1.0"],
    ["atlas", "Backend", "local-coder", "muse-ember-1.0"],
    ["prism", "Tester", "grill-reviewer", "local-coder"],
    ["quill", "Scribe", "muse-spark-1.3-contributor", "muse-wonder-1.0"],
    ["scout", "Scout", "local-coder", "muse-spark-1.3-contributor"]
  ];
  const actual = team.members.map((m) => [m.name, m.role, m.primary, m.backup]);
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`bad interactive roster: ${JSON.stringify(actual)}`);
  }
  const oracle = team.members.find((m) => m.name === "oracle");
  if (!oracle.charter.includes("Domain expertise: architect tasks")) {
    throw new Error("custom role charter was not generated");
  }
'
grep -qF '| @oracle | Architect |' "$interactive_dir/squad/team.md" || \
  fail "team.md is missing the custom Lead member"
grep -qF '| @scout | Scout |' "$interactive_dir/squad/team.md" || \
  fail "team.md is missing the extra member"
for name in oracle nova atlas prism quill scout; do
  [[ -f "$interactive_dir/agents/$name.md" ]] || fail "missing custom agent @$name"
done
grep -qF '[Oracle (Architect) | muse-ember-1.0]' "$interactive_dir/agents/oracle.md" || \
  fail "custom role label was not generated"
[[ -f "$interactive_dir/agents/worker.md" ]] || fail "generic worker agent was removed"
echo "  ok"

echo "== bash installer: interactive wizard 'n' seeds defaults =="
decline_dir="$TMP/decline-config"
mkdir -p "$decline_dir"
decline_output="$(
  MUSE_CONFIG_DIR="$decline_dir" MUSE_SQUAD_FORCE_INTERACTIVE=1 \
    bash "$ROOT/install" --no-backup <<< 'n' 2>&1
)"
grep -qF 'Customize Squad team members & models now?' <<<"$decline_output" || \
  fail "interactive install did not ask the team wizard question"
diff -q --strip-trailing-cr "$ROOT/payload/squad-team.default.json" \
  "$decline_dir/squad-team.json" >/dev/null || \
  fail "declining the wizard did not seed squad-team.default.json"
grep -q 'sync-team: 5 members' <<<"$decline_output" || \
  fail "declining the wizard did not run sync-team.js"
echo "  ok"

echo "== bash installer: --defaults skips the wizard =="
defaults_dir="$TMP/defaults-config"
mkdir -p "$defaults_dir"
cp "$TMP/interactive-config/squad-team.json" "$defaults_dir/squad-team.json"
defaults_before="$(shasum "$defaults_dir/squad-team.json")"
defaults_output="$(
  MUSE_CONFIG_DIR="$defaults_dir" MUSE_SQUAD_FORCE_INTERACTIVE=1 \
    bash "$ROOT/install" --reconfigure-team --defaults --no-backup 2>&1
)"
defaults_after="$(shasum "$defaults_dir/squad-team.json")"
[[ "$defaults_before" == "$defaults_after" ]] || fail "--defaults overwrote an existing team config"
if grep -qF 'Customize Squad team members & models now?' <<<"$defaults_output"; then
  fail "--defaults still prompted for team customization"
fi
grep -q 'unchanged.*squad-team.json' <<<"$defaults_output" || \
  fail "--defaults did not report the team config as unchanged"
echo "  ok"

echo "== preflight: missing Muse hard fails in non-interactive install =="
preflight_home="$TMP/preflight-home"
mkdir -p "$preflight_home"
if missing_output="$(HOME="$preflight_home" PATH="/usr/bin:/bin" \
  MUSE_CONFIG_DIR="$TMP/preflight-missing-config" MUSE_SQUAD_SKIP_MUSE_CHECK=0 \
  bash "$ROOT/install" --no-backup 2>&1)"; then
  printf '%s\n' "$missing_output"
  fail "install should fail when Muse is missing"
fi
grep -qF 'Muse Code was not found' <<<"$missing_output" || \
  fail "missing Muse error was not shown"
grep -qF -- '--skip-muse-check' <<<"$missing_output" || \
  fail "missing Muse error did not mention the skip flag"
echo "  ok"

echo "== preflight: interactive install offers the official Muse installer =="
preflight_bin="$TMP/preflight-bin"
preflight_muse_dir="$TMP/preflight-muse-bin"
preflight_config="$TMP/preflight-autoinstall-config"
mkdir -p "$preflight_bin" "$preflight_muse_dir" "$preflight_config"
cat > "$preflight_bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
cat <<'FAKE_INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$MUSE_INSTALL_DIR"
cat > "$MUSE_INSTALL_DIR/muse" <<'FAKE_MUSE'
#!/usr/bin/env bash
echo "Fake Muse Code 9.9.9"
FAKE_MUSE
chmod +x "$MUSE_INSTALL_DIR/muse"
FAKE_INSTALLER
FAKE_CURL
chmod +x "$preflight_bin/curl"
auto_output="$(
  HOME="$preflight_home" PATH="$preflight_bin:$preflight_muse_dir:/usr/bin:/bin" \
  MUSE_INSTALL_DIR="$preflight_muse_dir" MUSE_CONFIG_DIR="$preflight_config" \
  MUSE_SQUAD_SKIP_MUSE_CHECK=0 MUSE_SQUAD_FORCE_INTERACTIVE=1 \
  bash "$ROOT/install" --defaults --no-backup <<< 'Y' 2>&1
)"
grep -qF 'Muse Code does not appear to be installed' <<<"$auto_output" || \
  fail "interactive preflight did not offer to install Muse"
grep -qF 'installing  Muse Code via the official installer' <<<"$auto_output" || \
  fail "interactive preflight did not run the official installer"
[[ -x "$preflight_muse_dir/muse" ]] || fail "official installer did not create a Muse executable"
diff -q --strip-trailing-cr "$ROOT/payload/mcp/endpoints.default.json" \
  "$preflight_config/endpoints.json" >/dev/null || \
  fail "install did not continue after Muse was installed"
echo "  ok"

echo "== preflight: discovers Muse config from XDG_CONFIG_HOME =="
xdg_home="$TMP/xdg-home"
xdg_root="$TMP/xdg-config"
mkdir -p "$xdg_home/.local/bin" "$xdg_root/muse"
cat > "$xdg_home/.local/bin/muse" <<'FAKE_MUSE'
#!/usr/bin/env bash
echo "Fake Muse Code 9.9.9"
FAKE_MUSE
chmod +x "$xdg_home/.local/bin/muse"
printf '{"schema_version":1}\n' > "$xdg_root/muse/settings.json"
xdg_output="$(
  HOME="$xdg_home" XDG_CONFIG_HOME="$xdg_root" PATH="$xdg_home/.local/bin:$PATH" \
  MUSE_SQUAD_SKIP_MUSE_CHECK=0 bash "$ROOT/install" --defaults --no-backup 2>&1
)"
grep -qF "found      Muse config at $xdg_root/muse" <<<"$xdg_output" || \
  fail "preflight did not discover the XDG Muse config dir"
[[ -f "$xdg_root/muse/endpoints.json" ]] || \
  fail "install did not use the discovered XDG config dir"
[[ ! -e "$xdg_home/.config/muse/endpoints.json" ]] || \
  fail "install ignored the discovered XDG config dir"
echo "  ok"

echo "== preflight: explicit config dir is never overridden =="
explicit_config="$TMP/explicit-preflight-config"
explicit_output="$(
  HOME="$xdg_home" XDG_CONFIG_HOME="$xdg_root" PATH="$xdg_home/.local/bin:$PATH" \
  MUSE_SQUAD_SKIP_MUSE_CHECK=0 \
  bash "$ROOT/install" --dir "$explicit_config" --defaults --no-backup 2>&1
)"
grep -qF 'using      '"$explicit_config"' (explicit)' <<<"$explicit_output" || \
  fail "explicit --dir was not honored during preflight"
[[ -f "$explicit_config/endpoints.json" ]] || \
  fail "install did not use the explicit config dir"
echo "  ok"

echo "== preflight: missing config hard fails without a TTY =="
config_home="$TMP/config-home"
mkdir -p "$config_home/.local/bin"
cat > "$config_home/.local/bin/muse" <<'FAKE_MUSE'
#!/usr/bin/env bash
echo "Fake Muse Code 9.9.9"
FAKE_MUSE
chmod +x "$config_home/.local/bin/muse"
if config_missing_output="$(
  HOME="$config_home" PATH="$config_home/.local/bin:/usr/bin:/bin" \
  MUSE_CONFIG_DIR= MUSE_SQUAD_SKIP_MUSE_CHECK=0 \
  bash "$ROOT/install" --defaults --no-backup 2>&1
)"; then
  printf '%s\n' "$config_missing_output"
  fail "install should fail when no Muse config dir is found"
fi
grep -qF 'could not find a Muse config directory' <<<"$config_missing_output" || \
  fail "missing config error was not shown"
echo "  ok"

echo "== preflight: typed config path is persisted =="
typed_home="$TMP/typed-home"
typed_config="$TMP/typed-config"
mkdir -p "$typed_home/.local/bin" "$typed_config"
cat > "$typed_home/.local/bin/muse" <<'FAKE_MUSE'
#!/usr/bin/env bash
echo "Fake Muse Code 9.9.9"
FAKE_MUSE
chmod +x "$typed_home/.local/bin/muse"
printf '{"schema_version":1}\n' > "$typed_config/settings.json"
typed_output="$(
  HOME="$typed_home" PATH="$typed_home/.local/bin:$PATH" \
  MUSE_SQUAD_SKIP_MUSE_CHECK=0 MUSE_SQUAD_FORCE_INTERACTIVE=1 \
  bash "$ROOT/install" --defaults --no-backup \
    <<< "$(printf '%s\n%s\n' "$TMP/not-a-muse-config" "$typed_config")" 2>&1
)"
grep -qF 'Where is your Muse config directory?' <<<"$typed_output" || \
  fail "preflight did not prompt for the Muse config dir"
grep -qF 'not a Muse config directory' <<<"$typed_output" || \
  fail "preflight accepted an invalid config dir without validation"
grep -qx "$typed_config" "$typed_home/.config/muse-squad/config-dir" || \
  fail "typed Muse config dir was not persisted"
[[ -f "$typed_config/endpoints.json" ]] || \
  fail "install did not use the typed config dir"
rerun_output="$(
  HOME="$typed_home" PATH="$typed_home/.local/bin:$PATH" \
  MUSE_SQUAD_SKIP_MUSE_CHECK=0 bash "$ROOT/install" --defaults --no-backup 2>&1
)"
grep -qF "found      Muse config at $typed_config" <<<"$rerun_output" || \
  fail "persisted Muse config dir was not reused"
echo "  ok"

echo "== preflight: --skip-muse-check bypasses detection =="
skip_output="$(
  HOME="$preflight_home" PATH="/usr/bin:/bin" \
  MUSE_CONFIG_DIR="$TMP/preflight-skip-config" MUSE_SQUAD_SKIP_MUSE_CHECK=0 \
  bash "$ROOT/install" --skip-muse-check --defaults --no-backup 2>&1
)"
grep -qF 'skipped    Muse preflight' <<<"$skip_output" || \
  fail "--skip-muse-check did not bypass preflight"
env_skip_output="$(
  HOME="$preflight_home" PATH="/usr/bin:/bin" \
  MUSE_CONFIG_DIR="$TMP/preflight-env-skip-config" MUSE_SQUAD_SKIP_MUSE_CHECK=1 \
  bash "$ROOT/install" --defaults --no-backup 2>&1
)"
grep -qF 'skipped    Muse preflight' <<<"$env_skip_output" || \
  fail "MUSE_SQUAD_SKIP_MUSE_CHECK=1 did not bypass preflight"
echo "  ok"

echo "== preflight: uninstall skips Muse detection =="
uninstall_preflight_output="$(
  HOME="$preflight_home" PATH="/usr/bin:/bin" \
  MUSE_CONFIG_DIR="$TMP/preflight-uninstall-config" MUSE_SQUAD_SKIP_MUSE_CHECK=0 \
  bash "$ROOT/install" --uninstall --no-backup 2>&1
)"
if grep -qF 'Muse Code was not found' <<<"$uninstall_preflight_output"; then
  fail "uninstall should not require Muse to be installed"
fi
grep -qF 'muse-squad v' <<<"$uninstall_preflight_output" || \
  fail "uninstall did not run after skipping preflight"
echo "  ok"

echo "== payload: subagent task labeling/reporting rule =="
for skill in skills/squad-plan/SKILL.md skills/squad-execute/SKILL.md; do
  grep -qF '## TUI Task Labels and Reporting' "$ROOT/payload/$skill" || \
    fail "missing labeling/reporting section in $skill"
  grep -qF '[<agent-role> | <model-tag>] <action>' "$ROOT/payload/$skill" || \
    fail "missing generic label format in $skill"
  grep -qF '`native` tags' "$ROOT/payload/$skill" || \
    fail "missing native fallback tag guidance in $skill"
  grep -qF 'Subagents / Models' "$ROOT/payload/$skill" || \
    fail "missing Subagents / Models roster requirement in $skill"
  grep -qF '[<Name> (<Role>) | <model-or-endpoint>] <concise action>' "$ROOT/payload/$skill" || \
    fail "missing roster-aware label format in $skill"
  grep -qF 'local-coder+grill-reviewer' "$ROOT/payload/$skill" || \
    fail "missing combined endpoint tag in $skill"
  grep -qF 'squad-team.json' "$ROOT/payload/$skill" || \
    fail "missing roster startup step in $skill"
  grep -qF '.muse/squad/decisions.md' "$ROOT/payload/$skill" || \
    fail "missing project memory bootstrap in $skill"
  grep -qF '└ ◈ <task> running <elapsed>' "$ROOT/payload/$skill" || \
    fail "missing TUI footer example in $skill"
done
echo "  ok"

echo "== bash installer: verify endpoints config =="
diff -q --strip-trailing-cr "$ROOT/payload/mcp/endpoints.default.json" "$TMP/bash-config/endpoints.json"
verify_endpoints "$TMP/bash-config/endpoints.json"
node -e '
  const fs = require("fs");
  const mode = fs.statSync(process.argv[1]).mode & 0o777;
  if (process.platform !== "win32" && mode !== 0o600) throw new Error(`expected 0600, got ${mode.toString(8)}`);
' "$TMP/bash-config/endpoints.json"
echo "  ok"

echo "== bash installer: verify settings registration =="
verify_entry "$TMP/bash-config/settings.json" "$TMP/bash-config/endpoints.json"
echo "  ok"

echo "== bash installer: update mode preserves custom team config =="
update_dir="$TMP/update-config"
update_log="$TMP/update.log"
update_bin="$TMP/fake-bin"
mkdir -p "$update_dir/agents" "$update_bin"
: > "$update_log"
cp "$TMP/interactive-config/squad-team.json" "$update_dir/squad-team.json"
team_before="$(shasum "$update_dir/squad-team.json")"
printf 'sentinel\n' > "$update_dir/agents/oracle.md"
cat > "$update_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
out=""
while (( $# > 0 )); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat > "$out" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail
echo "ran-remote $*" >> "$UPDATE_LOG"
echo "remote v9.9.9" > "$UPDATE_DIR/REMOTE_MARKER"
exec bash "$INSTALL_ROOT/install" "$@"
REMOTE
chmod +x "$out"
CURL
chmod +x "$update_bin/curl"
update_output="$(
  PATH="$update_bin:$PATH" UPDATE_LOG="$update_log" UPDATE_DIR="$update_dir" \
    INSTALL_ROOT="$ROOT" MUSE_CONFIG_DIR="$update_dir" \
    bash "$ROOT/install" --update --reconfigure-team --no-backup 2>&1
)"
printf '%s\n' "$update_output"
[[ -f "$update_dir/REMOTE_MARKER" ]] || fail "update did not use remote installer"
grep -q -- "--dir $update_dir" "$update_log" || fail "update did not forward --dir"
grep -q -- "--no-backup" "$update_log" || fail "update did not forward --no-backup"
grep -q -- "--defaults" "$update_log" || fail "update did not force default team mode"
if grep -q -- '--reconfigure-team' "$update_log"; then
  fail "update forwarded --reconfigure-team to the downloaded installer"
fi
team_after="$(shasum "$update_dir/squad-team.json")"
[[ "$team_before" == "$team_after" ]] || fail "--update overwrote a custom squad-team.json"
grep -q 'unchanged.*squad-team.json' <<<"$update_output" || \
  fail "update did not report the custom team config as unchanged"
grep -qF 'Generated by muse-squad sync-team.js' "$update_dir/agents/oracle.md" || \
  fail "update did not regenerate wrappers from the existing roster"
echo "  ok"

echo "== bash installer: merge with existing settings =="
mkdir -p "$TMP/merge-config"
printf 'my own note\n' > "$TMP/merge-config/USER-NOTES.txt"
printf 'my agents notes\n' > "$TMP/merge-config/AGENTS.md"
cat > "$TMP/merge-config/settings.json" <<'JSON'
{
  "schema_version": 1,
  "theme": "dark",
  "mcpServers": {
    "other": { "transport": "stdio", "command": "other-cmd", "args": [], "mode": "optional" }
  }
}
JSON
merge_output="$(MUSE_CONFIG_DIR="$TMP/merge-config" bash "$ROOT/install")"
grep -q 'backed up' <<<"$merge_output" || fail "backup was not reported"
grep -q 'restore' <<<"$merge_output" || fail "restore path was not printed"
merge_backup="$(latest_backup "$TMP/merge-config")"
[[ -n "$merge_backup" ]] || fail "no backup folder was created"
[[ -f "$merge_backup/USER-NOTES.txt" ]] || fail "backup missed a custom file"
[[ -f "$merge_backup/AGENTS.md" ]] || fail "backup missed AGENTS.md"
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
  if (!s.mcpServers.other) throw new Error("lost other MCP server");
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

echo "== bash installer: existing AGENTS.md is preserved and updated =="
agents_dir="$TMP/agents-config"
mkdir -p "$agents_dir"
printf '# My global rules\n\nKeep responses terse.\n' > "$agents_dir/AGENTS.md"
MUSE_CONFIG_DIR="$agents_dir" bash "$ROOT/install" --no-backup >/dev/null
grep -qF '# My global rules' "$agents_dir/AGENTS.md" || fail "AGENTS.md user header lost"
grep -qF 'Keep responses terse.' "$agents_dir/AGENTS.md" || fail "AGENTS.md user text lost"
grep -qF '## Muse Squad Default Delegation Policy' "$agents_dir/AGENTS.md" || fail "policy not appended"
[[ "$(grep -cF '<!-- muse-squad:begin -->' "$agents_dir/AGENTS.md")" == "1" ]] || fail "duplicate policy marker"
printf '\n## My tail notes\n\nTail line.\n' >> "$agents_dir/AGENTS.md"
MUSE_CONFIG_DIR="$agents_dir" bash "$ROOT/install" --no-backup >/dev/null
rerun_agents="$(MUSE_CONFIG_DIR="$agents_dir" bash "$ROOT/install" --no-backup)"
grep -q 'unchanged.*AGENTS.md' <<<"$rerun_agents" || fail "policy re-run was not idempotent"
grep -qF '## My tail notes' "$agents_dir/AGENTS.md" || fail "tail notes lost on update"
grep -qF 'Keep responses terse.' "$agents_dir/AGENTS.md" || fail "header lost on update"
[[ "$(grep -cF '<!-- muse-squad:begin -->' "$agents_dir/AGENTS.md")" == "1" ]] || fail "duplicate policy marker after update"
echo "  ok"

echo "== bash installer: MUSE.md fallback =="
muse_dir="$TMP/muse-policy-config"
mkdir -p "$muse_dir"
printf '# Muse rules\n\nOnly use Rust.\n' > "$muse_dir/MUSE.md"
MUSE_CONFIG_DIR="$muse_dir" bash "$ROOT/install" --no-backup >/dev/null
[[ ! -e "$muse_dir/AGENTS.md" ]] || fail "created AGENTS.md despite existing MUSE.md"
grep -qF '## Muse Squad Default Delegation Policy' "$muse_dir/MUSE.md" || fail "policy not appended to MUSE.md"
grep -qF 'Only use Rust.' "$muse_dir/MUSE.md" || fail "MUSE.md user text lost"
MUSE_CONFIG_DIR="$muse_dir" bash "$ROOT/install" --uninstall --no-backup >/dev/null
grep -qF '# Muse rules' "$muse_dir/MUSE.md" || fail "MUSE.md header lost on uninstall"
grep -qF 'Only use Rust.' "$muse_dir/MUSE.md" || fail "MUSE.md user text lost on uninstall"
if grep -q 'muse-squad:begin' "$muse_dir/MUSE.md"; then fail "policy block left in MUSE.md"; fi
echo "  ok"

echo "== bash installer: AGENTS.md cleanup on uninstall =="
MUSE_CONFIG_DIR="$agents_dir" bash "$ROOT/install" --uninstall --no-backup >/dev/null
grep -qF '# My global rules' "$agents_dir/AGENTS.md" || fail "uninstall lost AGENTS.md header"
grep -qF 'Keep responses terse.' "$agents_dir/AGENTS.md" || fail "uninstall lost AGENTS.md text"
grep -qF '## My tail notes' "$agents_dir/AGENTS.md" || fail "uninstall lost AGENTS.md tail"
if grep -q 'muse-squad:begin' "$agents_dir/AGENTS.md"; then fail "uninstall left policy block"; fi
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
[[ ! -e "$TMP/bash-config/AGENTS.md" ]] || fail "uninstall left a policy-only AGENTS.md behind"
for name in keaton fenster mcmanus hockney verbal; do
  [[ ! -e "$TMP/bash-config/agents/$name.md" ]] || fail "uninstall left generated agent @$name behind"
done
[[ ! -e "$TMP/bash-config/squad/team.md" ]] || fail "uninstall left team.md behind"
[[ ! -e "$TMP/bash-config/squad-team.json" ]] || fail "uninstall left squad-team.json behind"
[[ ! -d "$TMP/bash-config/squad" ]] || fail "uninstall left the squad directory behind"
SETTINGS="$TMP/bash-config/settings.json" node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.env.SETTINGS, "utf8"));
  if (s.mcpServers && s.mcpServers["custom-coder"]) throw new Error("custom-coder not unregistered");
'
[[ -f "$TMP/bash-config/endpoints.json" ]] || { echo "FAIL: endpoints.json was removed" >&2; exit 1; }
echo "  ok"

echo "== bash installer: uninstall preserves other settings =="
MUSE_CONFIG_DIR="$TMP/merge-config" bash "$ROOT/install" --uninstall >/dev/null
SETTINGS="$TMP/merge-config/settings.json" node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.env.SETTINGS, "utf8"));
  if (s.mcpServers && s.mcpServers["custom-coder"]) throw new Error("custom-coder not unregistered");
  if (s.theme !== "dark" || !s.mcpServers.other) throw new Error("lost unrelated settings");
'
echo "  ok"

echo "== persistent team materializer =="
node "$ROOT/scripts/test-sync-team.js"

echo "== MCP bridge routing =="
node "$ROOT/scripts/test-mcp-bridge.js"

if command -v pwsh >/dev/null 2>&1; then
  echo "== PowerShell installer: install =="
  mkdir -p "$TMP/ps-config"
  printf 'ps user file\n' > "$TMP/ps-config/USER-NOTES.txt"
  MUSE_CONFIG_DIR="$TMP/ps-config" pwsh -NoProfile -File "$ROOT/install.ps1"

  echo "== PowerShell installer: verify =="
  for rel in "${EXPECTED[@]}"; do
    diff -q --strip-trailing-cr "$ROOT/payload/$rel" "$TMP/ps-config/$rel"
    echo "  ok  $rel"
  done
  diff -q --strip-trailing-cr "$ROOT/payload/mcp/endpoints.default.json" "$TMP/ps-config/endpoints.json"
  diff -q --strip-trailing-cr "$TMP/expected-agents.md" "$TMP/ps-config/AGENTS.md"
  diff -q --strip-trailing-cr "$ROOT/payload/squad-team.default.json" "$TMP/ps-config/squad-team.json"
  grep -qF '| @keaton | Lead |' "$TMP/ps-config/squad/team.md" || fail "PowerShell team.md is missing @keaton"
  for name in keaton fenster mcmanus hockney verbal; do
    [[ -f "$TMP/ps-config/agents/$name.md" ]] || fail "PowerShell missing generated agent @$name"
  done
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
  [[ ! -e "$TMP/ps-config/AGENTS.md" ]] || fail "PowerShell uninstall left AGENTS.md behind"
  for name in keaton fenster mcmanus hockney verbal; do
    [[ ! -e "$TMP/ps-config/agents/$name.md" ]] || fail "PowerShell uninstall left @$name behind"
  done
  [[ ! -e "$TMP/ps-config/squad/team.md" ]] || fail "PowerShell uninstall left team.md behind"
  [[ ! -e "$TMP/ps-config/squad-team.json" ]] || fail "PowerShell uninstall left squad-team.json behind"
  [[ ! -d "$TMP/ps-config/squad" ]] || fail "PowerShell uninstall left the squad directory behind"

  echo "== PowerShell installer: MUSE.md fallback =="
  ps_muse_dir="$TMP/ps-muse-config"
  mkdir -p "$ps_muse_dir"
  printf '# ps rules\n\nKeep diffs small.\n' > "$ps_muse_dir/MUSE.md"
  MUSE_CONFIG_DIR="$ps_muse_dir" pwsh -NoProfile -File "$ROOT/install.ps1" --no-backup >/dev/null
  [[ ! -e "$ps_muse_dir/AGENTS.md" ]] || fail "PowerShell created AGENTS.md despite MUSE.md"
  grep -qF '## Muse Squad Default Delegation Policy' "$ps_muse_dir/MUSE.md" || fail "PowerShell did not append policy to MUSE.md"
  MUSE_CONFIG_DIR="$ps_muse_dir" pwsh -NoProfile -File "$ROOT/install.ps1" --uninstall --no-backup >/dev/null
  grep -qF '# ps rules' "$ps_muse_dir/MUSE.md" || fail "PowerShell uninstall lost MUSE.md header"
  grep -qF 'Keep diffs small.' "$ps_muse_dir/MUSE.md" || fail "PowerShell uninstall lost MUSE.md text"
  if grep -q 'muse-squad:begin' "$ps_muse_dir/MUSE.md"; then fail "PowerShell left policy block in MUSE.md"; fi
  echo "  ok"
else
  echo "== PowerShell installer: skipped (pwsh not on PATH) =="
fi

echo "ALL TESTS PASSED"
