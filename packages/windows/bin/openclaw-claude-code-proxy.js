#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const packageRoot = path.resolve(__dirname, '..');
const args = process.argv.slice(2);
const invokedName = path.basename(process.argv[1] || '');
const defaultCommand = invokedName.includes('uninstall') ? 'uninstall' : null;
const scriptFile = path.join(packageRoot, 'Windows', 'claude-code-proxy.bat');
const cmdExe = process.env.ComSpec || 'cmd.exe';

function printUsage() {
    console.log('@rtedeschi/oc-claude-proxy-windows');
    console.log('');
    console.log('Supported platform: Windows only.');
    console.log('');
    console.log('Usage:');
    console.log('  oc-claude-proxy-windows');
    console.log('  oc-claude-proxy-windows install [port]');
    console.log('  oc-claude-proxy-windows uninstall');
    console.log('  oc-claude-proxy-windows-uninstall');
    console.log('  oc-claude-proxy-windows serve [port]');
    console.log('  oc-claude-proxy-windows help');
}

function exitWithError(message, exitCode = 1) {
    console.error(message);
    process.exit(exitCode);
}

function toCmdArgument(argument) {
    if (!argument) {
        return '""';
    }

    return `"${String(argument).replace(/"/g, '""')}"`;
}

function runCommand(commandArgs, extraEnv = {}) {
    const commandLine = `call "${scriptFile}"${commandArgs.length > 0 ? ` ${commandArgs.map(toCmdArgument).join(' ')}` : ''}`;
    const result = spawnSync(cmdExe, ['/d', '/s', '/c', commandLine], {
        stdio: 'inherit',
        windowsVerbatimArguments: true,
        env: {
            ...process.env,
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

if (process.platform !== 'win32') {
    exitWithError('Only Windows is currently supported by this package.');
}

if (!fs.existsSync(scriptFile)) {
    exitWithError(`Missing installer script: ${scriptFile}`);
}

runCommand(command ? [command, ...args.slice(args[0] ? 1 : 0)] : args);