#requires -Version 5.1
# muse-squad installer - GENERATED FILE, DO NOT EDIT BY HAND.
# Source of truth: payload/ + scripts/generate-installers.sh

$ErrorActionPreference = 'Stop'

$Version = '0.1.0'
$configDir = if ($env:MUSE_CONFIG_DIR) { $env:MUSE_CONFIG_DIR } else { Join-Path $HOME '.config/muse' }
$mode = 'install'
$help = $false
$skipMcp = $false
if ($null -eq $args) { $args = @() }

for ($i = 0; $i -lt $args.Count; $i++) {
  switch -CaseSensitive ($args[$i]) {
    '--uninstall' { $mode = 'uninstall' }
    '--no-mcp' { $skipMcp = $true }
    '--dir' {
      if (($i + 1) -ge $args.Count) { throw '--dir requires a value' }
      $configDir = $args[++$i]
    }
    '-h' { $help = $true }
    '--help' { $help = $true }
    default { throw "Unknown option: $($args[$i])" }
  }
}

if ($help) {
  @'
muse-squad installer

Usage:
  irm <url>/v1/install.ps1 | iex
  powershell -File install.ps1 [--dir PATH] [--uninstall] [--no-mcp]

Options:
  --dir PATH       Install into PATH instead of ~/.config/muse
  --uninstall      Remove managed files and unregister custom-coder
  --no-mcp         Skip custom-coder MCP registration
  --help, -h       Show this help

Environment:
  MUSE_CONFIG_DIR     Equivalent to --dir (useful with irm | iex)
  MUSE_SQUAD_SKIP_MCP Set to 1 to skip MCP registration

Endpoints are configured in endpoints.json inside the config directory.

Note: Windows PowerShell 5.1 has no `irm` alias. Use:
  Invoke-RestMethod '<url>/v1/install.ps1' | iex
'@ | Write-Host
  return
}

