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
