#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const packageRoot = path.resolve(__dirname, '..');
const args = process.argv.slice(2);
const invokedName = path.basename(process.argv[1] || '');
const defaultCommand = invokedName.includes('uninstall') ? 'uninstall' : null;
const scriptFile = path.join(packageRoot, 'Ubuntu', 'claude-code-proxy.sh');

function printUsage() {
    console.log('@rtedeschi/oc-claude-proxy-ubuntu');
    console.log('');
    console.log('Supported platform: Ubuntu (Linux) only.');
    console.log('');
    console.log('Usage:');
    console.log('  oc-claude-proxy-ubuntu');
    console.log('  oc-claude-proxy-ubuntu install [port]');
    console.log('  oc-claude-proxy-ubuntu uninstall');
    console.log('  oc-claude-proxy-ubuntu-uninstall');
    console.log('  oc-claude-proxy-ubuntu serve [port]');
    console.log('  oc-claude-proxy-ubuntu start|stop|restart|status');
    console.log('  oc-claude-proxy-ubuntu logs [-f] [lines]');
    console.log('  oc-claude-proxy-ubuntu help');
}

function exitWithError(message, exitCode = 1) {
    console.error(message);
    process.exit(exitCode);
}

function runCommand(commandArgs, extraEnv = {}) {
    const result = spawnSync('bash', [scriptFile, ...commandArgs], {
        stdio: 'inherit',
        env: {
            ...process.env,
            OC_PROXY_SOURCE_PACKAGE_ROOT: packageRoot,
            ...extraEnv
        }
    });

    if (result.error) {
        exitWithError(result.error.message);
    }

    process.exit(result.status == null ? 1 : result.status);
}

const command = args[0] || defaultCommand;

if (command === 'help' || command === '--help' || command === '-h') {
    printUsage();
    process.exit(0);
}

if (process.platform !== 'linux') {
    exitWithError('Only Ubuntu (Linux) is currently supported by this package.');
}

if (!fs.existsSync(scriptFile)) {
    exitWithError(`Missing installer script: ${scriptFile}`);
}

// When invoked via a *-uninstall alias with no explicit command, inject it.
if (defaultCommand && (args.length === 0 || /^[0-9]+$/.test(args[0]))) {
    runCommand([defaultCommand, ...args]);
} else {
    runCommand(args);
}
