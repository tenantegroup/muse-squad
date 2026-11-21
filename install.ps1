#requires -Version 5.1
# muse-squad installer - GENERATED FILE, DO NOT EDIT BY HAND.
# Source of truth: payload/ + scripts/generate-installers.sh

$ErrorActionPreference = 'Stop'

$Version = '0.3.0'
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
    foreach ($line in $output) {
      $name = ([string]$line).Trim()
      if ($name -and -not $providers.Contains($name)) { $providers.Add($name) }
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
    throw "Invalid provider number: $answer"
  }
  return $answer
}

function Resolve-Provider-List([string]$answer, [string]$default) {
  if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
  $resolved = @()
  foreach ($part in ($answer -split ',')) {
    $part = ([string]$part).Trim()
    if (-not $part) { continue }
    $resolved += (Resolve-Provider $part '')
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

function Write-Team-Config([string]$membersFile, [string]$action) {
  $dest = Get-Dest 'muse-squad.toml'
  $parent = Split-Path -Parent $dest
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $nodeScript = @'
const fs = require('fs');
const path = require('path');

const configFile = process.argv[2];
const membersFile = process.argv[3];
const outputFile = process.argv[4];

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
const config = require(path.join(path.dirname(configFile), 'mcp', 'config.js'))
  .loadConfig({ config_file: configFile });

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
  `name = ${quote(config.squad.name)}`,
  `memory_dir = ${quote(config.squad.memory_dir)}`,
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
fs.writeFileSync(outputFile, `${prefix}${lines.join('\n')}`);
'@
  $rendered = & node -e $nodeScript $dest $membersFile
  if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -ne 0) {
    throw "team config generation failed with exit code $LASTEXITCODE"
  }
  $normalized = (($rendered -join "`n") -replace "(?:\r?\n)+\z", "`n")
  [IO.File]::WriteAllText($dest, $normalized, [System.Text.UTF8Encoding]::new($false))
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
      if ($used.Contains($name)) {
        Write-Host "  name already in use: $name"
        continue
      }
      [void]$used.Add($name)
      break
    }
    $primary = Resolve-Provider `
      (Read-Defaulted "Primary provider for $name ($menu)" $defaultPrimary[$i]) $defaultPrimary[$i]
    if (-not (Test-Provider-Known $primary)) { throw "unknown provider: $primary" }
    $fallback = Resolve-Provider-List `
      (Read-Defaulted "Fallback providers for $name (comma-separated, empty for none)" $defaultFallback[$i]) `
      $defaultFallback[$i]
    if (-not (Test-Provider-List $fallback)) { throw "unknown provider in fallback list: $fallback" }
    $charter = Get-Existing-Charter $name
    if ([string]::IsNullOrWhiteSpace($charter)) {
      $charter = "Domain expertise: $name tasks. Voice: concise and evidence-first. " +
        'Guardrails: stay scoped to assigned files, preserve existing conventions, and verify changes before reporting done.'
    }
    $charter = ((Read-Defaulted "Charter for $name" $charter).Trim() -replace '\s+', ' ')
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
      if ($used.Contains($name)) {
        Write-Host "  name already in use: $name"
        continue
      }
      [void]$used.Add($name)
      break
    }
    $primary = Resolve-Provider `
      (Read-Defaulted "Primary provider for $name ($menu)" 'Muse-Ember') 'Muse-Ember'
    if (-not (Test-Provider-Known $primary)) { throw "unknown provider: $primary" }
    $fallback = Resolve-Provider-List `
      (Read-Defaulted "Fallback providers for $name (comma-separated, empty for none)" 'Home-Ornith') 'Home-Ornith'
    if (-not (Test-Provider-List $fallback)) { throw "unknown provider in fallback list: $fallback" }
    $charter = Read-Defaulted 'Charter' 'Domain expertise: bounded implementation tasks. Voice: concise and evidence-first. Guardrails: stay scoped to assigned files, preserve existing conventions, and verify changes before reporting done.'
    $charter = ($charter.Trim() -replace '\s+', ' ')
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
  Uninstall-File 'skills/squad-team/SKILL.md'
  Uninstall-File 'skills/squad-doctor/SKILL.md'
  Uninstall-File 'skills/squad-plan/SKILL.md'
  Uninstall-File 'skills/squad-execute/SKILL.md'
  Uninstall-File 'mcp/bridge.js'
  Uninstall-File 'mcp/config.js'
  Uninstall-File 'mcp/doctor.js'
  Uninstall-File 'mcp/register-settings.js'
  Uninstall-File 'mcp/sync-team.js'
  Uninstall-File 'agents/plan-reviewer.md'
  Uninstall-File 'agents/general-purpose.md'
  Uninstall-File 'agents/worker.md'
  if (Test-Path -LiteralPath (Get-Dest 'muse-squad.toml')) {
    Write-Host "  kept       $(Get-Dest 'muse-squad.toml') (config is never removed)"
  }
  Write-Host 'done.'
  return
}

Install-File 'skills/squad-team/SKILL.md' @'
---
name: squad-team
description: Manage the single muse-squad.toml config and regenerate the roster and member wrappers.
---
You are in SQUAD-TEAM mode. Change the squad configuration and its generated outputs only.

## Read first

1. Resolve the Muse config directory: use `MUSE_CONFIG_DIR` when set, otherwise `~/.config/muse` (`%USERPROFILE%\.config\muse` on Windows).
2. Read `muse-squad.toml` from that directory and the generated `squad/team.md`.
3. Show the current roster briefly as `@<name> | primary | fallback chain` before asking what to change.

## What you may edit

Edit only `muse-squad.toml`. Do not hand-edit `squad/team.md`, `agents/<name>.md`, `AGENTS.md` / `MUSE.md`, or anything under `mcp/`. This is the only config file; there are no per-repo settings and no helper agents to edit.

The file uses `schema = 1` and these tables:

- `[providers.<Name>]` — a provider name may contain letters, numbers, `.`, `_`, and `-`. `type = "native"` requires `model` and `max_concurrency`. `type = "http"` requires `base_url`, `api_key`, and `model`, and accepts `temperature`, `top_p`, `max_tokens`, `max_input_chars`, `on_context_exceeded`, `max_concurrency`, `timeout_ms`, `queue_timeout_ms`, and `max_retries`. `api_key` may be plaintext or `${ENV_VAR}`.
- `[squad.<name>]` — one per member, with only `primary`, an ordered `fallback` array, and `charter`.

Every member needs at least one provider in its chain: `primary` and every `fallback` entry must match a provider table name exactly. Validate all cross-references before writing. Never invent a provider name. Member names are lowercase slugs (`a-z0-9-`); retired helper names are reserved. Keep `schema = 1`. Do not add display names, responsibilities, labels, or any new member keys. Use `#` for TOML comments, not `;`.

## Apply the change

Ask which change to make unless the user already stated it clearly:

- add, rename, or remove a provider (check every member chain before removing);
- add, rename, or remove a member (at least one member must remain);
- change a member's `primary`, reorder or replace its `fallback` array, or rewrite its `charter`;
- change any provider setting, including moving a secret into `${ENV_VAR}`.

Before writing, copy `muse-squad.toml` to a timestamped sibling backup such as `muse-squad.toml.bak.20261121-143022`. Apply the smallest valid TOML edit, then parse the result and re-check every provider reference. If parsing or validation fails, restore the backup and stop.

## Regenerate

Run the materializer with the same config directory:

```bash
node "$MUSE_CONFIG_DIR/mcp/sync-team.js" --config-dir "$MUSE_CONFIG_DIR"
```

On Windows without `MUSE_CONFIG_DIR`, use `node "$HOME\.config\muse\mcp\sync-team.js" --config-dir "$HOME\.config\muse"`.

If the command fails, restore the config backup, report the exact error, and do not claim success.

Stale `agents/<name>.md` wrappers that carry the generated marker are removed automatically. Leave any unmarked agent file untouched.

## Finish

Re-read `squad/team.md`. Report the final `@<name> | primary | fallback` table and the regenerated file paths. Never report the change as done until the materializer exited successfully.
'@
Install-File 'skills/squad-doctor/SKILL.md' @'
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
3. HTTP providers — a live `GET /v1/models` (or `GET /models` when `base_url` already ends in `/v1`) with a short timeout. `OK` means reachable, `AUTH` means 401/403, `HTTP` means another error status, `DOWN` / `TIMEOUT` means no answer. Native providers are reported as `native` and are not pinged; the MCP router skips them too.
4. Roster and wrappers — that `squad/team.md` and every global `agents/<name>.md` match what `sync-team.js` would generate from the TOML, that only current members have generated wrappers, and that no leftover non-member agent files remain.
5. Secrets — every `api_key` is redacted in all output, including `--json`.

Exit code `0` means all checks passed, `1` means at least one check failed, and `2` means the diagnostic itself could not run.

## Recommended follow-ups

- Missing or bad `muse-squad` registration: re-run the installer, or run `node "$MUSE_CONFIG_DIR/mcp/register-settings.js"` with the installer's usual `--settings` and `--bridge` arguments.
- Config parse or cross-reference failure: fix `muse-squad.toml` with `/squad-team`. An unknown provider in a member's chain blocks that member's routing.
- `DOWN` / `TIMEOUT`: check that the HTTP model server is running, `base_url` is correct, and the port is exposed. A native provider needs no ping.
- `AUTH`: check that provider's `api_key` or its `${ENV_VAR}` source; never echo the key into chat.
- Roster drift or leftover wrappers: run `node "$MUSE_CONFIG_DIR/mcp/sync-team.js" --config-dir "$MUSE_CONFIG_DIR"`, or use `/squad-team` if the TOML itself needs editing.

Present a short summary table of `Check | Status | Detail`, list failing checks first, and do not claim the installation is healthy unless the diagnostic exited `0`.
'@
Install-File 'skills/squad-plan/SKILL.md' @'
---
name: squad-plan
description: Member-scoped, explore-first planning mode that writes a decision-complete plan before coding.
---
You are in SQUAD-PLAN mode. Do NOT edit product code yet.

## Named members and project memory (read first)

At startup, read `~/.config/muse/muse-squad.toml` (`schema = 1`) and the generated roster at `~/.config/muse/squad/team.md`. Use only the members defined under `[squad.<name>]`; every step goes to a named member. Match each step to that member's `charter`. If no charter fits, ask the user which member should own the step instead of inventing a helper.

If `.muse/squad/` does not exist in this repository yet, create `.muse/squad/decisions.md` and `.muse/squad/history/` before starting. Every named member reads `.muse/squad/decisions.md` and `.muse/squad/history/<name>.md` before starting, and appends concise lasting learnings to its own history file when finished. Ask the `@secretary` member to append durable decisions to `.muse/squad/decisions.md` before sign-off.

## TUI labels and reporting

When spawning any subagent, set its short task label exactly to:

`[<name> | <provider-name>] <concise action>`

- `<name>` is the member's lowercase name from `[squad.<name>]`.
- `<provider-name>` is the provider actually serving the step: the member's `primary` for native work, or the HTTP provider that answered through `muse-squad` for delegated work. Use the provider name exactly as written in the TOML. Never guess it from a charter or invent a model tag.
- Keep the action under ~50 characters; start with a verb; no trailing punctuation.
- Add no parenthetical text and no second field.

Examples:

```text
[team-lead | Muse-Spark] Review architecture
[frontend | Home-Ornith] Sketch login form changes
[backend | DeepSeek-Flash] Map retry queue changes
[tester | Home-Ornith] List verification commands
[secretary | Muse-Ember] Record plan decisions
```

Always include a "Subagents / Providers" roster in user-facing summaries and before asking for sign-off. For each entry list the member name, provider, action, and outcome. For `muse-squad` tool calls, report the member, the provider shown in tool meta, and the outcome; if meta is unavailable, say so explicitly.

## Provider limits and health (read first)

At the start, call `muse-squad:list_providers` (or read `muse-squad.toml`) to learn each provider's `max_concurrency`, `max_input_chars`, and `type`. Native providers are built into Muse and cannot be called by the MCP router; the router skips them and tries that member's HTTP providers in chain order.

- Never spawn more simultaneous native subagents of one native provider than its `max_concurrency`; batch extra exploration into later waves.
- Parallel calls to `muse-squad` are safe: the router queues requests and serializes them per HTTP provider's `max_concurrency`.
- Use `muse-squad:member_status("<name>")` to inspect a member's chain before assigning a large step.

## Member-scoped routing and quota retries

`muse-squad:generate_code` and `muse-squad:critique_plan` are member-scoped:

- `generate_code(member, prompt|task_spec, context|file_context, optional system/temperature/max_tokens)`
- `critique_plan(member, plan_markdown, optional repo_context/temperature/max_tokens)`

The router resolves the named member's `primary` first, then its `fallback` providers in order. Native providers are skipped by the router; HTTP providers are tried in chain order. There is no global fallback and no silent model switching.

- **Native-primary member:** run the native subagent first. If it fails because of quota, rate limits, or subscription limits, retry that exact step through `muse-squad:critique_plan` (plan and review steps) or `muse-squad:generate_code` (code and diff steps) with `member="<name>"`. The router uses that member's HTTP fallbacks. Do not treat the failed native turn as the member's result.
- **HTTP-primary member:** the generated wrapper pins a lightweight native runner and delegates heavy work to `muse-squad` with `member="<name>"`.

If the member chain cannot serve the request, the tool returns a hard error listing every attempt. Stop planning, report the error and its attempts verbatim, and ask the user to fix that member's chain with `/squad-team`. Do not retry with a different member, a different provider, or inline work.

## Context size

When calling `muse-squad`, keep `repo_context`, `file_context`, and `plan_markdown` short and relevant. Check the target HTTP provider's `max_input_chars` before sending; send only the needed files or excerpts. If a reply starts with the input-truncated warning, shorten the context and re-ask instead of trusting the critique.

## Planning steps

1. Map the relevant files, dependencies, and existing patterns using named members only.
2. Ask the user clarifying questions only if an architectural fork cannot be resolved from the codebase.
3. Draft a decision-complete implementation plan in `.muse/PLAN.md` with exact file paths, dependency order, and verification commands. If the file already has a `## Execution Log & Decisions` section, preserve it verbatim at the bottom.
4. Plan grill: ask the architecture charter member (default `@team-lead`) to audit `.muse/PLAN.md` against the actual files, then request an independent critique through `muse-squad:critique_plan` with `member="<name>"` for that same member. Synthesize valid issues into `.muse/PLAN.md` and ask `@secretary` to append durable choices to `.muse/squad/decisions.md`.
5. Present a summary of what was caught, including the Subagents / Providers roster, before asking the user for `/squad-execute` sign-off.
'@
Install-File 'skills/squad-execute/SKILL.md' @'
---
name: squad-execute
description: Executes the approved .muse/PLAN.md with named squad members and a verification gate that blocks premature completion.
---

## Named members and project memory (read first)

At startup, read `~/.config/muse/muse-squad.toml` and the generated roster at `~/.config/muse/squad/team.md`. Use only the members defined under `[squad.<name>]`. All implementation and review goes through named members; there are no unnamed helpers. Match each task to a member's `charter`, and ask the user which member owns a step if no charter fits.

If `.muse/squad/` does not exist yet, create `.muse/squad/decisions.md` and `.muse/squad/history/`. Every member reads both files before starting and appends concise lasting learnings when finished. Use isolated Git worktrees for bounded implementation tasks where available.

## TUI labels and reporting

When spawning any subagent, set its short task label exactly to:

`[<name> | <provider-name>] <concise action>`

- `<name>` is the member's lowercase name from `[squad.<name>]`.
- `<provider-name>` is the provider actually serving the step: the member's `primary` for native work, or the HTTP provider that answered through `muse-squad` for delegated work. Use the provider name exactly as written in the TOML; never guess it from a charter or invent a model tag.
- Keep the action under ~50 characters; start with a verb; no trailing punctuation.
- Add no parenthetical text and no second field.

Examples:

```text
[team-lead | Muse-Spark] Sequence wave dependencies
[frontend | Home-Ornith] Build login form
[backend | DeepSeek-Flash] Add retry queue
[tester | Home-Ornith] Run regression suite
[secretary | Muse-Ember] Log wave decisions
```

Always include a "Subagents / Providers" roster in wave, progress, and completion summaries. For each entry list the member name, provider, action, and outcome. For `muse-squad` tool calls, report the member, the provider shown in tool meta, and the outcome; if meta is unavailable, say so explicitly. When practical, include the member name and provider in execution-log entries.

## Provider limits, health, and member-scoped routing (read first)

At the start, call `muse-squad:list_providers` (or read `muse-squad.toml`) to learn each provider's `type`, `max_concurrency`, and `max_input_chars`. Use `muse-squad:member_status("<name>")` to inspect a member's chain before assigning work. Native providers are built into Muse and cannot be called by the MCP router; the router skips them and tries that member's HTTP providers in chain order.

`muse-squad:generate_code` and `muse-squad:critique_plan` are member-scoped:

- `generate_code(member, prompt|task_spec, context|file_context, optional system/temperature/max_tokens)`
- `critique_plan(member, plan_markdown, optional repo_context/temperature/max_tokens)`

The router resolves the named member's `primary` first, then its `fallback` providers in order. There is no global fallback and no silent model switching.

- **Native-primary member:** run the native subagent first. If it fails because of quota, rate limits, or subscription limits, retry that exact step through `muse-squad:generate_code` (implementation steps) or `muse-squad:critique_plan` (reviews) with `member="<name>"`. The router uses that member's HTTP fallbacks. Do not treat the failed native turn as the member's result.
- **HTTP-primary member:** the generated wrapper pins a lightweight native runner and delegates heavy work to `muse-squad` with `member="<name>"`.
- Parallel calls to `muse-squad` are safe: the router queues requests and serializes them per HTTP provider's `max_concurrency`. Do not add separate locking in members.

**Errors stop the wave.** If any member chain returns a hard error, stop the current wave immediately, report the error and every attempted provider verbatim, and ask the user to fix that member's chain with `/squad-team`. Do not retry with a different member, a different provider, or inline work, and do not advance to the next wave.

## Context size

Before each `generate_code` call, check the target HTTP provider's `max_input_chars`. Keep `file_context` (and any `repo_context`) to the smallest excerpts that explain the change — no whole-file dumps, logs, or unrelated tests. If the reply starts with the input-truncated warning, shorten the context and re-ask; do not apply a diff generated from cut-off context.

## Patch discipline (diffs, not full rewrites)

- Ask `generate_code` for a targeted unified diff (`git apply` format) for existing files. A single targeted function or block with its path and line range is acceptable when a diff is impractical; a full-file rewrite is not.
- The orchestrator — the native runner in the wrapper, or any model with native `Edit` tools — applies each hunk surgically, preserving the rest of the file. Do not overwrite whole files with generated output.
- Reject and re-prompt if the result is a full file, truncated content, `...`/placeholders, or an unapplyable diff. Never repair omitted code by guessing.
- Run the fastest incremental check on changed files, then the Verification Gate after applying patches.

## Verification gate (do not stop until verified)

You are not done and must not return control to the user while any `.muse/TODO.md` item is unchecked or while any verification command fails.

Read `.muse/PLAN.md`, including any existing `## Execution Log & Decisions` section; it is the durable handoff record when resuming a long or interrupted session. Group independent tasks into successive waves. After every wave — before advancing and before reporting completion:

1. Update `.muse/TODO.md` (create it from the plan if it does not exist). Check off only items whose changes are applied and verified; leave or add `- [ ]` items for remaining or newly discovered work. Record exact verification commands and results in the checklist.
2. Run every verification command listed in `.muse/PLAN.md` from the repository root — for example `npm test`, `cargo check`, `pytest`, or `go test ./...`. If the plan lists none, detect the project's typechecker and test commands from its manifests, add them to `.muse/TODO.md`, and run them.
3. If any command fails, fix the failure in another bounded wave with the appropriate named member and repeat this gate. Never mark an item done or claim success based on a partial pass.
4. Append a short entry to `## Execution Log & Decisions` at the bottom of `.muse/PLAN.md` (create the section if absent). Record the wave number, what landed, decisions and *why*, gotchas discovered, exact verification commands and results, and any remaining work or blockers. Append only — never rewrite or delete earlier entries. Ask `@secretary` to append durable decisions to `.muse/squad/decisions.md` and each member to append lasting learnings to its own `.muse/squad/history/<name>.md`.
5. Only when all TODO items are checked and all verification commands pass, summarize what was verified and return control to the user, including the Subagents / Providers roster for the run.

## Session handoff notes

The `## Execution Log & Decisions` section in `.muse/PLAN.md` is authoritative state, not chat history. Keep entries short (a few bullets per wave) and append-only:

```markdown
## Execution Log & Decisions

### Wave 2 - 2026-11-21
- Landed: retry/backoff in mcp/bridge.js; TOML defaults refreshed.
- Decision: 4xx is non-retryable - an invalid key must fail fast, not burn chain attempts. Reason: silent auth failures wasted a wave earlier.
- Gotcha: fallback notices belong in MCP `meta`, not tool text, or `git apply` breaks.
- Verified: `node --check mcp/bridge.js` PASS; `npm test` PASS.
- Remaining: Windows installer still untested locally (no pwsh).
```

On resume, read this section first and continue from the last entry instead of re-deriving decisions from scratch. If a later wave reverses a decision, append a new entry saying so with the reason — do not edit history.
'@
Install-File 'mcp/bridge.js' @'
#!/usr/bin/env node
'use strict';

// MCP stdio server for the muse-squad roster. Every generation or critique is
// scoped to a named squad member; the member's provider chain comes from
// muse-squad.toml. Zero npm dependencies, Node 18+ (global fetch).

const configModule = require('./config.js');

const SERVER_NAME = 'muse-squad';
const SERVER_VERSION = '0.3.0';
const CONFIG_FILE = configModule.configPath({});

const DEFAULT_SYSTEM = [
  'You are a named squad member completing a bounded software task.',
  'For existing files, return ONLY a unified diff in `git apply` format with exact file paths and enough context lines to apply cleanly.',
  'If a diff is genuinely impractical, return ONLY the targeted function or block with its file path and line range - never the entire file.',
  'Never output a full-file rewrite, ellipses, placeholders, or truncation markers. Do not use markdown fences.',
  'Do not add commentary, apologies, or explanations. Touch only the files named in the task.',
  'Preserve the existing style, imports, and conventions shown in the context.'
].join(' ');

const CRITIQUE_SYSTEM = [
  'You are a strict code auditor performing an adversarial review of an implementation plan.',
  'Find missing edge cases, security flaws, or broken assumptions in this plan.',
  'Be skeptical. Identify concrete risks, ambiguity, missing files, race conditions, and untested paths.',
  'Return only a numbered list of findings with severity and a short justification.',
  'Do not praise the plan, rewrite it, or modify any code.'
].join(' ');

const MEMBER_PARAM = {
  type: 'string',
  description: 'Name of a squad member from muse-squad.toml.'
};

const TOOLS = [
  {
    name: 'generate_code',
    description: 'Generate a targeted unified diff (or single function/block) through a squad member\'s provider chain. Never returns full-file rewrites.',
    inputSchema: {
      type: 'object',
      properties: {
        member: MEMBER_PARAM,
        prompt: { type: 'string', description: 'Bounded implementation task to perform.' },
        task_spec: { type: 'string', description: 'Alias for prompt.' },
        context: { type: 'string', description: 'Relevant file contents or excerpts to work from.' },
        file_context: { type: 'string', description: 'Alias for context.' },
        system: { type: 'string', description: 'Optional override for the worker system prompt.' },
        temperature: { type: 'number', description: 'Optional sampling temperature override.' },
        max_tokens: { type: 'integer', description: 'Optional maximum tokens to generate.' }
      },
      required: ['member'],
      anyOf: [{ required: ['prompt'] }, { required: ['task_spec'] }],
      additionalProperties: false
    }
  },
  {
    name: 'critique_plan',
    description: 'Audit a plan through a squad member\'s provider chain. Reports concrete risks without editing code.',
    inputSchema: {
      type: 'object',
      properties: {
        member: MEMBER_PARAM,
        plan_markdown: { type: 'string', description: 'Full markdown of .muse/PLAN.md to audit.' },
        repo_context: { type: 'string', description: 'Relevant repository files and structure the plan relies on.' },
        temperature: { type: 'number', description: 'Optional sampling temperature override.' },
        max_tokens: { type: 'integer', description: 'Optional maximum tokens to generate.' }
      },
      required: ['member', 'plan_markdown'],
      additionalProperties: false
    }
  },
  {
    name: 'member_status',
    description: 'Report squad members, their ordered provider chains, and live queue state. Keys are redacted. Omit member to list the whole squad.',
    inputSchema: {
      type: 'object',
      properties: { member: MEMBER_PARAM },
      additionalProperties: false
    }
  },
  {
    name: 'list_providers',
    description: 'Report every configured provider with its model, limits, and live queue state, plus the current squad roster. Keys are redacted.',
    inputSchema: {
      type: 'object',
      properties: {},
      additionalProperties: false
    }
  }
];

const CONFIG_GUIDANCE = [
  `Expected config file: ${CONFIG_FILE}`,
  'Create or fix muse-squad.toml with at least one [providers.<Name>] table and one [squad.<name>] table.',
  'Every member primary/fallback value must match a provider name exactly. Run node mcp/doctor.js for details.'
].join(' ');

function log(message) {
  process.stderr.write(`[${SERVER_NAME}] ${message}\n`);
}

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function ok(id, result) {
  send({ jsonrpc: '2.0', id, result });
}

function fail(id, code, message) {
  send({ jsonrpc: '2.0', id, error: { code, message } });
}

function configError(message) {
  return new Error(`${message}\n${CONFIG_GUIDANCE}`);
}

function loadConfigOrThrow() {
  try {
    return configModule.loadConfig();
  } catch (error) {
    throw configError(error.message);
  }
}

function resolveMember(config, requested) {
  if (typeof requested !== 'string' || !requested.trim()) {
    throw new Error('"member" must be a non-empty squad member name');
  }
  const member = config.squad.members[requested];
  if (!member) {
    throw new Error(
      `unknown squad member "${requested}". Available: ${Object.keys(config.squad.members).join(', ')}`
    );
  }
  const chain = [];
  for (const name of [member.primary, ...member.fallback]) {
    if (!chain.includes(name)) chain.push(name);
  }
  return { member, chain, providersByName: config.providers };
}

// --- Per-provider FIFO concurrency queues ---------------------------------

const providerQueues = new Map();

function grantWaiters(state) {
  while (state.waiters.length > 0 && state.active < state.limit) {
    const waiter = state.waiters.shift();
    state.active += 1;
    if (waiter.timer) clearTimeout(waiter.timer);
    waiter.grant();
  }
}

function queueState(name, limit) {
  let state = providerQueues.get(name);
  if (!state) {
    state = { active: 0, limit, waiters: [] };
    providerQueues.set(name, state);
  }
  if (state.limit !== limit) {
    // Hot reload: adopt the new limit without touching active slot counts.
    state.limit = limit;
    grantWaiters(state);
  }
  return state;
}

function releaseSlot(state) {
  state.active = Math.max(0, state.active - 1);
  grantWaiters(state);
}

function acquireSlot(name, limit, queueTimeoutMs) {
  const state = queueState(name, limit);
  if (state.active < state.limit) {
    state.active += 1;
    return Promise.resolve(() => releaseSlot(state));
  }
  return new Promise((resolve, reject) => {
    const waiter = {
      grant: () => resolve(() => releaseSlot(state)),
      timer: null
    };
    state.waiters.push(waiter); // FIFO: later callers wait behind earlier ones
    waiter.timer = setTimeout(() => {
      const index = state.waiters.indexOf(waiter);
      if (index === -1) return; // already granted
      state.waiters.splice(index, 1);
      const error = new Error(`queue timeout waiting for provider "${name}" after ${queueTimeoutMs}ms`);
      error.queueTimeout = true;
      error.retryable = false; // let the member's next fallback decide
      reject(error);
    }, queueTimeoutMs);
  });
}

function queueSnapshot(name) {
  const state = providerQueues.get(name);
  return {
    activeCalls: state ? state.active : 0,
    queuedCalls: state ? state.waiters.length : 0
  };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function isRetryable(error) {
  if (!error || typeof error !== 'object') return false;
  if (error.retryable === false) return false;
  if (typeof error.status === 'number') return error.status === 429 || error.status >= 500;
  return true; // network failures and aborts
}

async function postChatOnce(provider, payload) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), provider.timeout_ms);
  let target;
  try {
    target = new URL(`${provider.base_url.replace(/\/+$/, '')}/chat/completions`);
  } catch (error) {
    clearTimeout(timer);
    const invalid = new Error(`invalid base_url for "${provider.name}": ${error.message}`);
    invalid.retryable = false;
    throw invalid;
  }

  try {
    const response = await fetch(target.toString(), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${provider.api_key || ''}`
      },
      body: JSON.stringify(payload),
      signal: controller.signal
    });

    if (!response.ok) {
      const body = await response.text().catch(() => '');
      const error = new Error(`HTTP ${response.status}: ${body.slice(0, 200)}`);
      error.status = response.status;
      throw error;
    }

    let data;
    try {
      data = await response.json();
    } catch (error) {
      const invalid = new Error(`invalid JSON response: ${error.message}`);
      invalid.retryable = false;
      throw invalid;
    }
    const content = data && data.choices && data.choices[0] && data.choices[0].message
      ? data.choices[0].message.content
      : undefined;
    if (typeof content !== 'string') {
      const invalid = new Error('unexpected response: missing choices[0].message.content');
      invalid.retryable = false;
      throw invalid;
    }
    return {
      content,
      upstreamModel: typeof data.model === 'string' ? data.model : undefined,
      usage: data && typeof data.usage === 'object' && data.usage ? data.usage : undefined
    };
  } finally {
    clearTimeout(timer);
  }
}

async function chatWithRetries(provider, payload) {
  // One slot is held across the whole retry sequence for this provider.
  const release = await acquireSlot(
    provider.name,
    provider.max_concurrency,
    provider.queue_timeout_ms
  );
  try {
    let lastError;
    for (let attempt = 0; attempt <= provider.max_retries; attempt++) {
      try {
        return await postChatOnce(provider, payload);
      } catch (error) {
        lastError = error;
        if (attempt >= provider.max_retries || !isRetryable(error)) break;
        await sleep(1000 * 2 ** attempt);
      }
    }
    throw lastError;
  } finally {
    release(); // never leak a slot on failure, abort, or timeout
  }
}

function redactExtra(extra) {
  if (!extra || typeof extra !== 'object') return extra;
  const copy = Array.isArray(extra) ? [] : {};
  for (const [key, value] of Object.entries(extra)) {
    if (/^(api[_-]?key|authorization|secret|password|token)$/i.test(key)) {
      copy[key] = '<redacted>';
    } else if (value && typeof value === 'object') {
      copy[key] = redactExtra(value);
    } else {
      copy[key] = value;
    }
  }
  return copy;
}

function buildPayload(provider, requestTemplate) {
  const { params } = requestTemplate;
  let system = requestTemplate.systemPrompt;
  let user = requestTemplate.userPrompt;
  let warning = '';

  if (provider.max_input_chars !== undefined) {
    const limit = provider.max_input_chars;
    const total = system.length + user.length;
    if (total > limit) {
      if (provider.on_context_exceeded === 'fallback') {
        const error = new Error(
          `input size ${total} exceeds max_input_chars ${limit} for provider "${provider.name}"`
        );
        error.contextExceeded = true;
        error.retryable = false; // let the member's next fallback decide
        throw error;
      }
      if (system.length > limit) {
        system = system.slice(0, limit);
        user = '';
      } else {
        user = user.slice(0, Math.max(0, limit - system.length));
      }
      warning = `> *[Warning: Input truncated to max_input_chars for '${provider.name}']*\n\n`;
    }
  }

  const extra = provider.extra_body && typeof provider.extra_body === 'object'
    ? provider.extra_body
    : {};
  const temperature = params.temperature === undefined ? provider.temperature : params.temperature;
  const maxTokens = params.max_tokens !== undefined
    ? params.max_tokens
    : (Object.prototype.hasOwnProperty.call(extra, 'max_tokens') ? undefined : provider.max_tokens);

  return {
    warning,
    payload: {
      ...extra, // backend-specific knobs first
      // Core fields are written last so a malformed extra_body cannot clobber them.
      model: provider.model,
      messages: [
        { role: 'system', content: system },
        { role: 'user', content: user }
      ],
      stream: false,
      ...(temperature === undefined ? {} : { temperature }),
      ...(maxTokens === undefined ? {} : { max_tokens: maxTokens })
    }
  };
}

async function queryWithMember(memberInfo, requestTemplate) {
  const attempts = [];
  for (let index = 0; index < memberInfo.chain.length; index++) {
    const name = memberInfo.chain[index];
    const provider = memberInfo.providersByName[name];

    if (!provider) {
      attempts.push({ provider: name, error: 'provider not found in config' });
      continue;
    }
    if (provider.type !== 'http') {
      attempts.push({
        provider: name,
        type: 'native',
        model: provider.model,
        error: 'native providers cannot be called by the muse-squad MCP router'
      });
      continue;
    }

    try {
      const { payload, warning } = buildPayload(provider, requestTemplate);
      const result = await chatWithRetries(provider, payload);
      return {
        text: `${warning}${result.content}`,
        meta: {
          member: memberInfo.member.name,
          primary: memberInfo.member.primary,
          chain: memberInfo.chain,
          servedBy: name,
          servedProvider: name,
          servedModel: provider.model,
          ...(result.upstreamModel ? { upstreamModel: result.upstreamModel } : {}),
          ...(result.usage ? { usage: result.usage } : {}),
          fallbackUsed: index > 0,
          chainIndex: index,
          attempts
        }
      };
    } catch (error) {
      attempts.push({ provider: name, type: 'http', model: provider.model, error: error.message });
    }
  }

  throw new Error(
    `Member "${memberInfo.member.name}" could not be served. Attempted providers:\n` +
    attempts.map((item) => `- ${item.provider}${item.type ? ` (${item.type})` : ''}: ${item.error}`).join('\n')
  );
}

function memberSummary(config, name) {
  const selected = resolveMember(config, name);
  const providers = selected.chain.map((providerName) => {
    const provider = selected.providersByName[providerName];
    return {
      name: providerName,
      type: provider.type,
      model: provider.model,
      callableByMcp: provider.type === 'http',
      ...queueSnapshot(providerName)
    };
  });
  return {
    name: selected.member.name,
    primary: selected.member.primary,
    fallback: [...selected.member.fallback],
    chain: selected.chain,
    charter: selected.member.charter,
    providers
  };
}

function providerSummary(config, name) {
  const provider = config.providers[name];
  return {
    name,
    type: provider.type,
    model: provider.model,
    ...(provider.base_url === undefined ? {} : { baseUrl: provider.base_url }),
    temperature: provider.temperature,
    topP: provider.extra_body && provider.extra_body.top_p,
    maxTokens: provider.max_tokens,
    max_tokens: provider.max_tokens,
    maxInputChars: provider.max_input_chars,
    max_input_chars: provider.max_input_chars,
    onContextExceeded: provider.on_context_exceeded,
    on_context_exceeded: provider.on_context_exceeded,
    extraBody: redactExtra(provider.extra_body),
    extra_body: redactExtra(provider.extra_body),
    maxConcurrency: provider.max_concurrency,
    max_concurrency: provider.max_concurrency,
    timeoutMs: provider.timeout_ms,
    timeout_ms: provider.timeout_ms,
    queueTimeoutMs: provider.queue_timeout_ms,
    queue_timeout_ms: provider.queue_timeout_ms,
    maxRetries: provider.max_retries,
    max_retries: provider.max_retries,
    apiKeyConfigured: provider.api_key === undefined ? false : Boolean(provider.api_key),
    ...queueSnapshot(name)
  };
}

async function callTool(name, args) {
  const params = args || {};
  const config = loadConfigOrThrow();

  if (name === 'member_status') {
    const members = Object.keys(config.squad.members).map((memberName) =>
      memberSummary(config, memberName)
    );
    const selected = params.member === undefined ? null : memberSummary(config, params.member);
    const text = JSON.stringify({
      ok: true,
      available: true,
      configFile: CONFIG_FILE,
      schema: config.schema,
      squad: config.squad.name,
      members,
      ...(selected ? { selected } : {})
    }, null, 2);
    return { content: [{ type: 'text', text }] };
  }

  if (name === 'list_providers') {
    const text = JSON.stringify({
      ok: true,
      available: true,
      configFile: CONFIG_FILE,
      schema: config.schema,
      providers: Object.fromEntries(
        Object.keys(config.providers).map((providerName) => [
          providerName,
          providerSummary(config, providerName)
        ])
      ),
      members: Object.keys(config.squad.members).map((memberName) => {
        const member = config.squad.members[memberName];
        return {
          name: memberName,
          primary: member.primary,
          fallback: [...member.fallback]
        };
      })
    }, null, 2);
    return { content: [{ type: 'text', text }] };
  }

  if (name === 'critique_plan') {
    if (typeof params.plan_markdown !== 'string' || params.plan_markdown.trim() === '') {
      throw new Error('critique_plan requires a non-empty "plan_markdown"');
    }
    const memberInfo = resolveMember(config, params.member);
    const user = [
      'PLAN MARKDOWN:',
      params.plan_markdown,
      '',
      'REPO CONTEXT:',
      typeof params.repo_context === 'string' && params.repo_context.trim()
        ? params.repo_context
        : '(none provided)'
    ].join('\n');
    const result = await queryWithMember(memberInfo, {
      systemPrompt: CRITIQUE_SYSTEM,
      userPrompt: user,
      params
    });
    return { content: [{ type: 'text', text: result.text }], meta: result.meta };
  }

  if (name === 'generate_code') {
    const prompt = typeof params.prompt === 'string' ? params.prompt : params.task_spec;
    if (typeof prompt !== 'string' || prompt.trim() === '') {
      throw new Error('generate_code requires a non-empty "prompt" (or "task_spec")');
    }
    const context = typeof params.context === 'string' ? params.context : params.file_context;
    const memberInfo = resolveMember(config, params.member);
    const system = typeof params.system === 'string' && params.system.trim() ? params.system : DEFAULT_SYSTEM;
    const user = typeof context === 'string' && context.trim()
      ? `TASK:\n${prompt}\n\nRELEVANT CONTEXT:\n${context}`
      : `TASK:\n${prompt}`;
    const result = await queryWithMember(memberInfo, {
      systemPrompt: system,
      userPrompt: user,
      params
    });
    return { content: [{ type: 'text', text: result.text }], meta: result.meta };
  }

  throw new Error(`unknown tool: ${name}`);
}

async function handleLine(line) {
  let message;
  try {
    message = JSON.parse(line);
  } catch (error) {
    fail(null, -32700, `parse error: ${error.message}`);
    return;
  }

  const id = message.id;
  const isNotification = id === undefined;
  const method = message.method;

  try {
    switch (method) {
      case 'initialize': {
        const version = message.params && message.params.protocolVersion
          ? message.params.protocolVersion
          : '2025-06-18';
        ok(id, {
          protocolVersion: version,
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: SERVER_NAME, version: SERVER_VERSION }
        });
        return;
      }
      case 'notifications/initialized':
      case 'notifications/cancelled':
        return;
      case 'ping':
        ok(id, {});
        return;
      case 'tools/list':
        ok(id, { tools: TOOLS });
        return;
      case 'tools/call': {
        const params = message.params || {};
        try {
          const { content, meta } = await callTool(params.name, params.arguments);
          ok(id, meta ? { content, meta } : { content });
        } catch (error) {
          ok(id, { content: [{ type: 'text', text: `Error: ${error.message}` }], isError: true });
        }
        return;
      }
      default:
        if (!isNotification) fail(id, -32601, `method not found: ${method}`);
    }
  } catch (error) {
    if (!isNotification) fail(id, -32603, `internal error: ${error.message}`);
    else log(`internal error in ${method}: ${error.message}`);
  }
}

let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (line) void handleLine(line);
  }
});

module.exports = {
  CONFIG_FILE,
  SERVER_NAME,
  SERVER_VERSION,
  TOOLS,
  callTool,
  handleLine,
  resolveMember
};
'@
Install-File 'mcp/config.js' @'
#!/usr/bin/env node
'use strict';

// Zero-dependency reader for muse-squad.toml.
// Implements the small TOML subset used by muse-squad and validates the
// single-file config so every other tool can trust the shape.

const fs = require('fs');
const os = require('os');
const path = require('path');

const SCHEMA = 1;
const PROVIDER_NAME_RE = /^[A-Za-z0-9._-]+$/;
const MEMBER_NAME_RE = /^[a-z0-9][a-z0-9-]*$/;

const PROVIDER_KEYS = new Set([
  'type', 'base_url', 'api_key', 'model', 'temperature', 'top_p',
  'max_tokens', 'max_input_chars', 'on_context_exceeded', 'extra_body',
  'max_concurrency', 'timeout_ms', 'queue_timeout_ms', 'max_retries'
]);
const SQUAD_KEYS = new Set(['name', 'memory_dir']);
const MEMBER_KEYS = new Set(['primary', 'fallback', 'charter']);

function expandHome(value) {
  return String(value).replace(/^~(?=$|[\\/])/, os.homedir());
}

function configPath(options = {}) {
  const configDir = expandHome(options.config_dir || process.env.MUSE_CONFIG_DIR ||
    path.join(os.homedir(), '.config', 'muse'));
  return expandHome(options.config_file || process.env.MUSE_SQUAD_CONFIG_FILE ||
    path.join(configDir, 'muse-squad.toml'));
}

function stripComment(text) {
  let quote = null;
  let escaped = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char === '\\' && quote === '"') {
      escaped = true;
      continue;
    }
    if (quote) {
      if (char === quote) quote = null;
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      continue;
    }
    if (char === '#') return text.slice(0, i);
  }
  return text;
}

function decodeBasic(value) {
  let out = '';
  for (let i = 0; i < value.length; i++) {
    const char = value[i];
    if (char !== '\\' || i + 1 >= value.length) {
      out += char;
      continue;
    }
    const next = value[++i];
    const decoded = {
      n: '\n',
      t: '\t',
      r: '\r',
      b: '\b',
      f: '\f',
      '"': '"',
      '\\': '\\'
    }[next];
    out += decoded === undefined ? `\\${next}` : decoded;
  }
  return out;
}

function parseScalar(raw, file, lineNo) {
  const text = String(raw).trim();
  if (!text) throw new Error(`${file}:${lineNo}: empty value`);

  if (text === 'true') return true;
  if (text === 'false') return false;

  if (/^-?\d+$/.test(text)) {
    const value = Number(text);
    if (!Number.isSafeInteger(value)) throw new Error(`${file}:${lineNo}: integer out of range`);
    return value;
  }
  if (/^-?\d+\.\d+$/.test(text)) {
    const value = Number(text);
    if (!Number.isFinite(value)) throw new Error(`${file}:${lineNo}: invalid number`);
    return value;
  }

  if (text.startsWith('"""')) {
    if (!text.endsWith('"""') || text.length < 6) {
      throw new Error(`${file}:${lineNo}: unterminated multi-line string`);
    }
    return decodeBasic(text.slice(3, -3).replace(/^\r?\n/, ''));
  }
  if (text.startsWith("'''")) {
    if (!text.endsWith("'''") || text.length < 6) {
      throw new Error(`${file}:${lineNo}: unterminated multi-line string`);
    }
    return text.slice(3, -3).replace(/^\r?\n/, '');
  }
  if (text.startsWith('"')) {
    if (!text.endsWith('"') || text.length < 2) {
      throw new Error(`${file}:${lineNo}: unterminated string`);
    }
    return decodeBasic(text.slice(1, -1));
  }
  if (text.startsWith("'")) {
    if (!text.endsWith("'") || text.length < 2) {
      throw new Error(`${file}:${lineNo}: unterminated string`);
    }
    return text.slice(1, -1);
  }

  throw new Error(`${file}:${lineNo}: values must be quoted strings, numbers, booleans, or arrays`);
}

function splitArray(text, file, lineNo) {
  const inner = text.slice(1, -1);
  const items = [];
  let current = '';
  let quote = null;
  let escaped = false;
  for (const char of inner) {
    if (escaped) {
      current += char;
      escaped = false;
      continue;
    }
    if (char === '\\' && quote === '"') {
      current += char;
      escaped = true;
      continue;
    }
    if (quote) {
      current += char;
      if (char === quote) quote = null;
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      current += char;
      continue;
    }
    if (char === ',') {
      items.push(current.trim());
      current = '';
      continue;
    }
    current += char;
  }
  if (quote) throw new Error(`${file}:${lineNo}: unterminated string in array`);
  if (current.trim()) items.push(current.trim());
  return items;
}

function parseToml(raw, file) {
  const lines = String(raw).replace(/^\uFEFF/, '').split(/\r?\n/);
  const root = {};
  let table = root;

  for (let i = 0; i < lines.length; i++) {
    const lineNo = i + 1;
    const line = lines[i];
    const trimmed = stripComment(line).trim();
    if (!trimmed) continue;

    const tableMatch = trimmed.match(/^\[([^\[\]]+)\]$/);
    if (tableMatch) {
      const parts = tableMatch[1].trim().split('.').map((part) => part.trim());
      if (parts.some((part) => !part)) throw new Error(`${file}:${lineNo}: invalid table name`);
      table = root;
      for (const part of parts) {
        if (table[part] === undefined) table[part] = {};
        if (!table[part] || typeof table[part] !== 'object' || Array.isArray(table[part])) {
          throw new Error(`${file}:${lineNo}: table conflict at ${part}`);
        }
        table = table[part];
      }
      continue;
    }

    const keyMatch = line.match(/^\s*([A-Za-z0-9_.-]+)\s*=\s*([\s\S]*)$/);
    if (!keyMatch) throw new Error(`${file}:${lineNo}: cannot parse line: ${line}`);
    const key = keyMatch[1];
    let valueText = stripComment(keyMatch[2]).trim();
    const rawValueText = keyMatch[2].trim();

    const multilineMatch = rawValueText.match(/^("""|''')/);
    if (multilineMatch && rawValueText.indexOf(multilineMatch[1], 3) === -1) {
      const delimiter = multilineMatch[1];
      const collected = [rawValueText.slice(3)];
      let closed = false;
      while (++i < lines.length) {
        const next = lines[i];
        const end = next.indexOf(delimiter);
        if (end >= 0) {
          collected.push(next.slice(0, end));
          closed = true;
          break;
        }
        collected.push(next);
      }
      if (!closed) throw new Error(`${file}:${lineNo}: unterminated multi-line string`);
      valueText = `${delimiter}${collected.join('\n')}${delimiter}`;
    }

    if (valueText.startsWith('[')) {
      if (!valueText.endsWith(']')) throw new Error(`${file}:${lineNo}: unterminated array`);
      table[key] = splitArray(valueText, file, lineNo).map((item) => parseScalar(item, file, lineNo));
    } else {
      table[key] = parseScalar(valueText, file, lineNo);
    }
  }
  return root;
}

function expandEnv(value, file, keyPath) {
  if (Array.isArray(value)) return value.map((item) => expandEnv(item, file, keyPath));
  if (value && typeof value === 'object') {
    const copy = {};
    for (const [key, item] of Object.entries(value)) {
      copy[key] = expandEnv(item, file, keyPath ? `${keyPath}.${key}` : key);
    }
    return copy;
  }
  if (typeof value !== 'string') return value;
  const key = String(keyPath || '').split('.').pop();
  if (key !== 'api_key' || !value.includes('${')) return value;
  return value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (match, name) => {
    const resolved = process.env[name];
    if (resolved === undefined || resolved === '') {
      throw new Error(`${file}: ${keyPath} references unset environment variable ${name}`);
    }
    return resolved;
  });
}

function requireObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be a table`);
  }
  return value;
}

