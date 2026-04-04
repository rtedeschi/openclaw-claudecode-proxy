# openclaw-claudecode-proxy

Route Anthropic Messages API requests through the real Claude Code CLI so OpenClaw can use Claude Code with native client attestation.

## What this repo contains

- `Ubuntu/claude-code-proxy.sh`: Starts a local HTTP proxy on port `8787` by default.
- `Ubuntu/claude-code-proxy-setup.sh`: Installs the proxy into `~/.openclaw`, registers a user `systemd` service, and patches OpenClaw config to use the proxy provider.

## Requirements

This setup assumes a Linux machine using the Ubuntu-oriented scripts in this repo.

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
cd Ubuntu
chmod +x claude-code-proxy.sh claude-code-proxy-setup.sh
./claude-code-proxy-setup.sh
```

To use a different local port:

```bash
cd Ubuntu
PROXY_PORT=8788 ./claude-code-proxy-setup.sh
```

## What the setup script does

`Ubuntu/claude-code-proxy-setup.sh` performs the following actions:

1. Verifies `jq`, `node`, and `claude` are installed.
2. Verifies Claude Code CLI is working.
3. Backs up existing OpenClaw config files with a timestamp suffix.
4. Copies the proxy script to `~/.openclaw/workspace/scripts/claude-code-proxy.sh`.
5. Installs a user `systemd` service at `~/.config/systemd/user/claude-code-proxy.service`.
6. Enables and starts that service when possible.
7. Patches `~/.openclaw/openclaw.json` to add a `claude-code` provider pointing at `http://localhost:<port>`.
8. Patches `~/.openclaw/agents/main/agent/models.json` to register the same provider at runtime.
9. Attempts to restart the OpenClaw gateway.

## Installed model mapping

After setup, OpenClaw is configured to use:

- Primary: `claude-code/claude-opus-4-5`
- Fallback: `claude-code/claude-sonnet-4-5`

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
cd Ubuntu
./claude-code-proxy.sh
```

Or on a custom port:

```bash
cd Ubuntu
./claude-code-proxy.sh 8788
```

## Notes

- The proxy only handles `POST /v1/messages`.
- Session state is stored in `/tmp/claude-code-proxy-state.json`.
- Debug logs are written to `/tmp/claude-code-proxy-debug.log`.
- The proxy limits Claude Code tool access to a restricted allowlist suitable for this bridge.
