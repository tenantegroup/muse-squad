#!/usr/bin/env bash
# Regenerates the standalone installers from payload/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD_DIR="$ROOT/payload"
VERSION_FILE="$ROOT/VERSION"
CONFIG_DEFAULT="$PAYLOAD_DIR/muse-squad.default.toml"
AGENTS_POLICY="$PAYLOAD_DIR/AGENTS.md"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -f "$VERSION_FILE" ]] || die "missing $VERSION_FILE"
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ -n "$VERSION" ]] || die "empty $VERSION_FILE"

# Explicit order keeps generated output deterministic.
MANAGED_PATHS=(
  "skills/squad-team/SKILL.md"
  "skills/squad-doctor/SKILL.md"
  "skills/squad-plan/SKILL.md"
  "skills/squad-execute/SKILL.md"
  "mcp/bridge.js"
  "mcp/config.js"
  "mcp/doctor.js"
  "mcp/register-settings.js"
  "mcp/sync-team.js"
)

# Files installed by older versions that no longer belong in a squad install.
LEGACY_AGENTS=(
  "agents/plan-reviewer.md"
  "agents/general-purpose.md"
  "agents/worker.md"
)

for rel in "${MANAGED_PATHS[@]}"; do
  f="$PAYLOAD_DIR/$rel"
  [[ -f "$f" ]] || die "missing payload file: $f"
  if LC_ALL=C grep -q "'@" "$f"; then
    die "payload contains a PowerShell here-string terminator ('@): $f"
  fi
done
[[ -f "$CONFIG_DEFAULT" ]] || die "missing $CONFIG_DEFAULT"
if LC_ALL=C grep -q "'@" "$CONFIG_DEFAULT"; then
  die "config default contains a PowerShell here-string terminator ('@): $CONFIG_DEFAULT"
fi
[[ -f "$AGENTS_POLICY" ]] || die "missing $AGENTS_POLICY"
if LC_ALL=C grep -q "'@" "$AGENTS_POLICY"; then
  die "agents policy contains a PowerShell here-string terminator ('@): $AGENTS_POLICY"
fi
node "$ROOT/payload/mcp/config.js" --file "$CONFIG_DEFAULT" --json >/dev/null ||
  die "$CONFIG_DEFAULT is not valid muse-squad TOML"

emit_bash() {
  local out="$ROOT/install" i=0 rel delim content
  {
    cat <<'HDR'
#!/usr/bin/env bash
# muse-squad installer - GENERATED FILE, DO NOT EDIT BY HAND.
# Source of truth: payload/ + scripts/generate-installers.sh
set -euo pipefail

HDR
    printf 'VERSION=%q\n' "$VERSION"
    cat <<'BODY'
CONFIG_DIR="${MUSE_CONFIG_DIR:-${HOME}/.config/muse}"
CONFIG_DIR_EXPLICIT=0
[[ -n "${MUSE_CONFIG_DIR:-}" ]] && CONFIG_DIR_EXPLICIT=1
MODE="install"
SKIP_MCP=0
SKIP_MUSE_CHECK=0
BACKUP_CHOICE="auto"
RECONFIGURE_TEAM=0
USE_DEFAULTS=0
REPO_RAW_BASE="https://raw.githubusercontent.com/tenantegroup/muse-squad/main"
MUSE_SQUAD_STATE_FILE="${HOME}/.config/muse-squad/config-dir"

usage() {
  cat <<'USAGE'
muse-squad installer

Usage:
  curl -fsSL https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install | bash
  bash install [--dir PATH] [--update] [--uninstall] [--no-mcp] [--help]
  bash install [--reconfigure-team] [--defaults] [--skip-muse-check]

Options:
  --dir PATH          Install into PATH instead of $HOME/.config/muse
  --update            Download and run the latest installer from GitHub, then install
  --uninstall         Remove managed files and unregister muse-squad
  --no-mcp            Skip muse-squad MCP registration
  --backup            Force a backup prompt/backup
  --no-backup         Skip the backup prompt and backup
  --reconfigure-team  Rerun the interactive team wizard on an existing install
  --defaults          Skip the team wizard and use the default roster
  --skip-muse-check   Skip Muse install/config discovery
  --help, -h          Show this help

Environment:
  MUSE_CONFIG_DIR          Equivalent to --dir (useful with curl | bash)
  MUSE_SQUAD_SKIP_MCP      Set to 1 to skip MCP registration
  MUSE_SQUAD_NO_BACKUP     Set to 1 to skip backup unless --backup is passed
  MUSE_SQUAD_SKIP_MUSE_CHECK Set to 1 to skip Muse install/config discovery
  MUSE_SQUAD_FORCE_INTERACTIVE Set to 1 to attempt prompts even without a TTY
  MUSE_SQUAD_TTY           Terminal device for prompts (default /dev/tty or CONIN$)

Providers and squad members are configured in muse-squad.toml inside the config directory.
USAGE
}

log()  { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

while (( $# > 0 )); do
  case "$1" in
    --dir)
      (( $# >= 2 )) || fail "--dir requires a value"
      CONFIG_DIR="$2"; CONFIG_DIR_EXPLICIT=1; shift 2 ;;
    --update) MODE="update"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    --no-mcp) SKIP_MCP=1; shift ;;
    --backup) BACKUP_CHOICE="yes"; shift ;;
    --no-backup) BACKUP_CHOICE="no"; shift ;;
    --reconfigure-team) RECONFIGURE_TEAM=1; shift ;;
    --defaults) USE_DEFAULTS=1; shift ;;
    --skip-muse-check) SKIP_MUSE_CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

if [[ "$BACKUP_CHOICE" == "auto" && "${MUSE_SQUAD_NO_BACKUP:-0}" == "1" ]]; then
  BACKUP_CHOICE="no"
fi
if [[ "${MUSE_SQUAD_SKIP_MUSE_CHECK:-0}" == "1" ]]; then
  SKIP_MUSE_CHECK=1
fi
while [[ "$CONFIG_DIR" == */ && "$CONFIG_DIR" != "/" ]]; do
  CONFIG_DIR="${CONFIG_DIR%/}"
done

# fd 0 is the installer script when it is piped in, so prompts must use the
# controlling terminal instead. MUSE_SQUAD_TTY exists for automation/tests.
MUSE_SQUAD_TTY="${MUSE_SQUAD_TTY:-/dev/tty}"
MUSE_SQUAD_TTY_LINE=1

tty_readable() {
  ( : < "$MUSE_SQUAD_TTY" ) 2>/dev/null
}

# A regular-file override is used by tests; read it one line at a time. A real
# terminal keeps its input queue across open/read/close, so reopen it per prompt.
read_tty_value() {
  local __var="$1" value=""
  if [[ -f "$MUSE_SQUAD_TTY" ]]; then
    if ! value="$(awk -v n="$MUSE_SQUAD_TTY_LINE" \
      'NR == n { print; found = 1; exit } END { if (!found) exit 1 }' \
      "$MUSE_SQUAD_TTY" 2>/dev/null)"; then
      return 1
    fi
    MUSE_SQUAD_TTY_LINE=$((MUSE_SQUAD_TTY_LINE + 1))
  else
    IFS= read -r value < "$MUSE_SQUAD_TTY" || return 1
  fi
  printf -v "$__var" '%s' "$value"
}

interactive_input() {
  [[ "${MUSE_SQUAD_FORCE_INTERACTIVE:-0}" == "1" ]] && return 0
  [[ -t 0 ]] && return 0
  tty_readable
}

read_answer() {
  local __var="$1" __value=""
  if [[ -t 0 ]]; then
    IFS= read -r __value || return 1
  elif tty_readable; then
    read_tty_value __value || return 1
  else
    # Forced-interactive automation may feed answers on stdin.
    IFS= read -r __value || return 1
  fi
  printf -v "$__var" '%s' "$__value"
}

read_default() {
  local __var="$1" __default="${2-}" value=""
  if read_answer value && [[ -n "$value" ]]; then
    printf -v "$__var" '%s' "$value"
  else
    printf -v "$__var" '%s' "$__default"
  fi
}

preflight_interactive() {
  interactive_input
}

muse_missing_error() {
  fail "Muse Code was not found. Install it with 'curl -fsSL https://dev.meta.ai/install.sh | bash' (macOS/Linux) or 'irm https://dev.meta.ai/install.ps1 | iex' (Windows), then re-run. Pass --skip-muse-check to bypass."
}

muse_installed() {
  if command -v muse >/dev/null 2>&1 && muse --version >/dev/null 2>&1; then
    return 0
  fi
  local candidate
  for candidate in \
    "$HOME/.local/bin/muse" \
    "/usr/local/bin/muse" \
    "/opt/homebrew/bin/muse" \
    "/Applications/Muse Code.app/Contents/MacOS/muse"; do
    [[ -x "$candidate" ]] || continue
    if "$candidate" --version >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

install_muse() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to run the official Muse Code installer"
  log "  installing  Muse Code via the official installer"
  if ! curl -fsSL https://dev.meta.ai/install.sh | bash; then
    fail "the Muse Code installer failed; see https://dev.meta.ai/docs/muse-code"
  fi
}

read_saved_config_dir() {
  local saved=""
  [[ -f "$MUSE_SQUAD_STATE_FILE" ]] || return 0
  IFS= read -r saved < "$MUSE_SQUAD_STATE_FILE" || true
  saved="${saved%$'\r'}"
  [[ -n "$saved" ]] && printf '%s' "$saved"
}

save_config_dir() {
  local dest="$MUSE_SQUAD_STATE_FILE"
  mkdir -p "$(dirname "$dest")" || fail "cannot create directory for $dest"
  printf '%s\n' "$1" > "$dest" || fail "cannot write $dest"
  chmod 600 "$dest" || fail "cannot set permissions on $dest"
}

valid_muse_config_dir() {
  local dir="$1" marker
  [[ -d "$dir" ]] || return 1
  for marker in settings.json auth.json trust.json agents skills mcp; do
    [[ -e "$dir/$marker" ]] && return 0
  done
  return 1
}