function requireString(value, label, { allowEmpty = false } = {}) {
  if (typeof value !== 'string' || (!allowEmpty && !value.trim())) {
    throw new Error(`${label} must be a non-empty string`);
  }
  return value;
}

function requireInteger(value, label, { min = 1, fallback } = {}) {
  if (value === undefined && fallback !== undefined) return fallback;
  if (!Number.isInteger(value) || value < min) {
    throw new Error(`${label} must be an integer >= ${min}`);
  }
  return value;
}

function requireNumber(value, label, { min = 0, fallback } = {}) {
  if (value === undefined && fallback !== undefined) return fallback;
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= min) {
    throw new Error(`${label} must be a number > ${min}`);
  }
  return value;
}

function checkKeys(table, allowed, label) {
  for (const key of Object.keys(table)) {
    if (!allowed.has(key)) throw new Error(`${label}: unknown setting "${key}"`);
  }
}

function normalizeProvider(name, raw, file) {
  const label = `${file}: provider "${name}"`;
  requireObject(raw, label);
  checkKeys(raw, PROVIDER_KEYS, label);

  const type = requireString(raw.type, `${label}.type`);
  if (type !== 'http' && type !== 'native') {
    throw new Error(`${label}.type must be "http" or "native"`);
  }
  if (type === 'native' && (raw.base_url !== undefined || raw.api_key !== undefined)) {
    throw new Error(`${label}: native providers cannot declare base_url or api_key`);
  }

  const extraBody = raw.extra_body === undefined ? {} : raw.extra_body;
  requireObject(extraBody, `${label}.extra_body`);
  if (raw.top_p !== undefined && extraBody.top_p === undefined) {
    extraBody.top_p = requireNumber(raw.top_p, `${label}.top_p`, { min: -Infinity });
  }

  const provider = {
    name,
    type,
    model: requireString(raw.model, `${label}.model`),
    temperature: raw.temperature === undefined
      ? undefined
      : requireNumber(raw.temperature, `${label}.temperature`, { min: -Infinity }),
    max_tokens: raw.max_tokens === undefined
      ? undefined
      : requireInteger(raw.max_tokens, `${label}.max_tokens`),
    max_input_chars: raw.max_input_chars === undefined
      ? undefined
      : requireInteger(raw.max_input_chars, `${label}.max_input_chars`),
    on_context_exceeded: raw.on_context_exceeded === undefined ? 'truncate' : raw.on_context_exceeded,
    extra_body: JSON.parse(JSON.stringify(extraBody)),
    max_concurrency: requireInteger(raw.max_concurrency, `${label}.max_concurrency`, { fallback: 1 }),
    timeout_ms: requireInteger(raw.timeout_ms, `${label}.timeout_ms`, { fallback: 600000 }),
    queue_timeout_ms: requireInteger(raw.queue_timeout_ms, `${label}.queue_timeout_ms`, { fallback: 300000 }),
    max_retries: requireInteger(raw.max_retries, `${label}.max_retries`, { min: 0, fallback: 2 })
  };

  if (provider.on_context_exceeded !== 'truncate' && provider.on_context_exceeded !== 'fallback') {
    throw new Error(`${label}.on_context_exceeded must be "truncate" or "fallback"`);
  }
  if (type === 'http') {
    provider.base_url = requireString(raw.base_url, `${label}.base_url`);
    provider.api_key = raw.api_key === undefined
      ? ''
      : requireString(raw.api_key, `${label}.api_key`, { allowEmpty: true });
  }
  return provider;
}

