#!/usr/bin/env node
'use strict';

// Shared interactive squad builder used by both generated installers.
// It builds JSONL member records from the role catalog; installers render and
// validate the final TOML before replacing muse-squad.toml.

const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');
const config = require('./config.js');
const roles = require('./roles.js');

const MEMBER_NAME_RE = /^[a-z0-9][a-z0-9-]*$/;

function die(message) {
  process.stderr.write(`team-wizard: ${message}\n`);
  process.exit(1);
}

function log(message) {
  process.stdout.write(`${message}\n`);
}

function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--config') opts.config = argv[++i];
    else if (argv[i] === '--members-file') opts.membersFile = argv[++i];
    else if (argv[i] === '--render') opts.render = argv[++i];
    else if (argv[i] === '--help' || argv[i] === '-h') opts.help = true;
    else die(`unknown option: ${argv[i]}`);
  }
  if (opts.render && !opts.membersFile) die('--render requires --members-file');
  return opts;
}

function usage() {
  return [
    'Usage:',
    '  node team-wizard.js --config PATH [--members-file PATH]',
    '  node team-wizard.js --render CONFIG_PATH --members-file PATH',
    '',
    'Builds [squad] members from the built-in role catalog, or renders a JSONL',
    'member file into valid muse-squad TOML on stdout.'
  ].join('\n');
}

function quote(value) {
  return JSON.stringify(String(value));
}

function quoteBlock(value) {
  const text = String(value).trim();
  if (text.includes('"""')) return quote(text);
  return `"""\n${text}\n"""`;
}

function loadState(configFile) {
  const raw = fs.readFileSync(configFile, 'utf8');
  let parsed;
  try {
    parsed = config.parseToml(raw, configFile);
  } catch (error) {
    die(`cannot parse ${configFile}: ${error.message}`);
  }
  const providerNames = Object.keys(parsed.providers || {});
  if (providerNames.length === 0) die(`no providers are defined in ${configFile}`);

  let existing = [];
  try {
    const loaded = config.loadConfig({ config_file: configFile });
    existing = Object.values(loaded.squad.members).map((member) => ({
      name: member.name,
      primary: member.primary,
      fallback: member.fallback.slice(),
      charter: member.charter,
      roleId: null
    }));
  } catch (error) {
    // A broken squad section is repaired by replacing it from the catalog.
  }

  return {
    raw,
    parsed,
    providerOrder: providerNames.slice(),
    squadName: (parsed.squad && parsed.squad.name) || 'Muse Squad',
    memoryDir: (parsed.squad && parsed.squad.memory_dir) || '.muse/squad',
    existing
  };
}

function createPrompt() {
  const inputPath = process.env.MUSE_SQUAD_WIZARD_INPUT;
  const startLine = Math.max(1, Number(process.env.MUSE_SQUAD_WIZARD_LINE || 1) || 1);
  const queue = [];
  let waiting = null;
  let ended = false;
  let lineNumber = 0;

  const input = inputPath
    ? fs.createReadStream(inputPath, { encoding: 'utf8' })
    : process.stdin;
  const rl = readline.createInterface({ input, terminal: false });

  rl.on('line', (line) => {
    lineNumber++;
    if (lineNumber < startLine) return;
    if (waiting) {
      const resolve = waiting.resolve;
      waiting = null;
      resolve(line);
    } else {
      queue.push(line);
    }
  });
  rl.on('close', () => {
    ended = true;
    if (waiting) {
      const reject = waiting.reject;
      waiting = null;
      reject(new Error('no more wizard input'));
    }
  });

  return {
    ask: (question) => new Promise((resolve, reject) => {
      process.stderr.write(question);
      if (queue.length > 0) return resolve(queue.shift());
      if (ended) return reject(new Error('no more wizard input'));
      waiting = { resolve, reject };
    }),
    close: () => rl.close()
  };
}

function menuText(items) {
  return items.map((item, index) => `${index + 1}: ${item}`).join(', ');
}

function resolveProvider(answer, fallback, state) {
  const value = String(answer == null ? '' : answer).trim();
  if (!value) return fallback || '';
  if (/^\d+$/.test(value)) {
    const index = Number(value) - 1;
    if (index >= 0 && index < state.providerOrder.length) return state.providerOrder[index];
    throw new Error(`invalid provider number: ${value}`);
  }
  if (!state.providerOrder.includes(value)) throw new Error(`unknown provider: ${value}`);
  return value;
}

