#!/usr/bin/env node
'use strict';

// Verifies the zero-dependency TOML reader, validator, redaction, and CLI.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const CONFIG_JS = path.join(ROOT, 'payload', 'mcp', 'config.js');
const config = require(CONFIG_JS);

const SECRET = 'config-secret-do-not-leak';
const ENV_KEY = 'MUSE_SQUAD_TEST_API_KEY';

function assert(condition, message) {
  if (!condition) throw new Error(`assertion failed: ${message}`);
}

function expectThrows(fn, pattern, label) {
  let error = null;
  try {
    fn();
  } catch (caught) {
    error = caught;
  }
  assert(error, `${label} throws`);
  if (pattern) {
    assert(pattern.test(error.message), `${label} error matches ${pattern}: ${error.message}`);
  }
  return error;
}

function cleanEnv(extra = {}) {
  const env = { ...process.env };
  delete env.MUSE_CONFIG_DIR;
  delete env.MUSE_SQUAD_CONFIG_FILE;
  delete env[ENV_KEY];
  for (const [key, value] of Object.entries(extra)) {
    if (value === undefined) delete env[key];
    else env[key] = value;
  }
  return env;
}

function runCli(args, extraEnv = {}) {
  return spawnSync(process.execPath, [CONFIG_JS, ...args], {
    encoding: 'utf8',
    env: cleanEnv(extraEnv)
  });
}

function write(file, text) {
  fs.writeFileSync(file, text);
}

function validConfigText() {
  return [
    '# top-level comment',
    'schema = 1',
    '',
    '[providers.Local]',
    'type = "http"',
    'base_url = "http://127.0.0.1:1/v1"',
    `api_key = "\${${ENV_KEY}}" # inline comment`,
    "model = 'local-model'",
    'temperature = 0.25',
    'top_p = 0.9',
    'max_tokens = 512',
    'max_concurrency = 2',
    '',
    '[providers.Second]',
    'type = "native"',
    'model = "native-model"',
    '',
    '[providers.Third]',
    'type = "http"',
    'base_url = "http://127.0.0.1:2/v1"',
    'api_key = ""',
    'model = "third-model"',
    '',
    '[squad.alpha]',
    'primary = "Local"',
    'fallback = ["Second", "Third"]',
    'charter = """',
    'Lead work.',
    'Second line.',
    '"""',
    '',
    '[squad.beta]',
    'primary = "Second"',
    'charter = "Review work"',
    ''
  ].join('\n');
}

function minimalConfigText() {
  return [
    'schema = 1',
    '[providers.Basic]',
    'type = "http"',
    'base_url = "http://example.test/v1"',
    'model = "basic-model"',
    '[squad.basic]',
    'primary = "Basic"',
    'charter = "Basic charter"',
    ''
  ].join('\n');
}

