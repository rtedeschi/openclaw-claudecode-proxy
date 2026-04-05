# openclaw-claudecode-proxy

## Support this project

This project is free and open source. If it saves you time or helps your team, you can support ongoing maintenance and development here:

- GitHub Sponsors: https://github.com/sponsors/rtedeschi

Route Anthropic Messages API requests through the real Claude Code CLI so OpenClaw can use Claude Code with native client attestation.

The proxy now runs in a stateless per-turn mode: each OpenClaw turn is rebuilt from system instructions, a bounded recent-conversation window, and a deterministic memory digest instead of relying on Claude session resume for continuity.

## Supported platforms

Only Ubuntu and Windows are currently supported.

- Ubuntu: supported via `Ubuntu/claude-code-proxy.sh`
- Windows: supported via `Windows/claude-code-proxy.bat`
- Other Linux distributions: not currently supported
- macOS: not currently supported

## What this repo contains

- `Core/claude-code-proxy.js`: Shared Node.js proxy implementation.
- `Ubuntu/claude-code-proxy.sh`: Single Ubuntu entrypoint that installs the proxy, patches `openclaw.json`, installs a user `systemd` service, and runs the proxy in `serve` mode.
- `Windows/claude-code-proxy.bat`: Single Windows entrypoint that installs the proxy, patches `openclaw.json`, registers a startup task, and runs the proxy in `serve` mode.

## Requirements

This repo includes separate entrypoints for Ubuntu and Windows only.

Required tools:

- `claude` CLI installed and authenticated
- `node`
- `openclaw` already installed and initialized

Ubuntu install also requires:

- `jq`
- `systemctl`

Windows install also requires:

- `powershell`
- `schtasks`

Required OpenClaw files:

- `~/.openclaw/openclaw.json`
- `%USERPROFILE%\.openclaw\openclaw.json`

The setup script will stop if `~/.openclaw/openclaw.json` does not exist. If needed, run:

```bash
openclaw wizard
```

The Claude CLI must also be usable before setup:

```bash
claude --version
```

If that fails, run `claude` once and complete authentication first.

## Getting started

Run the installer for your supported operating system.

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

## What the script does

The platform entrypoint in `install` mode performs the following actions:

1. Verifies the required platform tools, `node`, and `claude` are installed.
2. Verifies Claude Code CLI is working.
3. Backs up `openclaw.json` with a timestamp suffix.
4. Copies the platform script and shared JS entrypoint to `~/.openclaw/workspace/scripts/` on Linux or `%USERPROFILE%\.openclaw\workspace\scripts\` on Windows.
5. Adds or updates `models.providers["claude-code-proxy"]` in `openclaw.json`.
6. Adds alias entries for `claude-code-proxy/claude-opus-4-5` and `claude-code-proxy/claude-sonnet-4-5`.
7. Installs persistent startup:
Linux uses a user `systemd` service.
Windows uses a Scheduled Task named `ClaudeCodeProxy`.
8. Starts the background service or task on port `8787` by default.
9. Attempts to restart the OpenClaw gateway.

At runtime, the proxy composes each turn statelessly from:

1. OpenClaw system instructions
2. proxy tool-bridge rules
3. a bounded recent conversation window
4. a deterministic memory digest built from `MEMORY.md` and recent daily memory files
5. the current user message

The script does not automatically change `agents.defaults.model.primary`.
It prints a suggestion to set it to one of the proxy-backed models after install.

## Installed model mapping

After setup, OpenClaw has this proxy provider available:

- Provider: `claude-code-proxy`
- Available model IDs: `claude-code-proxy/claude-opus-4-5` and `claude-code-proxy/claude-sonnet-4-5`

Suggested default model change:

- `agents.defaults.model.primary = claude-code-proxy/claude-opus-4-5`
- or `agents.defaults.model.primary = claude-code-proxy/claude-sonnet-4-5`

The proxy also normalizes these requested model names if they are sent by clients:

- `claude-opus-4-6` -> `claude-opus-4-5`
- `claude-sonnet-4-6` -> `claude-sonnet-4-5`
- `claude-haiku-4-6` -> `claude-haiku-4-5`

## Verify the installation

Check the proxy service:

```bash
systemctl --user status claude-code-proxy.service
```

On Windows, check the startup task:

```bat
schtasks /Query /TN "ClaudeCodeProxy"
```

Restart it manually if needed:

```bash
systemctl --user restart claude-code-proxy.service
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

## Manual run

If you do not want to use the `systemd` service, you can run the proxy directly:

```bash
./Ubuntu/claude-code-proxy.sh serve
```

Or on a custom port:

```bash
./Ubuntu/claude-code-proxy.sh serve 8788
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

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