expand_user_path() {
  local value="$1"
  case "$value" in
    "~"|"~/"*) value="$HOME${value#\~}" ;;
  esac
  printf '%s' "$value"
}

preflight() {
  (( SKIP_MUSE_CHECK )) && { log "  skipped    Muse preflight"; return 0; }

  if ! muse_installed; then
    if preflight_interactive; then
      local answer
      printf 'Muse Code does not appear to be installed. Install it now? [Y/n]: ' >&2
      read_default answer "Y"
      case "$answer" in
        [Yy]|[Yy][Ee][Ss]) install_muse ;;
        [Nn]|[Nn][Oo]) muse_missing_error ;;
        *) fail "expected Y or n for the Muse Code install prompt" ;;
      esac
      if ! muse_installed; then
        fail "Muse Code was still not found after installation. Open a new terminal and re-run this installer."
      fi
    else
      muse_missing_error
    fi
  fi

  if (( CONFIG_DIR_EXPLICIT )); then
    log "  using      $CONFIG_DIR (explicit)"
    return 0
  fi

  local -a candidates=()
  local saved candidate typed
  saved="$(read_saved_config_dir || true)"
  [[ -n "$saved" ]] && candidates+=("$saved")
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    candidates+=("$XDG_CONFIG_HOME/muse")
  fi
  candidates+=("$HOME/.config/muse" "$HOME/.muse")
  [[ -n "${APPDATA:-}" ]] && candidates+=("$APPDATA/muse")
  [[ -n "${LOCALAPPDATA:-}" ]] && candidates+=("$LOCALAPPDATA/muse")

  for candidate in "${candidates[@]}"; do
    if valid_muse_config_dir "$candidate"; then
      CONFIG_DIR="$candidate"
      log "  found      Muse config at $CONFIG_DIR"
      return 0
    fi
  done

  if preflight_interactive; then
    while :; do
      printf 'Where is your Muse config directory? ' >&2
      read_answer typed || fail "no Muse config directory was supplied"
      typed="$(expand_user_path "$(trim_value "$typed")")"
      if valid_muse_config_dir "$typed"; then
        CONFIG_DIR="$typed"
        save_config_dir "$CONFIG_DIR"
        log "  using      Muse config at $CONFIG_DIR"
        log "  saved      $MUSE_SQUAD_STATE_FILE"
        return 0
      fi
      printf '  not a Muse config directory (need settings.json, auth.json, trust.json, agents/, skills/, or mcp/)\n' >&2
    done
  fi

  fail "could not find a Muse config directory. Pass --dir PATH, set MUSE_CONFIG_DIR, or re-run in a terminal."
}

backup_config() {
  [[ -d "$CONFIG_DIR" ]] || { log "  skip backup  no existing config dir"; return 0; }

  if [[ "$BACKUP_CHOICE" == "no" ]]; then
    log "  skipped      backup (--no-backup)"
    return 0
  fi

  local answer="Y"
  if interactive_input; then
    printf 'Back up current Muse config before continuing? [Y/n]: ' >&2
    read_default answer "Y"
  else
    log "  no interactive terminal detected; backing up by default"
  fi

  case "$answer" in
    ''|[Yy]|[Yy][Ee][Ss]) ;;
    [Nn]|[Nn][Oo])
      log "  skipped      backup (user chose no)"
      return 0 ;;
    *)
      fail "expected Y or n for backup prompt" ;;
  esac

  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  backup="${CONFIG_DIR}.backup.${stamp}"
  mkdir -p "$backup" || fail "cannot create backup dir $backup"
  chmod 700 "$backup" || fail "cannot secure backup dir $backup"
  cp -a "$CONFIG_DIR/." "$backup/" || fail "cannot back up $CONFIG_DIR to $backup"
  log "  backed up    $CONFIG_DIR -> $backup"
  log "  restore      $backup"
}

install_file() {
  local rel="$1" dest="$CONFIG_DIR/$1" tmp bak
  mkdir -p "$(dirname "$dest")" || fail "cannot create directory for $dest"
  tmp="$(mktemp "${TMPDIR:-/tmp}/muse-squad.XXXXXX")" || fail "mktemp failed"
  cat > "$tmp"
  if [[ -f "$dest" ]]; then
    if cmp -s "$tmp" "$dest" || diff -q --strip-trailing-cr "$tmp" "$dest" >/dev/null 2>&1; then
      rm -f "$tmp"; log "  unchanged  $dest"; return 0
    fi
  fi
  if [[ -f "$dest" ]]; then
    bak="${dest}.bak.$(date +%Y%m%d%H%M%S)"
    mv "$dest" "$bak" || fail "cannot back up $dest"
    log "  backed up  $dest -> $bak"
  fi
  mv "$tmp" "$dest" || fail "cannot install $dest"
  log "  installed  $dest"
}

uninstall_file() {
  local dest="$CONFIG_DIR/$1"
  if [[ -f "$dest" ]]; then
    rm -f "$dest" || fail "cannot remove $dest"
    log "  removed    $dest"
  fi
}

AGENTS_BEGIN='<!-- muse-squad:begin -->'
AGENTS_END='<!-- muse-squad:end -->'

policy_target() {
  if [[ -f "$CONFIG_DIR/AGENTS.md" ]]; then
    printf '%s\n' "$CONFIG_DIR/AGENTS.md"
  elif [[ -f "$CONFIG_DIR/MUSE.md" ]]; then
    printf '%s\n' "$CONFIG_DIR/MUSE.md"
  else
    printf '%s\n' "$CONFIG_DIR/AGENTS.md"
  fi
}

trim_trailing_newlines() {
  local value="$1"
  while [[ "$value" == *$'\n' ]]; do value="${value%$'\n'}"; done
  printf '%s' "$value"
}

install_agents_policy() {
  local dest content existing updated before after bak
  dest="$(policy_target)"
  content="$(cat)"
  mkdir -p "$(dirname "$dest")" || fail "cannot create directory for $dest"
  existing=""
  if [[ -f "$dest" ]]; then existing="$(cat "$dest")"; fi

  if [[ "$existing" == *"$AGENTS_BEGIN"* || "$existing" == *"$AGENTS_END"* ]]; then
    if [[ "$existing" != *"$AGENTS_BEGIN"*"$AGENTS_END"* ||
          "$existing" == *"$AGENTS_END"*"$AGENTS_BEGIN"* ]]; then
      log "  warning    $dest has a partial or reordered muse-squad block; left unchanged"
      return 0
    fi
    before="${existing%%$AGENTS_BEGIN*}"
    after="${existing#*$AGENTS_END}"
    updated="$(trim_trailing_newlines "$before")${content}$(trim_trailing_newlines "$after")"
  elif [[ -n "$existing" ]]; then
    updated="$(trim_trailing_newlines "$existing")"$'\n\n'"${content}"
  else
    updated="${content}"
  fi
  updated="$(trim_trailing_newlines "$updated")"$'\n'

  if [[ -f "$dest" ]] && cmp -s <(printf '%s' "$updated") "$dest"; then
    log "  unchanged  $dest"
    return 0
  fi
  if [[ -f "$dest" ]]; then
    bak="${dest}.bak.$(date +%Y%m%d%H%M%S)"
    mv "$dest" "$bak" || fail "cannot back up $dest"
    log "  backed up  $dest -> $bak"
  fi
  printf '%s' "$updated" > "$dest" || fail "cannot install $dest"
  log "  installed  $dest"
}

uninstall_agents_policy() {
  local dest existing before after updated
  for dest in "$CONFIG_DIR/AGENTS.md" "$CONFIG_DIR/MUSE.md"; do
    [[ -f "$dest" ]] || continue
    existing="$(cat "$dest")"
    if [[ "$existing" != *"$AGENTS_BEGIN"* || "$existing" != *"$AGENTS_END"* ]]; then
      continue
    fi
    if [[ "$existing" == *"$AGENTS_END"*"$AGENTS_BEGIN"* ]]; then
      log "  warning    $dest has a reordered muse-squad block; left unchanged"
      continue
    fi
    before="$(trim_trailing_newlines "${existing%%$AGENTS_BEGIN*}")"
    after="$(trim_trailing_newlines "${existing#*$AGENTS_END}")"
    if [[ -n "$before" && -n "$after" ]]; then
      updated="${before}"$'\n\n'"${after}"$'\n'
    elif [[ -n "$before" ]]; then
      updated="${before}"$'\n'
    elif [[ -n "$after" ]]; then
      updated="${after}"$'\n'
    else
      rm -f "$dest" || fail "cannot remove $dest"
      log "  removed    $dest"
      continue
    fi
    printf '%s' "$updated" > "$dest" || fail "cannot update $dest"
    log "  updated    $dest"
  done
}

install_config() {
  local dest="$CONFIG_DIR/muse-squad.toml" tmp
  if [[ -f "$dest" ]]; then
    log "  unchanged  $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")" || fail "cannot create directory for $dest"
  tmp="$(mktemp "${TMPDIR:-/tmp}/muse-squad-config.XXXXXX")" || fail "mktemp failed"
  cat > "$tmp"
  chmod 600 "$tmp" || fail "cannot set permissions on $dest"
  mv "$tmp" "$dest" || fail "cannot install $dest"
  log "  created    $dest"
}

available_providers() {
  local config="$CONFIG_DIR/muse-squad.toml" parser="$CONFIG_DIR/mcp/config.js" output
  if command -v node >/dev/null 2>&1 && [[ -f "$config" && -f "$parser" ]]; then
    output="$(node "$parser" --file "$config" --list-providers 2>/dev/null)" || output=""
    if [[ -n "$output" ]]; then
      printf '%s\n' "$output"
      return 0
    fi
  fi
  # The squad section may be invalid from an earlier interrupted wizard. The
  # provider tables are independent, so read their headings directly as a
  # fallback and let the rewritten config be validated before it is installed.
  [[ -f "$config" ]] || return 0
  sed -n 's/^\[providers\.\([^]]*\)\][[:space:]]*$/\1/p' "$config" 2>/dev/null
}

