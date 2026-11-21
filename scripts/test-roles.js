#!/usr/bin/env node
'use strict';

// Verifies the vendored role catalog, charter builder, templates, and CLI.
const path = require('path');
const { spawnSync } = require('child_process');
const roles = require(path.join(__dirname, '..', 'payload', 'mcp', 'roles.js'));

function assert(condition, message) {
  if (!condition) throw new Error(`assertion failed: ${message}`);
}

const SOFTWARE_IDS = [
  'lead', 'frontend', 'backend', 'reviewer', 'tester', 'devops', 'docs'
];

const REQUIRED_HEADINGS = [
  '## Identity',
  '## Ownership',
  '## How I Work',
  '## Boundaries',
  '## Routing Cues',
  '## Voice',
  '## Delegation'
];

function runCli(args) {
  const result = spawnSync(process.execPath, [
    path.join(__dirname, '..', 'payload', 'mcp', 'roles.js'), ...args
  ], { encoding: 'utf8' });
  assert(result.status === 0, `CLI ${args.join(' ')} exits 0: ${result.stderr}`);
  return result.stdout;
}

function main() {
  for (const name of [
    'UPSTREAM_REF', 'ROLES', 'ROLE_IDS', 'ENGINEERING_ROLE_IDS',
    'CATEGORY_ROLE_IDS', 'CATEGORIES', 'TEMPLATES', 'PROVIDER_DEFAULTS',
    'getRole', 'getTemplate', 'listRoles', 'buildCharter', 'renameCharter',
    'templateMembers'
  ]) {
    assert(roles[name] !== undefined, `exports ${name}`);
  }

  assert(roles.ROLES.length === 20, 'exactly 20 roles');
  assert(new Set(roles.ROLE_IDS).size === 20, 'role IDs are unique');
  assert(roles.ENGINEERING_ROLE_IDS.length === 13, '13 engineering roles');
  assert(roles.CATEGORY_ROLE_IDS.length === 7, '7 category roles');
  assert(roles.ROLE_IDS.includes('fact-checker'), 'fact-checker is included');
  assert(!roles.ROLE_IDS.includes('product-manager'), 'product-manager is out of agreed scope');
  assert(/^[0-9a-f]{40}$/.test(roles.UPSTREAM_REF), 'upstream ref is a pinned commit');

  for (const role of roles.ROLES) {
    assert(/^[a-z0-9][a-z0-9-]*$/.test(role.id), `valid role id: ${role.id}`);
    for (const field of ['title', 'category', 'emoji', 'vibe', 'style', 'voice', 'attribution']) {
      assert(typeof role[field] === 'string' && role[field].trim(), `${role.id}.${field}`);
    }
    for (const field of ['expertise', 'ownership', 'approach', 'routingPatterns']) {
      assert(Array.isArray(role[field]) && role[field].length > 0, `${role.id}.${field}`);
    }
    assert(role.boundaries && role.boundaries.handles && role.boundaries.doesNotHandle,
      `${role.id}.boundaries`);
    assert(roles.getRole(role.id) === role, `getRole(${role.id})`);

    const charter = roles.buildCharter(role.id, role.id);
    assert(charter.includes(role.attribution), `${role.id} charter attribution`);
    assert(charter.includes(`# @${role.id} — ${role.title}`), `${role.id} charter heading`);
    assert(charter.includes(`Invoke me as @${role.id}.`), `${role.id} charter delegation`);
    for (const heading of REQUIRED_HEADINGS) {
      assert(charter.includes(heading), `${role.id} charter heading ${heading}`);
    }
    for (const forbidden of ['Coordinator', '.squad/', '**Model**', 'model: auto']) {
      assert(!charter.includes(forbidden), `${role.id} charter omits ${forbidden}`);
    }
    assert(!charter.includes('"""'), `${role.id} charter has no TOML triple quotes`);
    assert(!charter.includes("'@"), `${role.id} charter has no PowerShell here-string terminator`);
  }

  assert(roles.listRoles({ category: 'quality' }).length === 3, 'quality category filter');
  assert(roles.listRoles({ search: 'architecture' }).some((role) => role.id === 'lead'),
    'keyword search finds lead');

  const templates = Object.fromEntries(roles.TEMPLATES.map((template) => [template.id, template]));
  assert(templates.software.roleIds.join(',') === SOFTWARE_IDS.join(','), 'software template roster');
  assert(templates.engineering.roleIds.length === 13, 'engineering template size');
  assert(templates.full.roleIds.length === 20, 'full template size');
  assert(templates.custom.roleIds.length === 0, 'custom template starts empty');
  for (const template of roles.TEMPLATES) {
    for (const id of template.roleIds) {
      assert(roles.getRole(id), `${template.id} references known role ${id}`);
    }
  }

  const members = roles.templateMembers('software');
  assert(members.map((member) => member.name).join(',') === SOFTWARE_IDS.join(','),
    'software template member names');
  for (const member of members) {
    assert(roles.getRole(member.name), `generated member ${member.name} has a role`);
    assert(typeof member.primary === 'string' && member.primary, `${member.name} primary`);
    assert(Array.isArray(member.fallback) && !member.fallback.includes(member.primary),
      `${member.name} fallback`);
    assert(member.charter.includes(`@${member.name}`), `${member.name} generated charter name`);
  }

  const renamed = roles.renameCharter(members[0].charter, 'lead', 'architect');
  assert(renamed.includes('# @architect —'), 'rename updates charter heading');
  assert(renamed.includes('Invoke me as @architect.'), 'rename updates delegation line');
  assert(!renamed.includes('@lead'), 'rename removes old @name references');
  const prefixRename = roles.renameCharter('@lead and @lead-2', 'lead', 'architect');
  assert(prefixRename === '@architect and @lead-2', 'rename does not rewrite longer names');

  const stats = runCli(['--stats']);
  assert(stats.includes('roles: 20'), 'CLI stats role count');
  assert(stats.includes('templates: 4'), 'CLI stats template count');
  const list = JSON.parse(runCli(['--list', '--json']));
  assert(list.length === 20, 'CLI list JSON count');
  const cliMembers = runCli(['--template', 'software']).trim().split('\n').map(JSON.parse);
  assert(cliMembers.length === 7, 'CLI template JSONL count');
  assert(cliMembers[0].name === 'lead', 'CLI template first member');
  assert(runCli(['--charter', 'reviewer']).includes('## Ownership'), 'CLI charter output');

  process.stdout.write('ROLES TESTS PASSED\n');
}

main();
