# openclaw-claudecode-proxy

Route Anthropic Messages API requests through the real Claude Code CLI so OpenClaw can use Claude Code with native client attestation.

## What this repo contains

- `Core/claude-code-proxy.js`: Shared Node.js proxy implementation.
- `Ubuntu/claude-code-proxy.sh`: Single Linux entrypoint that installs the proxy, patches `openclaw.json`, installs a user `systemd` service, and runs the proxy in `serve` mode.

## Requirements

This setup assumes a Linux machine using the Ubuntu-oriented script in this repo.

Required tools:

- `claude` CLI installed and authenticated
- `node`
- `jq`
- `systemctl` for automatic background startup as a user service
- `openclaw` already installed and initialized

Required OpenClaw files:

- `~/.openclaw/openclaw.json`

The setup script will stop if `~/.openclaw/openclaw.json` does not exist. If needed, run:

```bash
openclaw wizard
```

The Claude CLI must also be usable before setup:

```bash
claude --version
```

If that fails, run `claude` once and complete authentication first.

## Installation

From this repository:

```bash
chmod +x Ubuntu/claude-code-proxy.sh
./Ubuntu/claude-code-proxy.sh
```

To use a different local port:

```bash
./Ubuntu/claude-code-proxy.sh install 8788
```

## What the script does

`Ubuntu/claude-code-proxy.sh` in `install` mode performs the following actions:

1. Verifies `jq`, `node`, and `claude` are installed.
2. Verifies Claude Code CLI is working.
3. Verifies `systemctl` is available for a persistent user service.
4. Backs up `~/.openclaw/openclaw.json` with a timestamp suffix.
5. Copies the script and shared JS entrypoint to `~/.openclaw/workspace/scripts/`.
6. Adds or updates `models.providers["claude-code-proxy"]` in `~/.openclaw/openclaw.json`.
7. Adds alias entries for `claude-code-proxy/claude-opus-4-5` and `claude-code-proxy/claude-sonnet-4-5`.
8. Installs a user `systemd` service at `~/.config/systemd/user/claude-code-proxy.service`.
9. Enables and starts that service on port `8787` by default.
10. Attempts to restart the OpenClaw gateway.

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

Restart it manually if needed:

```bash
systemctl --user restart claude-code-proxy.service
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

The service uses the same script in `serve` mode, so install and runtime now share a single entrypoint.

## Notes

- The proxy only handles `POST /v1/messages`.
- Session state is stored in `/tmp/claude-code-proxy-state.json`.
- Debug logs are written to `/tmp/claude-code-proxy-debug.log`.
- The proxy limits Claude Code tool access to a restricted allowlist suitable for this bridge.