existing_charter() {
  local config="$1" name="$2" parser="$CONFIG_DIR/mcp/config.js"
  if command -v node >/dev/null 2>&1 && [[ -f "$config" && -f "$parser" ]]; then
    node -e '
      const config = require(process.argv[1]).loadConfig({ config_file: process.argv[2] });
      const member = config.squad.members[process.argv[3]];
      if (member) process.stdout.write(member.charter.replace(/\s+/g, " ").trim());
    ' "$parser" "$config" "$name" 2>/dev/null || true
  fi
}

wizard_interactive() {
  [[ "$MODE" == "install" ]] || return 1
  (( USE_DEFAULTS )) && return 1
  interactive_input
}

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

normalize_member_name() {
  local value="$1" slug
  slug="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')"
  [[ -n "$slug" ]] || slug="member"
  printf '%s' "$slug"
}

prompt_default() {
  local __var="$1" prompt="$2" default="$3" answer
  printf '%s [%s]: ' "$prompt" "$default" >&2
  read_default answer "$default"
  printf -v "$__var" '%s' "$answer"
}

resolve_provider_selection() {
  local answer="$1" default="$2" index
  [[ -z "$answer" ]] && { printf '%s' "$default"; return 0; }
  if [[ "$answer" =~ ^[0-9]+$ ]]; then
    index=$((answer - 1))
    if (( index >= 0 && index < ${#WIZARD_PROVIDERS[@]} )); then
      printf '%s' "${WIZARD_PROVIDERS[$index]}"
      return 0
    fi
    printf '  invalid provider number: %s\n' "$answer" >&2
    return 1
  fi
  printf '%s' "$answer"
}

resolve_provider_list() {
  local answer="$1" default="$2" resolved part out=""
  [[ -z "$answer" ]] && { printf '%s' "$default"; return 0; }
  local -a parts=()
  IFS=',' read -r -a parts <<< "$answer"
  for part in "${parts[@]}"; do
    part="$(trim_value "$part")"
    [[ -n "$part" ]] || continue
    if ! resolved="$(resolve_provider_selection "$part" "")"; then
      return 1
    fi
    [[ -n "$out" ]] && out+=","
    out+="$resolved"
  done
  printf '%s' "$out"
}

provider_is_known() {
  local candidate="$1" known
  for known in "${WIZARD_PROVIDERS[@]-}"; do
    [[ "$known" == "$candidate" ]] && return 0
  done
  return 1
}

validate_provider_list() {
  local list="$1" part
  [[ -z "$list" ]] && return 0
  local -a parts=()
  IFS=',' read -r -a parts <<< "$list"
  for part in "${parts[@]}"; do
    provider_is_known "$part" || return 1
  done
  return 0
}

member_name_is_usable() {
  local name="$1"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  # A numeric-only name is a valid slug but is almost always a mistaken
  # provider-menu answer. Reject it here so the wizard can ask again.
  [[ "$name" =~ ^[0-9]+$ ]] && return 1
  return 0
}

value_in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

validate_fallback_list() {
  local primary="$1" list="$2" part
  [[ -z "$list" ]] && return 0
  if ! validate_provider_list "$list"; then
    printf '  unknown provider in fallback list: %s\n' "$list" >&2
    return 1
  fi
  local -a parts=() seen=()
  IFS=',' read -r -a parts <<< "$list"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    if [[ "$part" == "$primary" ]]; then
      printf '  fallback must not repeat the primary provider: %s\n' "$part" >&2
      return 1
    fi
    if (( ${#seen[@]} > 0 )) && value_in_list "$part" "${seen[@]}"; then
      printf '  fallback must not contain duplicate providers: %s\n' "$part" >&2
      return 1
    fi
    seen+=("$part")
  done
  return 0
}

is_name_used() {
  local candidate="$1" used
  for used in "${USED_NAMES[@]-}"; do
    [[ "$used" == "$candidate" ]] && return 0
  done
  return 1
}

render_team_config() {
  local config_file="$1" members_file="$2" node_file
  node_file="$(mktemp "${TMPDIR:-/tmp}/muse-squad-render.XXXXXX")" || fail "mktemp failed"
  cat > "$node_file" <<'NODE'
const fs = require('fs');
const path = require('path');

const configFile = process.argv[2];
const membersFile = process.argv[3];

function quote(value) {
  return JSON.stringify(String(value));
}

function quoteBlock(value) {
  const text = String(value).trim();
  if (text.includes('"""')) return quote(text);
  return `"""\n${text}\n"""`;
}

const raw = fs.readFileSync(configFile, 'utf8');
const marker = raw.match(/^\[squad\][ \t]*$/m);
if (!marker) throw new Error('muse-squad.toml has no [squad] table');
const prefix = raw.slice(0, marker.index).replace(/\r?\n+$/, '\n');

function squadValue(key, fallback) {
  const match = prefix.match(new RegExp(`^${key}[ \\t]*=[ \\t]*("(?:[^"\\\\]|\\\\.)*")[ \\t]*$`, 'm'));
  return match ? JSON.parse(match[1]) : fallback;
}

const members = fs.readFileSync(membersFile, 'utf8').split(/\r?\n/)
  .filter((line) => line.length > 0)
  .map((line) => {
    const fields = line.split('\t');
    if (fields.length !== 4) throw new Error(`bad member line: ${line}`);
    const [name, primary, fallback, charter] = fields;
    return {
      name,
      primary,
      fallback: fallback ? fallback.split(',') : [],
      charter
    };
  });

const lines = [
  '[squad]',
  `name = ${quote(squadValue('name', 'Muse Squad'))}`,
  `memory_dir = ${quote(squadValue('memory_dir', '.muse/squad'))}`,
  ''
];
for (const member of members) {
  lines.push(
    `[squad.${member.name}]`,
    `primary = ${quote(member.primary)}`,
    `fallback = [${member.fallback.map(quote).join(', ')}]`,
    `charter = ${quoteBlock(member.charter)}`,
    ''
  );
}
process.stdout.write(`${prefix}${lines.join('\n')}`);
NODE
  if ! node "$node_file" "$config_file" "$members_file"; then
    rm -f "$node_file"
    fail "team config generation failed"
  fi
  rm -f "$node_file"
}

validate_rendered_config() {
  local file="$1" parser="$CONFIG_DIR/mcp/config.js"
  command -v node >/dev/null 2>&1 || return 0
  [[ -f "$parser" ]] || return 0
  node "$parser" --file "$file" --list-providers >/dev/null 2>&1
}

configure_team() {
  local dest="$CONFIG_DIR/muse-squad.toml" action="created" seeded=0
  if (( FIRST_INSTALL )); then
    # Seed first so the provider menu can be built from the default TOML, then
    # let an interactive wizard replace it.
    if [[ ! -f "$dest" ]]; then
      install_default_config
      seeded=1
    fi
    if ! wizard_interactive || ! command -v node >/dev/null 2>&1; then
      return 0
    fi
  else
    action="updated"
    if (( ! RECONFIGURE_TEAM )); then
      log "  unchanged  $dest"
      return 0
    fi
    if ! wizard_interactive; then
      log "  unchanged  $dest (team wizard skipped)"
      return 0
    fi
    if ! command -v node >/dev/null 2>&1; then
      log "  warning    node not found; keeping existing team config"
      return 0
    fi
  fi

  local customize_answer="Y"
  printf 'Customize Squad team members & models now? [Y/n]: ' >&2
  read_default customize_answer "Y"
  case "$customize_answer" in
    [Yy]|[Yy][Ee][Ss]) ;;
    [Nn]|[Nn][Oo])
      if (( seeded )); then
        log "  kept defaults  $dest"
      else
        log "  unchanged  $dest"
      fi
      return 0 ;;
    *)
      fail "expected Y or n for team customization prompt" ;;
  esac

  local provider
  WIZARD_PROVIDERS=()
  while IFS= read -r provider; do
    [[ -n "$provider" ]] || continue
    if ! provider_is_known "$provider"; then
      WIZARD_PROVIDERS+=("$provider")
    fi
  done < <(available_providers)
  (( ${#WIZARD_PROVIDERS[@]} > 0 )) || fail "no providers are defined in $dest"

  WIZARD_PROVIDER_MENU=""
  local i
  for i in "${!WIZARD_PROVIDERS[@]}"; do
    [[ -n "$WIZARD_PROVIDER_MENU" ]] && WIZARD_PROVIDER_MENU+=", "
    WIZARD_PROVIDER_MENU+="$((i + 1)): ${WIZARD_PROVIDERS[$i]}"
  done

  local -a default_names=(team-lead frontend backend tester secretary)
  local -a default_primary=(Muse-Spark Home-Ornith Home-Ornith Home-Ornith Muse-Ember)
  local -a default_fallback=("DeepSeek-Flash" "Muse-Ember" "DeepSeek-Flash" "Muse-Ember" "Home-Ornith")
  local -a names=() primaries=() fallbacks=() charters=()
  USED_NAMES=()
  local name primary fallback charter answer
  local raw_name raw_primary raw_fallback charter_default

  for i in 0 1 2 3 4; do
    while :; do
      prompt_default name "Member $((i + 1)) name" "${default_names[$i]}"
      name="$(normalize_member_name "$name")"
      if ! member_name_is_usable "$name"; then
        printf '  member name must include at least one letter\n' >&2
        continue
      fi
      if is_name_used "$name"; then
        printf '  name already in use: %s\n' "$name" >&2
        continue
      fi
      break
    done

    while :; do
      prompt_default raw_primary "Primary provider for $name ($WIZARD_PROVIDER_MENU)" "${default_primary[$i]}"
      if primary="$(resolve_provider_selection "$raw_primary" "${default_primary[$i]}")"; then
        if provider_is_known "$primary"; then
          break
        fi
        printf '  unknown provider: %s\n' "$primary" >&2
      fi
    done

    while :; do
      prompt_default raw_fallback "Fallback providers for $name (comma-separated, empty for none)" "${default_fallback[$i]}"
      if fallback="$(resolve_provider_list "$raw_fallback" "${default_fallback[$i]}")" && \
         validate_fallback_list "$primary" "$fallback"; then
        break
      fi
    done

    charter_default="$(existing_charter "$dest" "$name")"
    [[ -n "$charter_default" ]] || charter_default="Domain expertise: $name tasks. Voice: concise and evidence-first. Guardrails: stay scoped to assigned files, preserve existing conventions, and verify changes before reporting done."
    while :; do
      prompt_default charter "Charter for $name" "$charter_default"
      charter="$(printf '%s' "$charter" | tr '\t' ' ' | tr '\n' ' ' | tr -s ' ')"
      [[ -n "$charter" ]] && break
      printf '  charter cannot be empty\n' >&2
    done

    names+=("$name")
    primaries+=("$primary")
    fallbacks+=("$fallback")
    charters+=("$charter")
    USED_NAMES+=("$name")
  done

  while :; do
    printf 'Add another team member? [y/N]: ' >&2
    read_default answer ""
    case "$answer" in
      [Yy]|[Yy][Ee][Ss]) ;;
      *) break ;;
    esac

    while :; do
      printf 'Extra member name: ' >&2
      read_default raw_name ""
      [[ -n "$raw_name" ]] || { printf '  name cannot be empty\n' >&2; continue; }
      name="$(normalize_member_name "$raw_name")"
      if ! member_name_is_usable "$name"; then
        printf '  member name must include at least one letter\n' >&2
        continue
      fi
      if is_name_used "$name"; then
        printf '  name already in use: %s\n' "$name" >&2
        continue
      fi
      break
    done

    while :; do
      prompt_default raw_primary "Primary provider for $name ($WIZARD_PROVIDER_MENU)" 'Muse-Ember'
      if primary="$(resolve_provider_selection "$raw_primary" 'Muse-Ember')"; then
        if provider_is_known "$primary"; then
          break
        fi
        printf '  unknown provider: %s\n' "$primary" >&2
      fi
    done

    while :; do
      prompt_default raw_fallback "Fallback providers for $name (comma-separated, empty for none)" 'Home-Ornith'
      if fallback="$(resolve_provider_list "$raw_fallback" 'Home-Ornith')" && \
         validate_fallback_list "$primary" "$fallback"; then
        break
      fi
    done

    charter_default='Domain expertise: bounded implementation tasks. Voice: concise and evidence-first. Guardrails: stay scoped to assigned files, preserve existing conventions, and verify changes before reporting done.'
    while :; do
      prompt_default charter "Charter for $name" "$charter_default"
      charter="$(printf '%s' "$charter" | tr '\t' ' ' | tr '\n' ' ' | tr -s ' ')"
      [[ -n "$charter" ]] && break
      printf '  charter cannot be empty\n' >&2
    done

    names+=("$name")
    primaries+=("$primary")
    fallbacks+=("$fallback")
    charters+=("$charter")
    USED_NAMES+=("$name")
  done

  local members_file config_tmp
  members_file="$(mktemp "${TMPDIR:-/tmp}/muse-squad-members.XXXXXX")" || fail "mktemp failed"
  config_tmp="$(mktemp "${TMPDIR:-/tmp}/muse-squad-config.XXXXXX")" || fail "mktemp failed"
  : > "$members_file"
  for i in "${!names[@]}"; do
    printf '%s\t%s\t%s\t%s\n' \
      "${names[$i]}" "${primaries[$i]}" "${fallbacks[$i]}" "${charters[$i]}" >> "$members_file"
  done
  render_team_config "$dest" "$members_file" > "$config_tmp" || fail "cannot render $dest"
  if ! validate_rendered_config "$config_tmp"; then
    rm -f "$members_file" "$config_tmp"
    fail "team config failed validation; no changes were written"
  fi
  mkdir -p "$(dirname "$dest")" || fail "cannot create directory for $dest"
  mv "$config_tmp" "$dest" || fail "cannot install $dest"
  rm -f "$members_file"
  log "  $action    $dest"
}

run_sync_team() {
  local action="$1" script="$CONFIG_DIR/mcp/sync-team.js"
  if ! command -v node >/dev/null 2>&1; then
    log "  warning    node not found on PATH; skipping team materialization"
    return 0
  fi
  if [[ ! -f "$script" ]]; then
    log "  warning    $script missing; skipping team materialization"
    return 0
  fi
  local -a args=("$script" --config-dir "$CONFIG_DIR")
  if [[ "$action" == "uninstall" ]]; then
    args+=(--uninstall)
  fi
  node "${args[@]}" || fail "team materialization failed"
}

register_mcp() {
  local action="$1" registrar="$CONFIG_DIR/mcp/register-settings.js"
  if (( SKIP_MCP )) || [[ "${MUSE_SQUAD_SKIP_MCP:-0}" == "1" ]]; then
    log "  skipped    MCP registration"
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    log "  warning    node not found on PATH; skipping MCP registration"
    return 0
  fi
  local node_major
  node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || printf '0')"
  if [[ "$node_major" =~ ^[0-9]+$ ]] && (( node_major < 18 )); then
    log "  warning    node $node_major is too old; MCP bridge requires Node 18+"
  fi
  if [[ ! -f "$registrar" ]]; then
    log "  warning    $registrar missing; skipping MCP registration"
    return 0
  fi
  local -a args=(--settings "$CONFIG_DIR/settings.json" --bridge "$CONFIG_DIR/mcp/bridge.js")
  if [[ "$action" == "unregister" ]]; then
    node "$registrar" "${args[@]}" --unregister
    return $?
  fi
  args+=(--config-file "$CONFIG_DIR/muse-squad.toml")
  node "$registrar" "${args[@]}"
}

self_update() {
  local url="$REPO_RAW_BASE/install" tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/muse-squad-update.XXXXXX")" || fail "mktemp failed"
  log "  fetching   $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tmp" || fail "cannot download latest installer"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$url" || fail "cannot download latest installer"
  else
    rm -f "$tmp"
    fail "--update requires curl or wget"
  fi
  chmod +x "$tmp" || true
  local -a args=(--dir "$CONFIG_DIR" --defaults)
  (( SKIP_MCP )) && args+=(--no-mcp)
  (( SKIP_MUSE_CHECK )) && args+=(--skip-muse-check)
  [[ "$BACKUP_CHOICE" == "yes" ]] && args+=(--backup)
  [[ "$BACKUP_CHOICE" == "no" ]] && args+=(--no-backup)
  # --update must never trigger a reconfigure on the downloaded installer.
  log "  running    latest installer"
  bash "$tmp" "${args[@]}"
  rc=$?
  rm -f "$tmp"
  return $rc
}

if [[ "$MODE" != "uninstall" ]]; then
  preflight
fi

log "muse-squad v$VERSION - $MODE"
log "config dir: $CONFIG_DIR"

if [[ "$MODE" == "update" ]]; then
  self_update || exit $?
  # The downloaded installer already did the work; keep reading to EOF so a
  # piped `curl ... | bash` does not report a broken pipe.
  MODE="updated"
fi

FIRST_INSTALL=0
if [[ ! -f "$CONFIG_DIR/muse-squad.toml" ]]; then
  FIRST_INSTALL=1
fi

if [[ "$MODE" != "updated" ]]; then
  backup_config
fi

if [[ "$MODE" == "uninstall" ]]; then
  register_mcp unregister
  uninstall_agents_policy
  run_sync_team uninstall
  if [[ -d "$CONFIG_DIR/squad" ]]; then
    rm -rf "$CONFIG_DIR/squad" || fail "cannot remove $CONFIG_DIR/squad"
    log "  removed    $CONFIG_DIR/squad"
  fi
BODY

    for rel in "${MANAGED_PATHS[@]}" "${LEGACY_AGENTS[@]}"; do
      printf '  uninstall_file %q\n' "$rel"
    done

    cat <<'MID'
  if [[ -f "$CONFIG_DIR/muse-squad.toml" ]]; then
    log "  kept       $CONFIG_DIR/muse-squad.toml (config is never removed)"
  fi
  log "done."
elif [[ "$MODE" == "updated" ]]; then
  :
else

MID

    for rel in "${MANAGED_PATHS[@]}"; do
      i=$((i + 1))
      delim="MSQ_PAYLOAD_$(printf '%03d' "$i")"
      content="$(cat "$PAYLOAD_DIR/$rel")"
      printf "install_file %q <<'%s'\n" "$rel" "$delim"
      printf '%s\n' "$content"
      printf '%s\n' "$delim"
    done

    printf "install_default_config() {\n"
    printf "  install_config <<'MSQ_CONFIG_DEFAULT'\n"
    cat "$CONFIG_DEFAULT"
    printf 'MSQ_CONFIG_DEFAULT\n'
    printf "}\n"

    printf "install_agents_policy <<'MSQ_AGENTS_POLICY'\n"
    printf '%s\n' '<!-- muse-squad:begin -->'
    cat "$AGENTS_POLICY"
    printf '%s\n' '<!-- muse-squad:end -->'
    printf 'MSQ_AGENTS_POLICY\n'

    for rel in "${LEGACY_AGENTS[@]}"; do
      printf 'uninstall_file %q\n' "$rel"
    done

    cat <<'FOOT'
configure_team
run_sync_team install
register_mcp install
if [[ "$MODE" == "install" && "$FIRST_INSTALL" == "1" ]]; then
  log ""
  log "Next steps:"
  log "  1. Configure: edit $CONFIG_DIR/muse-squad.toml (providers, endpoints, and squad members)."
  log "  2. Use in Muse Code: /squad-plan to create .muse/PLAN.md, then /squad-execute."
  log "  3. Customize: edit muse-squad.toml; generated agents in $CONFIG_DIR/agents/ are rebuilt from it."
  log "  4. Check setup any time with /squad-doctor."
  log "  5. Update later: re-run this installer with --update."
fi
log "done."
fi
FOOT
  } > "$out"
  chmod +x "$out"
  printf 'generated %s\n' "$out"
}

emit_powershell() {
  local out="$ROOT/install.ps1" rel content
  {
    cat <<'HDR'
#requires -Version 5.1
# muse-squad installer - GENERATED FILE, DO NOT EDIT BY HAND.
# Source of truth: payload/ + scripts/generate-installers.sh

$ErrorActionPreference = 'Stop'

HDR
    printf "\$Version = '%s'\n" "$VERSION"
    cat <<'BODY'
$configDir = if ($env:MUSE_CONFIG_DIR) { $env:MUSE_CONFIG_DIR } else { Join-Path $HOME '.config/muse' }
$configDirExplicit = [bool]$env:MUSE_CONFIG_DIR
$mode = 'install'
$help = $false
$skipMcp = $false
$skipMuseCheck = $false
$backupChoice = 'auto'
$reconfigureTeam = $false
$useDefaults = $false
$repoRawBase = 'https://raw.githubusercontent.com/tenantegroup/muse-squad/main'
$stateFile = Join-Path $HOME '.config/muse-squad/config-dir'
if ($null -eq $args) { $args = @() }

for ($i = 0; $i -lt $args.Count; $i++) {
  switch -CaseSensitive ($args[$i]) {
    '--update' { $mode = 'update' }
    '--uninstall' { $mode = 'uninstall' }
    '--no-mcp' { $skipMcp = $true }
    '--backup' { $backupChoice = 'yes' }
    '--no-backup' { $backupChoice = 'no' }
    '--reconfigure-team' { $reconfigureTeam = $true }
    '--defaults' { $useDefaults = $true }
    '--skip-muse-check' { $skipMuseCheck = $true }
    '--dir' {
      if (($i + 1) -ge $args.Count) { throw '--dir requires a value' }
      $configDir = $args[++$i]
      $configDirExplicit = $true
    }
    '-h' { $help = $true }
    '--help' { $help = $true }
    default { throw "Unknown option: $($args[$i])" }
  }
}

$configDir = [IO.Path]::GetFullPath($configDir)
if ($configDir -notmatch '^[A-Za-z]:[\\/]?$') {
  $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $configDir = $configDir.TrimEnd($trimChars)
}
if ($backupChoice -eq 'auto' -and $env:MUSE_SQUAD_NO_BACKUP -eq '1') {
  $backupChoice = 'no'
}
if ($env:MUSE_SQUAD_SKIP_MUSE_CHECK -eq '1') {
  $skipMuseCheck = $true
}

if ($help) {
  @'
muse-squad installer

Usage:
  irm https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install.ps1 | iex
  powershell -File install.ps1 [--dir PATH] [--update] [--uninstall] [--no-mcp]
  powershell -File install.ps1 [--reconfigure-team] [--defaults] [--skip-muse-check]

Options:
  --dir PATH          Install into PATH instead of ~/.config/muse
  --update            Download and run the latest installer from GitHub, then install
  --uninstall         Remove managed files and unregister muse-squad
  --no-mcp            Skip muse-squad MCP registration
  --backup            Force a backup prompt/backup
  --no-backup         Skip the backup prompt and backup
  --reconfigure-team  Rerun the interactive team wizard on an existing install
  --defaults          Skip the team wizard and use the default roster
  --skip-muse-check   Skip Muse install/config discovery
  --help, -h          Show this help

Environment:
  MUSE_CONFIG_DIR          Equivalent to --dir (useful with irm | iex)
  MUSE_SQUAD_SKIP_MCP      Set to 1 to skip MCP registration
  MUSE_SQUAD_NO_BACKUP     Set to 1 to skip backup unless --backup is passed
  MUSE_SQUAD_SKIP_MUSE_CHECK Set to 1 to skip Muse install/config discovery
  MUSE_SQUAD_FORCE_INTERACTIVE Set to 1 to attempt prompts even without a TTY
  MUSE_SQUAD_TTY           Terminal device for prompts (default /dev/tty or CONIN$)

Providers and squad members are configured in muse-squad.toml inside the config directory.

Note: Windows PowerShell 5.1 has no `irm` alias. Use:
  Invoke-RestMethod 'https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install.ps1' | iex
'@ | Write-Host
  return
}

function Get-Dest([string]$rel) {
  $parts = $rel -replace '/', [IO.Path]::DirectorySeparatorChar
  return [IO.Path]::GetFullPath((Join-Path $configDir $parts))
}

# When the installer is piped in, stdin carries the script rather than user
# input. Read prompts from the controlling console/TTY when one is available.
$script:ConsoleInputPath = $env:MUSE_SQUAD_TTY
if ([string]::IsNullOrWhiteSpace($script:ConsoleInputPath)) {
  if ([IO.Path]::DirectorySeparatorChar -eq '\') { $script:ConsoleInputPath = 'CONIN$' }
  else { $script:ConsoleInputPath = '/dev/tty' }
}
$script:ConsoleInputReader = $null

function Get-Console-Input-Reader {
  if ($null -ne $script:ConsoleInputReader) { return $script:ConsoleInputReader }
  try {
    $reader = New-Object System.IO.StreamReader -ArgumentList $script:ConsoleInputPath
    $script:ConsoleInputReader = $reader
    return $reader
  } catch {
    return $null
  }
}

function Test-Console-Input {
  try {
    if (-not [Environment]::UserInteractive) { return $false }
    if (-not [Console]::IsInputRedirected) { return $true }
    return ($null -ne (Get-Console-Input-Reader))
  } catch {
    return $false
  }
}

function Read-Interactive([string]$prompt) {
  if ([Console]::IsInputRedirected) {
    $reader = Get-Console-Input-Reader
    if ($null -ne $reader) {
      Write-Host "$prompt`: " -NoNewline
      return $reader.ReadLine()
    }
  }
  return Read-Host $prompt
}

function Test-Preflight-Interactive {
  if ($env:MUSE_SQUAD_FORCE_INTERACTIVE -eq '1') { return $true }
  return (Test-Console-Input)
}

function Show-Muse-Missing-Error {
  throw 'Muse Code was not found. Install it with irm https://dev.meta.ai/install.ps1 | iex (Windows) or curl -fsSL https://dev.meta.ai/install.sh | bash (macOS/Linux), then re-run. Pass --skip-muse-check to bypass.'
}

function Test-Muse-Installed {
  $cmd = Get-Command muse -CommandType Application -ErrorAction SilentlyContinue
  if ($cmd) {
    try {
      & $cmd.Source --version *> $null
      if ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) { return $true }
    } catch {
      # Try known install paths below.
    }
  }
  $candidates = @()
  if ($env:LOCALAPPDATA) {
    $candidates += (Join-Path $env:LOCALAPPDATA 'Programs/muse/muse.cmd')
    $candidates += (Join-Path $env:LOCALAPPDATA 'Programs/Muse Code/muse.cmd')
  }
  if ($env:ProgramFiles) {
    $candidates += (Join-Path $env:ProgramFiles 'Muse Code/muse.cmd')
  }
  $candidates += (Join-Path $HOME '.local/bin/muse')
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $true }
  }
  return $false
}

function Install-Muse {
  Write-Host '  installing  Muse Code via the official installer'
  Invoke-RestMethod 'https://dev.meta.ai/install.ps1' | Invoke-Expression
}

function Read-Saved-Config-Dir {
  if (-not (Test-Path -LiteralPath $stateFile)) { return '' }
  return ([string](Get-Content -LiteralPath $stateFile -Raw)).Trim()
}

function Save-Config-Dir([string]$dir) {
  $parent = Split-Path -Parent $stateFile
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  [IO.File]::WriteAllText($stateFile, "$dir`n", [System.Text.UTF8Encoding]::new($false))
  Write-Host "  saved      $stateFile"
}

function Test-Muse-Config-Dir([string]$dir) {
  if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $false }
  foreach ($marker in @('settings.json', 'auth.json', 'trust.json', 'agents', 'skills', 'mcp')) {
    if (Test-Path -LiteralPath (Join-Path $dir $marker)) { return $true }
  }
  return $false
}