function normalizeMember(name, raw, file) {
  const label = `${file}: member "${name}"`;
  requireObject(raw, label);
  checkKeys(raw, MEMBER_KEYS, label);

  const fallback = raw.fallback === undefined ? [] : raw.fallback;
  if (!Array.isArray(fallback) || fallback.some((item) => typeof item !== 'string' || !item.trim())) {
    throw new Error(`${label}.fallback must be an array of provider names`);
  }
  const primary = requireString(raw.primary, `${label}.primary`);
  if (fallback.includes(primary)) {
    throw new Error(`${label}.fallback must not repeat the primary provider`);
  }
  if (new Set(fallback).size !== fallback.length) {
    throw new Error(`${label}.fallback must not contain duplicate providers`);
  }
  return {
    name,
    primary,
    fallback: [...fallback],
    charter: requireString(raw.charter, `${label}.charter`)
  };
}

function validateConfig(raw, file) {
  checkKeys(raw, new Set(['schema', 'providers', 'squad']), file);
  if (raw.schema !== SCHEMA) throw new Error(`${file}: schema must be ${SCHEMA}`);

  const providerTable = requireObject(raw.providers, `${file}: providers`);
  const providerNames = Object.keys(providerTable);
  if (providerNames.length === 0) throw new Error(`${file}: at least one provider is required`);
  const providers = {};
  for (const name of providerNames) {
    if (!PROVIDER_NAME_RE.test(name)) throw new Error(`${file}: invalid provider name "${name}"`);
    providers[name] = normalizeProvider(name, providerTable[name], file);
  }

  const squadTable = requireObject(raw.squad, `${file}: squad`);
  const memberNames = Object.keys(squadTable).filter(
    (key) => !SQUAD_KEYS.has(key) && MEMBER_NAME_RE.test(key)
  );
  for (const key of Object.keys(squadTable)) {
    if (!SQUAD_KEYS.has(key) && !memberNames.includes(key)) {
      throw new Error(`${file}: squad: unknown setting "${key}"`);
    }
  }
  if (memberNames.length === 0) throw new Error(`${file}: at least one squad member is required`);
  const members = {};
  for (const name of memberNames) {
    members[name] = normalizeMember(name, squadTable[name], file);
  }

  for (const member of Object.values(members)) {
    for (const providerName of [member.primary, ...member.fallback]) {
      if (!Object.prototype.hasOwnProperty.call(providers, providerName)) {
        throw new Error(`${file}: member "${member.name}" references unknown provider "${providerName}"`);
      }
    }
  }

  return {
    schema: SCHEMA,
    file,
    squad: {
      name: typeof squadTable.name === 'string' && squadTable.name ? squadTable.name : 'Muse Squad',
      memory_dir: typeof squadTable.memory_dir === 'string' && squadTable.memory_dir
        ? squadTable.memory_dir
        : '.muse/squad',
      members
    },
    providers
  };
}

