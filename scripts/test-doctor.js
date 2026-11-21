#!/usr/bin/env node
'use strict';

// Verifies squad-doctor against a temporary config dir and a mock model server.
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const DOCTOR = path.join(ROOT, 'payload', 'mcp', 'doctor.js');
const SYNC = path.join(ROOT, 'payload', 'mcp', 'sync-team.js');
const REGISTER = path.join(ROOT, 'payload', 'mcp', 'register-settings.js');
const TEAM_DEFAULT = path.join(ROOT, 'payload', 'squad-team.default.json');
const SECRET = 'doctor-secret-do-not-leak';

function assert(condition, message) {
  if (!condition) throw new Error(`assertion failed: ${message}`);
}

function expectContains(text, needle, label) {
  assert(text.includes(needle), `${label} contains ${JSON.stringify(needle)}`);
}

function runSync(script, args) {
  return spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });
}

function doctor(args) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [DOCTOR, ...args], { encoding: 'utf8' });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', (status) => resolve({ status, stdout, stderr }));
  });
}

async function expectDoctor(args, ok, needle) {
  const result = await doctor(args);
  const output = `${result.stdout}${result.stderr}`;
  assert(result.status === (ok ? 0 : 1), `doctor exit ${result.status}: ${output}`);
  assert(!output.includes(SECRET), 'doctor output must not leak api keys');
  if (needle) expectContains(output, needle, 'doctor output');
  return result;
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
  const server = http.createServer((request, response) => {
    if (request.url === '/v1/models' || request.url === '/bad/v1/models') {
      const ok = request.url === '/v1/models';
      response.writeHead(ok ? 200 : 500, { 'content-type': 'application/json' });
      response.end(JSON.stringify(ok ? { data: [{ id: 'local-model' }] } : { error: 'boom' }));
      return;
    }
    response.writeHead(404);
    response.end('{}');
  });
  const port = await listen(server);
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-squad-doctor-'));

  try {
    const configDir = path.join(tempDir, 'config');
    const mcpDir = path.join(configDir, 'mcp');
    fs.mkdirSync(mcpDir, { recursive: true });
    fs.copyFileSync(SYNC, path.join(mcpDir, 'sync-team.js'));
    fs.copyFileSync(DOCTOR, path.join(mcpDir, 'doctor.js'));
    fs.copyFileSync(TEAM_DEFAULT, path.join(configDir, 'squad-team.json'));

    const endpointsFile = path.join(configDir, 'endpoints.json');
    const settingsFile = path.join(configDir, 'settings.json');
    const writeEndpoints = (badBase) => fs.writeFileSync(endpointsFile, JSON.stringify({
      default: 'local-ok',
      fallback_order: ['local-ok'],
      endpoints: {
        'local-ok': { base_url: `http://127.0.0.1:${port}/v1`, api_key: SECRET, model: 'ok-model' },
        'local-bad': { base_url: `http://127.0.0.1:${port}${badBase}`, api_key: SECRET, model: 'bad-model' }
      }
    }, null, 2));
    writeEndpoints('/bad');

    const registered = runSync(REGISTER, [
      '--settings', settingsFile,
      '--bridge', path.join(mcpDir, 'bridge.js'),
      '--config-file', endpointsFile
    ]);
    assert(registered.status === 0, `register-settings failed: ${registered.stderr}`);

    const synced = runSync(SYNC, [
      '--config-dir', configDir,
      '--team-file', path.join(configDir, 'squad-team.json'),
      '--endpoints-file', endpointsFile,
      '--project-dir', tempDir
    ]);
    assert(synced.status === 0, `sync-team failed: ${synced.stderr}`);

    const args = ['--config-dir', configDir, '--timeout-ms', '1000'];
    const bad = await expectDoctor(args, false, 'local-bad');
    expectContains(bad.stdout, 'HTTP', 'bad endpoint status');
    expectContains(bad.stdout, '1 problem found', 'bad endpoint summary');

    writeEndpoints('');
    await expectDoctor(args, true, 'all checks passed');

    const jsonResult = await expectDoctor([...args, '--json'], true);
    const report = JSON.parse(jsonResult.stdout);
    assert(report.ok && report.problems === 0, 'JSON report is healthy');
    assert(report.checks.endpoints.length === 2, 'JSON report lists both endpoints');
    assert(!jsonResult.stdout.includes(SECRET), 'JSON report must not leak api keys');

    const goodSettings = fs.readFileSync(settingsFile, 'utf8');
    const settings = JSON.parse(goodSettings);
    delete settings.mcpServers['custom-coder'];
    fs.writeFileSync(settingsFile, JSON.stringify(settings, null, 2));
    await expectDoctor(args, false, 'custom-coder is not registered');
    fs.writeFileSync(settingsFile, goodSettings);

    const wrapper = path.join(configDir, 'agents', 'keaton.md');
    const originalWrapper = fs.readFileSync(wrapper, 'utf8');
    fs.writeFileSync(wrapper, `${originalWrapper}\n// drift\n`);
    await expectDoctor(args, false, '@keaton wrapper out of sync');
    fs.writeFileSync(wrapper, originalWrapper);

    const stale = path.join(configDir, 'agents', 'ghost.md');
    const marker = '<!-- Generated by muse-squad sync-team.js; edit squad-team.json and re-run the installer. -->';
    fs.writeFileSync(stale, `${marker}\n# ghost\n`);
    await expectDoctor(args, false, '@ghost stale generated wrapper');
    fs.unlinkSync(stale);

    await expectDoctor(args, true, 'all checks passed');
    console.log('DOCTOR TESTS PASSED');
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
    await close(server);
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
