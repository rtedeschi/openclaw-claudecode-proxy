# openclaw-claudecode-proxy

## About

This project routes Anthropic Messages API requests through the real Claude Code CLI so OpenClaw can use Claude Code with native client attestation.

It is not a perfect solution. It is a pragmatic bridge to avoid losing months of OpenClaw work while keeping that workflow usable.

The proxy now runs in a stateless per-turn mode: each OpenClaw turn is rebuilt from system instructions, a bounded recent-conversation window, and a deterministic memory digest instead of relying on Claude session resume for continuity.

## Supported platforms

Published npm packages target Ubuntu and Windows separately.

- Ubuntu: published as `@rtedeschi/oc-claude-proxy-ubuntu`
- Windows: published as `@rtedeschi/oc-claude-proxy-windows`
- Other Linux distributions: not currently supported
- macOS: not currently supported

## What this repo contains

- `Core/claude-code-proxy.js`: Shared Node.js proxy implementation.
- `Ubuntu/claude-code-proxy.sh`: Ubuntu service manager for install, uninstall, status, logs, and foreground serve.
- `Windows/claude-code-proxy.bat`: Windows installer and startup-task runner kept in the repo for manual use.

## Requirements

This repo includes separate Ubuntu and Windows entrypoints, and each supported platform has its own npm package.

Required tools:

- `claude` CLI installed and authenticated
- `node`
- `openclaw` already installed and initialized

Ubuntu install also requires:

- `jq`
- `systemctl`
- `journalctl`

Windows install also requires:

- `powershell`
- `schtasks`

Required OpenClaw files:

- Ubuntu: current user `~/.openclaw/openclaw.json` or root `/root/.openclaw/openclaw.json`
- Windows: `%USERPROFILE%\.openclaw\openclaw.json`

On Ubuntu, the setup script resolves the target installation in this order:

1. the invoking user's `~/.openclaw/openclaw.json`
2. root's `/root/.openclaw/openclaw.json`
3. fail if neither exists

This matters for global `npm install -g` runs under `sudo`: the script now prefers the calling user's OpenClaw install before falling back to root.

The setup script will stop if neither Ubuntu path exists. If needed, run:

```bash
openclaw wizard
```

The Claude CLI must also be usable before setup:

```bash
claude --version
```

If that fails, run `claude` once and complete authentication first.

## Getting started

### Install from npm

Install Ubuntu globally:

```bash
npm install -g @rtedeschi/oc-claude-proxy-ubuntu
```

Install Windows globally:

```powershell
npm install -g @rtedeschi/oc-claude-proxy-windows
```

### Install from GitHub Packages

GitHub Packages requires scoped registry configuration for install.

Add this to `~/.npmrc`:

```ini
@rtedeschi:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=YOUR_GITHUB_PAT
```

The token needs at least `read:packages`.

Install Ubuntu globally from GitHub Packages:

```bash
npm install -g @rtedeschi/oc-claude-proxy-ubuntu
```

Install Windows globally from GitHub Packages:

```powershell
npm install -g @rtedeschi/oc-claude-proxy-windows
```

If your npm client is still resolving the package from `registry.npmjs.org`, use an explicit registry override:

```bash
npm install -g @rtedeschi/oc-claude-proxy-ubuntu --registry=https://npm.pkg.github.com
```

```powershell
npm install -g @rtedeschi/oc-claude-proxy-windows --registry=https://npm.pkg.github.com
```

`publishConfig.registry` controls where this package is published, but it does not force other machines to install from GitHub Packages. Install clients still need either the scoped `~/.npmrc` entry or the explicit `--registry` flag.

On Ubuntu global installs, the package `postinstall` hook immediately:

1. resolves whether to target the invoking user's OpenClaw install or root's
2. installs the proxy files into that OpenClaw workspace's `scripts/` directory
3. patches that installation's `openclaw.json`
4. installs the matching user `systemd` service
5. starts the background daemon right away

On Windows global installs, the package `postinstall` hook immediately:

