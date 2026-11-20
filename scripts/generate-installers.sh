#!/usr/bin/env bash
# Regenerates the standalone installers from payload/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD_DIR="$ROOT/payload"
VERSION_FILE="$ROOT/VERSION"
ENDPOINTS_DEFAULT="$PAYLOAD_DIR/mcp/endpoints.default.json"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -f "$VERSION_FILE" ]] || die "missing $VERSION_FILE"
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ -n "$VERSION" ]] || die "empty $VERSION_FILE"

# Explicit order keeps generated output deterministic.
MANAGED_PATHS=(
  "agents/plan-reviewer.md"
  "agents/general-purpose.md"
  "agents/worker.md"
  "skills/squad-plan/SKILL.md"
  "skills/squad-execute/SKILL.md"
  "mcp/bridge.js"
  "mcp/register-settings.js"
)

for rel in "${MANAGED_PATHS[@]}"; do
  f="$PAYLOAD_DIR/$rel"
  [[ -f "$f" ]] || die "missing payload file: $f"
  if LC_ALL=C grep -q "'@" "$f"; then
    die "payload contains a PowerShell here-string terminator ('@): $f"
  fi
done
[[ -f "$ENDPOINTS_DEFAULT" ]] || die "missing $ENDPOINTS_DEFAULT"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$ENDPOINTS_DEFAULT" ||
  die "$ENDPOINTS_DEFAULT is not valid JSON"

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
MODE="install"
SKIP_MCP=0
BACKUP_CHOICE="auto"

usage() {
  cat <<'USAGE'
muse-squad installer

Usage:
  curl -fsSL https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install | bash
  bash install [--dir PATH] [--uninstall] [--no-mcp] [--help]

Options:
  --dir PATH       Install into PATH instead of $HOME/.config/muse
  --uninstall      Remove managed files and unregister custom-coder
  --no-mcp         Skip custom-coder MCP registration
  --backup         Force a backup prompt/backup
  --no-backup      Skip the backup prompt and backup
  --help, -h       Show this help

Environment:
  MUSE_CONFIG_DIR     Equivalent to --dir (useful with curl | bash)
  MUSE_SQUAD_SKIP_MCP Set to 1 to skip MCP registration
  MUSE_SQUAD_NO_BACKUP Set to 1 to skip backup unless --backup is passed

Endpoints are configured in endpoints.json inside the config directory.
USAGE
}

log()  { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

while (( $# > 0 )); do
  case "$1" in
    --dir)
      (( $# >= 2 )) || fail "--dir requires a value"
      CONFIG_DIR="$2"; shift 2 ;;
    --uninstall) MODE="uninstall"; shift ;;
    --no-mcp) SKIP_MCP=1; shift ;;
    --backup) BACKUP_CHOICE="yes"; shift ;;
    --no-backup) BACKUP_CHOICE="no"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

if [[ "$BACKUP_CHOICE" == "auto" && "${MUSE_SQUAD_NO_BACKUP:-0}" == "1" ]]; then
  BACKUP_CHOICE="no"
fi
while [[ "$CONFIG_DIR" == */ && "$CONFIG_DIR" != "/" ]]; do
  CONFIG_DIR="${CONFIG_DIR%/}"
done

backup_config() {
  [[ -d "$CONFIG_DIR" ]] || { log "  skip backup  no existing config dir"; return 0; }

  if [[ "$BACKUP_CHOICE" == "no" ]]; then
    log "  skipped      backup (--no-backup)"
    return 0
  fi

  local answer="Y"
  if [[ -t 0 ]]; then
    printf 'Back up current Muse config before continuing? [Y/n] '
    if ! read -r answer; then answer="Y"; fi
    [[ -n "$answer" ]] || answer="Y"
  else
    log "  no TTY detected; backing up by default"
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
  log "  restore      copy the contents of $backup back into $CONFIG_DIR"
}

install_file() {
  local rel="$1" dest="$CONFIG_DIR/$1" tmp bak
  mkdir -p "$(dirname "$dest")" || fail "cannot create directory for $dest"
  tmp="$(mktemp "${TMPDIR:-/tmp}/muse-squad.XXXXXX")" || fail "mktemp failed"
  cat > "$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"; log "  unchanged  $dest"; return 0
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

install_endpoints_config() {
  local dest="$CONFIG_DIR/endpoints.json" tmp
  if [[ -f "$dest" ]]; then
    log "  unchanged  $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")" || fail "cannot create directory for $dest"
  tmp="$(mktemp "${TMPDIR:-/tmp}/muse-squad-endpoints.XXXXXX")" || fail "mktemp failed"
  cat > "$tmp"
  chmod 600 "$tmp" || fail "cannot set permissions on $dest"
  mv "$tmp" "$dest" || fail "cannot install $dest"
  log "  created    $dest"
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
  args+=(--config-file "$CONFIG_DIR/endpoints.json")
  node "$registrar" "${args[@]}"
}