function loadConfig(options = {}) {
  const file = configPath(options);
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (error) {
    if (error && error.code === 'ENOENT') throw new Error(`config file not found: ${file}`);
    throw new Error(`cannot read ${file}: ${error.message}`);
  }
  const parsed = parseToml(raw, file);
  return validateConfig(expandEnv(parsed, file, ''), file);
}

function redactSecrets(value) {
  if (Array.isArray(value)) return value.map(redactSecrets);
  if (value && typeof value === 'object') {
    const copy = {};
    for (const [key, item] of Object.entries(value)) {
      if (/^(api[_-]?key|authorization|secret|password|token)$/i.test(key)) {
        copy[key] = item ? '<redacted>' : '';
      } else {
        copy[key] = redactSecrets(item);
      }
    }
    return copy;
  }
  return value;
}

function redactConfig(config) {
  return redactSecrets(JSON.parse(JSON.stringify(config)));
}

const USAGE = [
  'Usage: node config.js [options]',
  '',
  'Options:',
  '  --config-dir PATH   Muse config directory (default: ~/.config/muse)',
  '  --dir PATH          Alias for --config-dir',
  '  --file PATH         Explicit config file',
  '  --json              Emit the parsed config as JSON',
  '  --list-providers    Emit provider names, one per line',
  '  --show-secrets      Include api_key values in JSON output',
  '  --help, -h          Show this help',
  '',
  'Environment: MUSE_CONFIG_DIR, MUSE_SQUAD_CONFIG_FILE'
].join('\n');

