#!/usr/bin/env node
'use strict';

// Repository-local Muse Squad memory. This module owns the canonical .muse/
// layout so skills, wrappers, and MCP tools agree across machines. It never
// reads or writes the global Muse config; that stays behind the MCP bridge.

const fs = require('fs');
const os = require('os');
const path = require('path');

const MEMORY_DIR = '.muse';
const LEGACY_MEMORY_DIR = '.muse/squad';
const CANONICAL_FILES = [
  `${MEMORY_DIR}/.gitignore`,
  `${MEMORY_DIR}/README.md`,
  `${MEMORY_DIR}/PLAN.md`,
  `${MEMORY_DIR}/TODO.md`,
  `${MEMORY_DIR}/decisions.md`,
  `${MEMORY_DIR}/history/.gitkeep`
];

const TEMPLATES = {
  [`${MEMORY_DIR}/.gitignore`]: [
    'local/',
    'squad/',
    ''
  ].join('\n'),

  [`${MEMORY_DIR}/README.md`]: [
    '# Muse Squad project memory',
    '',
    'This folder is repository-local project memory for Muse Squad. Unlike the',
    'global squad config, these files travel with the repository.',
    '',
    'Commit these canonical files so every machine starts from the same state:',
    '',
    '- `PLAN.md` - current approved implementation plan.',
    '- `TODO.md` - checked checklist with verification commands and results.',
    '- `decisions.md` - append-only durable decisions.',
    '- `history/<member>.md` - append-only learnings from each named member.',
    '',
    '`local/` is for machine-only scratch and is not tracked. `squad/` is the',
    'legacy layout and is not tracked after migration.',
    '',
    'Do not put API keys, provider credentials, absolute paths, or machine-specific',
    'provider names in these files. Keep paths relative to the repository root.',
    '',
    'Muse Squad creates missing files automatically at skill startup. After a plan',
    'or wave, commit the canonical files and pull them on other machines before',
    'resuming.',
    ''
  ].join('\n'),

  [`${MEMORY_DIR}/PLAN.md`]: [
    '# Plan',
    '',
    '## Goal',
    '',
    'Describe the outcome in one or two sentences.',
    '',
    '## Constraints',
    '',
    '- ...',
    '',
    '## Decisions',
    '',
    '- ...',
    '',
    '## Steps',
    '',
    '1. Owner: `@<name>`. Action and expected result.',
    '2. Owner: `@<name>`. Action and expected result.',
    '',
    '## Verification',
    '',
    '- `<command>` - expected result.',
    '',
    '## Open questions',
    '',
    '- ...',
    ''
  ].join('\n'),

  [`${MEMORY_DIR}/TODO.md`]: [
    '# TODO',
    '',
    '- [ ] Draft or confirm `.muse/PLAN.md`.',
    '- [ ] Record exact verification commands and results as work lands.',
    ''
  ].join('\n'),

  [`${MEMORY_DIR}/decisions.md`]: [
    '# Decisions',
    '',
    'Append-only. Use dated sections so merges stay readable.',
    '',
    '### YYYY-MM-DD - Topic',
    '',
    '- Context: ...',
    '- Decision: ...',
    '- Why: ...',
    ''
  ].join('\n'),

  [`${MEMORY_DIR}/history/.gitkeep`]: ''
};

function expandHome(value) {
  return String(value).replace(/^~(?=$|[\\/])/, os.homedir());
}

function resolveRepoRoot(input) {
  const raw = typeof input === 'string' && input.trim() ? input.trim() : process.cwd();
  const root = path.resolve(expandHome(raw));
  let stat;
  try {
    stat = fs.statSync(root);
  } catch (error) {
    throw new Error(`cannot access repo root ${root}: ${error.message}`);
  }
  if (!stat.isDirectory()) throw new Error(`repo root is not a directory: ${root}`);
  return root;
}

function readIfExists(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (error) {
    if (error && error.code === 'ENOENT') return null;
    throw error;
  }
}

function trailingNewline(text) {
  const value = String(text);
  return value.endsWith('\n') ? value : `${value}\n`;
}

function listMarkdown(dir) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (error) {
    if (error && error.code === 'ENOENT') return [];
    throw error;
  }
  return entries
    .filter((entry) => entry.isFile() && entry.name.endsWith('.md'))
    .map((entry) => entry.name)
    .sort();
}

function blocksMemory(line) {
  const trimmed = String(line).trim();
  if (!trimmed || trimmed.startsWith('#') || trimmed.startsWith('!')) return false;
  return /(^|\/)\.muse(?:\/|\*|$)/.test(trimmed);
}

function gitIgnoreStatus(root) {
  const text = readIfExists(path.join(root, '.gitignore'));
  const lines = text === null ? [] : text.split(/\r?\n/);
  const blockingLine = lines.find(blocksMemory) || null;
  return {
    present: text !== null,
    blocksMemory: blockingLine !== null,
    blockingLine
  };
}