function Invoke-Preflight {
  if ($skipMuseCheck) {
    Write-Host '  skipped    Muse preflight'
    return
  }

  if (-not (Test-Muse-Installed)) {
    if (Test-Preflight-Interactive) {
      $answer = Read-Interactive 'Muse Code does not appear to be installed. Install it now? [Y/n]'
      if ([string]::IsNullOrWhiteSpace($answer)) { $answer = 'Y' }
      if ($answer -match '^[Yy]([Ee][Ss])?$') {
        Install-Muse
      } elseif ($answer -match '^[Nn]([Oo])?$') {
        Show-Muse-Missing-Error
      } else {
        throw 'Expected Y or n for the Muse Code install prompt'
      }
      if (-not (Test-Muse-Installed)) {
        throw 'Muse Code was still not found after installation. Open a new terminal and re-run this installer.'
      }
    } else {
      Show-Muse-Missing-Error
    }
  }

  if ($configDirExplicit) {
    Write-Host "  using      $configDir (explicit)"
    return
  }

  $candidates = New-Object 'System.Collections.Generic.List[string]'
  $saved = Read-Saved-Config-Dir
  if ($saved) { $candidates.Add($saved) }
  if ($env:XDG_CONFIG_HOME) { $candidates.Add((Join-Path $env:XDG_CONFIG_HOME 'muse')) }
  $candidates.Add((Join-Path $HOME '.config/muse'))
  $candidates.Add((Join-Path $HOME '.muse'))
  if ($env:APPDATA) { $candidates.Add((Join-Path $env:APPDATA 'muse')) }
  if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'muse')) }

  foreach ($candidate in $candidates) {
    if (Test-Muse-Config-Dir $candidate) {
      $script:configDir = [IO.Path]::GetFullPath($candidate)
      Write-Host "  found      Muse config at $configDir"
      return
    }
  }

  if (Test-Preflight-Interactive) {
    while ($true) {
      $typed = Read-Interactive 'Where is your Muse config directory?'
      if ([string]::IsNullOrWhiteSpace($typed)) {
        Write-Host '  a config directory is required'
        continue
      }
      $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($typed)
      if (Test-Muse-Config-Dir $resolved) {
        $script:configDir = $resolved
        Save-Config-Dir $configDir
        Write-Host "  using      Muse config at $configDir"
        return
      }
      Write-Host '  not a Muse config directory (need settings.json, auth.json, trust.json, agents/, skills/, or mcp/)'
    }
  }

  throw 'Could not find a Muse config directory. Pass --dir PATH, set MUSE_CONFIG_DIR, or re-run in a terminal.'
}

