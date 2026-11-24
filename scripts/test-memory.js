#!/usr/bin/env node
'use strict';

// Verifies the canonical repository-local .muse/ layout and legacy migration.
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
    'MEMORY_DIR', 'LEGACY_MEMORY_DIR', 'CANONICAL_FILES', 'TEMPLATES',
    'resolveRepoRoot', 'memoryStatus', 'memoryInit'
  ]) {
    assert(typeof memory[name] !== 'undefined', `exports ${name}`);
  }
  assert(memory.MEMORY_DIR === '.muse', 'canonical memory directory is .muse');
  assert(memory.LEGACY_MEMORY_DIR === '.muse/squad', 'legacy directory is .muse/squad');
  for (const rel of memory.CANONICAL_FILES) {
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
    'memory_init refuses to create .muse outside a Git repo');

  const repoRoot = path.join(tempDir, 'repo');
  fs.mkdirSync(path.join(repoRoot, '.git'), { recursive: true });
  fs.mkdirSync(path.join(repoRoot, '.muse', 'squad', 'history'), { recursive: true });
  fs.writeFileSync(path.join(repoRoot, '.gitignore'), '.DS_Store\n.muse/\n');
  fs.writeFileSync(
    path.join(repoRoot, '.muse', 'squad', 'decisions.md'),
    'Legacy architecture decision.\n'
  );
  fs.writeFileSync(
    path.join(repoRoot, '.muse', 'squad', 'history', 'atlas.md'),
    'Legacy member learning.\n'
  );

  const before = memory.memoryStatus(repoRoot);
  assert(before.exists === true, 'status reports an existing .muse directory');
  assert(before.legacy.decisions === '.muse/squad/decisions.md', 'status finds legacy decisions');
  assert(before.legacy.history.join(',') === '.muse/squad/history/atlas.md',
    'status finds legacy history');
  assert(before.gitIgnore.blocksMemory === true &&
    before.gitIgnore.blockingLine === '.muse/',
    'status reports the blocking root gitignore rule');
  assert(before.warnings.some((item) => item.includes('Legacy .muse/squad')),
    'status warns about legacy memory');

  const init = memory.memoryInit(repoRoot);
  assert(init.planIncluded === false, 'default memory_init does not create PLAN.md');
  assert(init.created.includes('.muse/README.md'), 'memory_init creates README');
  assert(init.created.includes('.muse/TODO.md'), 'memory_init creates TODO');
  assert(init.copied.some((item) => item.to === '.muse/decisions.md'),
    'memory_init seeds decisions from legacy memory');
  assert(init.created.includes('.muse/history/.gitkeep'), 'memory_init creates history marker');
  assert(!init.created.includes('.muse/PLAN.md'), 'memory_init leaves PLAN.md to plan skills');
  assert(init.copied.some((item) => item.from === '.muse/squad/decisions.md'),
    'memory_init copies legacy decisions');
  assert(init.copied.some((item) => item.to === '.muse/history/atlas.md'),
    'memory_init copies legacy member history');
  assert(fs.existsSync(path.join(repoRoot, '.muse', 'squad', 'decisions.md')),
    'legacy decisions are left in place');
  assert(fs.existsSync(path.join(repoRoot, '.muse', 'squad', 'history', 'atlas.md')),
    'legacy member history is left in place');

  const decisionsText = read(path.join(repoRoot, '.muse', 'decisions.md'));
  assert(decisionsText.includes('Legacy architecture decision.'), 'legacy decision content was copied');
  assert(decisionsText.includes('<!-- muse-squad migrated from .muse/squad/decisions.md -->'),
    'legacy decision copy is marked');
  const historyText = read(path.join(repoRoot, '.muse', 'history', 'atlas.md'));
  assert(historyText.includes('Legacy member learning.'), 'legacy history content was copied');

  const again = memory.memoryInit(repoRoot);
  assert(again.copied.length === 0, 'second run copies nothing');
  assert(again.appended.length === 0, 'second run appends nothing');
  assert(
    count(read(path.join(repoRoot, '.muse', 'decisions.md')), 'muse-squad migrated from') === 1,
    'second run does not duplicate the migration marker'
  );

  const planned = memory.memoryInit(repoRoot, { include_plan: true });
  assert(planned.planIncluded === true, 'include_plan is reported');
  assert(planned.created.includes('.muse/PLAN.md'), 'include_plan creates PLAN.md');
  assert(fs.existsSync(path.join(repoRoot, '.muse', 'PLAN.md')), 'PLAN.md exists on disk');

  const after = memory.memoryStatus(repoRoot);
  assert(after.files['.muse/PLAN.md'] === true, 'status reports PLAN.md after creation');
  assert(after.files['.muse/history/atlas.md'] === true, 'status reports copied member history');

  for (const rel of memory.CANONICAL_FILES) {
    const file = path.join(repoRoot, rel);
    if (!fs.existsSync(file)) continue;
    assert(!read(file).includes(repoRoot), `${rel} contains no absolute repo path`);
  }
  assert(read(path.join(repoRoot, '.muse', '.gitignore')).includes('local/'),
    'local scratch is ignored');
  assert(read(path.join(repoRoot, '.muse', '.gitignore')).includes('squad/'),
    'legacy directory is ignored');

  console.log('MEMORY TESTS PASSED');
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}
