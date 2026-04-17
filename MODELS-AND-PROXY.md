# Model switching and proxy control

Practical operator guide for OpenClaw users running the Claude Code proxy on Ubuntu.

This is the file you want open when something feels wrong and you need to switch models or turn the proxy off fast.

## Quick reference

| Want to... | Command |
|-----------|---------|
| See what models are configured | `openclaw models list` |
| See which model this session uses | `openclaw models status` (or `/status` in TUI) |
| Change model for THIS session only | `/model <alias-or-id>` in TUI |
| Change default model going forward | `openclaw models set <id>` |
| Create/manage model aliases | `openclaw models aliases --help` |
| Stop the proxy (keep config) | `oc-claude-proxy-ubuntu stop` |
| Start it again | `oc-claude-proxy-ubuntu start` |
| See proxy status | `oc-claude-proxy-ubuntu status` |
| Follow proxy logs | `oc-claude-proxy-ubuntu logs -f` |
| Uninstall proxy cleanly | `oc-claude-proxy-ubuntu uninstall` |

## Model switching (no proxy changes needed)

OpenClaw's model system is provider-agnostic. The proxy is just another provider. You switch between providers the same way you always have.

### List what you have

```bash
openclaw models list
```

Shows everything configured in `~/.openclaw/openclaw.json` under `agents.defaults.models`.

Example output (after proxy install):

```
anthropic/claude-opus-4-7           (default)
openai/gpt-5.4                      alias: GPT
claude-cli/claude-sonnet-4-5
claude-cli/claude-opus-4-5
claude-cli/claude-haiku-4-5
claude-code-proxy/claude-opus-4-5   alias: opus
claude-code-proxy/claude-sonnet-4-5 alias: sonnet
```

### Switch for ONE session

In the TUI, type:

```
/model opus
```

or the fully-qualified form:

```
/model claude-code-proxy/claude-opus-4-5
```

That change lasts only for the current session. When you restart or open a new session, you're back on the default.

Under the hood this sets a `modelOverride` on the session entry. You can achieve the same thing programmatically by passing `model:` to the `session_status` tool.

### Switch the DEFAULT permanently

```bash
openclaw models set claude-code-proxy/claude-opus-4-5
```

This writes to `agents.defaults.model.primary` in `openclaw.json`. All new sessions use this model.

To switch back to direct Anthropic API:

```bash
openclaw models set anthropic/claude-opus-4-7
```

To switch to GPT:

```bash
openclaw models set openai/gpt-5.4
```

### Understand what each provider means

- **`anthropic/*`** — Direct to Anthropic API. Uses your `ANTHROPIC_API_KEY` or configured auth profile. Billed per-token. Full OpenClaw tool surface.
- **`openai/*`** — Direct to OpenAI API. Billed per-token.
- **`claude-cli/*`** — Built-in OpenClaw plugin that invokes the Claude CLI per-turn. Uses your Claude Code subscription. Simpler than the proxy, no memory-digest wrapping.
- **`claude-code-proxy/*`** — The proxy described in this repo. Invokes Claude CLI under the hood (like `claude-cli/*`) but wraps each request with memory digest, conversation context, and continuity logic.

If you don't need the proxy's memory wrapping, `claude-cli/*` is usually simpler and fine.

## Aliases

Aliases make model IDs typeable. The proxy install attempts to register these two aliases in `openclaw.json`:

- `opus` → `claude-code-proxy/claude-opus-4-5`
- `sonnet` → `claude-code-proxy/claude-sonnet-4-5`

⚠️ **Heads up: alias collision.** OpenClaw itself ships with an `opus` alias pointing to `anthropic/claude-opus-4-7` (direct API). When the proxy installs, it adds the alias inside its own `agents.defaults.models[...]` entry but does NOT overwrite your existing `opus` alias in `agents.defaults.aliases`. So after install you may see:

```bash
$ openclaw models aliases list
Aliases (2):
- GPT    -> openai/gpt-5.4
- opus   -> anthropic/claude-opus-4-7   # NOT the proxy!
```

If you want `opus` to mean the proxy variant, set it explicitly:

```bash
openclaw models aliases set opus claude-code-proxy/claude-opus-4-5
```

Or use unambiguous names:

```bash
openclaw models aliases set popus claude-code-proxy/claude-opus-4-5
openclaw models aliases set psonnet claude-code-proxy/claude-sonnet-4-5
```