function parseArgs(argv) {
  const opts = { json: false, listProviders: false, showSecrets: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') opts.help = true;
    else if (arg === '--json') opts.json = true;
    else if (arg === '--list-providers') opts.listProviders = true;
    else if (arg === '--show-secrets') opts.showSecrets = true;
    else if (arg === '--config-dir' || arg === '--dir' || arg === '--file') {
      const value = argv[++i];
      if (!value) throw new Error(`${arg} requires a value`);
      if (arg === '--file') opts.config_file = value;
      else opts.config_dir = value;
    } else {
      throw new Error(`unknown option: ${arg}`);
    }
  }
  return opts;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    process.stdout.write(`${USAGE}\n`);
    return;
  }
  const config = loadConfig(opts);
  if (opts.listProviders) {
    process.stdout.write(`${Object.keys(config.providers).join('\n')}\n`);
  } else if (opts.json) {
    const output = opts.showSecrets ? config : redactConfig(config);
    process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
  }
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`config: ${error.message}\n`);
    process.exitCode = 2;
  }
}

module.exports = {
  SCHEMA,
  configPath,
  expandHome,
  loadConfig,
  parseToml,
  redactConfig,
  validateConfig
};
'@
Install-File 'mcp/doctor.js' @'
#!/usr/bin/env node
'use strict';

