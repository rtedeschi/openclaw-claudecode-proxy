#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const packageRoot = path.resolve(__dirname, '..');
const scriptFile = path.join(packageRoot, 'Windows', 'claude-code-proxy.bat');
const cmdExe = process.env.ComSpec || 'cmd.exe';

function exitWithStatus(status) {
    process.exit(status == null ? 1 : status);
}

if (process.env.OC_PROXY_SKIP_POSTINSTALL === '1') {
    process.exit(0);
}

if (process.platform !== 'win32') {
    process.exit(0);
}

if (process.env.npm_config_global !== 'true') {
    process.exit(0);
}

if (!fs.existsSync(scriptFile)) {
    console.error(`Missing installer script: ${scriptFile}`);
    process.exit(1);
}

console.log('Configuring the Claude Code Proxy startup task for Windows...');

const result = spawnSync(cmdExe, ['/d', '/s', '/c', `call "${scriptFile}" install`], {
    stdio: 'inherit',
    windowsVerbatimArguments: true,
    env: {
        ...process.env,
        OC_PROXY_NO_PAUSE: '1'
    }
});

if (result.error) {
    console.error(result.error.message);
    process.exit(1);
}

exitWithStatus(result.status);