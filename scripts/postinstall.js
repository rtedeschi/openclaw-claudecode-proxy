#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const packageRoot = path.resolve(__dirname, '..');
const scriptFile = path.join(packageRoot, 'Ubuntu', 'claude-code-proxy.sh');

function parseOsRelease() {
    try {
        const raw = fs.readFileSync('/etc/os-release', 'utf8');
        const values = {};

        for (const line of raw.split(/\r?\n/)) {
            const match = line.match(/^([A-Z0-9_]+)=(.*)$/);
            if (!match) {
                continue;
            }

            values[match[1]] = match[2].replace(/^"|"$/g, '');
        }

        return values;
    } catch (error) {
        return null;
    }
}

function isUbuntu() {
    const osRelease = parseOsRelease();
    if (!osRelease) {
        return false;
    }

    const id = (osRelease.ID || '').toLowerCase();
    const idLike = (osRelease.ID_LIKE || '').toLowerCase().split(' ');
    return id === 'ubuntu' || idLike.includes('ubuntu');
}

if (process.env.OC_PROXY_SKIP_POSTINSTALL === '1') {
    process.exit(0);
}

if (process.platform !== 'linux' || !isUbuntu()) {
    process.exit(0);
}

if (process.env.npm_config_global !== 'true') {
    process.exit(0);
}

if (!fs.existsSync(scriptFile)) {
    console.error(`Missing installer script: ${scriptFile}`);
    process.exit(1);
}

console.log('Configuring the Claude Code Proxy user service for Ubuntu...');

const result = spawnSync('bash', [scriptFile, 'install', '--no-pause'], {
    stdio: 'inherit',
    env: {
        ...process.env,
        OC_PROXY_NO_PAUSE: '1',
        OC_PROXY_SOURCE_PACKAGE_ROOT: packageRoot
    }
});

if (result.error) {
    console.error(result.error.message);
    process.exit(1);
}

process.exit(result.status == null ? 1 : result.status);