#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const packageRoot = path.resolve(__dirname, '..');
const repoRoot = path.resolve(__dirname, '../../..');
const command = process.argv[2];

const syncedPaths = [
    {
        source: path.join(repoRoot, 'Core', 'claude-code-proxy.js'),
        destination: path.join(packageRoot, 'Core', 'claude-code-proxy.js')
    },
    {
        source: path.join(repoRoot, 'Windows', 'claude-code-proxy.bat'),
        destination: path.join(packageRoot, 'Windows', 'claude-code-proxy.bat')
    }
];

function copyFile(sourcePath, destinationPath) {
    fs.mkdirSync(path.dirname(destinationPath), { recursive: true });
    fs.copyFileSync(sourcePath, destinationPath);
}

function removeIfExists(targetPath) {
    fs.rmSync(targetPath, { recursive: true, force: true });
}

if (command === 'sync') {
    for (const entry of syncedPaths) {
        copyFile(entry.source, entry.destination);
    }

    process.exit(0);
}

if (command === 'clean') {
    removeIfExists(path.join(packageRoot, 'Core'));
    removeIfExists(path.join(packageRoot, 'Windows'));
    process.exit(0);
}

console.error('Usage: node scripts/sync-package-files.js <sync|clean>');
process.exit(1);