(`p` prefix for "proxy".)

To see all aliases:

```bash
openclaw models aliases list
```

To add your own:

```bash
openclaw models aliases set fast openai/gpt-5.4
```

Then `/model fast` works.

## Turning the proxy OFF without uninstalling

The proxy is a user systemd service. You can stop it at any time without touching OpenClaw config:

```bash
oc-claude-proxy-ubuntu stop
```

What this does:
- Stops the `claude-code-proxy.service` unit
- Leaves `~/.openclaw/openclaw.json` untouched
- Leaves the installed script files in place
- Leaves the systemd unit enabled, so it comes back at next boot

**Important:** If your default model is a `claude-code-proxy/*` model, stopping the proxy will break any session that tries to use it. Always switch models FIRST, then stop the proxy:

```bash
openclaw models set anthropic/claude-opus-4-7
oc-claude-proxy-ubuntu stop
```

To re-enable:

```bash
oc-claude-proxy-ubuntu start
openclaw models set claude-code-proxy/claude-opus-4-5
```

To stop it AND prevent it from starting at next boot:

```bash
oc-claude-proxy-ubuntu stop
systemctl --user disable claude-code-proxy.service
```

## Emergency: proxy broken, need to bail NOW

If the proxy is acting up and you need to get back to a working state immediately:

```bash
# 1. Switch to a direct provider
openclaw models set anthropic/claude-opus-4-7

# 2. Stop the proxy
oc-claude-proxy-ubuntu stop

# 3. Restart OpenClaw gateway to pick up the change
openclaw gateway restart
```

You're now off the proxy with no config changes needed to return to it later. Just run `oc-claude-proxy-ubuntu start` and flip the model back.

## Complete uninstall

If you want to remove the proxy entirely:

```bash
oc-claude-proxy-ubuntu uninstall
```

What this does:
- Stops and disables the systemd service
- Removes the systemd unit file
- Removes proxy entries from `openclaw.json` (targeted jq edits; leaves your custom values alone)
- Deletes the installed script files in `~/.openclaw/workspace/scripts/`
- Backs up `openclaw.json` to `openclaw.json.backup.<timestamp>` before editing
- Restarts the OpenClaw gateway

Then remove the npm package:

```bash
npm uninstall -g @rtedeschi/oc-claude-proxy-ubuntu
```

### What uninstall does NOT touch

- `/tmp/claude-code-proxy-state.json` and `/tmp/claude-code-proxy-debug.log` (ephemeral, cleaned on reboot)
- `agents.defaults.model.primary` — if you had set it to a proxy model, it will still point there. Fix with `openclaw models set anthropic/claude-opus-4-7` or any other valid model.
- Your `openclaw.json.backup.*` files — kept as safety net; delete them yourself when you're sure.

## Troubleshooting

### `openclaw models list` shows the proxy models but requests fail

Check the service:

```bash
oc-claude-proxy-ubuntu status
```

If it's not running:

```bash
oc-claude-proxy-ubuntu start
oc-claude-proxy-ubuntu logs -f
```

Watch the logs while you send a request to see what's happening.

### Proxy is running but responses feel wrong

Check the debug log:

```bash
tail -f /tmp/claude-code-proxy-debug.log
```

Every request gets logged with its translated shape (`mode=stateless`, preview of user content, etc). If you see `No response from Claude Code`, the upstream `claude` CLI failed.

Verify Claude Code itself works:

```bash
claude --version
echo "hello" | claude --print --output-format=stream-json --verbose
```

If that fails, fix Claude Code auth before anything else.

### I want to verify the proxy is actually being used

The proxy logs every request it handles. With the proxy as your default model, send any message in OpenClaw, then:

```bash
oc-claude-proxy-ubuntu logs --lines 20
```

You should see a fresh `Request mode=stateless` line. If you don't, your session is NOT going through the proxy.

Confirm with `/status` in the TUI — the `Model:` line should show `claude-code-proxy/...`, not `anthropic/...` or `openai/...`.

## Summary

The proxy is a drop-in provider. Switching to/from it is the same as switching between any other providers. The only thing to remember is:

1. Change your model choice FIRST (`openclaw models set <id>` or `/model <id>`)
2. THEN stop/start/uninstall the proxy if you need to

Do it in that order and you can never paint yourself into a corner.
