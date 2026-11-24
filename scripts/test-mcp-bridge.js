#!/usr/bin/env node
'use strict';

// Smoke test for the member-scoped MCP bridge using a local HTTP mock server.
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const BRIDGE = path.join(__dirname, '..', 'payload', 'mcp', 'bridge.js');
const ALPHA_SECRET = 'alpha-secret-do-not-leak';
const BETA_SECRET = 'beta-secret-do-not-leak';
const NESTED_SECRET = 'nested-secret-do-not-leak';
const ALPHA_OUTPUT = 'diff --git a/foo.ts b/foo.ts\n+export const foo = 1;\n';
const BETA_OUTPUT = 'fallback output\n';
const CRITIQUE_OUTPUT = '1. [HIGH] Missing rollback path.\n';
const TRUNCATION_WARNING = "> *[Warning: Input truncated to max_input_chars for 'Alpha']*\n\n";

let mode = 'ok';
let failRemaining = { alpha: 0, beta: 0 };
let lastRequest = null;
const calls = [];
const stats = { active: {}, maxActive: {}, order: {}, counts: {} };

function assert(condition, message) {
  if (!condition) throw new Error(`assertion failed: ${message}`);
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function setMode(next, failures = {}) {
  mode = next;
  failRemaining = { alpha: 0, beta: 0, ...failures };
}

function resetStats() {
  stats.active = {};
  stats.maxActive = {};
  stats.order = {};
  stats.counts = {};
}

function providerForUrl(url) {
  if (String(url).startsWith('/v1/alpha')) return 'alpha';
  if (String(url).startsWith('/v1/beta')) return 'beta';
  return 'unknown';
}

const server = http.createServer((request, response) => {
  let body = '';
  request.setEncoding('utf8');
  request.on('data', (chunk) => { body += chunk; });
  request.on('end', () => {
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch (error) {
      response.writeHead(400, { 'content-type': 'application/json' });
      response.end('{}');
      return;
    }

    const provider = providerForUrl(request.url);
    const key = (request.headers.authorization || '').replace(/^Bearer /, '');
    const userText = parsed.messages && parsed.messages[1] ? parsed.messages[1].content : '';
    const match = userText.match(/^TASK:\n(.*)$/);
    const label = match ? match[1] : 'other';
    calls.push({ provider, key, payload: parsed, label });
    lastRequest = parsed;

    stats.active[provider] = (stats.active[provider] || 0) + 1;
    stats.counts[provider] = (stats.counts[provider] || 0) + 1;
    stats.maxActive[provider] = Math.max(stats.maxActive[provider] || 0, stats.active[provider]);
    (stats.order[provider] = stats.order[provider] || []).push(label);

    const release = () => {
      stats.active[provider] = Math.max(0, stats.active[provider] - 1);
    };
    const respond = (status, payload) => {
      release();
      if (response.destroyed) return;
      response.writeHead(status, { 'content-type': 'application/json' });
      response.end(payload);
    };

    if (mode === 'unauth' && provider === 'alpha') {
      respond(401, '{"error":"bad key"}');
      return;
    }
    if (mode === 'allfail') {
      respond(503, '{"error":"down"}');
      return;
    }
    if (
      ['retry-429-alpha', 'retry-503-alpha', 'fail-once-alpha'].includes(mode) &&
      provider === 'alpha' && failRemaining.alpha > 0
    ) {
      failRemaining.alpha -= 1;
      const status = mode === 'retry-429-alpha' ? 429 : mode === 'retry-503-alpha' ? 503 : 401;
      respond(status, `{"error":"transient ${status}"}`);
      return;
    }
    if (mode === 'network-once-alpha' && provider === 'alpha' && failRemaining.alpha > 0) {
      failRemaining.alpha -= 1;
      release();
      request.socket.destroy();
      return;
    }

    const system = parsed.messages && parsed.messages[0] ? parsed.messages[0].content : '';
    const content = system.includes('code auditor')
      ? CRITIQUE_OUTPUT
      : (provider === 'beta' ? BETA_OUTPUT : ALPHA_OUTPUT);
    const payload = JSON.stringify({
      choices: [{ message: { role: 'assistant', content } }],
      model: provider === 'beta' ? 'beta-upstream' : 'alpha-upstream'
    });
    const wait = mode === 'timeout-once-alpha' && provider === 'alpha' && failRemaining.alpha > 0
      ? 200
      : mode === 'queue-slow' && provider === 'alpha' ? 200
        : mode === 'slow' && provider === 'alpha' ? 60
          : 0;
    if (mode === 'timeout-once-alpha' && wait === 200) failRemaining.alpha -= 1;
    if (wait > 0) setTimeout(() => respond(200, payload), wait);
    else respond(200, payload);
  });
});

function baseSettings() {
  return {
    alpha: {
      max_concurrency: 1,
      timeout_ms: 1000,
      queue_timeout_ms: 2000,
      max_retries: 0
    },
    beta: {
      max_concurrency: 1,
      timeout_ms: 1000,
      queue_timeout_ms: 2000,
      max_retries: 0
    }
  };
}

let settings = baseSettings();

function numberLines(target, source) {
  for (const key of [
    'max_concurrency', 'timeout_ms', 'queue_timeout_ms', 'max_retries',
    'max_input_chars', 'on_context_exceeded'
  ]) {
    if (source[key] !== undefined) target.push(`${key} = ${source[key]}`);
  }
}

function writeConfig(configFile, baseUrl) {
  const lines = [
    '# Generated by scripts/test-mcp-bridge.js',
    'schema = 1',
    '',
    '[providers.Alpha]',
    'type = "http"',
    `base_url = "${baseUrl}/v1/alpha"`,
    `api_key = "${ALPHA_SECRET}"`,
    'model = "alpha-model"',
    'temperature = 0.2'
  ];
  if (settings.alpha.enabled === false) lines.push('enabled = false');
  numberLines(lines, settings.alpha);
  lines.push(
    '',
    '[providers.Alpha.extra_body]',
    `api_key = "${NESTED_SECRET}"`,
    'top_p = 0.9',
    '',
    '[providers.Beta]',
    'type = "http"',
    `base_url = "${baseUrl}/v1/beta"`,
    `api_key = "${BETA_SECRET}"`,
    'model = "beta-model"'
  );
  if (settings.beta.enabled === false) lines.push('enabled = false');
  numberLines(lines, settings.beta);
  lines.push(
    '',
    '[providers.Native]',
    'type = "native"',
    'model = "native-model"',
    '',
    '[squad.solo]',
    'primary = "Alpha"',
    'charter = """',
    'Ship targeted diffs.',
    '"""',
    '',
    '[squad.hybrid]',
    'primary = "Alpha"',
    'fallback = ["Beta"]',
    'charter = """',
    'Implement and hand off overflow work.',
    '"""',
    '',
    '[squad.mixed]',
    'primary = "Native"',
    'fallback = ["Alpha", "Beta"]',
    'charter = """',
    'Review and implement with fallbacks.',
    '"""',
    ''
  );
  const tempFile = `${configFile}.tmp`;
  fs.writeFileSync(tempFile, lines.join('\n'));
  fs.renameSync(tempFile, configFile);
}

function resetConfig(configFile, baseUrl) {
  settings = baseSettings();
  writeConfig(configFile, baseUrl);
  setMode('ok');
  resetStats();
}

function bridgeEnv(extra = {}) {
  const env = { ...process.env };
  delete env.MUSE_CONFIG_DIR;
  delete env.MUSE_SQUAD_CONFIG_FILE;
  return { ...env, ...extra };
}

function startBridge(configFile) {
  const child = spawn(process.execPath, [BRIDGE], {
    env: bridgeEnv({ MUSE_SQUAD_CONFIG_FILE: configFile }),
    stdio: ['pipe', 'pipe', 'pipe']
  });
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk) => { stderr += chunk; });

  let buffer = '';
  const pending = new Map();
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (!line) continue;
      const message = JSON.parse(line);
      const resolve = pending.get(message.id);
      if (resolve) {
        pending.delete(message.id);
        resolve(message);
      }
    }
  });

  let nextId = 1;
  function request(method, params) {
    const id = nextId++;
    return new Promise((resolve) => {
      pending.set(id, resolve);
      child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
    });
  }
  function tool(name, args) {
    return request('tools/call', { name, arguments: args });
  }
  async function stop() {
    child.stdin.end();
    await new Promise((resolve) => child.on('close', resolve));
  }
  return { child, request, tool, stop, stderr: () => stderr };
}

