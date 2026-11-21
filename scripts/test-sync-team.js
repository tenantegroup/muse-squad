#!/usr/bin/env node
'use strict';

// Verifies the persistent team materializer against a temporary config dir.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const SYNC = path.join(ROOT, 'payload', 'mcp', 'sync-team.js');
const TEAM_DEFAULT = path.join(ROOT, 'payload', 'squad-team.default.json');

function assert(condition, message) {
  if (!condition) throw new Error(`assertion failed: ${message}`);
}

function run(args) {
  const result = spawnSync(process.execPath, [SYNC, ...args], { encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(`sync-team exited ${result.status}: ${result.stderr || result.stdout}`);
  }
  return result.stdout;
}

function frontmatter(file) {
  const content = fs.readFileSync(file, 'utf8');
  const parts = content.split('---');
  assert(parts.length >= 3, `${file} has YAML frontmatter`);
  const lines = parts[1].split('\n').filter(Boolean);
  const result = {};
  for (const line of lines) {
    const match = line.match(/^([a-z_]+):\s*(.+)$/);
    if (match) result[match[1]] = match[2].replace(/^"|"$/g, '');
  }
  return { content, fields: result };
}

function expectContains(text, needle, label) {
  assert(text.includes(needle), `${label} contains ${JSON.stringify(needle)}`);
}

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-squad-team-'));
try {
  const configDir = path.join(tempDir, 'config');
  const teamFile = path.join(configDir, 'squad-team.json');
  const endpointsFile = path.join(configDir, 'endpoints.json');
  fs.mkdirSync(path.join(configDir, 'agents'), { recursive: true });
  fs.mkdirSync(path.join(configDir, 'mcp'), { recursive: true });
  fs.copyFileSync(TEAM_DEFAULT, teamFile);
  fs.writeFileSync(endpointsFile, JSON.stringify({
    default: 'local-coder',
    fallback_order: ['local-coder', 'grill-reviewer'],
    endpoints: {
      'local-coder': { base_url: 'http://127.0.0.1:1/v1', api_key: 'k', model: 'local-model' },
      'grill-reviewer': { base_url: 'http://127.0.0.1:1/v1', api_key: 'k', model: 'grill-model' }
    }
  }, null, 2));
  const genericAgent = path.join(configDir, 'agents', 'worker.md');
  fs.writeFileSync(genericAgent, 'generic worker sentinel\n');

  const baseArgs = [
    '--config-dir', configDir,
    '--team-file', teamFile,
    '--endpoints-file', endpointsFile,
    '--project-name', 'baseline-project'
  ];
  const first = run(baseArgs);
  expectContains(first, '5 members', 'first run output');

  const roster = fs.readFileSync(path.join(configDir, 'squad', 'team.md'), 'utf8');
  expectContains(roster, '# Copilot Squad', 'team.md');
  expectContains(roster, '| @name | Role | Primary | Backup | Scope |', 'team.md');
  for (const [name, role] of [
    ['keaton', 'Lead'], ['fenster', 'Frontend'], ['mcmanus', 'Backend'],
    ['hockney', 'Tester'], ['verbal', 'Scribe']
  ]) {
    expectContains(roster, `| @${name} | ${role} |`, `team.md row @${name}`);
  }
  expectContains(roster, '`local-coder` (custom-coder)', 'team.md endpoint classification');
  expectContains(roster, '`muse-spark-1.3-contributor` (native)', 'team.md native classification');
  expectContains(roster, '.muse/squad/decisions.md', 'team.md memory path');
  expectContains(roster, '.muse/squad/history/<name>.md', 'team.md history path');

  const keaton = frontmatter(path.join(configDir, 'agents', 'keaton.md'));
  expectContains(keaton.content, 'name: keaton', 'keaton frontmatter');
  assert(keaton.fields.model === 'muse-spark-1.3-contributor', 'keaton pins native primary');
  expectContains(keaton.content, '`grill-reviewer`', 'keaton custom backup');
  expectContains(keaton.content, 'fallback_endpoint="grill-reviewer"', 'keaton restricted fallback');
  expectContains(keaton.content, 'quota, rate-limit, or subscription error', 'keaton native quota fallback trigger');
  expectContains(
    keaton.content,
    'the orchestrator must retry the same step through `custom-coder` using backup `grill-reviewer`',
    'keaton orchestrator retry instruction'
  );
  expectContains(keaton.content, '## Charter', 'keaton charter');
  expectContains(keaton.content, '.muse/squad/history/keaton.md', 'keaton history');
  expectContains(keaton.content, '[Keaton (Lead) | muse-spark-1.3-contributor]', 'keaton TUI label');

  const fenster = frontmatter(path.join(configDir, 'agents', 'fenster.md'));
  assert(fenster.fields.model === 'muse-ember-1.0', 'custom-primary uses lightweight runner');
  expectContains(fenster.content, 'endpoint="local-coder"', 'fenster primary endpoint');
  expectContains(fenster.content, 'fallback_endpoint=""', 'fenster native backup disables MCP fallback');
  expectContains(fenster.content, 'native Muse model', 'fenster notes native backup');

  const mcmanus = frontmatter(path.join(configDir, 'agents', 'mcmanus.md'));
  assert(mcmanus.fields.model === 'muse-ember-1.0', 'mcmanus uses runner model');
  expectContains(mcmanus.content, 'endpoint="local-coder"', 'mcmanus primary endpoint');
  expectContains(mcmanus.content, 'fallback_endpoint="grill-reviewer"', 'mcmanus custom backup');

  const hockney = frontmatter(path.join(configDir, 'agents', 'hockney.md'));
  expectContains(hockney.content, 'endpoint="local-coder"', 'hockney primary endpoint');
  expectContains(hockney.content, 'fallback_endpoint=""', 'hockney native backup');

  const verbal = frontmatter(path.join(configDir, 'agents', 'verbal.md'));
  assert(verbal.fields.model === 'muse-ember-1.0', 'verbal pins native primary');
  expectContains(verbal.content, '`local-coder`', 'verbal custom backup');
  expectContains(
    verbal.content,
    'the orchestrator must retry the same step through `custom-coder` using backup `local-coder`',
    'verbal orchestrator retry instruction'
  );
  expectContains(verbal.content, '[Verbal (Scribe) | muse-ember-1.0]', 'verbal TUI label');

  assert(
    fs.readFileSync(genericAgent, 'utf8') === 'generic worker sentinel\n',
    'generic worker.md is left untouched'
  );

  const second = run(baseArgs);
  expectContains(second, 'unchanged', 'second run is idempotent');
  assert(!/generated|updated/.test(second), 'second run regenerated nothing');

  const team = JSON.parse(fs.readFileSync(teamFile, 'utf8'));
  team.projects['override-project'] = {
    team_name: 'Override Squad',
    members: { fenster: { primary: 'grill-reviewer' } }
  };
  fs.writeFileSync(teamFile, JSON.stringify(team, null, 2));
  const repoDir = path.join(tempDir, 'my-api');
  fs.mkdirSync(repoDir, { recursive: true });
  const overrideArgs = [
    '--config-dir', configDir,
    '--team-file', teamFile,
    '--endpoints-file', endpointsFile,
    '--project-name', 'override-project',
    '--project-dir', repoDir
  ];
  const globalRosterBefore = fs.readFileSync(path.join(configDir, 'squad', 'team.md'), 'utf8');
  const globalFensterBefore = fs.readFileSync(path.join(configDir, 'agents', 'fenster.md'), 'utf8');

  const overridden = run(overrideArgs);
  expectContains(overridden, 'project override override-project', 'project override output');
  expectContains(overridden, 'generated', 'project override generated a wrapper');
  assert(
    fs.readFileSync(path.join(configDir, 'squad', 'team.md'), 'utf8') === globalRosterBefore,
    'project override does not change the global roster'
  );
  assert(
    fs.readFileSync(path.join(configDir, 'agents', 'fenster.md'), 'utf8') === globalFensterBefore,
    'project override does not change the global wrapper'
  );
  expectContains(globalRosterBefore, '# Copilot Squad', 'global roster still uses the base team');

  const projectRosterPath = path.join(repoDir, '.agents', 'squad', 'team.md');
  const projectRoster = fs.readFileSync(projectRosterPath, 'utf8');
  expectContains(projectRoster, '# Override Squad', 'project team_name override');
  expectContains(projectRoster, 'Project override: `override-project`', 'project roster note');
  expectContains(projectRoster, '`grill-reviewer` (custom-coder)', 'project roster model classification');

  const projectFenster = frontmatter(path.join(repoDir, '.agents', 'agents', 'fenster.md'));
  expectContains(projectFenster.content, 'endpoint="grill-reviewer"', 'project primary override');
  assert(!projectFenster.content.includes('endpoint="local-coder"'), 'old primary override is gone');
  assert(projectFenster.fields.model === 'muse-ember-1.0', 'project endpoint override stays a runner');
  expectContains(
    projectFenster.content,
    'Muse loads this project definition before the global user agent.',
    'project wrapper precedence note'
  );
  assert(
    !fs.existsSync(path.join(repoDir, '.agents', 'agents', 'keaton.md')),
    'unmodified members keep using the global wrapper'
  );

  delete team.projects['override-project'].members;
  fs.writeFileSync(teamFile, JSON.stringify(team, null, 2));
  const cleared = run(overrideArgs);
  expectContains(cleared, 'removed', 'stale project wrapper cleanup');
  assert(!fs.existsSync(path.join(repoDir, '.agents', 'agents', 'fenster.md')), 'stale project wrapper removed');
  expectContains(fs.readFileSync(projectRosterPath, 'utf8'), '# Override Squad', 'project roster kept for team_name override');
  assert(
    fs.readFileSync(path.join(configDir, 'agents', 'fenster.md'), 'utf8') === globalFensterBefore,
    'global wrapper is still base-only after clearing the patch'
  );

  team.projects['override-project'].members = { fenster: { primary: 'grill-reviewer' } };
  fs.writeFileSync(teamFile, JSON.stringify(team, null, 2));
  run(overrideArgs);
  assert(fs.existsSync(path.join(repoDir, '.agents', 'agents', 'fenster.md')), 'project wrapper recreated');

  const removed = run([...baseArgs, '--uninstall', '--project-dir', repoDir]);
  expectContains(removed, 'removed', 'uninstall reports removals');
  for (const name of ['keaton', 'fenster', 'mcmanus', 'hockney', 'verbal']) {
    assert(!fs.existsSync(path.join(configDir, 'agents', `${name}.md`)), `removed @${name} wrapper`);
  }
  assert(!fs.existsSync(path.join(configDir, 'squad', 'team.md')), 'removed team.md');
  assert(!fs.existsSync(path.join(repoDir, '.agents', 'agents', 'fenster.md')), 'removed project wrapper');
  assert(!fs.existsSync(projectRosterPath), 'removed project roster');
  assert(
    fs.readFileSync(genericAgent, 'utf8') === 'generic worker sentinel\n',
    'uninstall keeps generic worker.md'
  );

  // Custom roles and marker-based cleanup survive a deleted roster file.
  const customTeam = JSON.parse(fs.readFileSync(TEAM_DEFAULT, 'utf8'));
  customTeam.members = [{
    name: 'vaughn',
    display_name: 'Vaughn',
    role: 'Security',
    responsibility: 'Security reviews and risky-diff audits',
    primary: 'local-coder',
    backup: 'grill-reviewer',
    charter: 'Review risky diffs and name concrete failure modes.'
  }];
  customTeam.projects = {};
  fs.writeFileSync(teamFile, JSON.stringify(customTeam, null, 2));
  const customRun = run(baseArgs);
  expectContains(customRun, '1 members', 'custom roster run');
  const vaughn = frontmatter(path.join(configDir, 'agents', 'vaughn.md'));
  expectContains(vaughn.content, '[Vaughn (Security) | local-coder]', 'custom role label');
  expectContains(vaughn.content, 'Review risky diffs', 'custom charter');

  fs.unlinkSync(teamFile);
  const markerUninstall = run([...baseArgs, '--uninstall']);
  expectContains(markerUninstall, 'removed', 'marker-based uninstall reports removals');
  assert(!fs.existsSync(path.join(configDir, 'agents', 'vaughn.md')), 'custom wrapper removed without a roster');
  assert(
    fs.readFileSync(genericAgent, 'utf8') === 'generic worker sentinel\n',
    'marker-based uninstall keeps generic agents'
  );

  const missing = spawnSync(process.execPath, [SYNC, '--team-file', path.join(tempDir, 'absent.json')], {
    encoding: 'utf8'
  });
  assert(missing.status !== 0, 'missing team file is an error');
  expectContains(missing.stderr, 'not found', 'missing team file error is clear');

  console.log('SYNC TEAM TESTS PASSED');
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}