1. installs the proxy files into `%USERPROFILE%\.openclaw\workspace\scripts\`
2. patches `%USERPROFILE%\.openclaw\openclaw.json`
3. registers the `ClaudeCodeProxy` Scheduled Task
4. starts the task right away

If you want a non-default Ubuntu port:

```bash
oc-claude-proxy-ubuntu install 8788
```

If you want a non-default Windows port:

```powershell
oc-claude-proxy-windows install 8788
```

The Ubuntu package exposes these CLI names:

- `oc-claude-proxy-ubuntu`
- `openclaw-claude-code-proxy`
- `oc-claude-proxy-ubuntu-uninstall`
- `openclaw-claude-code-proxy-uninstall`

The Windows package exposes these CLI names:

- `oc-claude-proxy-windows`
- `openclaw-claude-code-proxy-windows`
- `oc-claude-proxy-windows-uninstall`
- `openclaw-claude-code-proxy-windows-uninstall`

With no arguments, the Ubuntu CLI prints current status. With no arguments, the Windows CLI runs the installer.

### Manual installers

If you prefer not to use npm, run the platform installer directly.

### Ubuntu

From this repository:

```bash
chmod +x Ubuntu/claude-code-proxy.sh
./Ubuntu/claude-code-proxy.sh
```

To use a different local port:

```bash
./Ubuntu/claude-code-proxy.sh install 8788
```

### Windows

From this repository in an Administrator `cmd.exe` or elevated PowerShell:

```bat
Windows\claude-code-proxy.bat
```

To use a different local port:

```bat
Windows\claude-code-proxy.bat install 8788
```

On Windows, run the installer elevated. The batch script updates `%USERPROFILE%\.openclaw\openclaw.json`, copies runtime files into the OpenClaw workspace, and registers a startup Scheduled Task.

The Windows npm package lives in `packages/windows/` in this repository and is meant to be published separately as `@rtedeschi/oc-claude-proxy-windows`.

## What the script does

The Ubuntu entrypoint in `install` mode performs the following actions:

1. Verifies the required platform tools, `node`, and `claude` are installed.
2. Verifies Claude Code CLI is working.
3. Backs up `openclaw.json` with a timestamp suffix.
4. Resolves the target OpenClaw installation on Ubuntu by checking the invoking user's `~/.openclaw/openclaw.json` first and `/root/.openclaw/openclaw.json` second.
5. Copies the platform script and shared JS entrypoint to the target OpenClaw workspace on Linux or `%USERPROFILE%\.openclaw\workspace\scripts\` on Windows.
6. Adds or updates `models.providers["claude-code-proxy"]` in `openclaw.json`.
7. Sets `agents.defaults.timeoutSeconds = 900` and `agents.defaults.llm.idleTimeoutSeconds = 900` so OpenClaw matches the proxy request timeout and idle timeout.
8. Adds alias entries for `claude-code-proxy/claude-opus-4-5` and `claude-code-proxy/claude-sonnet-4-5`.
9. Installs persistent startup.
Ubuntu uses a user `systemd` service.
Windows uses a Scheduled Task named `ClaudeCodeProxy`.
10. Starts the background service or task on port `8787` by default.
11. Attempts to restart the OpenClaw gateway.

At runtime, the proxy composes each turn statelessly from:

1. OpenClaw system instructions
2. proxy tool-bridge rules
3. a bounded recent conversation window
4. a deterministic memory digest built from `MEMORY.md` and recent daily memory files
5. the current user message

The script does not automatically change `agents.defaults.model.primary`.
It prints a suggestion to set it to one of the proxy-backed models after install.
It does set `agents.defaults.timeoutSeconds` to `900` and `agents.defaults.llm.idleTimeoutSeconds` to `900` so OpenClaw's timeout settings match the proxy request timeout and idle timeout.

## Installed model mapping

After setup, OpenClaw has this proxy provider available:

- Provider: `claude-code-proxy`
- Available model IDs:
  - `claude-code-proxy/claude-opus-4-7` (alias: `popus`)
  - `claude-code-proxy/claude-opus-4-6`
  - `claude-code-proxy/claude-opus-4-5`
  - `claude-code-proxy/claude-sonnet-4-6` (alias: `psonnet`)
  - `claude-code-proxy/claude-sonnet-4-5`

(The `p` prefix on the aliases stands for "proxy" and keeps them from
colliding with OpenClaw's built-in `opus`/`sonnet` aliases that point
at direct-API Anthropic models.)

Suggested default model:

- `agents.defaults.model.primary = claude-code-proxy/claude-opus-4-7`

Exact version IDs are passed through unchanged to Claude Code. If a client
asks for a version Claude Code doesn't support, the CLI will error
explicitly rather than silently rewriting the request.

### Tuning knobs

These environment variables adjust proxy behavior without a reinstall:

| Variable | Default | Meaning |
|----------|---------|---------|
| `OC_PROXY_MAX_CONTEXT_MESSAGES` | 30 | How many prior messages to include |
| `OC_PROXY_MAX_CONTEXT_CHARS_PER_MESSAGE` | 6000 | Per-message truncation |
| `OC_PROXY_MAX_MEMORY_EXCERPT_CHARS` | 20000 | `MEMORY.md` excerpt size |
| `OC_PROXY_MAX_DAILY_EXCERPT_CHARS` | 8000 | Today's daily-note excerpt size |
| `OC_PROXY_MAX_RECENT_MEMORY_FILES` | 5 | How many recent daily notes to mention |
| `OC_PROXY_JITTER_MIN_MS` | 200 | Minimum random delay between spawns |
| `OC_PROXY_JITTER_MAX_MS` | 1200 | Maximum random delay between spawns |
| `OC_PROXY_MIN_SPACING_MS` | 800 | Minimum spacing between consecutive spawns |

Set jitter/spacing to 0 to disable human-pacing behavior.

## Verify the installation

Check the proxy service:

```bash
oc-claude-proxy-ubuntu status
```

Follow logs:

```bash
oc-claude-proxy-ubuntu logs -f
```

On Windows, check the startup task:

```bat
schtasks /Query /TN "ClaudeCodeProxy"
```

Restart it manually if needed:

```bash
oc-claude-proxy-ubuntu restart
```

On Windows, start it manually if needed:

```bat
schtasks /Run /TN "ClaudeCodeProxy"
```

Restart OpenClaw if it did not restart automatically:

```bash
openclaw gateway restart
```

The proxy listens at:

```text
http://localhost:8787
```

If you used a custom `PROXY_PORT`, substitute that value.

The proxy request timeout is explicitly set to `900` seconds by default, and the installers write the same value to `agents.defaults.timeoutSeconds` and `agents.defaults.llm.idleTimeoutSeconds`.

## Uninstall and cleanup

For immediate, synchronous cleanup:

```bash
oc-claude-proxy-ubuntu uninstall
oc-claude-proxy-ubuntu-uninstall
```

On Windows:

```powershell
oc-claude-proxy-windows uninstall
oc-claude-proxy-windows-uninstall
```

The same cleanup can always be run through the installed script copy:

```bash
~/.openclaw/workspace/scripts/claude-code-proxy.sh uninstall
```

On Windows, the installed script copy can also be used directly:

```bat
%USERPROFILE%\.openclaw\workspace\scripts\claude-code-proxy.bat uninstall
```

After manual cleanup completes, remove the npm package if you no longer want the CLI installed:

```bash
npm uninstall -g @rtedeschi/oc-claude-proxy-ubuntu
```

```powershell
npm uninstall -g @rtedeschi/oc-claude-proxy-windows
```

## Manual run

If you do not want to use the `systemd` service, you can run the proxy directly:

```bash
oc-claude-proxy-ubuntu serve
```

Or on a custom port:

```bash
oc-claude-proxy-ubuntu serve 8788
```

On Windows, run the proxy directly:

```bat
Windows\claude-code-proxy.bat serve
```

Or on a custom port:

```bat
Windows\claude-code-proxy.bat serve 8788
```

The service uses the same script in `serve` mode, so install and runtime now share a single entrypoint.

## Notes

- The proxy only handles `POST /v1/messages`.
- The proxy no longer depends on Claude `session_id` resume for ordinary continuity; it rebuilds each turn from recent context plus memory digest.
- Session state is stored in the system temp directory as `claude-code-proxy-state.json`.
- Debug logs are written to the system temp directory as `claude-code-proxy-debug.log`.
- The proxy limits Claude Code tool access to a restricted allowlist suitable for this bridge.

## Publishing

The repository includes [`.github/workflows/publish-github-package.yml`](.github/workflows/publish-github-package.yml), which:

1. runs `npm pack` on pull requests and pushes to `main`
2. uploads the generated tarball as a workflow artifact
3. publishes to GitHub Packages on `v*` tags or manual workflow dispatch using `GITHUB_TOKEN`

The package name published to GitHub Packages is `@rtedeschi/oc-claude-proxy-ubuntu`.

## Development

This repository installs a tracked Git `pre-commit` hook from [`.githooks/pre-commit`](/home/aera/.openclaw/workspace/FluxTrade/openclaw-claudecode-proxy/.githooks/pre-commit).

The hook updates [package.json](/home/aera/.openclaw/workspace/FluxTrade/openclaw-claudecode-proxy/package.json) on each commit:

1. normal commits bump the patch version
2. if you manually change major or minor, the patch component is reset to `0`

To re-install the hook path in a fresh clone:

```bash
npm run setup-hooks
```

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
