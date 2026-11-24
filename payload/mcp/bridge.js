#!/usr/bin/env node
'use strict';

// MCP stdio server for the muse-squad roster. Every generation or critique is
// scoped to a named squad member; the member's provider chain comes from
// muse-squad.toml. Zero npm dependencies, Node 18+ (global fetch).

const configModule = require('./config.js');
const memoryModule = require('./memory.js');

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
  },
  {
    name: 'memory_status',
    description: 'Report repository-local .muse memory files, legacy .muse/squad content, and Git ignore status. Read-only.',
    inputSchema: {
      type: 'object',
      properties: {
        repo_root: { type: 'string', description: 'Absolute repository root, usually from git rev-parse --show-toplevel.' }
      },
      required: ['repo_root'],
      additionalProperties: false
    }
  },
  {
    name: 'memory_init',
    description: 'Create the repository-local .muse/ layout and copy legacy .muse/squad memory without deleting the originals.',
    inputSchema: {
      type: 'object',
      properties: {
        repo_root: { type: 'string', description: 'Absolute repository root, usually from git rev-parse --show-toplevel.' },
        include_plan: { type: 'boolean', description: 'Also create .muse/PLAN.md. Use only for /squad-plan or /squad-execute.' }
      },
      required: ['repo_root'],
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
    if (provider.enabled === false) {
      attempts.push({ provider: name, error: 'provider is disabled in muse-squad.toml' });
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
      enabled: provider.enabled !== false,
      model: provider.model,
      callableByMcp: provider.type === 'http' && provider.enabled !== false,
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
    enabled: provider.enabled !== false,
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

function requiredRepoRoot(params) {
  if (typeof params.repo_root !== 'string' || params.repo_root.trim() === '') {
    throw new Error(`${params && params.__tool} requires a non-empty "repo_root"`);
  }
  return memoryModule.resolveRepoRoot(params.repo_root);
}

async function callTool(name, args) {
  const params = args || {};

  if (name === 'memory_status' || name === 'memory_init') {
    const repoRoot = requiredRepoRoot({ ...params, __tool: name });
    const report = name === 'memory_status'
      ? memoryModule.memoryStatus(repoRoot)
      : memoryModule.memoryInit(repoRoot, { include_plan: params.include_plan === true });
    return { content: [{ type: 'text', text: JSON.stringify(report, null, 2) }] };
  }

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