function Backup-Config {
  if (-not (Test-Path -LiteralPath $configDir -PathType Container)) {
    Write-Host '  skip backup  no existing config dir'
    return
  }
  if ($backupChoice -eq 'no') {
    Write-Host '  skipped      backup (--no-backup)'
    return
  }

  $answer = 'Y'
  $interactive = $false
  try {
    $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
  } catch {
    $interactive = $false
  }
  if ($interactive) {
    $answer = Read-Interactive 'Back up current Muse config before continuing? [Y/n]'
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = 'Y' }
  } else {
    Write-Host '  no interactive input detected; backing up by default'
  }

  if ($answer -match '^[Yy]([Ee][Ss])?$') {
    # continue with the backup
  } elseif ($answer -match '^[Nn]([Oo])?$') {
    Write-Host '  skipped      backup (user chose no)'
    return
  } else {
    throw 'Expected Y or n for backup prompt'
  }

  $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID
  $parent = Split-Path -Parent $configDir
  $leaf = Split-Path -Leaf $configDir
  if ([string]::IsNullOrEmpty($parent)) { $parent = '.' }
  if ([string]::IsNullOrEmpty($leaf)) { $leaf = 'muse-config' }
  $backup = Join-Path $parent ($leaf + '.backup.' + $stamp)

  New-Item -ItemType Directory -Path $backup -Force | Out-Null
  Get-ChildItem -LiteralPath $configDir -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $backup -Recurse -Force
  }
  Write-Host "  backed up    $configDir -> $backup"
  Write-Host "  restore      $backup"
}

