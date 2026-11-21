#!/usr/bin/env node
'use strict';

// Lightweight, read-only diagnostics for a muse-squad installation.
// Zero npm dependencies; uses Node 18+ global fetch.

const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  GENERATED_MARKER,
  endpointAliases,
  buildRoster,
  buildWrapper,
  expandHome
} = require('./sync-team.js');

const DEFAULT_TIMEOUT_MS = 5000;
const USAGE = [
  'Usage: node doctor.js [options]',
  '',
  'Options:',
  '  --config-dir PATH   Muse config directory (default: ~/.config/muse)',
  '  --dir PATH          Alias for --config-dir',
  '  --timeout-ms N      Per-endpoint HTTP timeout (default: 5000)',
  '  --json              Emit a JSON report',
  '  --help, -h          Show this help',
  '',
  'Environment: MUSE_CONFIG_DIR, MODELS_CONFIG_FILE'
].join('\n');

function parseArgs(argv) {
  const opts = { timeout_ms: DEFAULT_TIMEOUT_MS, json: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') {
      opts.help = true;
    } else if (arg === '--json') {
      opts.json = true;
    } else if (arg === '--config-dir' || arg === '--dir' || arg === '--timeout-ms') {
      const value = argv[++i];
      if (!value) throw new Error(`${arg} requires a value`);
      if (arg === '--timeout-ms') {
        const timeout = Number(value);
        if (!Number.isInteger(timeout) || timeout <= 0) {
          throw new Error('--timeout-ms must be a positive integer');
        }
        opts.timeout_ms = timeout;
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

function checkSettings(configDir) {
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
    ? servers['custom-coder']
    : null;
  if (!entry || typeof entry !== 'object') {
    return {
      name: 'settings.json', status: 'MISSING', ok: false,
      detail: 'custom-coder is not registered under mcpServers'
    };
  }

  const bridge = path.join(configDir, 'mcp', 'bridge.js');
  const args = Array.isArray(entry.args) ? entry.args : [];
  const foundBridge = args.find((arg) => path.resolve(String(arg)) === path.resolve(bridge));
  const commandName = path.basename(String(entry.command || '')).toLowerCase();
  const commandOk = commandName === 'node' || commandName === 'node.exe';
  const expectedConfig = path.join(configDir, 'endpoints.json');
  const configuredEnv = entry.env && entry.env.MODELS_CONFIG_FILE;
  const configOk = !configuredEnv ||
    path.resolve(expandHome(configuredEnv)) === path.resolve(expectedConfig);
  const ok = Boolean(foundBridge && commandOk && configOk);
  const bits = [
    `command=${entry.command || '(none)'}`,
    `bridge=${foundBridge || '(missing)'}`
  ];
  if (!configOk) bits.push(`config=${configuredEnv}`);
  return { name: 'settings.json', status: ok ? 'OK' : 'BAD', ok, detail: bits.join(' ') };
}

function modelsUrl(baseUrl) {
  const trimmed = String(baseUrl).trim().replace(/\/+$/, '');
  if (/\/models$/i.test(trimmed)) return trimmed;
  if (/\/v1$/i.test(trimmed)) return `${trimmed}/models`;
  return `${trimmed}/v1/models`;
}

async function checkEndpoints(configFile, timeoutMs, secrets) {
  const loaded = loadJson(configFile);
  if (loaded.error) {
    return [{
      alias: 'endpoints.json', status: 'MISSING', ok: false,
      detail: loaded.error === 'file not found'
        ? `${configFile} not found`
        : `cannot parse ${configFile}: ${loaded.error}`
    }];
  }
  const endpoints = loaded.data && loaded.data.endpoints;
  if (!endpoints || typeof endpoints !== 'object' || Array.isArray(endpoints) ||
      Object.keys(endpoints).length === 0) {
    return [{ alias: 'endpoints.json', status: 'EMPTY', ok: false, detail: 'no endpoints configured' }];
  }

  for (const endpoint of Object.values(endpoints)) {
    if (endpoint && typeof endpoint === 'object' && endpoint.api_key) {
      secrets.add(String(endpoint.api_key));
    }
  }

  const results = [];
  for (const [alias, endpoint] of Object.entries(endpoints)) {
    if (!endpoint || typeof endpoint !== 'object' || !endpoint.base_url) {
      results.push({ alias, status: 'BAD', ok: false, detail: 'missing base_url' });
      continue;
    }
    const url = modelsUrl(endpoint.base_url);
    const headers = {};
    if (endpoint.api_key) headers.Authorization = `Bearer ${endpoint.api_key}`;
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
        alias, status, ok: response.ok,
        detail: redact(`${url} ${response.status}${hint}`, secrets)
      });
    } catch (error) {
      const timedOut = error && error.name === 'AbortError';
      results.push({
        alias,
        status: timedOut ? 'TIMEOUT' : 'DOWN',
        ok: false,
        detail: `${url} ${redact(error && error.message || error, secrets)}`
      });
    } finally {
      clearTimeout(timer);
    }
  }
  return results;
}