function resolveFallbackList(answer, fallback, primary, state) {
  const value = String(answer == null ? '' : answer).trim();
  const source = value || (fallback || []).join(',');
  if (!source) return [];
  const seen = new Set();
  const result = [];
  for (const part of source.split(',')) {
    const name = resolveProvider(part, '', state);
    if (!name) continue;
    if (name === primary) throw new Error(`fallback must not repeat the primary provider: ${name}`);
    if (seen.has(name)) throw new Error(`fallback must not contain duplicate providers: ${name}`);
    seen.add(name);
    result.push(name);
  }
  return result;
}

function resolveRole(value) {
  const text = String(value == null ? '' : value).trim();
  if (!text) return null;
  if (/^\d+$/.test(text)) {
    const index = Number(text) - 1;
    if (index < 0 || index >= roles.ROLE_IDS.length) throw new Error(`invalid role number: ${text}`);
    return roles.getRole(roles.ROLE_IDS[index]);
  }
  return roles.getRole(text);
}

function validateMemberName(name, members) {
  if (!MEMBER_NAME_RE.test(name) || /^\d+$/.test(name)) {
    throw new Error('member name must include at least one letter and use lowercase slugs');
  }
  if (members.some((member) => member.name === name)) {
    throw new Error(`name already in use: ${name}`);
  }
  return name;
}

function printRoles() {
  process.stderr.write('\nRole catalog:\n');
  roles.ROLES.forEach((role, index) => {
    process.stderr.write(`  ${index + 1}: ${role.id} - ${role.title} (${role.category})\n`);
  });
}

function printMembers(members) {
  process.stderr.write('\nSelected members:\n');
  if (members.length === 0) {
    process.stderr.write('  (none)\n');
    return;
  }
  members.forEach((member, index) => {
    const role = member.roleId || 'custom';
    const chain = [member.primary, ...member.fallback].join(' -> ');
    process.stderr.write(`  ${index + 1}: @${member.name} | ${role} | ${chain}\n`);
  });
}

function membersFromTemplate(templateId) {
  return roles.templateMembers(templateId).map((member) => ({ ...member, roleId: member.name }));
}

async function chooseTemplate(state, prompt) {
  const options = roles.TEMPLATES.map((template) => ({
    id: template.id,
    label: `${template.id} - ${template.title} (${template.roleIds.length} roles)`
  }));
  if (state.existing.length > 0) {
    options.unshift({ id: 'keep', label: 'keep - Keep current squad' });
  }
  process.stderr.write('\nBuilt-in role catalog: 20 roles. Choose a starting team:\n');
  options.forEach((option, index) => {
    process.stderr.write(`  ${index + 1}: ${option.label}\n`);
  });
  const defaultOption = state.existing.length > 0
    ? '1'
    : String(options.findIndex((option) => option.id === 'software') + 1);
  while (true) {
    const answer = (await prompt.ask(`Starting team [${defaultOption}]: `)).trim() || defaultOption;
    const index = /^\d+$/.test(answer)
      ? Number(answer) - 1
      : options.findIndex((option) => option.id === answer);
    if (index >= 0 && index < options.length) {
      const selected = options[index].id;
      if (state.existing.length > 0 && selected !== 'keep') {
        const replace = (await prompt.ask(
          `Replace the current roster and regenerate charters from ${selected}? [y/N]: `
        )).trim();
        if (!/^[yY]([eE][sS])?$/.test(replace)) {
          process.stderr.write('  kept current squad\n');
          return 'keep';
        }
      }
      return selected;
    }
    process.stderr.write(`  invalid starting team: ${answer}\n`);
  }
}