function Install-File([string]$rel, [string]$content) {
  $dest = Get-Dest $rel
  $parent = Split-Path -Parent $dest
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $normalized = $content -replace "(?:\r?\n)+\z", "`n"
  $existing = $null
  if (Test-Path -LiteralPath $dest) { $existing = [IO.File]::ReadAllText($dest) }
  if (($null -ne $existing) -and ($existing -ceq $normalized)) {
    Write-Host "  unchanged  $dest"
    return
  }
  if ($null -ne $existing) {
    $bak = "$dest.bak." + (Get-Date -Format 'yyyyMMddHHmmss')
    Move-Item -LiteralPath $dest -Destination $bak -Force
    Write-Host "  backed up  $dest -> $bak"
  }
  [IO.File]::WriteAllText($dest, $normalized, [System.Text.UTF8Encoding]::new($false))
  Write-Host "  installed  $dest"
}

function Uninstall-File([string]$rel) {
  $dest = Get-Dest $rel
  if (Test-Path -LiteralPath $dest) {
    Remove-Item -LiteralPath $dest -Force
    Write-Host "  removed    $dest"
  }
}

$agentsBegin = '<!-- muse-squad:begin -->'
$agentsEnd = '<!-- muse-squad:end -->'

function Get-Policy-File {
  $agents = Get-Dest 'AGENTS.md'
  if (Test-Path -LiteralPath $agents -PathType Leaf) { return $agents }
  $muse = Get-Dest 'MUSE.md'
  if (Test-Path -LiteralPath $muse -PathType Leaf) { return $muse }
  return $agents
}

function Trim-Newlines([string]$text, [string]$side) {
  $chars = [char[]]@("`r", "`n")
  if ($side -eq 'end') { return $text.TrimEnd($chars) }
  if ($side -eq 'start') { return $text.TrimStart($chars) }
  return $text.Trim($chars)
}

function Write-Policy-File([string]$dest, [string]$updated, [string]$verb, [bool]$makeBackup) {
  $parent = Split-Path -Parent $dest
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $normalized = $updated.TrimEnd([char[]]@("`r", "`n")) + "`n"
  $existing = $null
  if (Test-Path -LiteralPath $dest -PathType Leaf) { $existing = [IO.File]::ReadAllText($dest) }
  if (($null -ne $existing) -and ($existing -ceq $normalized)) {
    Write-Host "  unchanged  $dest"
    return
  }
  if (($null -ne $existing) -and $makeBackup) {
    $bak = "$dest.bak." + (Get-Date -Format 'yyyyMMddHHmmss')
    Move-Item -LiteralPath $dest -Destination $bak -Force
    Write-Host "  backed up  $dest -> $bak"
  }
  [IO.File]::WriteAllText($dest, $normalized, [System.Text.UTF8Encoding]::new($false))
  Write-Host "  $verb  $dest"
}

function Install-Agents-Policy([string]$content) {
  $dest = Get-Policy-File
  $block = $content.TrimEnd([char[]]@("`r", "`n"))
  $existing = $null
  if (Test-Path -LiteralPath $dest -PathType Leaf) { $existing = [IO.File]::ReadAllText($dest) }
  $beginIx = -1
  $endIx = -1
  if ($null -ne $existing) {
    $beginIx = $existing.IndexOf($agentsBegin, [StringComparison]::Ordinal)
    $endIx = $existing.IndexOf($agentsEnd, [StringComparison]::Ordinal)
  }
  $parts = @()
  if (($beginIx -ge 0) -or ($endIx -ge 0)) {
    if (($beginIx -lt 0) -or ($endIx -lt 0) -or ($endIx -lt $beginIx)) {
      Write-Host "  warning    $dest has a partial or reordered muse-squad block; left unchanged"
      return
    }
    $before = Trim-Newlines ($existing.Substring(0, $beginIx)) 'end'
    $after = Trim-Newlines ($existing.Substring($endIx + $agentsEnd.Length)) 'start'
    if ($before.Length -gt 0) { $parts += $before }
    $parts += $block
    if ($after.Length -gt 0) { $parts += $after }
  } else {
    if ($null -ne $existing) {
      $before = Trim-Newlines $existing 'end'
      if ($before.Length -gt 0) { $parts += $before }
    }
    $parts += $block
  }
  Write-Policy-File $dest ([string]::Join("`n`n", $parts)) 'installed' $true
}

function Uninstall-Agents-Policy {
  foreach ($name in @('AGENTS.md', 'MUSE.md')) {
    $dest = Get-Dest $name
    if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { continue }
    $existing = [IO.File]::ReadAllText($dest)
    $beginIx = $existing.IndexOf($agentsBegin, [StringComparison]::Ordinal)
    $endIx = $existing.IndexOf($agentsEnd, [StringComparison]::Ordinal)
    if (($beginIx -lt 0) -and ($endIx -lt 0)) { continue }
    if (($beginIx -lt 0) -or ($endIx -lt 0) -or ($endIx -lt $beginIx)) {
      Write-Host "  warning    $dest has a partial or reordered muse-squad block; left unchanged"
      continue
    }
    $before = Trim-Newlines ($existing.Substring(0, $beginIx)) 'end'
    $after = Trim-Newlines ($existing.Substring($endIx + $agentsEnd.Length)) 'start'
    $parts = @()
    if ($before.Length -gt 0) { $parts += $before }
    if ($after.Length -gt 0) { $parts += $after }
    if ($parts.Count -eq 0) {
      Remove-Item -LiteralPath $dest -Force
      Write-Host "  removed    $dest"
      continue
    }
    Write-Policy-File $dest ([string]::Join("`n`n", $parts)) 'updated' $false
  }
}

function Install-Config([string]$content) {
  $dest = Get-Dest 'muse-squad.toml'
  if (Test-Path -LiteralPath $dest) {
    Write-Host "  unchanged  $dest"
    return
  }
  $parent = Split-Path -Parent $dest
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $normalized = $content -replace "(?:\r?\n)+\z", "`n"
  [IO.File]::WriteAllText($dest, $normalized, [System.Text.UTF8Encoding]::new($false))
  try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule -ArgumentList @($identity, 'FullControl', 'Allow')
    $acl = Get-Acl -LiteralPath $dest
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $dest -AclObject $acl
  } catch {
    # ACLs are best effort; the file still owns the current user by default.
  }
  Write-Host "  created    $dest"
}

function Test-Interactive-Input {
  if ($env:MUSE_SQUAD_FORCE_INTERACTIVE -eq '1') { return $true }
  return (Test-Console-Input)
}

function Get-Available-Providers {
  $providers = New-Object 'System.Collections.Generic.List[string]'
  $configFile = Get-Dest 'muse-squad.toml'
  $parser = Get-Dest 'mcp/config.js'
  if ((Get-Command node -ErrorAction SilentlyContinue) -and
      (Test-Path -LiteralPath $configFile) -and (Test-Path -LiteralPath $parser)) {
    $output = & node $parser --file $configFile --list-providers 2>$null
    if ($LASTEXITCODE -eq 0 -and $output) {
      foreach ($line in $output) {
        $name = ([string]$line).Trim()
        if ($name -and -not $providers.Contains($name)) { $providers.Add($name) }
      }
      return $providers.ToArray()
    }
  }
  # Fall back to raw provider headings if the squad section is invalid.
  if (Test-Path -LiteralPath $configFile) {
    foreach ($line in (Get-Content -LiteralPath $configFile)) {
      if ($line -match '^\[providers\.([^\]]+)\]\s*$') {
        $name = $Matches[1].Trim()
        if ($name -and -not $providers.Contains($name)) { $providers.Add($name) }
      }
    }
  }
  return $providers.ToArray()
}

