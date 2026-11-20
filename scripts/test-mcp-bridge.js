#!/usr/bin/env node
'use strict';

// Smoke test for the resilient routing MCP bridge using a mock endpoint.
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const BRIDGE = path.join(__dirname, '..', 'payload', 'mcp', 'bridge.js');
const CANNED = 'diff --git a/foo.ts b/foo.ts\n+export const foo = 1;\n';
const CRITIQUE = '1. [HIGH] Missing rollback path.\n';
const FALLBACK = 'fallback model output\n';

let mode = 'ok';
let localFailuresRemaining = 0;
let lastRequest = null;
const calls = [];
const stats = { active: {}, maxActive: {}, order: {}, counts: {} };

function setMode(next) {
  mode = next;
  localFailuresRemaining = next === 'fail500-once' ? 1 : 0;
}

function assert(condition, message) {
  if (!condition) throw new Error(`assertion failed: ${message}`);
}

function localCount() {
  return calls.filter((call) => call.key === 'local-key').length;
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function resetStats() {
  stats.active = {};
  stats.maxActive = {};
  stats.order = {};
  stats.counts = {};
}

const server = http.createServer((request, response) => {
  let body = '';
  request.setEncoding('utf8');
  request.on('data', (chunk) => {
    body += chunk;
  });
  request.on('end', () => {
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch (error) {
      response.writeHead(400);
      response.end('{}');
      return;
    }
    const key = (request.headers.authorization || '').replace('Bearer ', '');
    const userText = parsed.messages[1].content;
    const match = userText.match(/^TASK:\n(.*)$/);
    const label = match ? match[1] : 'unknown';
    calls.push({ key, model: parsed.model, temperature: parsed.temperature, label });
    lastRequest = parsed;

    stats.active[key] = (stats.active[key] || 0) + 1;
    stats.counts[key] = (stats.counts[key] || 0) + 1;
    stats.maxActive[key] = Math.max(stats.maxActive[key] || 0, stats.active[key]);
    (stats.order[key] = stats.order[key] || []).push(label);

    const respond = (status, payload) => {
      stats.active[key] -= 1;
      response.writeHead(status, { 'Content-Type': 'application/json' });
      response.end(payload);
    };

    if (mode === 'unauth' && key === 'local-key') {
      respond(401, '{"error":"bad key"}');
      return;
    }
    if (mode === 'fail500-once' && key === 'local-key' && localFailuresRemaining > 0) {
      localFailuresRemaining -= 1;
      respond(503, '{"error":"loading"}');
      return;
    }
    if (mode === 'allfail') {
      respond(503, '{"error":"down"}');
      return;
    }

    const system = parsed.messages[0].content;
    const content = key === 'local-key'
      ? CANNED
      : (system.includes('code auditor') ? CRITIQUE : FALLBACK);
    const payload = JSON.stringify({ choices: [{ message: { role: 'assistant', content } }] });
    const wait = (mode === 'slow' && key === 'local-key') ? 30
      : (mode === 'queue-slow' && key === 'local-key') ? 200
        : 0;
    if (wait > 0) setTimeout(() => respond(200, payload), wait);
    else respond(200, payload);
  });
});

function writeConfig(configFile, baseUrl, overrides = {}) {
  fs.writeFileSync(configFile, JSON.stringify({
    default_endpoint: 'local-coder',
    fallback_order: ['local-coder', 'grill-reviewer'],
    muse_models: { 'muse-ember-1.0': 4, 'muse-spark-1.3': 2 },
    timeout_ms: 10000,
    queue_timeout_ms: 300000,
    max_retries: 2,
    endpoints: {
      'local-coder': {
        base_url: baseUrl, api_key: 'local-key', model: 'local-model',
        temperature: 0.2, max_concurrency: 1
      },
      'grill-reviewer': {
        base_url: baseUrl, api_key: 'grill-key', model: 'grill-model',
        temperature: 0.3, max_concurrency: 1
      }
    },
    ...overrides
  }, null, 2));
}

function setEndpointConcurrency(configFile, name, limit) {
  const config = JSON.parse(fs.readFileSync(configFile, 'utf8'));
  config.endpoints[name].max_concurrency = limit;
  fs.writeFileSync(configFile, JSON.stringify(config, null, 2));
}

function run(port, tempDir, configFile) {
  const baseUrl = `http://127.0.0.1:${port}/v1`;
  writeConfig(configFile, baseUrl);

  const child = spawn(process.execPath, [BRIDGE], {
    env: { ...process.env, MODELS_CONFIG_FILE: configFile },
    stdio: ['pipe', 'pipe', 'inherit']
  });

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

  function request(message) {
    return new Promise((resolve) => {
      pending.set(message.id, resolve);
      child.stdin.write(`${JSON.stringify(message)}\n`);
    });
  }

  function tool(id, name, args) {
    return request({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args } });
  }

  function finish() {
    child.stdin.end();
    server.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
    console.log('MCP BRIDGE TESTS PASSED');
  }

  (async () => {
    const init = await request({
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } }
    });
    assert(init.result.serverInfo.name === 'muse-squad-custom-coder', 'initialize serverInfo');

    const list = await request({ jsonrpc: '2.0', id: 2, method: 'tools/list' });
    for (const name of ['generate_code', 'critique_plan', 'coder_status', 'list_endpoints']) {
      const toolDef = list.result.tools.find((candidate) => candidate.name === name);
      assert(toolDef, `${name} is listed`);
    }
    for (const name of ['generate_code', 'critique_plan', 'coder_status']) {
      assert(
        list.result.tools.find((candidate) => candidate.name === name).inputSchema.properties.endpoint,
        `${name} accepts endpoint`
      );
    }
    const generateSchema = list.result.tools.find((item) => item.name === 'generate_code').inputSchema;
    assert(generateSchema.properties.task_spec, 'generate_code accepts task_spec alias');
    assert(generateSchema.properties.file_context, 'generate_code accepts file_context alias');
    assert(generateSchema.anyOf, 'generate_code accepts either prompt or task_spec');

    const status = await tool(3, 'coder_status', {});
    const statusText = status.result.content[0].text;
    assert(statusText.includes('"defaultEndpoint": "local-coder"'), 'default_endpoint is honored');
    assert(statusText.includes('grill-reviewer'), 'coder_status lists aliases');
    assert(statusText.includes('"maxRetries": 2'), 'coder_status reports max_retries');
    assert(statusText.includes('"queueTimeoutMs": 300000'), 'coder_status reports queue_timeout_ms');
    assert(statusText.includes('"maxConcurrency": 1'), 'coder_status reports max_concurrency');
    assert(statusText.includes('"muse-ember-1.0": 4'), 'coder_status reports muse_models');
    assert(statusText.includes('"activeCalls": 0'), 'coder_status reports live queue state');
    assert(!statusText.includes('grill-key'), 'coder_status redacts keys');

    const listing = JSON.parse((await tool(4, 'list_endpoints', {})).result.content[0].text);
    assert(listing.endpoints['local-coder'].max_concurrency === 1, 'list_endpoints reports max_concurrency');
    assert(listing.muse_models['muse-spark-1.3'] === 2, 'list_endpoints reports muse_models');
    assert(listing.queue_timeout_ms === 300000, 'list_endpoints reports queue_timeout_ms');

    const generated = await tool(5, 'generate_code', { prompt: 'add foo' });
    assert(generated.result.content[0].text === CANNED, 'generate_code returns clean diff');
    assert(generated.result.meta.servedBy === 'local-coder', 'meta reports serving endpoint');
    assert(generated.result.meta.fallbackUsed === false, 'meta reports no fallback');
    assert(lastRequest.temperature === 0.2, 'per-endpoint temperature is applied');
    assert(lastRequest.model === 'local-model', 'local model is used');
    assert(lastRequest.messages[0].content.includes('unified diff'), 'generate_code asks for a diff');
    assert(
      lastRequest.messages[0].content.includes('Never output a full-file rewrite'),
      'generate_code forbids full-file rewrites'
    );

    const aliased = await tool(6, 'generate_code', { task_spec: 'add bar', file_context: 'foo.ts' });
    assert(aliased.result.content[0].text === CANNED, 'task_spec/file_context aliases work');
    assert(lastRequest.messages[1].content.includes('foo.ts'), 'file_context reaches the model');

    const critique = await tool(7, 'critique_plan', {
      endpoint: 'grill-reviewer',
      plan_markdown: '# Plan\nStep 1',
      repo_context: 'src/index.ts exists'
    });
    assert(critique.result.content[0].text === CRITIQUE, 'critique_plan routes to grill-reviewer');
    assert(critique.result.meta.primary === 'grill-reviewer', 'critique meta reports primary');
    assert(lastRequest.temperature === 0.3, 'grill-reviewer temperature is applied');
    assert(
      lastRequest.messages[0].content.includes('Find missing edge cases, security flaws, or broken assumptions'),
      'critique_plan uses strict auditor prompt'
    );

    setMode('fail500-once');
    const retried = await tool(8, 'generate_code', { prompt: 'retry me' });
    assert(retried.result.content[0].text === CANNED, 'transient 503 is retried successfully');
    assert(localCount() === 4, 'local endpoint was called twice for the retried request');
    setMode('ok');

    setMode('unauth');
    const beforeFallback = localCount();
    const fallback = await tool(9, 'generate_code', { prompt: 'fallback please' });
    assert(fallback.result.content[0].text === FALLBACK, 'fallback endpoint serves the request');
    assert(fallback.result.meta.fallbackUsed === true, 'meta reports fallback');
    assert(fallback.result.meta.servedBy === 'grill-reviewer', 'meta names the fallback');
    assert(localCount() === beforeFallback + 1, '401 is not retried');
    assert(!fallback.result.content[0].text.startsWith('>'), 'fallback note does not pollute output');
    setMode('ok');

    const beforeUnknown = calls.length;
    const unknown = await tool(10, 'generate_code', { endpoint: 'nope', prompt: 'x' });
    assert(unknown.result.isError === true, 'unknown endpoint returns isError');
    assert(unknown.result.content[0].text.includes('unknown endpoint'), 'unknown endpoint error is clear');
    assert(calls.length === beforeUnknown, 'unknown endpoint makes no network calls');

    setMode('allfail');
    writeConfig(configFile, baseUrl, { max_retries: 0 });
    const allFailed = await tool(11, 'generate_code', { prompt: 'everything is down' });
    assert(allFailed.result.isError === true, 'all endpoints failing returns isError');
    assert(allFailed.result.content[0].text.includes('All endpoints failed'), 'all-failed error is clear');
    setMode('ok');

    // --- Concurrency: max_concurrency: 1 strictly serializes in FIFO order ---
    writeConfig(configFile, baseUrl, {
      default: 'local-coder',
      fallback_order: ['local-coder', 'grill-reviewer'],
      max_retries: 0,
      queue_timeout_ms: 10000
    });
    resetStats();
    setMode('slow');
    const fifo = await Promise.all([
      tool(12, 'generate_code', { prompt: 'fifo-1' }),
      tool(13, 'generate_code', { prompt: 'fifo-2' }),
      tool(14, 'generate_code', { prompt: 'fifo-3' })
    ]);
    assert(stats.maxActive['local-key'] === 1, 'max_concurrency 1 allows only one local call at a time');
    assert(
      JSON.stringify(stats.order['local-key']) === JSON.stringify(['fifo-1', 'fifo-2', 'fifo-3']),
      'queued calls are served FIFO'
    );
    assert(fifo.every((item) => item.result.meta.servedBy === 'local-coder'), 'queued calls stay on primary');
    assert(fifo.every((item) => item.result.meta.fallbackUsed === false), 'waiting does not trigger fallback');
    assert(!stats.counts['grill-key'], 'backup endpoint is untouched while primary is merely busy');
    setMode('ok');

    // --- Concurrency: queue timeout triggers fallback, not a hang ---
    writeConfig(configFile, baseUrl, {
      default: 'local-coder',
      fallback_order: ['local-coder', 'grill-reviewer'],
      max_retries: 0,
      queue_timeout_ms: 40
    });
    resetStats();
    setMode('queue-slow');
    const queued = await Promise.all([
      tool(15, 'generate_code', { prompt: 'queue-first' }),
      tool(16, 'generate_code', { prompt: 'queue-second' })
    ]);
    assert(queued[0].result.meta.servedBy === 'local-coder', 'first call holds the local slot');
    assert(queued[1].result.meta.servedBy === 'grill-reviewer', 'queue timeout falls back');
    assert(queued[1].result.meta.fallbackUsed === true, 'queue timeout fallback is reported in meta');
    assert(
      queued[1].result.meta.attempts.some((attempt) =>
        attempt.endpoint === 'local-coder' && /queue timeout/.test(attempt.error)
      ),
      'queue timeout is recorded as the primary failure reason'
    );
    setMode('ok');

    // --- Concurrency: a failed call always releases its slot ---
    writeConfig(configFile, baseUrl, {
      default: 'local-coder',
      fallback_order: ['local-coder'],
      max_retries: 0,
      queue_timeout_ms: 2000
    });
    resetStats();
    setMode('fail500-once');
    const failurePair = await Promise.all([
      tool(17, 'generate_code', { prompt: 'fail-first' }),
      tool(18, 'generate_code', { prompt: 'wait-second' })
    ]);
    assert(failurePair.some((item) => item.result.isError === true), 'first call fails');
    assert(
      failurePair.some((item) => item.result.content[0].text === CANNED),
      'queued call succeeds after failing call releases its slot'
    );
    assert(stats.maxActive['local-key'] === 1, 'slot was not leaked on failure');
    setMode('ok');

    // --- Concurrency: hot-reloaded limit changes without dropping in-flight work ---
    writeConfig(configFile, baseUrl, {
      default: 'local-coder',
      fallback_order: ['local-coder'],
      max_retries: 0,
      queue_timeout_ms: 10000
    });
    resetStats();
    setMode('slow');
    const hot1 = tool(19, 'generate_code', { prompt: 'hot-1' });
    await delay(10); // let hot-1 take the only slot
    const hot2 = tool(20, 'generate_code', { prompt: 'hot-2' }); // queues at limit 1
    setEndpointConcurrency(configFile, 'local-coder', 2);
    const hot3 = tool(21, 'generate_code', { prompt: 'hot-3' }); // sees new limit
    const hotResults = await Promise.all([hot1, hot2, hot3]);
    assert(hotResults.every((item) => item.result.content[0].text === CANNED), 'all in-flight calls complete after reload');
    assert(stats.maxActive['local-key'] === 2, 'reloaded limit is honored without resetting active slots');
    const reloadedListing = JSON.parse((await tool(22, 'list_endpoints', {})).result.content[0].text);
    assert(reloadedListing.endpoints['local-coder'].max_concurrency === 2, 'list_endpoints sees reloaded limit');
    assert(reloadedListing.endpoints['local-coder'].activeCalls === 0, 'no active slots leaked');
    assert(reloadedListing.endpoints['local-coder'].queuedCalls === 0, 'no waiters stranded');
    setMode('ok');

    writeConfig(configFile, baseUrl, { default: 'grill-reviewer' });
    const reloaded = await tool(23, 'coder_status', {});
    assert(reloaded.result.content[0].text.includes('"defaultEndpoint": "grill-reviewer"'), 'config hot reload');

    finish();
  })().catch((error) => {
    console.error(error);
    child.kill();
    server.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
    process.exitCode = 1;
  });
}

server.listen(0, '127.0.0.1', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-squad-router-'));
  run(server.address().port, tempDir, path.join(tempDir, 'endpoints.json'));
});