function checkRoster(configDir, endpointsFile) {
  const teamFile = path.join(configDir, 'squad-team.json');
  const loaded = loadJson(teamFile);
  if (loaded.error) {
    return {
      name: 'squad-team.json', status: 'MISSING', ok: false,
      detail: loaded.error === 'file not found'
        ? `${teamFile} not found`
        : `cannot parse ${teamFile}: ${loaded.error}`
    };
  }
  const team = loaded.data;
  if (!team || !Array.isArray(team.members) || team.members.length === 0) {
    return {
      name: 'squad-team.json', status: 'BAD', ok: false,
      detail: 'squad-team.json has no members'
    };
  }
  const endpointData = loadJson(endpointsFile).data || null;
  const aliases = endpointAliases(endpointData);
  const issues = [];
  const expectedNames = new Set();

  for (const member of team.members) {
    const name = member && member.name;
    if (typeof name !== 'string' || !name) {
      issues.push('member without a name');
      continue;
    }
    expectedNames.add(name);
    try {
      const wrapper = path.join(configDir, 'agents', `${name}.md`);
      if (!fs.existsSync(wrapper)) {
        issues.push(`@${name} wrapper missing`);
        continue;
      }
      const expected = buildWrapper(member, team, aliases);
      const actual = fs.readFileSync(wrapper, 'utf8');
      if (normalized(actual) !== normalized(expected)) {
        issues.push(`@${name} wrapper out of sync`);
      }
    } catch (error) {
      issues.push(`@${name} cannot verify: ${error.message}`);
    }
  }

  const roster = path.join(configDir, 'squad', 'team.md');
  try {
    if (!fs.existsSync(roster)) {
      issues.push('squad/team.md missing');
    } else {
      const expected = buildRoster(team, team.members, aliases, teamFile);
      if (normalized(fs.readFileSync(roster, 'utf8')) !== normalized(expected)) {
        issues.push('squad/team.md out of sync');
      }
    }
  } catch (error) {
    issues.push(`squad/team.md cannot verify: ${error.message}`);
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

  const ok = issues.length === 0;
  return {
    name: 'squad-team.json',
    status: ok ? 'OK' : 'BAD',
    ok,
    detail: ok
      ? `${team.members.length} members, wrappers and roster in sync`
      : issues.join('; ')
  };
}

function renderText(report) {
  const pad = (value, size) => String(value).padEnd(size);
  const lines = ['squad-doctor', ''];
  lines.push(`  ${pad(report.checks.settings.name, 16)} ${pad(report.checks.settings.status, 7)} ${report.checks.settings.detail}`);
  lines.push('  endpoints');
  for (const endpoint of report.checks.endpoints) {
    lines.push(`    ${pad(endpoint.alias, 16)} ${pad(endpoint.status, 7)} ${endpoint.detail}`);
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

  const configDir = expandHome(opts.config_dir || process.env.MUSE_CONFIG_DIR ||
    path.join(os.homedir(), '.config', 'muse'));
  const endpointsFile = expandHome(process.env.MODELS_CONFIG_FILE ||
    path.join(configDir, 'endpoints.json'));
  const secrets = new Set();

  const settings = checkSettings(configDir);
  const endpoints = await checkEndpoints(endpointsFile, opts.timeout_ms, secrets);
  const roster = checkRoster(configDir, endpointsFile);
  const checks = { settings, endpoints, roster };
  const problems = [settings, ...endpoints, roster].filter((check) => !check.ok).length;
  const report = { ok: problems === 0, problems, checks };

  process.stdout.write(opts.json ? `${JSON.stringify(report, null, 2)}\n` : renderText(report));
  if (!report.ok) process.exitCode = 1;
}

main().catch((error) => {
  process.stderr.write(`doctor.js: ${error.message}\n`);
  process.exitCode = 2;
});