function Get-Provider-Menu([string[]]$providers) {
  $items = @()
  for ($i = 0; $i -lt $providers.Count; $i++) {
    $items += "$($i + 1): $($providers[$i])"
  }
  return ($items -join ', ')
}

function Get-Existing-Charter([string]$name) {
  $configFile = Get-Dest 'muse-squad.toml'
  $parser = Get-Dest 'mcp/config.js'
  if ((Get-Command node -ErrorAction SilentlyContinue) -and
      (Test-Path -LiteralPath $configFile) -and (Test-Path -LiteralPath $parser)) {
    $script = @'
const config = require(process.argv[1]).loadConfig({ config_file: process.argv[2] });
const member = config.squad.members[process.argv[3]];
if (member) process.stdout.write(member.charter.replace(/\s+/g, ' ').trim());
'@
    $output = & node -e $script $parser $configFile $name 2>$null
    if ($output) { return (([string]($output -join ' ')).Trim()) }
  }
  return ''
}

function Read-Defaulted([string]$prompt, [string]$default) {
  $answer = Read-Interactive "$prompt [$default]"
  if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
  return $answer
}

function Read-Required([string]$prompt, [string]$fallback) {
  $answer = Read-Interactive $prompt
  if ([string]::IsNullOrWhiteSpace($answer)) { return $fallback }
  return $answer
}

function ConvertTo-Member-Name([string]$value) {
  $slug = $value.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  $slug = $slug.Trim('-')
  if ([string]::IsNullOrEmpty($slug)) { $slug = 'member' }
  return $slug
}

function Resolve-Provider([string]$answer, [string]$default) {
  if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
  if ($answer -match '^\d+$') {
    $index = [int]$answer - 1
    if ($index -ge 0 -and $index -lt $script:WizardProviders.Count) {
      return $script:WizardProviders[$index]
    }
    Write-Host "  invalid provider number: $answer"
    return $null
  }
  return $answer
}

function Resolve-Provider-List([string]$answer, [string]$default) {
  if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
  $resolved = @()
  foreach ($part in ($answer -split ',')) {
    $part = ([string]$part).Trim()
    if (-not $part) { continue }
    $value = Resolve-Provider $part ''
    if ([string]::IsNullOrEmpty($value)) { return $null }
    $resolved += $value
  }
  return ($resolved -join ',')
}

function Test-Provider-Known([string]$candidate) {
  return ($script:WizardProviders -contains $candidate)
}

function Test-Provider-List([string]$list) {
  if ([string]::IsNullOrWhiteSpace($list)) { return $true }
  foreach ($part in ($list -split ',')) {
    if (-not (Test-Provider-Known ([string]$part).Trim())) { return $false }
  }
  return $true
}

function Test-Member-Name([string]$name) {
  if ($name -notmatch '^[a-z0-9][a-z0-9-]*$') { return $false }
  if ($name -match '^\d+$') { return $false }
  return $true
}

function Test-Fallback-List([string]$primary, [string]$list) {
  if ([string]::IsNullOrWhiteSpace($list)) { return $true }
  $parts = @($list -split ',' | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($part in $parts) {
    if (-not (Test-Provider-Known $part)) {
      Write-Host "  unknown provider in fallback list: $list"
      return $false
    }
    if ($part -eq $primary) {
      Write-Host "  fallback must not repeat the primary provider: $part"
      return $false
    }
    if (-not $seen.Add($part)) {
      Write-Host "  fallback must not contain duplicate providers: $part"
      return $false
    }
  }
  return $true
}

function Write-Team-Config([string]$membersFile, [string]$action) {
  $dest = Get-Dest 'muse-squad.toml'
  $parent = Split-Path -Parent $dest
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $nodeScript = @'
const fs = require('fs');

const configFile = process.argv[2];
const membersFile = process.argv[3];

function quote(value) {
  return JSON.stringify(String(value));
}

function quoteBlock(value) {
  const text = String(value).trim();
  if (text.includes('"""')) return quote(text);
  return `"""\n${text}\n"""`;
}

const raw = fs.readFileSync(configFile, 'utf8');
const marker = raw.match(/^\[squad\][ \t]*$/m);
if (!marker) throw new Error('muse-squad.toml has no [squad] table');
const prefix = raw.slice(0, marker.index).replace(/\r?\n+$/, '\n');

function squadValue(key, fallback) {
  const match = prefix.match(new RegExp(`^${key}[ \\t]*=[ \\t]*("(?:[^"\\\\]|\\\\.)*")[ \\t]*$`, 'm'));
  return match ? JSON.parse(match[1]) : fallback;
}

const members = fs.readFileSync(membersFile, 'utf8').split(/\r?\n/)
  .filter((line) => line.length > 0)
  .map((line) => {
    const fields = line.split('\t');
    if (fields.length !== 4) throw new Error(`bad member line: ${line}`);
    const [name, primary, fallback, charter] = fields;
    return {
      name,
      primary,
      fallback: fallback ? fallback.split(',') : [],
      charter
    };
  });

const lines = [
  '[squad]',
  `name = ${quote(squadValue('name', 'Muse Squad'))}`,
  `memory_dir = ${quote(squadValue('memory_dir', '.muse/squad'))}`,
  ''
];
for (const member of members) {
  lines.push(
    `[squad.${member.name}]`,
    `primary = ${quote(member.primary)}`,
    `fallback = [${member.fallback.map(quote).join(', ')}]`,
    `charter = ${quoteBlock(member.charter)}`,
    ''
  );
}
process.stdout.write(`${prefix}${lines.join('\n')}`);
'@
  # `node -e` has no script path in argv, so argv[1] is the first user argument.
  # The placeholder keeps the renderer's argv[2]/argv[3] indexing intact.
  $rendered = & node -e $nodeScript - $dest $membersFile
  if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -ne 0) {
    throw "team config generation failed with exit code $LASTEXITCODE"
  }
  $normalized = (($rendered -join "`n") -replace "(?:\r?\n)+\z", "`n")
  $configTmp = Join-Path ([IO.Path]::GetTempPath()) ('muse-squad-config-' + [Guid]::NewGuid().ToString('N') + '.toml')
  try {
    [IO.File]::WriteAllText($configTmp, $normalized, [System.Text.UTF8Encoding]::new($false))
    $parser = Get-Dest 'mcp/config.js'
    if (Test-Path -LiteralPath $parser) {
      & node $parser --file $configTmp --list-providers 2>$null | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw 'team config failed validation; no changes were written'
      }
    }
    Move-Item -LiteralPath $configTmp -Destination $dest -Force
  } finally {
    if (Test-Path -LiteralPath $configTmp) {
      Remove-Item -LiteralPath $configTmp -Force -ErrorAction SilentlyContinue
    }
  }
  Write-Host "  $action  $dest"
}