function legacyStatus(root) {
  const decisionsRel = `${LEGACY_MEMORY_DIR}/decisions.md`;
  const history = listMarkdown(path.join(root, LEGACY_MEMORY_DIR, 'history'))
    .map((name) => `${LEGACY_MEMORY_DIR}/history/${name}`);
  const decisions = fs.existsSync(path.join(root, decisionsRel)) ? decisionsRel : null;
  return {
    present: decisions !== null || history.length > 0,
    decisions,
    history,
    files: [...(decisions ? [decisions] : []), ...history]
  };
}

function canonicalStatus(root) {
  const files = {};
  for (const rel of CANONICAL_FILES) {
    files[rel] = fs.existsSync(path.join(root, rel));
  }
  for (const name of listMarkdown(path.join(root, MEMORY_DIR, 'history'))) {
    files[`${MEMORY_DIR}/history/${name}`] = true;
  }
  return files;
}

function buildWarnings(status) {
  const warnings = [];
  if (!status.isGitRepo) {
    warnings.push('Not a Git repository. Confirm the repo root before creating .muse/.');
  }
  if (status.gitIgnore.blocksMemory) {
    warnings.push(
      `Root .gitignore blocks project memory with ${JSON.stringify(status.gitIgnore.blockingLine)}. ` +
        'Canonical files will not sync until that rule is changed.'
    );
  }
  if (status.legacy.present) {
    warnings.push('Legacy .muse/squad files found. Run muse-squad:memory_init to copy them.');
  }
  return warnings;
}

function memoryStatus(rootInput) {
  const repoRoot = resolveRepoRoot(rootInput);
  const status = {
    ok: true,
    repoRoot,
    memoryDir: MEMORY_DIR,
    isGitRepo: fs.existsSync(path.join(repoRoot, '.git')),
    exists: fs.existsSync(path.join(repoRoot, MEMORY_DIR)),
    files: canonicalStatus(repoRoot),
    legacy: legacyStatus(repoRoot),
    gitIgnore: gitIgnoreStatus(repoRoot)
  };
  status.warnings = buildWarnings(status);
  return status;
}

function writeIfAbsent(root, rel, report) {
  const dest = path.join(root, rel);
  if (fs.existsSync(dest)) {
    report.skipped.push(rel);
    return false;
  }
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  const template = Object.prototype.hasOwnProperty.call(TEMPLATES, rel) ? TEMPLATES[rel] : '';
  fs.writeFileSync(dest, trailingNewline(template));
  report.created.push(rel);
  return true;
}

function mergeLegacy(root, from, to, report) {
  const source = path.join(root, from);
  if (!fs.existsSync(source)) return;
  const legacyText = fs.readFileSync(source, 'utf8');
  const dest = path.join(root, to);
  const marker = `<!-- muse-squad migrated from ${from} -->`;
  const existing = readIfExists(dest);

  if (existing !== null && existing.includes(marker)) {
    report.skipped.push(`${to} (legacy already migrated)`);
    return;
  }

  fs.mkdirSync(path.dirname(dest), { recursive: true });
  if (existing === null) {
    fs.writeFileSync(dest, `${marker}\n${trailingNewline(legacyText)}`);
    report.copied.push({ from, to });
    return;
  }

  fs.writeFileSync(
    dest,
    `${existing.replace(/\s+$/, '')}\n\n${marker}\n\n${legacyText.replace(/\s+$/, '')}\n`
  );
  report.appended.push({ from, to });
}

function memoryInit(rootInput, options = {}) {
  const repoRoot = resolveRepoRoot(rootInput);
  if (!fs.existsSync(path.join(repoRoot, '.git'))) {
    throw new Error(
      `${repoRoot} is not a Git repository; pass the output of git rev-parse --show-toplevel`
    );
  }

  const report = {
    ok: true,
    repoRoot,
    memoryDir: MEMORY_DIR,
    created: [],
    copied: [],
    appended: [],
    skipped: [],
    planIncluded: options.include_plan === true
  };

  fs.mkdirSync(path.join(repoRoot, MEMORY_DIR, 'history'), { recursive: true });
  fs.mkdirSync(path.join(repoRoot, MEMORY_DIR, 'local'), { recursive: true });

  // Copy legacy content before templates so migrated files keep their original
  // text instead of carrying an empty template heading.
  mergeLegacy(
    repoRoot,
    `${LEGACY_MEMORY_DIR}/decisions.md`,
    `${MEMORY_DIR}/decisions.md`,
    report
  );
  for (const name of listMarkdown(path.join(repoRoot, LEGACY_MEMORY_DIR, 'history'))) {
    mergeLegacy(
      repoRoot,
      `${LEGACY_MEMORY_DIR}/history/${name}`,
      `${MEMORY_DIR}/history/${name}`,
      report
    );
  }

  const files = options.include_plan === true
    ? CANONICAL_FILES
    : CANONICAL_FILES.filter((rel) => rel !== `${MEMORY_DIR}/PLAN.md`);
  for (const rel of files) writeIfAbsent(repoRoot, rel, report);

  report.warnings = memoryStatus(repoRoot).warnings;
  return report;
}

module.exports = {
  MEMORY_DIR,
  LEGACY_MEMORY_DIR,
  CANONICAL_FILES,
  TEMPLATES,
  expandHome,
  resolveRepoRoot,
  memoryStatus,
  memoryInit
};