async function editMembers(members, state, prompt) {
  while (true) {
    printMembers(members);
    process.stderr.write(
      '\nEdit commands: add <role>, remove <number>, rename <number> <name>, ' +
      'provider <number>, charter <number>, list, members, done\n'
    );
    const line = (await prompt.ask('Edit [done]: ')).trim();
    const [command, ...args] = line ? line.split(/\s+/) : ['done'];
    try {
      if (command === 'done' || command === 'd') return members;
      if (command === 'list' || command === 'l') {
        printRoles();
      } else if (command === 'members' || command === 'm') {
        printMembers(members);
      } else if (command === 'add' || command === 'a') {
        let role = resolveRole(args[0]);
        if (!role) process.stderr.write(`  unknown role: ${args[0]}\n`);
        while (!role) {
          const answer = (await prompt.ask('Role ID or number: ')).trim();
          role = resolveRole(answer);
          if (!role) process.stderr.write(`  unknown role: ${answer}\n`);
        }
        const name = validateMemberName(role.id, members);
        const defaults = roles.PROVIDER_DEFAULTS[role.id] ||
          { primary: 'Muse-Ember', fallback: ['Home-Ornith'] };
        members.push({
          name,
          primary: defaults.primary,
          fallback: defaults.fallback.slice(),
          charter: roles.buildCharter(role.id, name),
          roleId: role.id
        });
        process.stderr.write(`  added @${name}\n`);
      } else if (command === 'remove' || command === 'r') {
        const index = Number(args[0]) - 1;
        if (!Number.isInteger(index) || index < 0 || index >= members.length) {
          throw new Error(`invalid member number: ${args[0] || ''}`);
        }
        const [removed] = members.splice(index, 1);
        process.stderr.write(`  removed @${removed.name}\n`);
      } else if (command === 'rename' || command === 'n') {
        const index = Number(args[0]) - 1;
        if (!Number.isInteger(index) || index < 0 || index >= members.length) {
          throw new Error(`invalid member number: ${args[0] || ''}`);
        }
        const member = members[index];
        let newName = args[1];
        while (!newName) {
          newName = (await prompt.ask(`New name for @${member.name}: `)).trim();
        }
        const normalized = validateMemberName(newName, members.filter((item) => item !== member));
        member.charter = roles.renameCharter(member.charter, member.name, normalized);
        process.stderr.write(`  renamed @${member.name} to @${normalized}\n`);
        member.name = normalized;
      } else if (command === 'provider' || command === 'p') {
        const index = Number(args[0]) - 1;
        if (!Number.isInteger(index) || index < 0 || index >= members.length) {
          throw new Error(`invalid member number: ${args[0] || ''}`);
        }
        const member = members[index];
        process.stderr.write(`\nProviders: ${menuText(state.providerOrder)}\n`);
        const primaryAnswer = await prompt.ask(
          `Primary provider for ${member.name} [${member.primary}]: `
        );
        member.primary = resolveProvider(primaryAnswer, member.primary, state);
        const fallbackAnswer = await prompt.ask(
          `Fallback providers for ${member.name} (comma-separated) [${member.fallback.join(',')}]: `
        );
        member.fallback = resolveFallbackList(
          fallbackAnswer, member.fallback, member.primary, state
        );
        process.stderr.write(`  updated providers for @${member.name}\n`);
      } else if (command === 'charter' || command === 'c') {
        const index = Number(args[0]) - 1;
        if (!Number.isInteger(index) || index < 0 || index >= members.length) {
          throw new Error(`invalid member number: ${args[0] || ''}`);
        }
        const member = members[index];
        const suggested = member.roleId || member.name;
        let role = resolveRole(args[1] || suggested);
        while (!role) {
          const answer = (await prompt.ask(`Role ID for charter [${suggested}]: `)).trim() || suggested;
          role = resolveRole(answer);
          if (!role) process.stderr.write(`  unknown role: ${answer}\n`);
        }
        member.roleId = role.id;
        member.charter = roles.buildCharter(role.id, member.name);
        process.stderr.write(`  regenerated charter for @${member.name} from ${role.id}\n`);
      } else {
        throw new Error(`unknown edit command: ${command}`);
      }
    } catch (error) {
      process.stderr.write(`  ${error.message}\n`);
    }
  }
}