function Configure-Team {
  $dest = Get-Dest 'muse-squad.toml'
  $action = 'created'
  $seeded = $false
  if ($firstInstall) {
    # Seed first so the provider menu can be built from the default TOML, then
    # let an interactive wizard replace it.
    if (-not (Test-Path -LiteralPath $dest)) {
      Install-Config (Get-Config-Defaults)
      $seeded = $true
    }
    if ($useDefaults -or -not (Test-Interactive-Input) -or
        -not (Get-Command node -ErrorAction SilentlyContinue)) {
      return
    }
  } else {
    $action = 'updated'
    if (-not $reconfigureTeam) {
      Write-Host "  unchanged  $dest"
      return
    }
    if ($useDefaults -or -not (Test-Interactive-Input)) {
      Write-Host "  unchanged  $dest (team wizard skipped)"
      return
    }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
      Write-Host '  warning    node not found; keeping existing team config'
      return
    }
  }

  $customize = Read-Interactive 'Customize Squad team members & models now? [Y/n]'
  if ([string]::IsNullOrWhiteSpace($customize)) { $customize = 'Y' }
  if ($customize -match '^[Nn]([Oo])?$') {
    if ($seeded) {
      Write-Host "  kept defaults  $dest"
    } else {
      Write-Host "  unchanged  $dest"
    }
    return
  }
  if ($customize -notmatch '^[Yy]([Ee][Ss])?$') {
    throw 'Expected Y or n for team customization prompt'
  }

  $script:WizardProviders = Get-Available-Providers
  if ($script:WizardProviders.Count -eq 0) {
    throw "no providers are defined in $dest"
  }
  $menu = Get-Provider-Menu $script:WizardProviders

  $defaultNames = @('team-lead', 'frontend', 'backend', 'tester', 'secretary')
  $defaultPrimary = @('Muse-Spark', 'Home-Ornith', 'Home-Ornith', 'Home-Ornith', 'Muse-Ember')
  $defaultFallback = @('DeepSeek-Flash', 'Muse-Ember', 'DeepSeek-Flash', 'Muse-Ember', 'Home-Ornith')
  $members = @()
  $used = New-Object 'System.Collections.Generic.HashSet[string]'

  for ($i = 0; $i -lt 5; $i++) {
    while ($true) {
      $rawName = Read-Defaulted "Member $($i + 1) name" $defaultNames[$i]
      $name = ConvertTo-Member-Name $rawName
      if (-not (Test-Member-Name $name)) {
        Write-Host '  member name must include at least one letter'
        continue
      }
      if ($used.Contains($name)) {
        Write-Host "  name already in use: $name"
        continue
      }
      [void]$used.Add($name)
      break
    }

    while ($true) {
      $rawPrimary = Read-Defaulted "Primary provider for $name ($menu)" $defaultPrimary[$i]
      $primary = Resolve-Provider $rawPrimary $defaultPrimary[$i]
      if ([string]::IsNullOrEmpty($primary)) { continue }
      if (-not (Test-Provider-Known $primary)) {
        Write-Host "  unknown provider: $primary"
        continue
      }
      break
    }

    while ($true) {
      $rawFallback = Read-Defaulted "Fallback providers for $name (comma-separated, empty for none)" $defaultFallback[$i]
      $fallback = Resolve-Provider-List $rawFallback $defaultFallback[$i]
      if ([string]::IsNullOrEmpty($fallback)) { continue }
      if (-not (Test-Fallback-List $primary $fallback)) { continue }
      break
    }

    $charterDefault = Get-Existing-Charter $name
    if ([string]::IsNullOrWhiteSpace($charterDefault)) {
      $charterDefault = "Domain expertise: $name tasks. Voice: concise and evidence-first. " +
        'Guardrails: stay scoped to assigned files, preserve existing conventions, and verify changes before reporting done.'
    }
    while ($true) {
      $charter = ((Read-Defaulted "Charter for $name" $charterDefault).Trim() -replace '\s+', ' ')
      if (-not [string]::IsNullOrWhiteSpace($charter)) { break }
      Write-Host '  charter cannot be empty'
    }
    $members += [pscustomobject]@{ name = $name; primary = $primary; fallback = $fallback; charter = $charter }
  }

  while ($true) {
    $answer = Read-Interactive 'Add another team member? [y/N]'
    if ($answer -notmatch '^[Yy]([Ee][Ss])?$') { break }

    while ($true) {
      $rawName = Read-Required 'Extra member name' ''
      if ([string]::IsNullOrWhiteSpace($rawName)) {
        Write-Host '  name cannot be empty'
        continue
      }
      $name = ConvertTo-Member-Name $rawName
      if (-not (Test-Member-Name $name)) {
        Write-Host '  member name must include at least one letter'
        continue
      }
      if ($used.Contains($name)) {
        Write-Host "  name already in use: $name"
        continue
      }
      [void]$used.Add($name)
      break
    }

    while ($true) {
      $rawPrimary = Read-Defaulted "Primary provider for $name ($menu)" 'Muse-Ember'
      $primary = Resolve-Provider $rawPrimary 'Muse-Ember'
      if ([string]::IsNullOrEmpty($primary)) { continue }
      if (-not (Test-Provider-Known $primary)) {
        Write-Host "  unknown provider: $primary"
        continue
      }
      break
    }

    while ($true) {
      $rawFallback = Read-Defaulted "Fallback providers for $name (comma-separated, empty for none)" 'Home-Ornith'
      $fallback = Resolve-Provider-List $rawFallback 'Home-Ornith'
      if ([string]::IsNullOrEmpty($fallback)) { continue }
      if (-not (Test-Fallback-List $primary $fallback)) { continue }
      break
    }

    $charterDefault = 'Domain expertise: bounded implementation tasks. Voice: concise and evidence-first. Guardrails: stay scoped to assigned files, preserve existing conventions, and verify changes before reporting done.'
    while ($true) {
      $charter = ((Read-Defaulted 'Charter' $charterDefault).Trim() -replace '\s+', ' ')
      if (-not [string]::IsNullOrWhiteSpace($charter)) { break }
      Write-Host '  charter cannot be empty'
    }
    $members += [pscustomobject]@{ name = $name; primary = $primary; fallback = $fallback; charter = $charter }
  }

  $membersFile = Join-Path ([IO.Path]::GetTempPath()) ('muse-squad-members-' + [Guid]::NewGuid().ToString('N') + '.tsv')
  try {
    $lines = foreach ($member in $members) {
      "$($member.name)`t$($member.primary)`t$($member.fallback)`t$($member.charter)"
    }
    [IO.File]::WriteAllText($membersFile, (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    Write-Team-Config $membersFile $action
  } finally {
    if (Test-Path -LiteralPath $membersFile) {
      Remove-Item -LiteralPath $membersFile -Force -ErrorAction SilentlyContinue
    }
  }
}

function Uninstall-Team {
  $squadDir = Get-Dest 'squad'
  if (Test-Path -LiteralPath $squadDir -PathType Container) {
    Remove-Item -LiteralPath $squadDir -Recurse -Force
    Write-Host "  removed    $squadDir"
  }
}

function Invoke-Sync-Team([string]$action) {
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host '  warning    node not found on PATH; skipping team materialization'
    return
  }
  $script = Get-Dest 'mcp/sync-team.js'
  if (-not (Test-Path -LiteralPath $script)) {
    Write-Host "  warning    $script missing; skipping team materialization"
    return
  }
  $nodeArgs = @($script, '--config-dir', $configDir)
  if ($action -eq 'uninstall') { $nodeArgs += '--uninstall' }
  & node @nodeArgs
  if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -ne 0) {
    throw "team materialization failed with exit code $LASTEXITCODE"
  }
}

function Register-Mcp([string]$action) {
  if ($skipMcp -or $env:MUSE_SQUAD_SKIP_MCP -eq '1') {
    Write-Host '  skipped    MCP registration'
    return
  }
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host '  warning    node not found on PATH; skipping MCP registration'
    return
  }
  $nodeMajor = & node -p 'process.versions.node.split(".")[0]' 2>$null
  if ($nodeMajor -match '^\d+$' -and [int]$nodeMajor -lt 18) {
    Write-Host "  warning    node $nodeMajor is too old; MCP bridge requires Node 18+"
  }
  $registrar = Get-Dest 'mcp/register-settings.js'
  if (-not (Test-Path -LiteralPath $registrar)) {
    Write-Host "  warning    $registrar missing; skipping MCP registration"
    return
  }
  $nodeArgs = @($registrar, '--settings', (Get-Dest 'settings.json'), '--bridge', (Get-Dest 'mcp/bridge.js'))
  if ($action -eq 'unregister') {
    $nodeArgs += '--unregister'
  } else {
    $nodeArgs += @('--config-file', (Get-Dest 'muse-squad.toml'))
  }
  & node @nodeArgs
  if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -ne 0) {
    throw "MCP registration failed with exit code $LASTEXITCODE"
  }
}

function Invoke-SelfUpdate {
  $url = "$repoRawBase/install.ps1"
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("muse-squad-update-" + [Guid]::NewGuid().ToString('N') + '.ps1')
  Write-Host "  fetching   $url"
  try {
    if (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue) {
      Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    } else {
      Invoke-RestMethod -Uri $url -OutFile $tmp
    }
  } catch {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    throw "cannot download latest installer: $($_.Exception.Message)"
  }
  $updateArgs = @('--dir', $configDir, '--defaults')
  if ($skipMcp -or $env:MUSE_SQUAD_SKIP_MCP -eq '1') { $updateArgs += '--no-mcp' }
  if ($skipMuseCheck) { $updateArgs += '--skip-muse-check' }
  if ($backupChoice -eq 'yes') { $updateArgs += '--backup' }
  if ($backupChoice -eq 'no') { $updateArgs += '--no-backup' }
  # --update must never trigger a reconfigure on the downloaded installer.
  Write-Host '  running    latest installer'
  try {
    $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } elseif (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { $null }
    if ($shell) {
      & $shell -NoProfile -File $tmp @updateArgs
      $rc = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
      if ($rc -ne 0) { throw "latest installer failed with exit code $rc" }
    } else {
      & $tmp @updateArgs
    }
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
}

if ($mode -ne 'uninstall') {
  Invoke-Preflight
}

Write-Host "muse-squad v$Version - $mode"
Write-Host "config dir: $configDir"

if ($mode -eq 'update') {
  Invoke-SelfUpdate
  Write-Host 'done.'
  return
}

$firstInstall = -not (Test-Path -LiteralPath (Get-Dest 'muse-squad.toml'))

Backup-Config

if ($mode -eq 'uninstall') {
  Register-Mcp 'unregister'
  Uninstall-Agents-Policy
  Invoke-Sync-Team 'uninstall'
  Uninstall-Team
BODY

    for rel in "${MANAGED_PATHS[@]}" "${LEGACY_AGENTS[@]}"; do
      printf "  Uninstall-File '%s'\n" "$rel"
    done

    cat <<'MID'
  if (Test-Path -LiteralPath (Get-Dest 'muse-squad.toml')) {
    Write-Host "  kept       $(Get-Dest 'muse-squad.toml') (config is never removed)"
  }
  Write-Host 'done.'
  return
}

MID

    for rel in "${MANAGED_PATHS[@]}"; do
      content="$(cat "$PAYLOAD_DIR/$rel")"
      printf "Install-File '%s' @'\n" "$rel"
      printf '%s\n' "$content"
      printf "'@\n"
    done

    for rel in "${LEGACY_AGENTS[@]}"; do
      printf "  Uninstall-File '%s'\n" "$rel"
    done

    printf "function Get-Config-Defaults {\n  @'\n"
    cat "$CONFIG_DEFAULT"
    printf "'@\n}\n"

    printf "Install-Agents-Policy @'\n"
    printf '%s\n' '<!-- muse-squad:begin -->'
    cat "$AGENTS_POLICY"
    printf '%s\n' '<!-- muse-squad:end -->'
    printf "'@\n"

    cat <<'FOOT'
Configure-Team
Invoke-Sync-Team 'install'
Register-Mcp 'install'
if ($mode -eq 'install' -and $firstInstall) {
  Write-Host ''
  Write-Host 'Next steps:'
  Write-Host "  1. Configure: edit $(Join-Path $configDir 'muse-squad.toml') (providers, endpoints, and squad members)."
  Write-Host '  2. Use in Muse Code: /squad-plan to create .muse/PLAN.md, then /squad-execute.'
  Write-Host "  3. Customize: edit muse-squad.toml; generated agents in $(Join-Path $configDir 'agents') are rebuilt from it."
  Write-Host '  4. Check setup any time with /squad-doctor.'
  Write-Host '  5. Update later: re-run this installer with --update.'
}
Write-Host 'done.'
FOOT
  } > "$out"
  printf 'generated %s\n' "$out"
}

emit_bash
emit_powershell
