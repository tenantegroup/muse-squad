#!/usr/bin/env node
'use strict';

// Verifies the canonical repository-local .muse-squad/ layout and migration
// from both legacy .muse/ and .muse/squad/ memory.
const fs = require('fs');
const os = require('os');
const path = require('path');

const memory = require(path.join(__dirname, '..', 'payload', 'mcp', 'memory.js'));

function assert(condition, message) {
  if (!condition) throw new Error(`assertion failed: ${message}`);
}

function read(file) {
  return fs.readFileSync(file, 'utf8');
}

function count(text, needle) {
  return text.split(needle).length - 1;
}

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-squad-memory-'));
try {
  for (const name of [
    'MEMORY_DIR', 'LEGACY_MEMORY_DIR', 'LEGACY_MEMORY_DIRS', 'CANONICAL_FILES',
    'TEMPLATES', 'resolveRepoRoot', 'memoryStatus', 'memoryInit'
  ]) {
    assert(typeof memory[name] !== 'undefined', `exports ${name}`);
  }
  assert(memory.MEMORY_DIR === '.muse-squad', 'canonical memory directory is .muse-squad');
  assert(memory.LEGACY_MEMORY_DIR === '.muse/squad', 'legacy directory is .muse/squad');
  assert(memory.LEGACY_MEMORY_DIRS.join(',') === '.muse,.muse/squad',
    'both legacy directories are reported');
  for (const rel of memory.CANONICAL_FILES) {
    assert(rel.startsWith('.muse-squad/'), `canonical path is under .muse-squad: ${rel}`);
    assert(memory.TEMPLATES[rel] !== undefined, `template exists for ${rel}`);
    assert(!rel.includes('..'), `canonical path stays in repo: ${rel}`);
  }

  let missingError = null;
  try {
    memory.resolveRepoRoot(path.join(tempDir, 'does-not-exist'));
  } catch (error) {
    missingError = error;
  }
  assert(missingError && /cannot access repo root/.test(missingError.message),
    'missing repo root is rejected');

  const plainDir = path.join(tempDir, 'plain');
  fs.mkdirSync(plainDir, { recursive: true });
  const plainStatus = memory.memoryStatus(plainDir);
  assert(plainStatus.isGitRepo === false, 'plain directory is not reported as a Git repo');
  assert(plainStatus.warnings.some((item) => item.includes('Not a Git repository')),
    'plain directory warns about repo verification');

  let plainError = null;
  try {
    memory.memoryInit(plainDir);
  } catch (error) {
    plainError = error;
  }
  assert(plainError && /not a Git repository/.test(plainError.message),
    'memory_init refuses to create .muse-squad outside a Git repo');

  const repoRoot = path.join(tempDir, 'repo');
  fs.mkdirSync(path.join(repoRoot, '.git'), { recursive: true });
  fs.mkdirSync(path.join(repoRoot, '.muse', 'history'), { recursive: true });
  fs.mkdirSync(path.join(repoRoot, '.muse', 'squad', 'history'), { recursive: true });
  fs.writeFileSync(path.join(repoRoot, '.gitignore'), '.DS_Store\n.muse-squad/\n.muse/\n');
  fs.writeFileSync(path.join(repoRoot, '.muse', 'PLAN.md'), 'Legacy plan.\n');
  fs.writeFileSync(path.join(repoRoot, '.muse', 'TODO.md'), '- [x] Legacy task.\n');
  fs.writeFileSync(path.join(repoRoot, '.muse', 'decisions.md'), 'Decision from .muse.\n');
  fs.writeFileSync(path.join(repoRoot, '.muse', 'history', 'atlas.md'), 'Learning from .muse.\n');
  fs.writeFileSync(
    path.join(repoRoot, '.muse', 'squad', 'decisions.md'),
    'Decision from legacy squad.\n'
  );
  fs.writeFileSync(
    path.join(repoRoot, '.muse', 'squad', 'history', 'atlas.md'),
    'Learning from legacy squad.\n'
  );
  fs.writeFileSync(
    path.join(repoRoot, '.muse', 'squad', 'history', 'bravo.md'),
    'Unique learning from bravo.\n'
  );

  const before = memory.memoryStatus(repoRoot);
  assert(before.isGitRepo === true, 'status reports the Git repo');
  assert(before.exists === false, 'status reports no canonical layout yet');
  assert(before.memoryDir === '.muse-squad', 'status reports the canonical memory dir');
  assert(before.legacy.present === true && before.legacy.pending === true,
    'status reports unmigrated legacy memory');
  assert(before.legacy.dirs.join(',') === '.muse,.muse/squad', 'status finds both legacy dirs');
  assert(before.legacy.files.length === 7, 'status lists all legacy files');
  assert(before.legacy.mappings.some((item) =>
    item.from === '.muse/PLAN.md' && item.to === '.muse-squad/PLAN.md'),
  'status maps the newer legacy plan');
  assert(before.legacy.mappings.some((item) =>
    item.from === '.muse/squad/history/bravo.md' &&
    item.to === '.muse-squad/history/bravo.md'),
  'status maps older legacy member history');
  assert(before.gitIgnore.blocksMemory === true &&
    before.gitIgnore.blockingLine === '.muse-squad/',
  'status reports the blocking canonical gitignore rule');
  assert(before.gitIgnore.legacyBlockingLine === '.muse/',
    'status reports the legacy gitignore rule separately');
  assert(before.warnings.some((item) => item.includes('Unmigrated')),
    'status warns about unmigrated legacy files');

  const init = memory.memoryInit(repoRoot);
  assert(init.planIncluded === false, 'default memory_init does not create a template plan');
  assert(init.created.includes('.muse-squad/README.md'), 'memory_init creates README');
  assert(init.created.includes('.muse-squad/.gitignore'), 'memory_init creates the inner ignore file');
  assert(init.created.includes('.muse-squad/history/.gitkeep'), 'memory_init creates history marker');
  assert(!init.created.includes('.muse-squad/PLAN.md'), 'memory_init leaves PLAN.md to plan skills');
  assert(init.copied.some((item) =>
    item.from === '.muse/PLAN.md' && item.to === '.muse-squad/PLAN.md'),
  'memory_init preserves an existing legacy plan');
  assert(init.copied.some((item) =>
    item.from === '.muse/TODO.md' && item.to === '.muse-squad/TODO.md'),
  'memory_init seeds TODO from .muse');
  assert(init.copied.some((item) =>
    item.from === '.muse/decisions.md' && item.to === '.muse-squad/decisions.md'),
  'memory_init seeds decisions from .muse');
  assert(init.copied.some((item) =>
    item.from === '.muse/history/atlas.md' && item.to === '.muse-squad/history/atlas.md'),
  'memory_init copies newer member history');
  assert(init.copied.some((item) =>
    item.from === '.muse/squad/history/bravo.md' &&
    item.to === '.muse-squad/history/bravo.md'),
  'memory_init copies older unique member history');
  assert(init.appended.some((item) =>
    item.from === '.muse/squad/decisions.md' && item.to === '.muse-squad/decisions.md'),
  'memory_init appends older decisions');
  assert(init.appended.some((item) =>
    item.from === '.muse/squad/history/atlas.md' &&
    item.to === '.muse-squad/history/atlas.md'),
  'memory_init appends older member history');
  assert(fs.existsSync(path.join(repoRoot, '.muse', 'PLAN.md')), 'legacy plan is left in place');
  assert(fs.existsSync(path.join(repoRoot, '.muse', 'decisions.md')),
    'legacy decisions are left in place');
  assert(fs.existsSync(path.join(repoRoot, '.muse', 'squad', 'decisions.md')),
    'older legacy decisions are left in place');
  assert(fs.existsSync(path.join(repoRoot, '.muse', 'squad', 'history', 'bravo.md')),
    'older legacy history is left in place');

  const decisionsText = read(path.join(repoRoot, '.muse-squad', 'decisions.md'));
  assert(decisionsText.includes('Decision from .muse.'), 'newer decision content was copied');
  assert(decisionsText.includes('Decision from legacy squad.'), 'older decision content was copied');
  assert(decisionsText.includes('<!-- muse-squad migrated from .muse/decisions.md -->'),
    'newer decision copy is marked');
  assert(decisionsText.includes('<!-- muse-squad migrated from .muse/squad/decisions.md -->'),
    'older decision copy is marked');
  const atlasText = read(path.join(repoRoot, '.muse-squad', 'history', 'atlas.md'));
  assert(atlasText.includes('Learning from .muse.'), 'newer history content was copied');
  assert(atlasText.includes('Learning from legacy squad.'), 'older history content was copied');
  assert(read(path.join(repoRoot, '.muse-squad', 'history', 'bravo.md'))
    .includes('Unique learning from bravo.'), 'unique older history was copied');

  const after = memory.memoryStatus(repoRoot);
  assert(after.exists === true, 'status reports the canonical layout');
  assert(after.files['.muse-squad/PLAN.md'] === true, 'status reports the canonical plan');
  assert(after.files['.muse-squad/history/atlas.md'] === true, 'status reports copied history');
  assert(after.files['.muse-squad/history/bravo.md'] === true, 'status reports unique copied history');
  assert(after.legacy.present === true, 'status still sees untouched legacy files');
  assert(after.legacy.pending === false, 'status no longer asks to migrate copied files');
  assert(!after.warnings.some((item) => item.includes('Unmigrated')),
    'status has no stale migration warning');

  const decisionsBeforeAgain = read(path.join(repoRoot, '.muse-squad', 'decisions.md'));
  const again = memory.memoryInit(repoRoot);
  assert(again.copied.length === 0, 'second run copies nothing');
  assert(again.appended.length === 0, 'second run appends nothing');
  assert(read(path.join(repoRoot, '.muse-squad', 'decisions.md')) === decisionsBeforeAgain,
    'second run does not rewrite decisions');
  assert(count(read(path.join(repoRoot, '.muse-squad', 'decisions.md')),
    'muse-squad migrated from .muse/decisions.md') === 1,
  'newer decision marker appears once');
  assert(count(read(path.join(repoRoot, '.muse-squad', 'decisions.md')),
    'muse-squad migrated from .muse/squad/decisions.md') === 1,
  'older decision marker appears once');

  for (const rel of memory.CANONICAL_FILES) {
    const file = path.join(repoRoot, rel);
    if (!fs.existsSync(file)) continue;
    assert(!read(file).includes(repoRoot), `${rel} contains no absolute repo path`);
  }
  assert(read(path.join(repoRoot, '.muse-squad', '.gitignore')).includes('local/'),
    'local scratch is ignored');
  assert(!read(path.join(repoRoot, '.muse-squad', '.gitignore')).includes('squad/'),
    'canonical ignore file does not need a legacy rule');

  const plannedRepo = path.join(tempDir, 'planned-repo');
  fs.mkdirSync(path.join(plannedRepo, '.git'), { recursive: true });
  const planned = memory.memoryInit(plannedRepo, { include_plan: true });
  assert(planned.planIncluded === true, 'include_plan is reported');
  assert(planned.created.includes('.muse-squad/PLAN.md'), 'include_plan creates PLAN.md');
  assert(fs.existsSync(path.join(plannedRepo, '.muse-squad', 'PLAN.md')), 'PLAN.md exists on disk');
  assert(memory.memoryStatus(plannedRepo).files['.muse-squad/PLAN.md'] === true,
    'status reports the plan after creation');

  console.log('MEMORY TESTS PASSED');
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}
