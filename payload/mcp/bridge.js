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
