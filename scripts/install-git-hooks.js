#!/usr/bin/env node

const path = require('path');
const { spawnSync } = require('child_process');

const repoRoot = path.resolve(__dirname, '..');
const hooksPath = '.githooks';

const result = spawnSync('git', ['config', '--local', 'core.hooksPath', hooksPath], {
    cwd: repoRoot,
    stdio: 'inherit'
});

if (result.error) {
    console.error(result.error.message);
    process.exit(1);
}

process.exit(result.status == null ? 1 : result.status);