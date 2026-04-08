# @rtedeschi/oc-claude-proxy-windows

Windows package for the OpenClaw Claude Code proxy.

This package installs the existing Windows startup-task workflow from this repository and runs it automatically during global npm installation on Windows.

## Install

```powershell
npm install -g @rtedeschi/oc-claude-proxy-windows --registry=https://npm.pkg.github.com
```

## Commands

```powershell
oc-claude-proxy-windows
oc-claude-proxy-windows install 8788
oc-claude-proxy-windows uninstall
oc-claude-proxy-windows-uninstall
openclaw-claude-code-proxy-windows install 8788
openclaw-claude-code-proxy-windows-uninstall
```

The installer updates `%USERPROFILE%\.openclaw\openclaw.json`, copies runtime files into `%USERPROFILE%\.openclaw\workspace\scripts\`, registers the `ClaudeCodeProxy` Scheduled Task, and starts it.

The uninstall command removes the `ClaudeCodeProxy` Scheduled Task, deletes the installed runtime files from `%USERPROFILE%\.openclaw\workspace\scripts\`, removes the `claude-code-proxy` provider entries from `%USERPROFILE%\.openclaw\openclaw.json`, and restarts the OpenClaw gateway.