// Lightweight, read-only diagnostics for a muse-squad installation.
// Zero npm dependencies; uses Node 18+ global fetch.

const fs = require('fs');
const os = require('os');
const path = require('path');
const configModule = require('./config.js');
const {
  GENERATED_MARKER,
  buildRoster,
  buildWrapper
} = require('./sync-team.js');

const SERVER_NAME = 'muse-squad';
const LEGACY_SERVER = 'custom-coder';
const GENERIC_AGENTS = ['worker', 'plan-reviewer', 'general-purpose'];
const DEFAULT_TIMEOUT_MS = 5000;
const USAGE = [
  'Usage: node doctor.js [options]',
  '',
  'Options:',
  '  --config-dir PATH   Muse config directory (default: ~/.config/muse)',
  '  --dir PATH          Alias for --config-dir',
  '  --file PATH         Explicit muse-squad.toml path',
  '  --timeout-ms N      Per-provider HTTP timeout (default: 5000)',
  '  --json              Emit a JSON report',
  '  --help, -h          Show this help',
  '',
  'Environment: MUSE_CONFIG_DIR, MUSE_SQUAD_CONFIG_FILE'
].join('\n');

function parseArgs(argv) {
  const opts = { timeout_ms: DEFAULT_TIMEOUT_MS, json: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') {
      opts.help = true;
    } else if (arg === '--json') {
      opts.json = true;
    } else if (arg === '--config-dir' || arg === '--dir' || arg === '--file' || arg === '--timeout-ms') {
      const value = argv[++i];
      if (!value) throw new Error(`${arg} requires a value`);
      if (arg === '--timeout-ms') {
        const timeout = Number(value);
        if (!Number.isInteger(timeout) || timeout <= 0) {
          throw new Error('--timeout-ms must be a positive integer');
        }
        opts.timeout_ms = timeout;
      } else if (arg === '--file') {
        opts.config_file = value;
      } else {
        opts.config_dir = value;
      }
    } else {
      throw new Error(`unknown option: ${arg}`);
    }
  }
  return opts;
}

function loadJson(file) {
  if (!fs.existsSync(file)) return { error: 'file not found' };
  try {
    return { data: JSON.parse(fs.readFileSync(file, 'utf8')) };
  } catch (error) {
    return { error: error.message };
  }
}

function normalized(content) {
  return String(content).replace(/\r?\n+$/, '') + '\n';
}

function redact(value, secrets) {
  let text = String(value == null ? '' : value);
  for (const secret of secrets) {
    if (secret) text = text.split(String(secret)).join('***');
  }
  return text;
}

function checkSettings(configDir, configFile) {
  const settingsFile = path.join(configDir, 'settings.json');
  const loaded = loadJson(settingsFile);
  if (loaded.error) {
    return {
      name: 'settings.json', status: 'MISSING', ok: false,
      detail: loaded.error === 'file not found'
        ? `${settingsFile} not found`
        : `cannot parse ${settingsFile}: ${loaded.error}`
    };
  }

  const settings = loaded.data;
  const servers = settings && settings.mcpServers;
  const entry = servers && typeof servers === 'object' && !Array.isArray(servers)
    ? servers[SERVER_NAME]
    : null;
  if (!entry || typeof entry !== 'object') {
    return {
      name: 'settings.json', status: 'MISSING', ok: false,
      detail: `${SERVER_NAME} is not registered under mcpServers`
    };
  }

  const bridge = path.join(configDir, 'mcp', 'bridge.js');
  const args = Array.isArray(entry.args) ? entry.args : [];
  const foundBridge = args.find((arg) => path.resolve(String(arg)) === path.resolve(bridge));
  const commandName = path.basename(String(entry.command || '')).toLowerCase();
  const commandOk = commandName === 'node' || commandName === 'node.exe';
  const configuredEnv = entry.env && entry.env.MUSE_SQUAD_CONFIG_FILE;
  const configOk = Boolean(configuredEnv) &&
    path.resolve(configModule.expandHome(configuredEnv)) === path.resolve(configFile);
  const legacyRegistered = (servers && Object.prototype.hasOwnProperty.call(servers, LEGACY_SERVER)) ||
    (settings.mcp_servers && Object.prototype.hasOwnProperty.call(settings.mcp_servers, LEGACY_SERVER));
  const ok = Boolean(foundBridge && commandOk && configOk && !legacyRegistered);

  const bits = [
    `command=${entry.command || '(none)'}`,
    `bridge=${foundBridge || '(missing)'}`,
    `config=${configuredEnv || '(missing)'}`
  ];
  if (legacyRegistered) bits.push(`legacy ${LEGACY_SERVER} still registered`);
  return { name: 'settings.json', status: ok ? 'OK' : 'BAD', ok, detail: bits.join(' ') };
}

function modelsUrl(baseUrl) {
  const trimmed = String(baseUrl).trim().replace(/\/+$/, '');
  if (/\/models$/i.test(trimmed)) return trimmed;
  if (/\/v1$/i.test(trimmed)) return `${trimmed}/models`;
  return `${trimmed}/v1/models`;
}

async function checkProviders(config, timeoutMs, secrets) {
  if (!config) {
    return [{
      provider: '(config)', status: 'BAD', ok: false,
      detail: 'provider check skipped because the config is invalid'
    }];
  }

  const results = [];
  for (const provider of Object.values(config.providers)) {
    for (const secret of [provider.api_key]) {
      if (secret) secrets.add(String(secret));
    }

    if (provider.type === 'native') {
      results.push({
        provider: provider.name,
        status: 'NATIVE',
        ok: true,
        detail: `model ${provider.model} (not pinged; advisory max_concurrency ${provider.max_concurrency})`
      });
      continue;
    }

    const url = modelsUrl(provider.base_url);
    const headers = provider.api_key ? { Authorization: `Bearer ${provider.api_key}` } : {};
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch(url, { method: 'GET', headers, signal: controller.signal });
      let hint = '';
      try {
        const body = await response.json();
        if (Array.isArray(body && body.data)) hint = `, ${body.data.length} models`;
      } catch (_) {
        // A non-JSON body still tells us the server answered.
      }
      const status = response.ok ? 'OK'
        : (response.status === 401 || response.status === 403 ? 'AUTH' : 'HTTP');
      results.push({
        provider: provider.name,
        status,
        ok: response.ok,
        detail: redact(`${url} ${response.status}${hint}`, secrets)
      });
    } catch (error) {
      const timedOut = error && error.name === 'AbortError';
      results.push({
        provider: provider.name,
        status: timedOut ? 'TIMEOUT' : 'DOWN',
        ok: false,
        detail: redact(`${url} ${error && error.message || error}`, secrets)
      });
    } finally {
      clearTimeout(timer);
    }
  }
  return results;
}

function checkRoster(config, configFile, configDir) {
  if (!config) {
    return {
      name: 'muse-squad.toml', status: 'SKIP', ok: false,
      detail: 'roster check skipped because the config is invalid'
    };
  }

  const issues = [];
  const expectedNames = new Set(Object.keys(config.squad.members));

  const roster = path.join(configDir, 'squad', 'team.md');
  try {
    if (!fs.existsSync(roster)) {
      issues.push('squad/team.md missing');
    } else {
      const expected = buildRoster(config, configFile);
      if (normalized(fs.readFileSync(roster, 'utf8')) !== normalized(expected)) {
        issues.push('squad/team.md out of sync');
      }
    }
  } catch (error) {
    issues.push(`squad/team.md cannot verify: ${error.message}`);
  }

  for (const name of expectedNames) {
    try {
      const wrapper = path.join(configDir, 'agents', `${name}.md`);
      if (!fs.existsSync(wrapper)) {
        issues.push(`@${name} wrapper missing`);
        continue;
      }
      const expected = buildWrapper(config, name, configFile);
      if (normalized(fs.readFileSync(wrapper, 'utf8')) !== normalized(expected)) {
        issues.push(`@${name} wrapper out of sync`);
      }
    } catch (error) {
      issues.push(`@${name} cannot verify: ${error.message}`);
    }
  }

  const agentsDir = path.join(configDir, 'agents');
  if (fs.existsSync(agentsDir)) {
    for (const entry of fs.readdirSync(agentsDir)) {
      if (!entry.endsWith('.md')) continue;
      const name = path.basename(entry, '.md');
      if (expectedNames.has(name)) continue;
      const content = fs.readFileSync(path.join(agentsDir, entry), 'utf8');
      if (content.includes(GENERATED_MARKER)) issues.push(`@${name} stale generated wrapper`);
    }
  }

  for (const name of GENERIC_AGENTS) {
    if (fs.existsSync(path.join(agentsDir, `${name}.md`))) {
      issues.push(`generic agent ${name}.md still present`);
    }
  }

  const ok = issues.length === 0;
  return {
    name: 'muse-squad.toml',
    status: ok ? 'OK' : 'BAD',
    ok,
    detail: ok
      ? `${expectedNames.size} members; roster and wrappers in sync; no generic agents`
      : issues.join('; ')
  };
}

function renderText(report) {
  const pad = (value, size) => String(value).padEnd(size);
  const lines = ['squad-doctor', ''];
  lines.push(`  ${pad(report.checks.settings.name, 16)} ${pad(report.checks.settings.status, 7)} ${report.checks.settings.detail}`);
  lines.push(`  ${pad(report.checks.config.name, 16)} ${pad(report.checks.config.status, 7)} ${report.checks.config.detail}`);
  lines.push('  providers');
  for (const provider of report.checks.providers) {
    lines.push(`    ${pad(provider.provider, 16)} ${pad(provider.status, 7)} ${provider.detail}`);
  }
  lines.push(`  ${pad(report.checks.roster.name, 16)} ${pad(report.checks.roster.status, 7)} ${report.checks.roster.detail}`);
  lines.push('');
  lines.push(report.ok
    ? 'Overall: all checks passed'
    : `Overall: ${report.problems} problem${report.problems === 1 ? '' : 's'} found`);
  return `${lines.join('\n')}\n`;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    process.stdout.write(`${USAGE}\n`);
    return;
  }

  const configDir = configModule.expandHome(opts.config_dir || process.env.MUSE_CONFIG_DIR ||
    path.join(os.homedir(), '.config', 'muse'));
  const configFile = configModule.configPath(opts);
  const secrets = new Set();

  let config = null;
  let configCheck;
  try {
    config = configModule.loadConfig({ config_file: configFile });
    for (const provider of Object.values(config.providers)) {
      if (provider.api_key) secrets.add(String(provider.api_key));
    }
    configCheck = {
      name: 'muse-squad.toml',
      status: 'OK',
      ok: true,
      detail: `${Object.keys(config.providers).length} providers, ${Object.keys(config.squad.members).length} members, schema ${config.schema}`
    };
  } catch (error) {
    configCheck = {
      name: 'muse-squad.toml', status: 'BAD', ok: false, detail: error.message
    };
  }

  const settings = checkSettings(configDir, configFile);
  const providers = await checkProviders(config, opts.timeout_ms, secrets);
  const roster = checkRoster(config, configFile, configDir);
  const checks = { settings, config: configCheck, providers, roster };
  const problems = [settings, configCheck, ...providers, roster].filter((check) => !check.ok).length;
  const report = { ok: problems === 0, problems, checks };

  process.stdout.write(opts.json ? `${JSON.stringify(report, null, 2)}\n` : renderText(report));
  if (!report.ok) process.exitCode = 1;
}

