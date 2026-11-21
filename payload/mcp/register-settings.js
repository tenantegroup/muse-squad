#!/usr/bin/env node
'use strict';

// Merges the custom-coder MCP entry into Muse Code's settings.json without
// disturbing any other settings or MCP servers.

const fs = require('fs');
const path = require('path');

function option(flag) {
  const index = process.argv.indexOf(flag);
  return index >= 0 && index + 1 < process.argv.length ? process.argv[index + 1] : undefined;
}

const settingsPath = option('--settings');
const bridgePath = option('--bridge');
const configFile = option('--config-file');
const unregister = process.argv.includes('--unregister');

if (!settingsPath) {
  console.error('register-settings.js: --settings is required');
  process.exit(2);
}

function loadSettings() {
  if (!fs.existsSync(settingsPath)) return {};
  const raw = fs.readFileSync(settingsPath, 'utf8');
  if (!raw.trim()) return {};
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('top-level JSON value must be an object');
    }
    return parsed;
  } catch (error) {
    throw new Error(`cannot parse ${settingsPath}: ${error.message}`);
  }
}

function backupSettings() {
  const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
  const backup = `${settingsPath}.bak.${stamp}`;
  fs.copyFileSync(settingsPath, backup);
  return backup;
}

function writeSettings(settings) {
  const dir = path.dirname(settingsPath);
  fs.mkdirSync(dir, { recursive: true });
  const temporary = path.join(dir, `.settings.json.muse-squad-${process.pid}.tmp`);
  fs.writeFileSync(temporary, `${JSON.stringify(settings, null, 2)}\n`, 'utf8');
  fs.renameSync(temporary, settingsPath);
}

function main() {
  const settings = loadSettings();
  if (settings.schema_version === undefined) settings.schema_version = 1;

  const hasServers = settings.mcpServers && typeof settings.mcpServers === 'object' && !Array.isArray(settings.mcpServers);
  if (!hasServers) settings.mcpServers = {};

  // Clean up legacy snake_case key left by older installers.
  const legacy = settings.mcp_servers && typeof settings.mcp_servers === 'object' && !Array.isArray(settings.mcp_servers)
    ? settings.mcp_servers
    : null;

  if (unregister) {
    const removedCurrent = Object.prototype.hasOwnProperty.call(settings.mcpServers, 'custom-coder');
    const removedLegacy = !!(legacy && Object.prototype.hasOwnProperty.call(legacy, 'custom-coder'));
    if (!removedCurrent && !removedLegacy) {
      console.log('  unchanged  custom-coder not registered');
      return;
    }
    if (removedCurrent) delete settings.mcpServers['custom-coder'];
    if (removedLegacy) delete legacy['custom-coder'];
  } else {
    if (!bridgePath || !configFile) {
      console.error('register-settings.js: --bridge and --config-file are required');
      process.exit(2);
    }
    settings.mcpServers['custom-coder'] = {
      transport: 'stdio',
      command: 'node',
      args: [bridgePath],
      env: {
        MODELS_CONFIG_FILE: configFile
      },
      mode: 'optional'
    };
    if (legacy && Object.prototype.hasOwnProperty.call(legacy, 'custom-coder')) {
      delete legacy['custom-coder'];
    }
  }

  // Remove empty legacy container to avoid confusing duplicate config.
  if (legacy && Object.keys(legacy).length === 0) {
    delete settings.mcp_servers;
  }

  const desired = `${JSON.stringify(settings, null, 2)}\n`;
  const current = fs.existsSync(settingsPath) ? fs.readFileSync(settingsPath, 'utf8') : '';
  if (current === desired) {
    console.log('  unchanged  settings.json');
    return;
  }

  if (fs.existsSync(settingsPath)) {
    const backup = backupSettings();
    console.log(`  backed up  ${settingsPath} -> ${backup}`);
  }
  writeSettings(settings);
  console.log(`  ${unregister ? 'unregistered' : 'registered'}  custom-coder in ${settingsPath}`);
}

try {
  main();
} catch (error) {
  console.error(`register-settings.js: ${error.message}`);
  process.exit(1);
}