function Get-Dest([string]$rel) {
  $parts = $rel -replace '/', [IO.Path]::DirectorySeparatorChar
  return [IO.Path]::GetFullPath((Join-Path $configDir $parts))
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

if ($mode -eq 'uninstall') {
  Register-Mcp 'unregister'
  Uninstall-File 'agents/plan-reviewer.md'
  Uninstall-File 'agents/general-purpose.md'
  Uninstall-File 'agents/worker.md'
  Uninstall-File 'skills/squad-plan/SKILL.md'
  Uninstall-File 'skills/squad-execute/SKILL.md'
  Uninstall-File 'mcp/bridge.js'
  Uninstall-File 'mcp/register-settings.js'
  if (Test-Path -LiteralPath (Get-Dest 'endpoints.json')) {
    Write-Host "  kept       endpoints.json (remove manually if desired)"
  }
  Write-Host 'done.'
  return
}

Install-File 'agents/plan-reviewer.md' @'
---
name: plan-reviewer
description: Stress-tests technical plans for edge cases, missing files, and architectural flaws. Read-only.
model: muse-spark-1.3-contributor
effort: high
disallowedTools: ["Edit", "Write", "Bash"]
---
Review the proposed plan in `.muse/PLAN.md`. Identify gaps, ambiguous requirements, race conditions, or missing verification steps. Do not modify code.
'@
Install-File 'agents/general-purpose.md' @'
---
name: general-purpose
description: Executes a single bounded implementation task from a written plan, with fast per-file diagnostics. Overrides the built-in general-purpose agent with the cheap local model.
model: local-llama/Ornith-1.5-35B-A3B-MLX-4bit
effort: medium
---
Complete the assigned step from `.muse/PLAN.md`. Only touch files listed in your brief, run the specified tests, and return a concise summary of changes.

## Patch Discipline

Apply `custom-coder:generate_code` output only as a targeted unified diff or single function/block using native `Edit` tools — never overwrite an entire file from local-model output. Reject full-file rewrites, truncation markers, and unapplyable diffs; re-prompt for a scoped diff instead.

## Instant Diagnostics

Immediately after applying code from `custom-coder:generate_code` — and before returning your summary — run the fastest available single-file or incremental check on the files you changed:

- Use any LSP diagnostics the harness exposes for the changed files.
- TypeScript/JavaScript: `npx tsc --noEmit` (or the project's incremental typecheck).
- Python: `ruff check <changed-files>` (or `python -m py_compile <changed-files>`).
- Rust: `cargo check` (incremental).
- Structural checks: `sg` / `ast-grep` if installed, for example to confirm a broken import or call pattern is gone.

Prefer checks scoped to the changed files. Do not install new tools or run full builds here — full verification belongs to the `/squad-execute` verification gate. If no fast checker is available, say so explicitly in your summary.

## Shared MCP Queue

Other workers may call `custom-coder` tools at the same time. The router queues those calls FIFO and serializes them per endpoint's `max_concurrency`, so just make your call and wait — do not add your own locks or retry loops, and do not switch endpoints to dodge a queue. If a call reports a queue timeout, return that in your summary and let the orchestrator re-batch the wave.
'@
Install-File 'agents/worker.md' @'
---
name: worker
description: Executes a single bounded implementation task from a written plan, with fast per-file diagnostics.
model: local-llama/Ornith-1.5-35B-A3B-MLX-4bit
effort: medium
---
Complete the assigned step from `.muse/PLAN.md`. Only touch files listed in your brief, run the specified tests, and return a concise summary of changes.

## Patch Discipline

Apply `custom-coder:generate_code` output only as a targeted unified diff or single function/block using native `Edit` tools — never overwrite an entire file from local-model output. Reject full-file rewrites, truncation markers, and unapplyable diffs; re-prompt for a scoped diff instead.

## Instant Diagnostics

Immediately after applying code from `custom-coder:generate_code` — and before returning your summary — run the fastest available single-file or incremental check on the files you changed:

- Use any LSP diagnostics the harness exposes for the changed files.
- TypeScript/JavaScript: `npx tsc --noEmit` (or the project's incremental typecheck).
- Python: `ruff check <changed-files>` (or `python -m py_compile <changed-files>`).
- Rust: `cargo check` (incremental).
- Structural checks: `sg` / `ast-grep` if installed, for example to confirm a broken import or call pattern is gone.

Prefer checks scoped to the changed files. Do not install new tools or run full builds here — full verification belongs to the `/squad-execute` verification gate. If no fast checker is available, say so explicitly in your summary.

## Shared MCP Queue

Other workers may call `custom-coder` tools at the same time. The router queues those calls FIFO and serializes them per endpoint's `max_concurrency`, so just make your call and wait — do not add your own locks or retry loops, and do not switch endpoints to dodge a queue. If a call reports a queue timeout, return that in your summary and let the orchestrator re-batch the wave.
'@
Install-File 'skills/squad-plan/SKILL.md' @'
---
name: squad-plan
description: Multi-agent explore-first planning mode that writes a decision-complete plan before coding.
---
You are in SQUAD-PLAN mode. Do NOT edit product code yet.

## Concurrency Budget (read first)

Before spawning anything, read `~/.config/muse/endpoints.json` (or call `custom-coder:list_endpoints`) and note the `muse_models` limits and each endpoint's `max_concurrency`. The orchestrator must never spawn more simultaneous native subagents of a given model than that model's `muse_models` limit — for example at most 4 `muse-ember-1.0` or 2 `muse-spark-1.3` subagents at once. Batch any larger exploration into successive waves. Parallel workers may safely call `custom-coder` MCP tools at the same time: the router queues requests FIFO and serializes them per endpoint's `max_concurrency`.

1. Spawn parallel read-only subagents (`explore` / `general-purpose`) to map the relevant files, dependencies, and existing patterns.
2. Ask the user clarifying questions ONLY if an architectural fork cannot be resolved from the codebase.
3. Draft a decision-complete implementation plan in `.muse/PLAN.md` with exact file paths, dependency order, and verification commands. If the file already has a `## Execution Log & Decisions` section, preserve it verbatim at the bottom — it is the durable handoff record from any prior execution session; do not overwrite it unless the user explicitly asks to reset the plan.
4. Dual-Brain Plan Grill:
   1. Spawn our native `plan-reviewer` subagent (read-only) to audit `.muse/PLAN.md` against the actual files in the repository.
   2. Simultaneously call the `custom-coder:critique_plan` MCP tool with `endpoint: "grill-reviewer"` so your self-hosted model performs an independent adversarial review.
   3. Synthesize both critiques, resolve any valid issues in `.muse/PLAN.md`, and present a summary of what was caught before asking the user for `/squad-execute` sign-off.
'@
Install-File 'skills/squad-execute/SKILL.md' @'
---
name: squad-execute
description: Executes the approved `.muse/PLAN.md` using parallel subagents in isolated worktrees, with a verification gate that blocks premature completion.
---
Read `.muse/PLAN.md`, including any existing `## Execution Log & Decisions` section — that section is the durable handoff record when resuming a long or interrupted session. Group independent tasks into parallel waves and delegate each bounded task to `worker` subagents using isolated Git worktrees (`--subagent-worktree-isolation` behavior).

Use the `custom-coder` MCP tool (`generate_code`) with `endpoint: "local-coder"` for heavy code generation: pass a bounded prompt plus the relevant file context, then apply and verify the returned diff locally.

## Concurrency Budget (read first)

At the start of execution, read `~/.config/muse/endpoints.json` (or call `custom-coder:list_endpoints`) and note the `muse_models` native-model limits and each endpoint's `max_concurrency`. Batch each wave so no model ever exceeds its `muse_models` limit simultaneously — e.g. at most 4 concurrent `muse-ember-1.0` workers or 2 `muse-spark-1.3` workers. If more tasks are ready, hold them for the next wave; never exceed the budget.

Multiple parallel workers may safely call `custom-coder` MCP tools concurrently: `bridge.js` queues requests FIFO and serializes them per endpoint's `max_concurrency` (local endpoints default to `1` to avoid GPU/RAM OOM). A queued call waits for a slot rather than failing over; fallback only happens after retries fail or the queue wait exceeds `queue_timeout_ms`. Do not implement separate locking in the workers.

## Patch Discipline (Diffs, Not Full Rewrites)

- Ask `generate_code` for a targeted unified diff (`git apply` format) for existing files. A single targeted function or block with its path and line range is acceptable when a diff is impractical; a full-file rewrite is not.
- The orchestrator — `muse-ember-1.0`, or any model with native `Edit` tools — applies each hunk surgically with `Edit`, preserving the rest of the file. Do not overwrite whole files with local-model output.
- Reject and re-prompt if the model returns a full file, truncated content, `...`/placeholders, or an unapplyable diff. Never "repair" omitted code by guessing.
- Run Instant Diagnostics and then the Verification Gate after applying patches.

## Verification Gate (Do Not Stop Until Verified)

You are not done and must not return control to the user while any `.muse/TODO.md` item is unchecked or while any verification command fails.

After every wave — before advancing to the next wave and before reporting completion:

1. Update `.muse/TODO.md` (create it from the plan if it does not exist). Check off only items whose changes are applied and verified; leave or add `- [ ]` items for remaining or newly discovered work. Record the exact verification commands and their results in the checklist.
2. Run every verification command listed in `.muse/PLAN.md` from the repository root — for example `npm test`, `cargo check`, `pytest`, or `go test ./...`. If the plan lists none, detect the project's typechecker and test commands from its manifests, add them to `.muse/TODO.md`, and run them.
3. If any command fails, fix the failure in another bounded wave (delegating to a `worker` where appropriate) and repeat this gate. Never mark an item done or claim success based on a partial pass.
4. Append a short entry to the `## Execution Log & Decisions` section at the bottom of `.muse/PLAN.md` (create the section if absent). Record the wave number, what landed, architectural decisions and *why*, gotchas discovered, exact verification commands/results, and any remaining work or blockers. Append only — never rewrite or delete earlier entries — so the on-disk record survives compaction and session restarts.
5. Only when all TODO items are checked and all verification commands pass, summarize what was verified and return control to the user.

## Session Handoff Notes

The `## Execution Log & Decisions` section in `.muse/PLAN.md` is authoritative state, not chat history. Keep entries short (a few bullets per wave) and append-only:

```markdown
## Execution Log & Decisions

### Wave 2 — 2026-11-20
- Landed: retry/backoff in mcp/bridge.js; endpoints seed config updated.
- Decision: 4xx is non-retryable — an invalid key must fail fast, not burn fallback attempts. Reason: silent auth failures wasted a wave earlier.
- Gotcha: fallback notice must stay in MCP `meta`, not tool text, or `git apply` breaks.
- Verified: `scripts/test-install.sh` PASS; `node --check mcp/bridge.js` PASS.
- Remaining: PowerShell installer still untested locally (no pwsh).
```

On resume, read this section first and continue from the last entry instead of re-deriving decisions from scratch. If a later wave reverses a decision, append a new entry saying so with the reason — do not edit history.
'@
Install-File 'mcp/bridge.js' @'
#!/usr/bin/env node
'use strict';

// MCP stdio server that routes code generation and plan critiques across
// named self-hosted OpenAI-compatible endpoints. Zero npm dependencies.
// Requires Node 18+ (uses global fetch and AbortController).
// The config file is re-read on every tool call, so edits apply immediately.

const fs = require('fs');
const os = require('os');
const path = require('path');

const SERVER_NAME = 'muse-squad-custom-coder';
const SERVER_VERSION = '0.1.0';
const CONFIG_FILE = (process.env.MODELS_CONFIG_FILE || '~/.config/muse/endpoints.json')
  .replace(/^~(?=$|[\\/])/, os.homedir());
const ENV_TIMEOUT = Number.parseInt(process.env.MUSE_CODER_TIMEOUT_MS || '', 10);
const DEFAULT_TIMEOUT_MS = Number.isFinite(ENV_TIMEOUT) && ENV_TIMEOUT > 0 ? ENV_TIMEOUT : 600000;
const DEFAULT_MAX_RETRIES = 2;
const DEFAULT_QUEUE_TIMEOUT_MS = 300000;
const DEFAULT_MAX_CONCURRENCY = 1;

// Per-endpoint queue state survives config reloads so in-flight slot counts
// are never reset while a request is still talking to an endpoint.
const endpointQueues = new Map();

const DEFAULT_SYSTEM = [
  'You are a coding worker in a multi-agent software team.',
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

const ENDPOINT_PARAM = {
  type: 'string',
  description: 'Named endpoint alias from endpoints.json. Omit to use the configured default.'
};

const TOOLS = [
  {
    name: 'generate_code',
    description: 'Generate a targeted unified diff (or single function/block) with automatic retry and fallback. Never returns full-file rewrites.',
    inputSchema: {
      type: 'object',
      properties: {
        endpoint: ENDPOINT_PARAM,
        prompt: { type: 'string', description: 'Bounded implementation task to perform.' },
        task_spec: { type: 'string', description: 'Alias for prompt.' },
        context: { type: 'string', description: 'Relevant file contents or excerpts to work from.' },
        file_context: { type: 'string', description: 'Alias for context.' },
        system: { type: 'string', description: 'Optional override for the worker system prompt.' },
        temperature: { type: 'number', description: 'Optional sampling temperature override.' },
        max_tokens: { type: 'integer', description: 'Optional maximum tokens to generate.' }
      },
      anyOf: [{ required: ['prompt'] }, { required: ['task_spec'] }],
      additionalProperties: false
    }
  },
  {
    name: 'critique_plan',
    description: 'Independently audit a plan for missing edge cases, security flaws, and broken assumptions, with retry and fallback.',
    inputSchema: {
      type: 'object',
      properties: {
        endpoint: ENDPOINT_PARAM,
        plan_markdown: { type: 'string', description: 'Full markdown of .muse/PLAN.md to audit.' },
        repo_context: { type: 'string', description: 'Relevant repository files and structure the plan relies on.' },
        temperature: { type: 'number', description: 'Optional sampling temperature override.' },
        max_tokens: { type: 'integer', description: 'Optional maximum tokens to generate.' }
      },
      required: ['plan_markdown'],
      additionalProperties: false
    }
  },
  {
    name: 'coder_status',
    description: 'List configured endpoint aliases, default, fallback order, retry/queue limits, and live queue state. Keys are redacted.',
    inputSchema: {
      type: 'object',
      properties: { endpoint: ENDPOINT_PARAM },
      additionalProperties: false
    }
  },
  {
    name: 'list_endpoints',
    description: 'Report every endpoint alias with its model and max_concurrency, plus the muse_models native-subagent limits and queue settings.',
    inputSchema: {
      type: 'object',
      properties: {},
      additionalProperties: false
    }
  }
];

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

function loadConfig() {
  let raw;
  try {
    raw = fs.readFileSync(CONFIG_FILE, 'utf8');
  } catch (error) {
    throw new Error(`cannot read endpoint config ${CONFIG_FILE}: ${error.message}`);
  }

  let config;
  try {
    config = JSON.parse(raw);
  } catch (error) {
    throw new Error(`invalid JSON in ${CONFIG_FILE}: ${error.message}`);
  }
  if (!config || typeof config !== 'object' || Array.isArray(config)) {
    throw new Error(`${CONFIG_FILE}: top-level JSON value must be an object`);
  }

  const endpoints = config.endpoints;
  if (!endpoints || typeof endpoints !== 'object' || Array.isArray(endpoints)) {
    throw new Error(`${CONFIG_FILE}: "endpoints" must be an object`);
  }
  const names = Object.keys(endpoints);
  if (names.length === 0) throw new Error(`${CONFIG_FILE}: "endpoints" must not be empty`);

  for (const name of names) {
    const endpoint = endpoints[name];
    if (!endpoint || typeof endpoint !== 'object' || Array.isArray(endpoint)) {
      throw new Error(`${CONFIG_FILE}: endpoint "${name}" must be an object`);
    }
    if (typeof endpoint.base_url !== 'string' || !endpoint.base_url.trim()) {
      throw new Error(`${CONFIG_FILE}: endpoint "${name}" needs a non-empty "base_url"`);
    }
    if (typeof endpoint.api_key !== 'string') {
      throw new Error(`${CONFIG_FILE}: endpoint "${name}" needs "api_key"`);
    }
    if (typeof endpoint.model !== 'string' || !endpoint.model.trim()) {
      throw new Error(`${CONFIG_FILE}: endpoint "${name}" needs a non-empty "model"`);
    }
    if (endpoint.temperature !== undefined && typeof endpoint.temperature !== 'number') {
      throw new Error(`${CONFIG_FILE}: endpoint "${name}" temperature must be a number`);
    }
    const maxConcurrency = endpoint.max_concurrency === undefined
      ? DEFAULT_MAX_CONCURRENCY
      : endpoint.max_concurrency;
    if (!Number.isInteger(maxConcurrency) || maxConcurrency < 1) {
      throw new Error(`${CONFIG_FILE}: endpoint "${name}" max_concurrency must be a positive integer`);
    }
    endpoint.max_concurrency = maxConcurrency; // normalize default for callers
  }

  // Accept both our "default" and the example's "default_endpoint".
  const defaultName = typeof config.default === 'string' && config.default
    ? config.default
    : (typeof config.default_endpoint === 'string' && config.default_endpoint
      ? config.default_endpoint
      : names[0]);
  if (!Object.prototype.hasOwnProperty.call(endpoints, defaultName)) {
    throw new Error(`${CONFIG_FILE}: default endpoint "${defaultName}" is not defined`);
  }

  let fallbackOrder = config.fallback_order === undefined ? names : config.fallback_order;
  if (!Array.isArray(fallbackOrder) || fallbackOrder.some((name) => typeof name !== 'string')) {
    throw new Error(`${CONFIG_FILE}: "fallback_order" must be an array of strings`);
  }

  const timeoutMs = config.timeout_ms === undefined
    ? DEFAULT_TIMEOUT_MS
    : config.timeout_ms;
  if (typeof timeoutMs !== 'number' || !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    throw new Error(`${CONFIG_FILE}: "timeout_ms" must be a positive number`);
  }

  const maxRetries = config.max_retries === undefined ? DEFAULT_MAX_RETRIES : config.max_retries;
  if (!Number.isInteger(maxRetries) || maxRetries < 0) {
    throw new Error(`${CONFIG_FILE}: "max_retries" must be a non-negative integer`);
  }

  const queueTimeoutMs = config.queue_timeout_ms === undefined
    ? DEFAULT_QUEUE_TIMEOUT_MS
    : config.queue_timeout_ms;
  if (typeof queueTimeoutMs !== 'number' || !Number.isFinite(queueTimeoutMs) || queueTimeoutMs <= 0) {
    throw new Error(`${CONFIG_FILE}: "queue_timeout_ms" must be a positive number`);
  }

  const museModels = config.muse_models === undefined ? {} : config.muse_models;
  if (!museModels || typeof museModels !== 'object' || Array.isArray(museModels)) {
    throw new Error(`${CONFIG_FILE}: "muse_models" must be an object`);
  }
  for (const [model, limit] of Object.entries(museModels)) {
    if (!Number.isInteger(limit) || limit < 0) {
      throw new Error(`${CONFIG_FILE}: muse_models["${model}"] must be a non-negative integer`);
    }
  }

  return { endpoints, defaultName, fallbackOrder, timeoutMs, maxRetries, queueTimeoutMs, museModels };
}

function requireEndpoint(config, requested) {
  const name = requested === undefined || requested === null || requested === ''
    ? config.defaultName
    : requested;
  if (typeof name !== 'string') throw new Error('"endpoint" must be a string');
  if (!Object.prototype.hasOwnProperty.call(config.endpoints, name)) {
    throw new Error(`unknown endpoint "${name}". Available: ${Object.keys(config.endpoints).join(', ')}`);
  }
  return name;
}

// --- Per-endpoint FIFO concurrency queues ---------------------------------

function grantWaiters(state) {
  while (state.waiters.length > 0 && state.active < state.limit) {
    const waiter = state.waiters.shift();
    state.active += 1;
    if (waiter.timer) clearTimeout(waiter.timer);
    waiter.grant();
  }
}

function queueState(name, limit) {
  let state = endpointQueues.get(name);
  if (!state) {
    state = { active: 0, limit, waiters: [] };
    endpointQueues.set(name, state);
  }
  if (state.limit !== limit) {
    // Hot reload: adopt the new limit without touching active slot counts.
    // A raised limit may immediately unblock queued callers.
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
      const error = new Error(
        `queue timeout waiting for endpoint "${name}" after ${queueTimeoutMs}ms`
      );
      error.queueTimeout = true;
      error.retryable = false; // do not retry the same endpoint; let fallback decide
      reject(error);
    }, queueTimeoutMs);
  });
}

function queueSnapshot(name) {
  const state = endpointQueues.get(name);
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

async function postChatOnce(endpoint, payload, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let target;
  try {
    target = new URL(`${endpoint.base_url.replace(/\/+$/, '')}/chat/completions`);
  } catch (error) {
    clearTimeout(timer);
    const invalid = new Error(`invalid base_url for "${endpoint.name}": ${error.message}`);
    invalid.retryable = false;
    throw invalid;
  }

  try {
    const response = await fetch(target.toString(), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${endpoint.api_key}`
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
    return content;
  } finally {
    clearTimeout(timer);
  }
}

async function chatWithRetries(endpoint, payload, config) {
  // One slot is held across the whole retry sequence for this endpoint, so a
  // queued caller keeps its FIFO position and a slow retry cannot hog slots.
  const release = await acquireSlot(
    endpoint.name,
    endpoint.max_concurrency,
    config.queueTimeoutMs
  );
  try {
    let lastError;
    for (let attempt = 0; attempt <= config.maxRetries; attempt++) {
      try {
        return await postChatOnce(endpoint, payload, config.timeoutMs);
      } catch (error) {
        lastError = error;
        if (attempt >= config.maxRetries || !isRetryable(error)) break;
        await sleep(1000 * 2 ** attempt);
      }
    }
    throw lastError;
  } finally {
    release(); // never leak a slot on failure, abort, or timeout
  }
}

async function queryWithFallback(primaryName, endpointConfig, payload, config) {
  const candidates = [];
  for (const name of [primaryName, ...config.fallbackOrder]) {
    if (name && !candidates.includes(name)) candidates.push(name);
  }

  const attempts = [];
  for (const name of candidates) {
    const endpoint = config.endpoints[name];
    if (!endpoint) {
      attempts.push({ endpoint: name, error: 'not found in config' });
      continue;
    }
    try {
      const text = await chatWithRetries({ ...endpoint, name }, payload, config);
      return {
        text,
        meta: {
          primary: primaryName,
          servedBy: name,
          fallbackUsed: name !== primaryName,
          attempts
        }
      };
    } catch (error) {
      attempts.push({ endpoint: name, model: endpoint.model, error: error.message });
    }
  }
  throw new Error(`All endpoints failed:\n- ${attempts.map((item) => `${item.endpoint}: ${item.error}`).join('\n- ')}`);
}

function buildPayload(parsed, systemPrompt, userPrompt, params) {
  const temperature = params.temperature === undefined
    ? parsed.temperature
    : params.temperature;
  return {
    model: parsed.model,
    messages: [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: userPrompt }
    ],
    stream: false,
    ...(temperature === undefined ? {} : { temperature }),
    ...(params.max_tokens === undefined ? {} : { max_tokens: params.max_tokens })
  };
}

async function callTool(name, args) {
  const params = args || {};
  const config = loadConfig();

  if (name === 'coder_status' || name === 'list_endpoints') {
    const selected = name === 'coder_status' ? requireEndpoint(config, params.endpoint) : null;
    const endpointInfo = (endpointName) => {
      const endpoint = config.endpoints[endpointName];
      return {
        name: endpointName,
        baseUrl: endpoint.base_url,
        model: endpoint.model,
        temperature: endpoint.temperature,
        maxConcurrency: endpoint.max_concurrency,
        max_concurrency: endpoint.max_concurrency,
        apiKeyConfigured: Boolean(endpoint.api_key),
        ...queueSnapshot(endpointName)
      };
    };
    const shared = {
      configFile: CONFIG_FILE,
      defaultEndpoint: config.defaultName,
      fallbackOrder: config.fallbackOrder,
      museModels: config.museModels,
      muse_models: config.museModels,
      maxRetries: config.maxRetries,
      timeoutMs: config.timeoutMs,
      queueTimeoutMs: config.queueTimeoutMs,
      queue_timeout_ms: config.queueTimeoutMs
    };
    const text = name === 'list_endpoints'
      ? JSON.stringify({
        ...shared,
        endpoints: Object.fromEntries(
          Object.keys(config.endpoints).map((endpointName) => [
            endpointName,
            endpointInfo(endpointName)
          ])
        )
      }, null, 2)
      : JSON.stringify({
        ...shared,
        availableEndpoints: Object.keys(config.endpoints),
        selected: endpointInfo(selected)
      }, null, 2);
    return { content: [{ type: 'text', text }] };
  }

  if (name === 'critique_plan') {
    if (typeof params.plan_markdown !== 'string' || params.plan_markdown.trim() === '') {
      throw new Error('critique_plan requires a non-empty "plan_markdown"');
    }
    const primary = requireEndpoint(config, params.endpoint);
    const user = [
      'PLAN MARKDOWN:',
      params.plan_markdown,
      '',
      'REPO CONTEXT:',
      typeof params.repo_context === 'string' && params.repo_context.trim()
        ? params.repo_context
        : '(none provided)'
    ].join('\n');
    const result = await queryWithFallback(
      primary,
      config.endpoints[primary],
      buildPayload(config.endpoints[primary], CRITIQUE_SYSTEM, user, params),
      config
    );
    return { content: [{ type: 'text', text: result.text }], meta: result.meta };
  }

  if (name === 'generate_code') {
    const prompt = typeof params.prompt === 'string' ? params.prompt : params.task_spec;
    if (typeof prompt !== 'string' || prompt.trim() === '') {
      throw new Error('generate_code requires a non-empty "prompt" (or "task_spec")');
    }
    const context = typeof params.context === 'string' ? params.context : params.file_context;
    const primary = requireEndpoint(config, params.endpoint);
    const system = typeof params.system === 'string' && params.system.trim() ? params.system : DEFAULT_SYSTEM;
    const user = typeof context === 'string' && context.trim()
      ? `TASK:\n${prompt}\n\nRELEVANT CONTEXT:\n${context}`
      : `TASK:\n${prompt}`;
    const result = await queryWithFallback(
      primary,
      config.endpoints[primary],
      buildPayload(config.endpoints[primary], system, user, params),
      config
    );
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
    if (line) {
      void handleLine(line);
    }
  }
});
process.stdin.on('end', () => process.exit(0));
process.on('uncaughtException', (error) => log(`uncaught: ${error.message}`));
'@
Install-File 'mcp/register-settings.js' @'
#!/usr/bin/env node
'use strict';

// Merges the custom-coder MCP entry into Muse Code's settings.json without
// disturbing any other settings or MCP servers.

const fs = require('fs');
const path = require('path');

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
  if (!settings.mcp_servers || typeof settings.mcp_servers !== 'object' || Array.isArray(settings.mcp_servers)) {
    settings.mcp_servers = {};
  }
  if (settings.schema_version === undefined) settings.schema_version = 1;

  if (unregister) {
    if (!Object.prototype.hasOwnProperty.call(settings.mcp_servers, 'custom-coder')) {
      console.log('  unchanged  custom-coder not registered');
      return;
    }
    delete settings.mcp_servers['custom-coder'];
  } else {
    if (!bridgePath || !configFile) {
      console.error('register-settings.js: --bridge and --config-file are required');
      process.exit(2);
    }
    settings.mcp_servers['custom-coder'] = {
      command: 'node',
      args: [bridgePath],
      env: {
        MODELS_CONFIG_FILE: configFile
      }
    };
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
  console.log(`  ${unregister ? 'unregistered' : 'registered'}  custom-coder in ${settingsPath}`);
}

try {
  main();
} catch (error) {
  console.error(`register-settings.js: ${error.message}`);
  process.exit(1);
}
'@
Install-Endpoints-Config @'
{
  "schema_version": 1,
  "default": "local-coder",
  "fallback_order": ["local-coder", "grill-reviewer"],
  "muse_models": {
    "muse-ember-1.0": 4,
    "muse-spark-1.3": 2
  },
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
      "base_url": "http://127.0.0.1:8000/v1",
      "api_key": "local-key",
      "model": "ornith-1.5-35b",
      "temperature": 0.3,
      "max_concurrency": 1
    }
  }
}
'@
Register-Mcp 'install'
Write-Host 'done.'