async function main() {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-squad-config-'));
  const envSnapshot = {
    MUSE_CONFIG_DIR: process.env.MUSE_CONFIG_DIR,
    MUSE_SQUAD_CONFIG_FILE: process.env.MUSE_SQUAD_CONFIG_FILE,
    [ENV_KEY]: process.env[ENV_KEY]
  };

  function restoreProcessEnv() {
    for (const [key, value] of Object.entries(envSnapshot)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }

  try {
    // --- Public surface ---------------------------------------------------
    for (const name of [
      'SCHEMA', 'configPath', 'expandHome', 'loadConfig',
      'parseToml', 'redactConfig', 'validateConfig'
    ]) {
      assert(typeof config[name] !== 'undefined', `exports ${name}`);
    }
    assert(config.SCHEMA === 1, 'SCHEMA is 1');

    // --- Path discovery ---------------------------------------------------
    assert(config.expandHome('~/muse-squad.toml') === path.join(os.homedir(), 'muse-squad.toml'),
      'expandHome expands ~/ paths');
    assert(config.expandHome('~') === os.homedir(), 'expandHome expands bare ~');
    assert(config.expandHome('/tmp/muse-squad.toml') === '/tmp/muse-squad.toml',
      'expandHome leaves absolute paths alone');

    delete process.env.MUSE_CONFIG_DIR;
    delete process.env.MUSE_SQUAD_CONFIG_FILE;
    assert(config.configPath() === path.join(os.homedir(), '.config', 'muse', 'muse-squad.toml'),
      'default config path');
    process.env.MUSE_CONFIG_DIR = path.join(tempDir, 'env-config-dir');
    assert(config.configPath() === path.join(tempDir, 'env-config-dir', 'muse-squad.toml'),
      'MUSE_CONFIG_DIR discovery');
    process.env.MUSE_SQUAD_CONFIG_FILE = path.join(tempDir, 'env-file.toml');
    assert(config.configPath() === path.join(tempDir, 'env-file.toml'),
      'MUSE_SQUAD_CONFIG_FILE overrides the config dir');
    assert(config.configPath({
      config_dir: path.join(tempDir, 'opt-dir'),
      config_file: path.join(tempDir, 'opt-file.toml')
    }) === path.join(tempDir, 'opt-file.toml'), 'explicit options win over environment');

    // --- Parser subset ----------------------------------------------------
    const scalars = config.parseToml([
      '# comment',
      '[misc]',
      'int = 42',
      'negative = -3',
      'float = 1.25',
      'yes = true',
      'no = false',
      'withHash = "hash # inside" # trailing comment',
      'escaped = "line\\nbreak"',
      "literal = 'raw \\n text'",
      'items = [1, 2, 3]',
      'words = ["a", "b"]'
    ].join('\n'), 'scalars.toml');
    assert(scalars.misc.int === 42, 'integer parsing');
    assert(scalars.misc.negative === -3, 'negative integer parsing');
    assert(scalars.misc.float === 1.25, 'float parsing');
    assert(scalars.misc.yes === true && scalars.misc.no === false, 'boolean parsing');
    assert(scalars.misc.withHash === 'hash # inside', 'comments outside strings are ignored');
    assert(scalars.misc.escaped === 'line\nbreak', 'basic strings decode escapes');
    assert(scalars.misc.literal === 'raw \\n text', 'literal strings keep backslashes');
    assert(JSON.stringify(scalars.misc.items) === '[1,2,3]', 'numeric arrays');
    assert(JSON.stringify(scalars.misc.words) === '["a","b"]', 'string arrays');

    const doubleBlock = config.parseToml('charter = """\nfirst line\nsecond line\n"""\n', 'block.toml');
    assert(doubleBlock.charter === 'first line\nsecond line\n', 'double-quoted multi-line block');
    const singleBlock = config.parseToml("charter = '''\nalpha\nbeta\n'''\n", 'block.toml');
    assert(singleBlock.charter === 'alpha\nbeta\n', 'single-quoted multi-line block');

    // --- Loading, validation, defaults, redaction -------------------------
    const validFile = path.join(tempDir, 'valid.toml');
    write(validFile, validConfigText());
    process.env[ENV_KEY] = SECRET;

    const loaded = config.loadConfig({ config_file: validFile });
    assert(loaded.schema === config.SCHEMA, 'loaded schema');
    assert(loaded.file === validFile, 'loaded file is reported');
    assert(Object.keys(loaded.providers).join(',') === 'Local,Second,Third', 'provider order');
    assert(loaded.providers.Local.api_key === SECRET, 'api_key env expansion');
    assert(loaded.providers.Local.temperature === 0.25, 'provider temperature');
    assert(loaded.providers.Local.top_p === undefined, 'top_p moves into extra_body');
    assert(loaded.providers.Local.extra_body.top_p === 0.9, 'top_p is available in extra_body');
    assert(loaded.providers.Local.max_tokens === 512, 'provider max_tokens');
    assert(loaded.providers.Local.max_concurrency === 2, 'provider max_concurrency');
    assert(loaded.providers.Third.api_key === '', 'empty api_key is allowed');
    assert(loaded.providers.Second.type === 'native', 'native provider type');
    assert(loaded.providers.Local.enabled === true, 'enabled defaults to true');
    const disabledFile = path.join(tempDir, 'disabled.toml');
    delete process.env.MUSE_SQUAD_TEST_DISABLED_KEY;
    write(disabledFile, validConfigText().replace(
      '[providers.Second]\ntype = "native"',
      [
        '[providers.Second]',
        'enabled = false',
        'max_concurrency = 0',
        'api_key = "${MUSE_SQUAD_TEST_DISABLED_KEY}"',
        'type = "native"'
      ].join('\n')
    ));
    const disabledConfig = config.loadConfig({ config_file: disabledFile });
    assert(disabledConfig.providers.Second.enabled === false, 'enabled = false is parsed');
    assert(disabledConfig.providers.Second.api_key === '', 'disabled env key is not resolved');
    assert(disabledConfig.providers.Local.enabled === true, 'other providers stay enabled');
    assert(loaded.squad.members.alpha.primary === 'Local', 'member primary');
    assert(JSON.stringify(loaded.squad.members.alpha.fallback) === '["Second","Third"]',
      'ordered fallback');
    assert(loaded.squad.members.alpha.charter === 'Lead work.\nSecond line.\n',
      'multi-line charter');
    assert(Object.keys(loaded.squad.members).join(',') === 'alpha,beta', 'member order');

    const redacted = config.redactConfig(loaded);
    assert(redacted.providers.Local.api_key === '<redacted>', 'non-empty key is redacted');
    assert(redacted.providers.Third.api_key === '', 'empty key stays empty');
    assert(loaded.providers.Local.api_key === SECRET, 'redactConfig does not mutate input');

    const dotted = config.validateConfig({
      schema: config.SCHEMA,
      providers: {
        'Provider.With.Dots': { type: 'http', base_url: 'http://example.test/v1', model: 'm' }
      },
      squad: { member: { primary: 'Provider.With.Dots', charter: 'Charter' } }
    }, 'inline.json');
    assert(dotted.providers['Provider.With.Dots'], 'allowed provider name characters include dots');

    const minimalFile = path.join(tempDir, 'minimal.toml');
    write(minimalFile, minimalConfigText());
    const defaults = config.loadConfig({ config_file: minimalFile });
    for (const key of ['max_concurrency', 'timeout_ms', 'queue_timeout_ms', 'max_retries']) {
      const value = defaults.providers.Basic[key];
      const floor = key === 'max_retries' ? 0 : 1;
      assert(Number.isInteger(value) && value >= floor, `${key} has a usable default (got ${value})`);
    }
    assert(defaults.providers.Basic.api_key === '', 'api_key defaults to an empty string');
    assert(defaults.providers.Basic.enabled === true, 'enabled defaults to true without an explicit key');

    const bundledDefault = config.loadConfig({
      config_file: path.join(ROOT, 'payload', 'muse-squad.default.toml')
    });
    for (const [name, provider] of Object.entries(bundledDefault.providers)) {
      assert(provider.enabled === true, `bundled default provider ${name} is explicitly enabled`);
    }

    delete process.env[ENV_KEY];
    expectThrows(() => config.loadConfig({ config_file: validFile }),
      /unset environment variable/, 'unset api_key env var errors');
    process.env[ENV_KEY] = SECRET;

    const literalText = validConfigText().replace(
      'base_url = "http://127.0.0.1:1/v1"',
      'base_url = "${MUSE_SQUAD_TEST_MISSING_VAR}"'
    );
    const literalFile = path.join(tempDir, 'literal.toml');
    write(literalFile, literalText);
    const literal = config.loadConfig({ config_file: literalFile });
    assert(literal.providers.Local.base_url === '${MUSE_SQUAD_TEST_MISSING_VAR}',
      '${ENV_VAR} is only expanded for api_key');

    // --- Rejected configurations -----------------------------------------
    let invalidIndex = 0;
    function expectInvalid(text, pattern, label) {
      const file = path.join(tempDir, `invalid-${invalidIndex++}.toml`);
      write(file, text);
      expectThrows(() => config.loadConfig({ config_file: file }), pattern, label);
    }
    const base = validConfigText();

    expectInvalid(base.replace('schema = 1', 'schema = 2'), /schema/, 'wrong schema');
    expectInvalid(
      base.replace('max_concurrency = 2', 'max_concurrency = 0'),
      /max_concurrency/,
      'zero max_concurrency is rejected for enabled providers'
    );
    expectInvalid(
      base.replace('[providers.Second]\ntype = "native"', '[providers.Second]\nenabled = "no"\ntype = "native"'),
      /enabled.*boolean/,
      'non-boolean enabled is rejected'
    );
    expectInvalid('schema = 1\n[squad.member]\nprimary = "P"\ncharter = "c"\n',
      /provider/, 'at least one provider');
    expectInvalid('schema = 1\n[providers.P]\ntype = "native"\nmodel = "m"\n[squad]\n',
      /member/, 'at least one member');
    expectInvalid(base.replace('schema = 1', 'schema = 1\nunexpected = 5'),
      /unexpected|unknown/, 'unknown top-level key');
    expectInvalid(`${base}[projects.override]\nname = "Override"\n`, /projects|unknown/,
      'project overrides are rejected');
    expectInvalid(base.replace('[providers.Second]', 'role = "Lead"\n\n[providers.Second]'),
      /role|unknown/, 'provider role is rejected');
    expectInvalid(base.replace('[squad.beta]', 'role = "Lead"\n\n[squad.beta]'),
      /role|unknown/, 'member role is rejected');
    expectInvalid(base.replace('[squad.beta]', 'title = "Lead"\n\n[squad.beta]'),
      /title|unknown/, 'member title is rejected');
    expectInvalid(base.replace('[squad.beta]', 'display_name = "Lead"\n\n[squad.beta]'),
      /display_name|unknown/, 'member display_name is rejected');
    expectInvalid(base.replace('[squad.beta]', 'responsibility = "x"\n\n[squad.beta]'),
      /responsibility|unknown/, 'member responsibility is rejected');
    expectInvalid(base.replace('[providers.Local]', '[providers.bad name]'),
      /invalid provider name/i, 'invalid provider name');
    expectInvalid(base.replace('[squad.beta]', '[squad.Bad]'), /unknown|invalid/i,
      'invalid member name');
    expectInvalid(base.replace('primary = "Local"', 'primary = "Missing"'),
      /unknown provider/, 'unknown provider reference');
    expectInvalid(base.replace('fallback = ["Second", "Third"]', 'fallback = ["Local", "Second"]'),
      /repeat|primary/i, 'fallback cannot repeat the primary');
    expectInvalid(base.replace('fallback = ["Second", "Third"]', 'fallback = ["Second", "Second"]'),
      /duplicate/i, 'fallback cannot contain duplicates');
    expectInvalid(base.replace('[providers.Second]\ntype = "native"',
      '[providers.Second]\ntype = "native"\nbase_url = "http://example.test/v1"'),
      /native/, 'native provider cannot set base_url');
    expectInvalid(base.replace('[providers.Second]\ntype = "native"',
      `[providers.Second]\ntype = "native"\napi_key = "${'${'}${ENV_KEY}}"`),
      /native/, 'native provider cannot set api_key');
    expectInvalid(base.replace('type = "http"', 'type = "bogus"'), /type/, 'unknown provider type');
    expectInvalid(base.replace('base_url = "http://127.0.0.1:1/v1"\n', ''),
      /base_url/, 'http provider requires base_url');
    expectInvalid(base.replace("model = 'local-model'", ''), /model/, 'provider requires model');

    // --- CLI --------------------------------------------------------------
    const cliDir = path.join(tempDir, 'cli-config');
    fs.mkdirSync(cliDir, { recursive: true });
    const cliFile = path.join(cliDir, 'muse-squad.toml');
    write(cliFile, validConfigText());
    const cliEnv = { MUSE_CONFIG_DIR: cliDir, [ENV_KEY]: SECRET };

    const redactedRun = runCli(['--json'], cliEnv);
    assert(redactedRun.status === 0, `config --json exit 0: ${redactedRun.stderr}`);
    const redactedJson = JSON.parse(redactedRun.stdout);
    assert(redactedJson.providers.Local.api_key === '<redacted>', 'CLI redacts api_key by default');
    assert(!redactedRun.stdout.includes(SECRET), 'CLI redacted output has no secret');

    const secretRun = runCli(['--json', '--show-secrets'], cliEnv);
    assert(secretRun.status === 0, `config --json --show-secrets exit 0: ${secretRun.stderr}`);
    assert(JSON.parse(secretRun.stdout).providers.Local.api_key === SECRET,
      '--show-secrets includes api_key');
    assert(secretRun.stdout.includes(SECRET), 'secret appears in --show-secrets output');

    const providersRun = runCli(['--list-providers'], cliEnv);
    assert(providersRun.status === 0, `config --list-providers exit 0: ${providersRun.stderr}`);
    assert(providersRun.stdout.trim().split('\n').join(',') === 'Local,Second,Third',
      '--list-providers prints one provider name per line');

    for (const flag of ['--dir', '--config-dir']) {
      const dirRun = runCli([flag, cliDir, '--json'], { [ENV_KEY]: SECRET });
      assert(dirRun.status === 0, `${flag} exit 0: ${dirRun.stderr}`);
      assert(JSON.parse(dirRun.stdout).providers.Local, `${flag} discovers the config file`);
    }

    const altFile = path.join(tempDir, 'alternative.toml');
    const altText = validConfigText()
      .replace('[providers.Local]', '[providers.AltLocal]')
      .replace('primary = "Local"', 'primary = "AltLocal"');
    write(altFile, altText);
    const fileRun = runCli(['--file', altFile, '--json'], {
      MUSE_SQUAD_CONFIG_FILE: path.join(tempDir, 'does-not-exist.toml'),
      [ENV_KEY]: SECRET
    });
    assert(fileRun.status === 0, `config --file exit 0: ${fileRun.stderr}`);
    assert(JSON.parse(fileRun.stdout).providers.AltLocal, '--file overrides discovery');

    const help = runCli(['--help']);
    assert(help.status === 0, 'config --help exit 0');
    for (const flag of [
      '--config-dir', '--dir', '--file', '--json', '--list-providers', '--show-secrets', '--help'
    ]) {
      assert(help.stdout.includes(flag), `--help documents ${flag}`);
    }

    const unknown = runCli(['--not-an-option']);
    assert(unknown.status !== 0, 'unknown option exits non-zero');
    assert(/unknown option/.test(unknown.stderr), 'unknown option error is clear');

    const missing = runCli(['--file', path.join(tempDir, 'absent.toml')]);
    assert(missing.status !== 0, 'missing config exits non-zero');
    assert(/not found/.test(missing.stderr), 'missing config error is clear');

    console.log('CONFIG TESTS PASSED');
  } finally {
    restoreProcessEnv();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