function renderConfig(state, members) {
  const marker = state.raw.match(/^\[squad\][ \t]*$/m);
  if (!marker) throw new Error('muse-squad.toml has no [squad] table');
  const prefix = state.raw.slice(0, marker.index).replace(/\r?\n+$/, '\n');
  const lines = [
    '[squad]',
    `name = ${quote(state.squadName)}`,
    `memory_dir = ${quote(state.memoryDir)}`,
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
  return `${prefix}${lines.join('\n')}`;
}

function validateMemberRecord(record) {
  if (!record || typeof record !== 'object' || Array.isArray(record)) {
    throw new Error('member record must be an object');
  }
  if (!MEMBER_NAME_RE.test(String(record.name || ''))) {
    throw new Error(`invalid member name in record: ${record.name || ''}`);
  }
  if (typeof record.primary !== 'string' || !record.primary) {
    throw new Error(`invalid primary provider for @${record.name}`);
  }
  if (!Array.isArray(record.fallback) || record.fallback.some((name) => typeof name !== 'string')) {
    throw new Error(`invalid fallback list for @${record.name}`);
  }
  if (typeof record.charter !== 'string' || !record.charter.trim()) {
    throw new Error(`invalid charter for @${record.name}`);
  }
  return {
    name: record.name,
    primary: record.primary,
    fallback: record.fallback.slice(),
    charter: record.charter
  };
}

function writeMembersFile(membersFile, members) {
  const body = members.map((member) => JSON.stringify({
    name: member.name,
    primary: member.primary,
    fallback: member.fallback,
    charter: member.charter
  })).join('\n');
  fs.writeFileSync(membersFile, `${body}\n`, { mode: 0o600 });
}

function readMembersFile(membersFile) {
  return fs.readFileSync(membersFile, 'utf8').split(/\r?\n/)
    .filter((line) => line.trim().length > 0)
    .map((line) => {
      let record;
      try {
        record = JSON.parse(line);
      } catch (error) {
        throw new Error(`bad JSONL member record: ${error.message}`);
      }
      return validateMemberRecord(record);
    });
}

function validateConfigText(text, sourceFile) {
  const temp = path.join(
    os.tmpdir(),
    `muse-squad-team-${process.pid}-${Date.now()}.toml`
  );
  try {
    fs.writeFileSync(temp, text, { mode: 0o600 });
    config.loadConfig({ config_file: temp });
  } finally {
    if (fs.existsSync(temp)) fs.unlinkSync(temp);
  }
  return sourceFile;
}

function renderFromMembersFile(configFile, membersFile) {
  const state = loadState(configFile);
  const members = readMembersFile(membersFile);
  if (members.length === 0) throw new Error('at least one squad member is required');
  const rendered = renderConfig(state, members);
  validateConfigText(rendered, configFile);
  return rendered;
}

function writeConfig(configFile, text) {
  const temp = path.join(path.dirname(configFile), `.muse-squad.toml.${process.pid}.tmp`);
  try {
    fs.writeFileSync(temp, text, { mode: 0o600 });
    validateConfigText(text, configFile);
    fs.renameSync(temp, configFile);
    try { fs.chmodSync(configFile, 0o600); } catch (error) { /* Windows ignores this. */ }
  } finally {
    if (fs.existsSync(temp)) fs.unlinkSync(temp);
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    log(usage());
    return;
  }
  if (opts.render) {
    process.stdout.write(renderFromMembersFile(opts.render, opts.membersFile));
    return;
  }
  if (!opts.config) die('--config is required');

  const configFile = path.resolve(opts.config);
  const state = loadState(configFile);
  const prompt = createPrompt();
  try {
    const templateId = await chooseTemplate(state, prompt);
    let members = templateId === 'keep'
      ? state.existing.map((member) => ({ ...member, fallback: member.fallback.slice() }))
      : membersFromTemplate(templateId);
    if (members.length === 0 && templateId !== 'custom') {
      die(`template "${templateId}" produced no members`);
    }
    printMembers(members);

    const accept = (await prompt.ask('\nAccept these members as-is? [Y/n]: ')).trim();
    const accepted = !/^[nN](o)?$/.test(accept);
    if (!accepted) members = await editMembers(members, state, prompt);
    if (members.length === 0) die('at least one squad member is required');

    log(`  template    ${templateId}`);
    log(`  members     ${members.length}`);
    log(`  names       ${members.map((member) => `@${member.name}`).join(', ')}`);
    log(`  ${accepted ? 'defaults    accepted' : 'overrides   applied'}`);

    if (opts.membersFile) {
      writeMembersFile(opts.membersFile, members);
      log(`  prepared    ${members.length} JSONL member records`);
      return;
    }
    writeConfig(configFile, renderConfig(state, members));
    log(`  updated    ${configFile}`);
  } finally {
    prompt.close();
  }
}

if (require.main === module) {
  main().catch((error) => die(error.message));
}

module.exports = {
  loadState,
  renderConfig,
  renderFromMembersFile,
  readMembersFile,
  validateConfigText,
  validateMemberRecord,
  writeMembersFile,
  membersFromTemplate,
  parseArgs,
  usage
};