log "muse-squad v$VERSION - $MODE"
log "config dir: $CONFIG_DIR"

backup_config

if [[ "$MODE" == "uninstall" ]]; then
  register_mcp unregister
BODY

    for rel in "${MANAGED_PATHS[@]}"; do
      printf '  uninstall_file %q\n' "$rel"
    done

    cat <<'MID'
  if [[ -f "$CONFIG_DIR/endpoints.json" ]]; then
    log "  kept       $CONFIG_DIR/endpoints.json (remove manually if desired)"
  fi
  log "done."
  exit 0
fi

MID

    for rel in "${MANAGED_PATHS[@]}"; do
      i=$((i + 1))
      delim="MSQ_PAYLOAD_$(printf '%03d' "$i")"
      content="$(cat "$PAYLOAD_DIR/$rel")"
      printf "install_file %q <<'%s'\n" "$rel" "$delim"
      printf '%s\n' "$content"
      printf '%s\n' "$delim"
    done

    printf "install_endpoints_config <<'MSQ_ENDPOINTS_CONFIG'\n"
    cat "$ENDPOINTS_DEFAULT"
    printf 'MSQ_ENDPOINTS_CONFIG\n'

    cat <<'FOOT'
register_mcp install
log "done."
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
$mode = 'install'
$help = $false
$skipMcp = $false
$backupChoice = 'auto'
if ($null -eq $args) { $args = @() }

for ($i = 0; $i -lt $args.Count; $i++) {
  switch -CaseSensitive ($args[$i]) {
    '--uninstall' { $mode = 'uninstall' }
    '--no-mcp' { $skipMcp = $true }
    '--backup' { $backupChoice = 'yes' }
    '--no-backup' { $backupChoice = 'no' }
    '--dir' {
      if (($i + 1) -ge $args.Count) { throw '--dir requires a value' }
      $configDir = $args[++$i]
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

if ($help) {
  @'
muse-squad installer

Usage:
  irm https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install.ps1 | iex
  powershell -File install.ps1 [--dir PATH] [--uninstall] [--no-mcp]

Options:
  --dir PATH       Install into PATH instead of ~/.config/muse
  --uninstall      Remove managed files and unregister custom-coder
  --no-mcp         Skip custom-coder MCP registration
  --backup         Force a backup prompt/backup
  --no-backup      Skip the backup prompt and backup
  --help, -h       Show this help

Environment:
  MUSE_CONFIG_DIR     Equivalent to --dir (useful with irm | iex)
  MUSE_SQUAD_SKIP_MCP Set to 1 to skip MCP registration
  MUSE_SQUAD_NO_BACKUP Set to 1 to skip backup unless --backup is passed

Endpoints are configured in endpoints.json inside the config directory.

Note: Windows PowerShell 5.1 has no `irm` alias. Use:
  Invoke-RestMethod 'https://raw.githubusercontent.com/tenantegroup/muse-squad/main/install.ps1' | iex
'@ | Write-Host
  return
}

function Get-Dest([string]$rel) {
  $parts = $rel -replace '/', [IO.Path]::DirectorySeparatorChar
  return [IO.Path]::GetFullPath((Join-Path $configDir $parts))
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
    $answer = Read-Host 'Back up current Muse config before continuing? [Y/n]'
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
  Write-Host "  restore      copy the contents of $backup back into $configDir"
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

function Install-Endpoints-Config([string]$content) {
  $dest = Get-Dest 'endpoints.json'
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
  Write-Host "  created    $dest"
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
    $nodeArgs += @('--config-file', (Get-Dest 'endpoints.json'))
  }
  & node @nodeArgs
  if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -ne 0) {
    throw "MCP registration failed with exit code $LASTEXITCODE"
  }
}

Write-Host "muse-squad v$Version - $mode"
Write-Host "config dir: $configDir"

Backup-Config

if ($mode -eq 'uninstall') {
  Register-Mcp 'unregister'
BODY

    for rel in "${MANAGED_PATHS[@]}"; do
      printf "  Uninstall-File '%s'\n" "$rel"
    done

    cat <<'MID'
  if (Test-Path -LiteralPath (Get-Dest 'endpoints.json')) {
    Write-Host "  kept       endpoints.json (remove manually if desired)"
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

    printf "Install-Endpoints-Config @'\n"
    cat "$ENDPOINTS_DEFAULT"
    printf "'@\n"

    cat <<'FOOT'
Register-Mcp 'install'
Write-Host 'done.'
FOOT
  } > "$out"
  printf 'generated %s\n' "$out"
}

emit_bash
emit_powershell