main().catch((error) => {
  process.stderr.write(`doctor.js: ${error.message}\n`);
  process.exitCode = 2;
});
'@
Install-File 'mcp/register-settings.js' @'
#!/usr/bin/env node
'use strict';

// Merges the muse-squad MCP entry into Muse Code's settings.json without
// disturbing any other settings or MCP servers.

const fs = require('fs');
const path = require('path');

const SERVER_NAME = 'muse-squad';
const LEGACY_SERVER = 'custom-coder';

function option(flag) {
  const index = process.argv.indexOf(flag);
  return index >= 0 && index + 1 < process.argv.length ? process.argv[index + 1] : undefined;
}

const settingsPath = option('--settings');
const bridgePath = option('--bridge');
const configFile = option('--config-file');
const unregister = process.argv.includes('--unregister');

if (!settingsPath) {
  console.error('register-settings.js: --settings is required');
  process.exit(2);
}

function loadSettings() {
  if (!fs.existsSync(settingsPath)) return {};
  const raw = fs.readFileSync(settingsPath, 'utf8');
  if (!raw.trim()) return {};
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('top-level JSON value must be an object');
    }
    return parsed;
  } catch (error) {
    throw new Error(`cannot parse ${settingsPath}: ${error.message}`);
  }
}

function backupSettings() {
  const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
  const backup = `${settingsPath}.bak.${stamp}`;
  fs.copyFileSync(settingsPath, backup);
  return backup;
}

function writeSettings(settings) {
  const dir = path.dirname(settingsPath);
  fs.mkdirSync(dir, { recursive: true });
  const temporary = path.join(dir, `.settings.json.muse-squad-${process.pid}.tmp`);
  fs.writeFileSync(temporary, `${JSON.stringify(settings, null, 2)}\n`, 'utf8');
  fs.renameSync(temporary, settingsPath);
}

function main() {
  const settings = loadSettings();
  if (settings.schema_version === undefined) settings.schema_version = 1;

  const hasServers = settings.mcpServers && typeof settings.mcpServers === 'object' && !Array.isArray(settings.mcpServers);
  if (!hasServers) settings.mcpServers = {};

  // Clean up legacy snake_case key left by older installers.
  const legacy = settings.mcp_servers && typeof settings.mcp_servers === 'object' && !Array.isArray(settings.mcp_servers)
    ? settings.mcp_servers
    : null;

  if (unregister) {
    const removedCurrent = Object.prototype.hasOwnProperty.call(settings.mcpServers, SERVER_NAME);
    const removedLegacy = Object.prototype.hasOwnProperty.call(settings.mcpServers, LEGACY_SERVER) ||
      !!(legacy && Object.prototype.hasOwnProperty.call(legacy, LEGACY_SERVER));
    if (!removedCurrent && !removedLegacy) {
      console.log(`  unchanged  ${SERVER_NAME} not registered`);
      return;
    }
    if (removedCurrent) delete settings.mcpServers[SERVER_NAME];
    if (Object.prototype.hasOwnProperty.call(settings.mcpServers, LEGACY_SERVER)) {
      delete settings.mcpServers[LEGACY_SERVER];
    }
    if (legacy && Object.prototype.hasOwnProperty.call(legacy, LEGACY_SERVER)) {
      delete legacy[LEGACY_SERVER];
    }
  } else {
    if (!bridgePath || !configFile) {
      console.error('register-settings.js: --bridge and --config-file are required');
      process.exit(2);
    }
    settings.mcpServers[SERVER_NAME] = {
      transport: 'stdio',
      command: 'node',
      args: [bridgePath],
      env: {
        MUSE_SQUAD_CONFIG_FILE: configFile
      },
      mode: 'optional'
    };
    if (Object.prototype.hasOwnProperty.call(settings.mcpServers, LEGACY_SERVER)) {
      delete settings.mcpServers[LEGACY_SERVER];
    }
    if (legacy && Object.prototype.hasOwnProperty.call(legacy, LEGACY_SERVER)) {
      delete legacy[LEGACY_SERVER];
    }
  }

  // Remove empty legacy container to avoid confusing duplicate config.
  if (legacy && Object.keys(legacy).length === 0) {
    delete settings.mcp_servers;
  }

  const desired = `${JSON.stringify(settings, null, 2)}\n`;
  const current = fs.existsSync(settingsPath) ? fs.readFileSync(settingsPath, 'utf8') : '';
  if (current === desired) {
    console.log('  unchanged  settings.json');
    return;
  }

  if (fs.existsSync(settingsPath)) {
    const backup = backupSettings();
    console.log(`  backed up  ${settingsPath} -> ${backup}`);
  }
  writeSettings(settings);
  console.log(`  ${unregister ? 'unregistered' : 'registered'}  ${SERVER_NAME} in ${settingsPath}`);
}

try {
  main();
} catch (error) {
  console.error(`register-settings.js: ${error.message}`);
  process.exit(1);
}
'@
Install-File 'mcp/sync-team.js' @'
#!/usr/bin/env node
'use strict';

// Materializes the single muse-squad.toml roster into native Muse agent
// wrappers and a human-readable roster. Zero npm dependencies.

const fs = require('fs');
const os = require('os');
const path = require('path');
const configModule = require('./config.js');

const GENERATED_MARKER =
  '<!-- Generated by muse-squad sync-team.js; edit muse-squad.toml and re-run the installer. -->';
const RUNNER_MODEL = 'muse-ember-1.0';

function die(message) {
  process.stderr.write(`sync-team: ${message}\n`);
  process.exit(1);
}

function log(message) {
  process.stdout.write(`${message}\n`);
}

function warn(message) {
  process.stderr.write(`sync-team: warning: ${message}\n`);
}

function expandHome(value) {
  return String(value).replace(/^~(?=$|[\\/])/, os.homedir());
}

const USAGE = [
  'Usage: node sync-team.js [options]',
  '',
  'Options:',
  '  --config-dir PATH   Muse config directory (default: ~/.config/muse)',
  '  --dir PATH          Alias for --config-dir',
  '  --file PATH         Explicit muse-squad.toml path',
  '  --uninstall         Remove only generated wrappers and roster',
  '  --help, -h          Show this help',
  '',
  'Environment: MUSE_CONFIG_DIR, MUSE_SQUAD_CONFIG_FILE'
].join('\n');

function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--uninstall') opts.uninstall = true;
    else if (arg === '--help' || arg === '-h') opts.help = true;
    else if (arg === '--config-dir' || arg === '--dir' || arg === '--file') {
      const value = argv[++i];
      if (!value) die(`${arg} requires a value`);
      if (arg === '--file') opts.config_file = value;
      else opts.config_dir = value;
    } else {
      die(`unknown option: ${arg}`);
    }
  }
  return opts;
}

function escapeCell(value) {
  return String(value).replace(/\|/g, '\\|').replace(/\r?\n/g, ' ');
}

function firstSentence(text) {
  const flat = String(text).replace(/\s+/g, ' ').trim();
  const match = flat.match(/^.*?[.!?](?=\s|$)/);
  return (match ? match[0] : flat).slice(0, 200);
}

function chain(config, member) {
  const names = [member.primary, ...member.fallback];
  return [...new Set(names)];
}

function chainLabel(config, member) {
  return chain(config, member)
    .map((name) => {
      const provider = config.providers[name];
      return `\`${name}\` (${provider.type})`;
    })
    .join(' -> ');
}

function buildRoster(config, configFile) {
  const file = path.basename(configFile || 'muse-squad.toml');
  const lines = [
    `# ${config.squad.name}`,
    '',
    GENERATED_MARKER,
    '',
    `Generated from \`${file}\` by \`mcp/sync-team.js\`. ` +
      'Edit the config and re-run the installer instead of editing this file.',
    '',
    '| @name | Primary | Fallback | Focus |',
    '| --- | --- | --- | --- |'
  ];

  for (const member of Object.values(config.squad.members)) {
    const primary = config.providers[member.primary];
    const fallbacks = member.fallback.length
      ? member.fallback.map((name) => `\`${name}\``).join(', ')
      : '(none)';
    lines.push(
      `| @${member.name} | \`${member.primary}\` (${primary.type}) | ${fallbacks} | ` +
      `${escapeCell(firstSentence(member.charter))} |`
    );
  }

  lines.push(
    '',
    '## Invoking members',
    '',
    'Mention `@<name>` in normal chat or spawn that named agent from `/squad-plan` and ' +
      '`/squad-execute`. Every task belongs to a named squad member; there are no generic helpers.',
    '',
    'Each wrapper reads the shared decisions log and its own history before work, then appends ' +
      'lasting learnings when done.',
    '',
    '## Project memory',
    '',
    `- \`${config.squad.memory_dir}/decisions.md\` - shared architectural decisions.`,
    `- \`${config.squad.memory_dir}/history/<name>.md\` - per-member conventions, file maps, and gotchas.`,
    '',
    'Create the directory and both paths on first use in a repository if they do not exist yet.'
  );
  return `${lines.join('\n')}\n`;
}

function buildWrapper(config, memberName, configFile) {
  const member = config.squad.members[memberName];
  if (!member) throw new Error(`unknown member "${memberName}"`);

  const primary = config.providers[member.primary];
  const runnerModel = primary.type === 'http' ? RUNNER_MODEL : primary.model;
  const decisions = `${config.squad.memory_dir}/decisions.md`;
  const history = `${config.squad.memory_dir}/history/${member.name}.md`;
  const chainNames = chain(config, member);
  const routing = [];

  routing.push(`Provider chain: ${chainLabel(config, member)}.`);

  if (primary.type === 'native') {
    routing.push(
      `- Primary \`${member.primary}\` is a native Muse model and is pinned in frontmatter.`,
      `- If this native turn fails because of quota, rate limits, or subscription limits, retry the SAME STEP through \`muse-squad:generate_code\` (or \`muse-squad:critique_plan\` for plans) with \`member="${member.name}"\`.`,
      '- The router skips native providers it cannot call and tries the first HTTP provider in this member\'s chain.'
    );
  } else {
    routing.push(
      `- Primary \`${member.primary}\` is an HTTP provider. The \`model: ${RUNNER_MODEL}\` frontmatter makes this a lightweight tool-runner; delegate heavy code generation to \`muse-squad:generate_code\` or plan critique to \`muse-squad:critique_plan\` with \`member="${member.name}"\`.`
    );
  }

  for (const name of member.fallback) {
    const provider = config.providers[name];
    if (provider.type === 'http') {
      routing.push(
        `- Fallback \`${name}\` is an HTTP provider in this member's chain; the router tries it automatically after an earlier provider fails.`
      );
    } else {
      routing.push(
        `- Fallback \`${name}\` is native model \`${provider.model}\`. If the router has exhausted the HTTP providers in this chain, retry the same step natively on that model and note the switch.`
      );
    }
  }

  if (member.fallback.length === 0) {
    routing.push(
      '- This member has no fallback. If its provider fails, stop and report the error; do not switch models or work inline.'
    );
  } else {
    routing.push(
      '- Never use a provider, model, or inline work outside this member\'s chain. If every provider in the chain fails, stop and report the error.'
    );
  }

  routing.push(
    'Report actual `servedBy`, `servedProvider`, `servedModel`, `fallbackUsed`, and `attempts` from tool meta; never infer who answered.'
  );

  const file = path.basename(configFile || 'muse-squad.toml');
  const description = `Use proactively for ${firstSentence(member.charter)} Invoke as @${member.name}.`;
  const lines = [
    '---',
    `name: ${member.name}`,
    `description: ${JSON.stringify(description)}`,
    `model: ${runnerModel}`,
    '---',
    GENERATED_MARKER,
    '',
    `# @${member.name}`,
    '',
    `You are @${member.name}, a named member of ${config.squad.name}. All work assigned to you must follow your charter and provider chain.`,
    '',
    '## Charter',
    '',
    member.charter.trim(),
    '',
    '## Routing',
    '',
    ...routing,
    '',
    '## Project memory',
    '',
    `Before starting, read \`${decisions}\` and \`${history}\` when present. If \`${config.squad.memory_dir}/\` does not exist in this repository, create it with \`${decisions}\` and an empty \`history/\` directory before proceeding.`,
    `When finished, append only concise lasting learnings to \`${history}\` - file conventions, gotchas, and decisions that matter next time. Never rewrite earlier notes.`,
    '',
    '## TUI label',
    '',
    `Use the short task title \`[${member.name} | ${member.primary}] <action>\` with the action under ~50 characters.`
  ];
  return `${lines.join('\n')}\n`;
}

