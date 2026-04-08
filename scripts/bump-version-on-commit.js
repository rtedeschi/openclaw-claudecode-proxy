#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const repoRoot = path.resolve(__dirname, '..');
const packageJsonPath = path.join(repoRoot, 'package.json');
const windowsPackageJsonPath = path.join(repoRoot, 'packages', 'windows', 'package.json');

function runGit(args, options = {}) {
    const result = spawnSync('git', args, {
        cwd: repoRoot,
        encoding: 'utf8',
        ...options
    });

    if (result.error) {
        throw result.error;
    }

    return result;
}

function parseSemver(version) {
    const match = String(version || '').trim().match(/^(\d+)\.(\d+)\.(\d+)$/);
    if (!match) {
        throw new Error(`Invalid version: ${version}`);
    }

    return {
        major: Number(match[1]),
        minor: Number(match[2]),
        patch: Number(match[3])
    };
}

function formatSemver(version) {
    return `${version.major}.${version.minor}.${version.patch}`;
}

function readJson(filePath) {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function readHeadVersion() {
    const result = runGit(['show', 'HEAD:package.json']);
    if (result.status !== 0) {
        return null;
    }

    return JSON.parse(result.stdout).version;
}

function hasStagedChanges() {
    const result = runGit(['diff', '--cached', '--name-only', '--diff-filter=ACMR']);
    if (result.status !== 0) {
        throw new Error(result.stderr || 'Unable to inspect staged files.');
    }

    return result.stdout
        .split(/\r?\n/)
        .map((entry) => entry.trim())
        .filter(Boolean)
        .length > 0;
}

function shouldSkip() {
    if (process.env.OC_PROXY_SKIP_VERSION_BUMP === '1') {
        return true;
    }

    if (!fs.existsSync(packageJsonPath)) {
        return true;
    }

    return !hasStagedChanges();
}

function computeNextVersion(headVersion, workingVersion) {
    const current = parseSemver(workingVersion);

    if (!headVersion) {
        return current;
    }

    const previous = parseSemver(headVersion);

    if (current.major !== previous.major || current.minor !== previous.minor) {
        return {
            major: current.major,
            minor: current.minor,
            patch: 0
        };
    }

    return {
        major: current.major,
        minor: current.minor,
        patch: current.patch > previous.patch ? current.patch : previous.patch + 1
    };
}

function main() {
    if (shouldSkip()) {
        return;
    }

    const packageJson = readJson(packageJsonPath);
    const nextVersion = computeNextVersion(readHeadVersion(), packageJson.version);
    const normalizedVersion = formatSemver(nextVersion);

    if (packageJson.version === normalizedVersion) {
        return;
    }

    packageJson.version = normalizedVersion;
    fs.writeFileSync(packageJsonPath, `${JSON.stringify(packageJson, null, 2)}\n`);

    if (fs.existsSync(windowsPackageJsonPath)) {
        const windowsPackageJson = readJson(windowsPackageJsonPath);
        windowsPackageJson.version = normalizedVersion;
        fs.writeFileSync(windowsPackageJsonPath, `${JSON.stringify(windowsPackageJson, null, 2)}\n`);
    }

    const filesToAdd = ['package.json'];

    if (fs.existsSync(windowsPackageJsonPath)) {
        filesToAdd.push(path.relative(repoRoot, windowsPackageJsonPath));
    }

    const addResult = runGit(['add', ...filesToAdd]);
    if (addResult.status !== 0) {
        throw new Error(addResult.stderr || 'Unable to stage package manifests.');
    }

    process.stdout.write(`Updated package manifests to ${normalizedVersion}\n`);
}

try {
    main();
} catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
}