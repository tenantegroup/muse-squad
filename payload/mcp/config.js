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
  'type', 'enabled', 'base_url', 'api_key', 'model', 'temperature', 'top_p',
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

function disabledApiKeyPaths(parsed) {
  const providers = parsed.providers && typeof parsed.providers === 'object' &&
    !Array.isArray(parsed.providers) ? parsed.providers : {};
  return new Set(
    Object.entries(providers)
      .filter(([, provider]) => provider && provider.enabled === false)
      .map(([name]) => `providers.${name}.api_key`)
  );
}

function expandEnv(value, file, keyPath, disabledKeys = new Set()) {
  if (Array.isArray(value)) {
    return value.map((item) => expandEnv(item, file, keyPath, disabledKeys));
  }
  if (value && typeof value === 'object') {
    const copy = {};
    for (const [key, item] of Object.entries(value)) {
      copy[key] = expandEnv(item, file, keyPath ? `${keyPath}.${key}` : key, disabledKeys);
    }
    return copy;
  }
  if (typeof value !== 'string') return value;
  const key = String(keyPath || '').split('.').pop();
  if (key !== 'api_key' || !value.includes('${')) return value;
  if (disabledKeys.has(keyPath)) return '';
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
  if (raw.enabled !== undefined && typeof raw.enabled !== 'boolean') {
    throw new Error(`${label}.enabled must be a boolean`);
  }
  const enabled = raw.enabled === undefined ? true : raw.enabled;
  if (!enabled) {
    return {
      name,
      type,
      enabled: false,
      model: typeof raw.model === 'string' ? raw.model : '',
      extra_body: {},
      api_key: '',
      max_concurrency: 1,
      timeout_ms: 600000,
      queue_timeout_ms: 300000,
      max_retries: 2
    };
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
    enabled,
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
  return validateConfig(expandEnv(parsed, file, '', disabledApiKeyPaths(parsed)), file);
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