function servedBy(meta, name) {
  return meta.servedBy === name || meta.servedProvider === name;
}

async function run(port, tempDir, configFile) {
  const baseUrl = `http://127.0.0.1:${port}`;
  resetConfig(configFile, baseUrl);
  const bridge = startBridge(configFile);

  try {
    // --- Protocol surface -------------------------------------------------
    const init = await bridge.request('initialize', {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'test', version: '1' }
    });
    assert(init.result && init.result.serverInfo, 'initialize returns serverInfo');
    assert(init.result.serverInfo.name === 'muse-squad', 'server name is muse-squad');
    assert(init.result.serverInfo.version === '0.3.0', 'server version is 0.3.0');

    const list = await bridge.request('tools/list');
    const toolNames = list.result.tools.map((item) => item.name).sort();
    assert(
      JSON.stringify(toolNames) ===
        JSON.stringify([
          'critique_plan', 'generate_code', 'list_providers', 'member_status',
          'memory_init', 'memory_status'
        ]),
      `tools are exactly the six expected names (got ${toolNames.join(',')})`
    );
    const generateSchema = list.result.tools.find((item) => item.name === 'generate_code').inputSchema;
    const critiqueSchema = list.result.tools.find((item) => item.name === 'critique_plan').inputSchema;
    const statusSchema = list.result.tools.find((item) => item.name === 'member_status').inputSchema;
    assert(generateSchema.required.includes('member'), 'generate_code requires member');
    assert(
      generateSchema.anyOf.some((option) => option.required.includes('prompt')) &&
        generateSchema.anyOf.some((option) => option.required.includes('task_spec')),
      'generate_code accepts prompt or task_spec'
    );
    for (const property of [
      'prompt', 'task_spec', 'context', 'file_context',
      'system', 'temperature', 'max_tokens'
    ]) {
      assert(generateSchema.properties[property], `generate_code accepts ${property}`);
    }
    assert(
      critiqueSchema.required.includes('member') && critiqueSchema.required.includes('plan_markdown'),
      'critique_plan requires member and plan_markdown'
    );
    for (const property of ['repo_context', 'temperature', 'max_tokens']) {
      assert(critiqueSchema.properties[property], `critique_plan accepts ${property}`);
    }
    assert(!statusSchema.required || !statusSchema.required.includes('member'),
      'member_status member is optional');
    const memoryStatusSchema = list.result.tools.find((item) => item.name === 'memory_status').inputSchema;
    const memoryInitSchema = list.result.tools.find((item) => item.name === 'memory_init').inputSchema;
    assert(memoryStatusSchema.required.includes('repo_root'), 'memory_status requires repo_root');
    assert(memoryInitSchema.required.includes('repo_root'), 'memory_init requires repo_root');
    assert(memoryInitSchema.properties.include_plan, 'memory_init accepts include_plan');

    // --- Repository memory tools -----------------------------------------
    const repoRoot = path.join(tempDir, 'memory-repo');
    fs.mkdirSync(path.join(repoRoot, '.git'), { recursive: true });
    fs.mkdirSync(path.join(repoRoot, '.muse', 'history'), { recursive: true });
    fs.mkdirSync(path.join(repoRoot, '.muse', 'squad', 'history'), { recursive: true });
    fs.writeFileSync(path.join(repoRoot, '.muse', 'PLAN.md'), 'Bridge legacy plan.\n');
    fs.writeFileSync(
      path.join(repoRoot, '.muse', 'squad', 'decisions.md'),
      'Bridge legacy decision.\n'
    );

    const memoryBefore = JSON.parse(
      (await bridge.tool('memory_status', { repo_root: repoRoot })).result.content[0].text
    );
    assert(memoryBefore.ok === true && memoryBefore.legacy.present === true &&
      memoryBefore.legacy.pending === true,
    'memory_status finds unmigrated legacy memory');
    assert(memoryBefore.legacy.dirs.join(',') === '.muse,.muse/squad',
      'memory_status reports both legacy directories');
    const memoryInitResult = JSON.parse(
      (await bridge.tool('memory_init', {
        repo_root: repoRoot, include_plan: true
      })).result.content[0].text
    );
    assert(memoryInitResult.ok === true && memoryInitResult.planIncluded === true,
      'memory_init runs through the bridge');
    assert(memoryInitResult.copied.length === 2, 'memory_init copies both legacy files');
    assert(memoryInitResult.memoryDir === '.muse-squad', 'bridge memory_init uses the canonical dir');
    assert(fs.readFileSync(path.join(repoRoot, '.muse-squad', 'PLAN.md'), 'utf8')
      .includes('Bridge legacy plan.'), 'bridge memory_init preserves the legacy plan');
    assert(fs.readFileSync(path.join(repoRoot, '.muse-squad', 'decisions.md'), 'utf8')
      .includes('Bridge legacy decision.'), 'bridge memory_init preserves legacy decisions');
    assert(fs.existsSync(path.join(repoRoot, '.muse', 'PLAN.md')) &&
      fs.existsSync(path.join(repoRoot, '.muse', 'squad', 'decisions.md')),
    'bridge memory_init leaves legacy originals in place');
    const memoryAfter = JSON.parse(
      (await bridge.tool('memory_status', { repo_root: repoRoot })).result.content[0].text
    );
    assert(memoryAfter.legacy.present === true && memoryAfter.legacy.pending === false,
      'memory_status stops asking to migrate after copying');
    const memoryAgain = JSON.parse(
      (await bridge.tool('memory_init', { repo_root: repoRoot })).result.content[0].text
    );
    assert(memoryAgain.copied.length === 0 && memoryAgain.appended.length === 0,
      'repeated bridge memory_init is idempotent');

    // --- Status tools -----------------------------------------------------
    const statusText = (await bridge.tool('member_status', {})).result.content[0].text;
    const status = JSON.parse(statusText);
    assert(status.ok === true && status.available === true, 'member_status reports availability');
    assert(status.members.length === 3, 'member_status lists every member');
    assert(!statusText.includes(ALPHA_SECRET) && !statusText.includes(BETA_SECRET),
      'member_status redacts api keys');
    const soloStatus = status.members.find((member) => member.name === 'solo');
    assert(soloStatus, 'member_status includes solo');
    assert(soloStatus.chain.join(',') === 'Alpha', 'member_status reports chain');
    assert(soloStatus.charter.includes('Ship targeted diffs.'), 'member_status includes charter');
    assert(soloStatus.providers[0].activeCalls === 0 &&
      soloStatus.providers[0].queuedCalls === 0, 'member_status reports queue state');
    const selectedText = (await bridge.tool('member_status', { member: 'mixed' }))
      .result.content[0].text;
    const selected = JSON.parse(selectedText);
    assert(selected.selected && selected.selected.name === 'mixed',
      'member_status selects the requested member');
    assert(selected.selected.chain.join(',') === 'Native,Alpha,Beta',
      'selected chain keeps primary and fallback order');
    assert(selected.selected.providers.find((item) => item.name === 'Native').callableByMcp === false,
      'native provider is not callable by MCP');
    assert(!selectedText.includes(ALPHA_SECRET), 'selected member redacts keys');

    const listingText = (await bridge.tool('list_providers', {})).result.content[0].text;
    const listing = JSON.parse(listingText);
    assert(listing.ok === true && listing.available === true, 'list_providers reports availability');
    assert(listing.providers.Alpha && listing.providers.Beta && listing.providers.Native,
      'list_providers includes all providers');
    assert(listing.members.some((member) => member.name === 'hybrid'),
      'list_providers includes members');
    assert(listing.providers.Alpha.apiKeyConfigured === true, 'list_providers reports key presence');
    assert(
      !listingText.includes(ALPHA_SECRET) &&
        !listingText.includes(BETA_SECRET) &&
        !listingText.includes(NESTED_SECRET),
      'list_providers redacts top-level and nested secrets'
    );

    // --- Member is mandatory ---------------------------------------------
    const beforeInvalid = calls.length;
    const noGenerateMember = await bridge.tool('generate_code', { prompt: 'x' });
    assert(noGenerateMember.result.isError === true, 'generate_code without member is an error');
    assert(/member/i.test(noGenerateMember.result.content[0].text),
      'generate_code explains the missing member');
    const noCritiqueMember = await bridge.tool('critique_plan', { plan_markdown: '# plan' });
    assert(noCritiqueMember.result.isError === true, 'critique_plan without member is an error');
    const unknownMember = await bridge.tool('generate_code', { member: 'ghost', prompt: 'x' });
    assert(unknownMember.result.isError === true, 'unknown member is an error');
    assert(/unknown squad member/i.test(unknownMember.result.content[0].text),
      'unknown member error is clear');
    assert(calls.length === beforeInvalid, 'invalid member requests make no network calls');

    // --- Primary generation, aliases, and overrides ----------------------
    resetStats();
    const generated = await bridge.tool('generate_code', {
      member: 'solo',
      prompt: 'add foo',
      context: 'foo.ts exists',
      system: 'CUSTOM SYSTEM',
      temperature: 0.7,
      max_tokens: 128
    });
    assert(generated.result.isError !== true, 'generate_code succeeds on primary');
    assert(generated.result.content[0].text === ALPHA_OUTPUT, 'output has no extra prefix');
    const genMeta = generated.result.meta;
    assert(genMeta.member === 'solo' && genMeta.primary === 'Alpha', 'meta names member and primary');
    assert(JSON.stringify(genMeta.chain) === '["Alpha"]', 'meta reports the chain');
    assert(servedBy(genMeta, 'Alpha'), 'meta names the serving provider');
    assert(genMeta.servedModel === 'alpha-model', 'meta names the configured model');
    assert(genMeta.fallbackUsed === false && genMeta.chainIndex === 0,
      'meta reports no fallback on success');
    assert(Array.isArray(genMeta.attempts) && genMeta.attempts.length === 0,
      'meta reports no attempts before a first-try success');
    assert(lastRequest.model === 'alpha-model', 'configured model is sent');
    assert(lastRequest.messages[0].content === 'CUSTOM SYSTEM', 'system override is sent');
    assert(lastRequest.messages[1].content.includes('add foo'), 'prompt is sent');
    assert(lastRequest.messages[1].content.includes('foo.ts exists'), 'context is sent');
    assert(lastRequest.temperature === 0.7 && lastRequest.max_tokens === 128,
      'temperature and max_tokens overrides are sent');
    assert(calls[calls.length - 1].key === ALPHA_SECRET, 'api key is sent to the provider');

    const aliased = await bridge.tool('generate_code', {
      member: 'solo', task_spec: 'add bar', file_context: 'bar.ts'
    });
    assert(aliased.result.content[0].text === ALPHA_OUTPUT, 'task_spec alias works');
    assert(lastRequest.messages[1].content.includes('add bar'), 'task_spec reaches the model');
    assert(lastRequest.messages[1].content.includes('bar.ts'), 'file_context reaches the model');

    const critique = await bridge.tool('critique_plan', {
      member: 'solo', plan_markdown: '# Plan\nStep 1', repo_context: 'src/a.ts exists'
    });
    assert(critique.result.content[0].text === CRITIQUE_OUTPUT, 'critique_plan uses auditor output');
    assert(servedBy(critique.result.meta, 'Alpha'), 'critique_plan meta names the provider');
    assert(lastRequest.messages[0].content.includes('code auditor'),
      'critique_plan uses the auditor system prompt');
    assert(lastRequest.messages[1].content.includes('# Plan') &&
      lastRequest.messages[1].content.includes('src/a.ts exists'),
    'plan_markdown and repo_context reach the model');

    // --- Native skip, ordered fallback, immediate 4xx --------------------
    settings.alpha.max_retries = 1; // 401 must not consume a retry even when retries are allowed
    writeConfig(configFile, baseUrl);
    setMode('unauth');
    resetStats();
    const fallback = await bridge.tool('generate_code', { member: 'mixed', prompt: 'fallback' });
    assert(fallback.result.content[0].text === BETA_OUTPUT, 'fallback provider serves the request');
    const fbMeta = fallback.result.meta;
    assert(JSON.stringify(fbMeta.chain) === '["Native","Alpha","Beta"]',
      'chain order is primary then fallbacks');
    assert(servedBy(fbMeta, 'Beta'), 'fallback meta names Beta');
    assert(fbMeta.fallbackUsed === true && fbMeta.chainIndex === 2,
      'fallback meta records the chain position');
    assert(fbMeta.attempts.some((item) => item.provider === 'Native' && /native/i.test(item.error)),
      'native provider skip is recorded');
    assert(fbMeta.attempts.some((item) => item.provider === 'Alpha' && /401/.test(item.error)),
      'failed primary is recorded');
    assert(stats.counts.alpha === 1, '401 is not retried');
    assert(stats.counts.beta === 1, 'fallback is called once');
    assert(!fallback.result.content[0].text.startsWith('>'), 'fallback output has no warning prefix');

    // --- Hard error lists every attempt ----------------------------------
    resetConfig(configFile, baseUrl);
    setMode('allfail');
    const allFailed = await bridge.tool('generate_code', { member: 'mixed', prompt: 'down' });
    assert(allFailed.result.isError === true, 'all providers failing returns isError');
    const allFailText = allFailed.result.content[0].text;
    for (const name of ['Native', 'Alpha', 'Beta']) {
      assert(allFailText.includes(name), `all-failed error lists ${name}`);
    }
    assert(/attempted providers/i.test(allFailText), 'all-failed error explains the attempts');
    assert(allFailed.result.meta === undefined, 'failed result has no meta');

    // --- Retry classification --------------------------------------------
    settings.alpha.max_retries = 1;
    writeConfig(configFile, baseUrl);

    setMode('retry-429-alpha', { alpha: 1 });
    resetStats();
    const retried429 = await bridge.tool('generate_code', { member: 'solo', prompt: 'retry 429' });
    assert(retried429.result.content[0].text === ALPHA_OUTPUT, '429 is retried successfully');
    assert(stats.counts.alpha === 2, '429 produced exactly one retry');

    setMode('retry-503-alpha', { alpha: 1 });
    resetStats();
    const retried503 = await bridge.tool('generate_code', { member: 'solo', prompt: 'retry 503' });
    assert(retried503.result.content[0].text === ALPHA_OUTPUT, '5xx is retried successfully');
    assert(stats.counts.alpha === 2, '503 produced exactly one retry');

    setMode('network-once-alpha', { alpha: 1 });
    resetStats();
    const retriedNetwork = await bridge.tool('generate_code', {
      member: 'solo', prompt: 'retry network'
    });
    assert(retriedNetwork.result.content[0].text === ALPHA_OUTPUT, 'network error is retried');
    assert(stats.counts.alpha === 2, 'network error produced exactly one retry');

    settings.alpha.timeout_ms = 30;
    writeConfig(configFile, baseUrl);
    setMode('timeout-once-alpha', { alpha: 1 });
    resetStats();
    const retriedTimeout = await bridge.tool('generate_code', {
      member: 'solo', prompt: 'retry timeout'
    });
    assert(retriedTimeout.result.content[0].text === ALPHA_OUTPUT, 'timeout is retried successfully');
    assert(stats.counts.alpha === 2, 'timeout produced exactly one retry');

    // --- FIFO queue with max_concurrency 1 -------------------------------
    resetConfig(configFile, baseUrl);
    setMode('slow');
    resetStats();
    const fifo = await Promise.all([
      bridge.tool('generate_code', { member: 'solo', prompt: 'fifo-1' }),
      bridge.tool('generate_code', { member: 'solo', prompt: 'fifo-2' }),
      bridge.tool('generate_code', { member: 'solo', prompt: 'fifo-3' })
    ]);
    assert(stats.maxActive.alpha === 1, 'max_concurrency 1 serializes calls');
    assert(stats.order.alpha.join(',') === 'fifo-1,fifo-2,fifo-3', 'queued calls are FIFO');
    assert(fifo.every((item) => item.result.content[0].text === ALPHA_OUTPUT),
      'all queued calls complete');
    assert(fifo.every((item) => item.result.meta.fallbackUsed === false),
      'waiting in the queue does not trigger fallback');

    // --- Queue timeout triggers member fallback --------------------------
    settings.alpha.queue_timeout_ms = 25;
    writeConfig(configFile, baseUrl);
    setMode('queue-slow');
    resetStats();
    const queued = await Promise.all([
      bridge.tool('generate_code', { member: 'hybrid', prompt: 'queue-first' }),
      bridge.tool('generate_code', { member: 'hybrid', prompt: 'queue-second' })
    ]);
    assert(servedBy(queued[0].result.meta, 'Alpha'), 'first call holds the provider slot');
    assert(servedBy(queued[1].result.meta, 'Beta'), 'queue timeout falls back to Beta');
    assert(queued[1].result.meta.fallbackUsed === true, 'queue fallback is reported');
    assert(queued[1].result.meta.attempts.some((item) =>
      item.provider === 'Alpha' && /queue timeout/i.test(item.error)),
    'queue timeout is recorded as the attempt failure');
    assert(stats.counts.alpha === 1 && stats.counts.beta === 1,
      'queue timeout did not add an upstream call to Alpha');

    // --- Slot release after failure --------------------------------------
    resetConfig(configFile, baseUrl);
    setMode('fail-once-alpha', { alpha: 1 });
    resetStats();
    const failedPair = await Promise.all([
      bridge.tool('generate_code', { member: 'solo', prompt: 'fail-first' }),
      bridge.tool('generate_code', { member: 'solo', prompt: 'wait-second' })
    ]);
    assert(failedPair.some((item) => item.result.isError === true), 'first call fails');
    assert(failedPair.some((item) => item.result.content[0].text === ALPHA_OUTPUT),
      'queued call succeeds after the failure releases the slot');
    assert(stats.maxActive.alpha === 1, 'failure did not leak a slot');
    const afterFailure = JSON.parse((await bridge.tool('member_status', {})).result.content[0].text);
    assert(afterFailure.members.find((member) => member.name === 'solo').providers[0].activeCalls === 0,
      'no active slots remain after failures');

    // --- Hot reload adopts a new max_concurrency -------------------------
    resetConfig(configFile, baseUrl);
    setMode('slow');
    resetStats();
    const hot1 = bridge.tool('generate_code', { member: 'solo', prompt: 'hot-1' });
    await delay(20);
    const hot2 = bridge.tool('generate_code', { member: 'solo', prompt: 'hot-2' });
    settings.alpha.max_concurrency = 2;
    writeConfig(configFile, baseUrl);
    const hot3 = bridge.tool('generate_code', { member: 'solo', prompt: 'hot-3' });
    const hotResults = await Promise.all([hot1, hot2, hot3]);
    const hotTexts = hotResults.map((item) => item.result.content[0].text);
    assert(hotTexts.every((text) => text === ALPHA_OUTPUT),
      `all in-flight calls complete after config reload (got ${JSON.stringify(hotTexts)})`);
    assert(stats.maxActive.alpha === 2, 'reloaded max_concurrency is honored');
    const afterReload = JSON.parse((await bridge.tool('member_status', {})).result.content[0].text);
    const reloadedSolo = afterReload.members.find((member) => member.name === 'solo').providers[0];
    assert(reloadedSolo.activeCalls === 0 && reloadedSolo.queuedCalls === 0,
      'no slots or waiters are stranded after reload');

    // --- Disabled providers are skipped without editing member chains -----
    resetConfig(configFile, baseUrl);
    settings.alpha.enabled = false;
    writeConfig(configFile, baseUrl);
    setMode('ok');
    resetStats();
    const disabledListing = JSON.parse((await bridge.tool('list_providers', {})).result.content[0].text);
    assert(disabledListing.providers.Alpha.enabled === false,
      'list_providers reports the disabled provider');
    assert(disabledListing.providers.Beta.enabled === true,
      'list_providers keeps other providers enabled');
    const hybridStatusText = (await bridge.tool('member_status', { member: 'hybrid' }))
      .result.content[0].text;
    const hybridStatus = JSON.parse(hybridStatusText);
    const alphaEntry = hybridStatus.selected.providers.find((item) => item.name === 'Alpha');
    assert(alphaEntry.enabled === false && alphaEntry.callableByMcp === false,
      'member_status marks a disabled provider not callable');
    const beforeDisabled = calls.length;
    const skipped = await bridge.tool('generate_code', { member: 'hybrid', prompt: 'skip-alpha' });
    assert(skipped.result.content[0].text === BETA_OUTPUT, 'disabled primary is skipped');
    assert(servedBy(skipped.result.meta, 'Beta'), 'fallback serves after the disabled primary');
    assert(skipped.result.meta.attempts.some(
      (item) => item.provider === 'Alpha' && /disabled/i.test(item.error)
    ), 'disabled skip is recorded in attempts');
    assert(calls.slice(beforeDisabled).every((item) => item.provider !== 'alpha'),
      'no HTTP request is sent to a disabled provider');
    resetConfig(configFile, baseUrl);

    // --- Only the truncation warning is prepended ------------------------
    resetConfig(configFile, baseUrl);
    settings.alpha.max_input_chars = 200;
    writeConfig(configFile, baseUrl);
    const longContext = `${'A'.repeat(500)}TAILMARKER`;
    const truncated = await bridge.tool('generate_code', {
      member: 'solo', prompt: 'short', context: longContext
    });
    assert(truncated.result.content[0].text.startsWith(TRUNCATION_WARNING),
      'truncation warning is prepended');
    assert(truncated.result.content[0].text.endsWith(ALPHA_OUTPUT),
      'model output follows the warning');
    assert(!lastRequest.messages[1].content.includes('TAILMARKER'), 'oversized tail is cut off');
    assert(lastRequest.messages[0].content.length + lastRequest.messages[1].content.length <= 200,
      'combined prompt fits max_input_chars');
    resetConfig(configFile, baseUrl);
    const noWarning = await bridge.tool('generate_code', { member: 'solo', prompt: 'plain' });
    assert(!noWarning.result.content[0].text.startsWith('>'),
      'normal output has no warning prefix');

    console.log('MCP BRIDGE TESTS PASSED');
  } finally {
    try {
      await bridge.stop();
    } catch (error) {
      bridge.child.kill();
    }
  }
}

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return server.address().port;
}

async function close(server) {
  await new Promise((resolve) => server.close(resolve));
}

async function main() {
  const port = await listen(server);
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-squad-mcp-'));
  try {
    await run(port, tempDir, path.join(tempDir, 'muse-squad.toml'));
  } finally {
    await close(server);
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