function normalized(content) {
  return String(content).replace(/\r?\n+$/, '') + '\n';
}

function writeIfChanged(dest, content) {
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  const updated = normalized(content);
  let existing = null;
  if (fs.existsSync(dest)) existing = fs.readFileSync(dest, 'utf8');
  if (existing !== null && normalized(existing) === updated) {
    log(`  unchanged  ${dest}`);
    return;
  }
  fs.writeFileSync(dest, updated, 'utf8');
  log(`  ${existing === null ? 'generated' : 'updated'}  ${dest}`);
}

function removeGeneratedAgents(agentsDir, keepNames = null) {
  if (!fs.existsSync(agentsDir)) return;
  for (const entry of fs.readdirSync(agentsDir)) {
    if (!entry.endsWith('.md')) continue;
    if (keepNames && keepNames.has(path.basename(entry, '.md'))) continue;
    const dest = path.join(agentsDir, entry);
    let content;
    try {
      content = fs.readFileSync(dest, 'utf8');
    } catch (error) {
      warn(`cannot read ${dest}: ${error.message}`);
      continue;
    }
    if (!content.includes(GENERATED_MARKER)) continue;
    try {
      fs.unlinkSync(dest);
      log(`  removed    ${dest}`);
    } catch (error) {
      warn(`cannot remove ${dest}: ${error.message}`);
    }
  }
}

function removeIfGenerated(dest, label) {
  if (!fs.existsSync(dest)) {
    log(`  absent     ${dest}`);
    return;
  }
  const content = fs.readFileSync(dest, 'utf8');
  if (!content.includes(GENERATED_MARKER)) {
    log(`  kept       ${dest} (not generated by muse-squad)`);
    return;
  }
  fs.unlinkSync(dest);
  log(`  removed    ${label}: ${dest}`);
}

function removeEmptyDir(dir) {
  try {
    if (fs.existsSync(dir) && fs.readdirSync(dir).length === 0) fs.rmdirSync(dir);
  } catch (error) {
    warn(`cannot remove empty directory ${dir}: ${error.message}`);
  }
}

function uninstall(configDir) {
  // Scan by marker instead of trusting config: a deleted or edited roster must
  // not leave stale generated wrappers behind on uninstall.
  removeGeneratedAgents(path.join(configDir, 'agents'));
  removeIfGenerated(path.join(configDir, 'squad', 'team.md'), 'team.md');
  removeEmptyDir(path.join(configDir, 'squad'));
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    process.stdout.write(`${USAGE}\n`);
    return;
  }

  const configDir = expandHome(opts.config_dir || process.env.MUSE_CONFIG_DIR ||
    path.join(os.homedir(), '.config', 'muse'));
  const configFile = configModule.configPath(opts);

  if (opts.uninstall) {
    uninstall(configDir);
    return;
  }

  const config = configModule.loadConfig({ config_file: configFile });
  const memberNames = Object.keys(config.squad.members);
  log(`sync-team: ${memberNames.length} members`);

  writeIfChanged(
    path.join(configDir, 'squad', 'team.md'),
    buildRoster(config, configFile)
  );
  for (const name of memberNames) {
    writeIfChanged(
      path.join(configDir, 'agents', `${name}.md`),
      buildWrapper(config, name, configFile)
    );
  }
  removeGeneratedAgents(path.join(configDir, 'agents'), new Set(memberNames));
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`sync-team: ${error && error.message || error}\n`);
    process.exitCode = 1;
  }
}

module.exports = {
  GENERATED_MARKER,
  RUNNER_MODEL,
  buildRoster,
  buildWrapper,
  expandHome,
  chain,
  uninstall
};
'@
  Uninstall-File 'agents/plan-reviewer.md'
  Uninstall-File 'agents/general-purpose.md'
  Uninstall-File 'agents/worker.md'
function Get-Config-Defaults {
  @'
# muse-squad configuration - schema = 1
# Single source of truth. Edit by hand or with /squad-team.
# There is no second config file and no migration step.

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
#
# Use # comments in this file (TOML does not use ; comments).

[providers.Home-Ornith]
type = "http"
base_url = "http://127.0.0.1:8000/v1"
api_key = "local-key"             # or "${LOCAL_MODEL_API_KEY}"
model = "local-llama/Ornith-1.5-35B-A3B-MLX-4bit"
temperature = 0.2
top_p = 0.9
max_tokens = 8192
max_input_chars = 96000
on_context_exceeded = "truncate"  # "truncate" or "fallback"
max_concurrency = 1
timeout_ms = 600000
queue_timeout_ms = 300000
max_retries = 2

[providers.DeepSeek-Flash]
type = "http"
base_url = "https://api.deepseek.com/v1"
api_key = "replace-me"            # e.g. "${DEEPSEEK_API_KEY}"
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
# primary + fallback must reference provider names above. At least one member.

[squad]

[squad.team-lead]
primary = "Muse-Spark"
fallback = ["DeepSeek-Flash"]
charter = """Domain expertise: system architecture, dependency order, risk analysis, and decision-complete planning. Voice: concise, decisive, and evidence-first; ask for the exact file or command instead of guessing. Guardrails: do not edit product code while planning, cite concrete files and verification steps, and surface ambiguity before it becomes an implementation assumption."""

[squad.frontend]
primary = "Home-Ornith"
fallback = ["Muse-Ember"]
charter = """Domain expertise: UI components, styling systems, accessibility, and browser-side state. Voice: pragmatic and detail-oriented; describe the visible behavior a change should produce. Guardrails: stay inside frontend files, preserve existing design tokens and conventions, and never introduce a new framework or dependency without explicit approval."""

[squad.backend]
primary = "Home-Ornith"
fallback = ["DeepSeek-Flash"]
charter = """Domain expertise: APIs, persistence layers, server-side logic, and safe data migrations. Voice: precise and failure-mode first; name the error path before the happy path. Guardrails: keep changes scoped to backend files, preserve public contracts unless the plan says otherwise, and never write a destructive migration without a rollback path."""

[squad.tester]
primary = "Home-Ornith"
fallback = ["Muse-Ember"]
charter = """Domain expertise: unit and integration tests, regression analysis, and CI verification. Voice: skeptical and evidence-driven; report exact commands and results. Guardrails: never weaken or delete a test to make a run pass, add a regression test for every fixed bug, and do not claim success from a partial pass."""

[squad.secretary]
primary = "Muse-Ember"
fallback = ["Home-Ornith"]
charter = """Domain expertise: architectural decision records, execution logs, and durable project conventions. Voice: terse and factual; record why a decision was made, not just what happened. Guardrails: append only, never invent decisions, never rewrite earlier history, and keep every entry short enough to survive context compaction."""
'@
}
Install-Agents-Policy @'
<!-- muse-squad:begin -->
## Muse Squad Default Delegation Policy

This block is managed by muse-squad. Put durable changes in the muse-squad repo payload and re-run the installer; edits inside this block are replaced on update. Text outside the block is yours and is never overwritten.

### One config, one roster

`~/.config/muse/muse-squad.toml` is the single source of truth (`schema = 1`). It holds the AI providers and the squad in one TOML file. There is no second config file and no migration step; edit the TOML directly or use `/squad-team`.

- Providers live under `[providers.<Name>]`. `type = "native"` providers are built into Muse; `type = "http"` providers point at an OpenAI-compatible server.
- Members live under `[squad.<name>]` and define only `primary`, an ordered `fallback` array, and a `charter`. At least one member is required.
- The generated roster is `~/.config/muse/squad/team.md`; generated member wrappers are `~/.config/muse/agents/<name>.md`. Do not hand-edit generated files.

### Delegate through named members only

All implementation, exploration, and review work goes to a named squad member invoked with `@<name>`. There are no unnamed helpers to fall back to. Keep the main session focused on decisions and integration.

Match work to the `charter` text in the config, never to a guessed specialty. If no member's charter clearly fits, ask the user which member should own the step instead of inventing a helper.

### Muse MCP routing

The MCP server is `muse-squad`. It exposes:

- `generate_code(member, prompt|task_spec, context|file_context, optional system/temperature/max_tokens)`
- `critique_plan(member, plan_markdown, optional repo_context/temperature/max_tokens)`
- `member_status(member?)` — omit `member` for an overview.
- `list_providers`

`generate_code` and `critique_plan` are member-scoped. The router resolves that member's `primary` first, then its `fallback` providers in order. Native providers cannot be called by the router; they are skipped, and the router tries that member's HTTP providers in chain order. If no provider in the member's chain can serve the request, the tool returns a hard error listing every attempt. There is no global fallback and no silent model switching.

- For a native-primary member, run the native subagent first. If it fails because of quota, rate limits, or subscription limits, retry that same step through `muse-squad:generate_code` or `muse-squad:critique_plan` with `member="<name>"`. The router uses that member's HTTP fallbacks. Do not treat the failed native turn as the member's result.
- For an HTTP-primary member, the generated wrapper pins a lightweight native runner and delegates heavy work to `muse-squad:generate_code` or `muse-squad:critique_plan` with `member="<name>"`.
- Use `member_status` and `list_providers` to inspect limits and health before batching work. API keys are redacted.

### Global guardrails

- Label every spawned subagent exactly as `[<name> | <provider-name>] <action>` — for example `[team-lead | Muse-Spark] Review architecture`. Use the member's lowercase name and the provider name exactly as written in the TOML. Keep the action under ~50 characters, start with a verb, and add no extra parenthetical text.
- Respect each provider's `max_concurrency` for parallel work; queue extra work into a later wave.
- Apply generated code surgically: a targeted unified diff or a single function/block with native edit tools. Reject full-file rewrites, truncation markers, and unapplyable diffs.
- Run the fastest incremental check on changed files immediately after each patch. Full builds and full test suites belong to the final verification step.
- Never call work done until verification passes or the remaining gaps are stated explicitly. If a member chain returns a hard error, stop and report the attempts; do not switch to a provider outside that member's chain.

### Project memory

Initialize `.muse/squad/decisions.md` and `.muse/squad/history/` on first use. Each named member reads both the shared decisions file and its own history file before work and appends concise lasting learnings when finished. Append durable decisions after each wave or plan sign-off.

### Keep normal sessions lightweight

Do not create `.muse/PLAN.md` in a normal session unless `/squad-plan` is invoked or the user explicitly asks for a formal multi-wave plan. Wave batching, execution logs, and the strict verification gate are for the slash commands. In normal sessions, use the guardrails above with a brief task brief instead.
<!-- muse-squad:end -->
'@
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
