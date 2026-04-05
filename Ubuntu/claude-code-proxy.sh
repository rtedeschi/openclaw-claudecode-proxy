#!/bin/bash
# Claude Code Proxy installer and service entrypoint for OpenClaw.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CURRENT_SCRIPT="${SCRIPT_DIR}/$(basename "$0")"
export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:${HOME}/.bun/bin:${HOME}/bin:${PATH}"
OPENCLAW_HOME="${HOME}/.openclaw"
OPENCLAW_CONFIG="${OPENCLAW_HOME}/openclaw.json"
OPENCLAW_WORKSPACE="${OPENCLAW_HOME}/workspace"
INSTALL_DIR="${OPENCLAW_HOME}/workspace/scripts"
INSTALL_CORE_DIR="${INSTALL_DIR}/Core"
INSTALLED_SCRIPT="${INSTALL_DIR}/claude-code-proxy.sh"
INSTALLED_PROXY_JS="${INSTALL_CORE_DIR}/claude-code-proxy.js"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SYSTEMD_SERVICE_NAME="claude-code-proxy.service"
SYSTEMD_SERVICE_PATH="${SYSTEMD_USER_DIR}/${SYSTEMD_SERVICE_NAME}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DEFAULT_PORT="${PROXY_PORT:-8787}"

MODE="${1:-install}"
PORT="${2:-$DEFAULT_PORT}"

if [[ "$MODE" =~ ^[0-9]+$ ]]; then
    PORT="$MODE"
    MODE="install"
fi

usage() {
    cat <<EOF
Usage:
  ./claude-code-proxy.sh
  ./claude-code-proxy.sh install [port]
  ./claude-code-proxy.sh serve [port]

Modes:
  install  Install the proxy, patch openclaw.json, install the user service, and start it.
  serve    Run the proxy in the foreground. This is the mode used by systemd.
EOF
}

pause_if_interactive() {
        if [ -t 0 ] && [ -t 1 ]; then
                read -r -n 1 -s -p "Press any key to continue . . . "
                echo ""
        fi
}

on_exit_pause_if_needed() {
    local status=$?

    if [ "$status" -ne 0 ] && [ "${MODE:-install}" != "serve" ]; then
        pause_if_interactive
    fi
}

trap on_exit_pause_if_needed EXIT

require_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "❌ Required command not found: $1"
        exit 1
    fi
}

verify_claude() {
    if ! claude --version > /dev/null 2>&1; then
        echo "❌ Claude Code CLI is installed but not usable. Run 'claude' to finish setup."
        exit 1
    fi
}

resolve_proxy_js() {
    local local_core="${SCRIPT_DIR}/Core/claude-code-proxy.js"
    local repo_core="${SCRIPT_DIR}/../Core/claude-code-proxy.js"

    if [ -f "$local_core" ]; then
        printf '%s\n' "$local_core"
        return 0
    fi

    if [ -f "$repo_core" ]; then
        printf '%s\n' "$repo_core"
        return 0
    fi

    echo "❌ Shared proxy entrypoint not found next to the script or in ../Core" >&2
    exit 1
}

backup_file() {
    local file_path="$1"

    if [ -f "$file_path" ]; then
        cp "$file_path" "${file_path}.backup.${TIMESTAMP}"
        echo "✅ Backed up $file_path"
    fi
}

install_files() {
    local source_proxy_js
    source_proxy_js="$(resolve_proxy_js)"

    mkdir -p "$INSTALL_CORE_DIR"

    if [ "$CURRENT_SCRIPT" != "$INSTALLED_SCRIPT" ]; then
        cp "$CURRENT_SCRIPT" "$INSTALLED_SCRIPT"
    fi

    if [ "$source_proxy_js" != "$INSTALLED_PROXY_JS" ]; then
        cp "$source_proxy_js" "$INSTALLED_PROXY_JS"
    fi

    chmod +x "$INSTALLED_SCRIPT"

    echo "✅ Installed script at $INSTALLED_SCRIPT"
    echo "✅ Installed proxy JS at $INSTALLED_PROXY_JS"
}

patch_openclaw_config() {
    local tmp_file
    tmp_file="$(mktemp)"

    jq \
        --arg proxy_port "$PORT" \
        '
        def proxy_models:
            [
                {
                    "id": "claude-opus-4-5",
                    "name": "Claude Opus 4.5 (Proxy)",
                    "api": "anthropic-messages",
                    "reasoning": false,
                    "input": ["text"],
                    "cost": {
                        "input": 0,
                        "output": 0,
                        "cacheRead": 0,
                        "cacheWrite": 0
                    },
                    "contextWindow": 200000,
                    "maxTokens": 8192
                },
                {
                    "id": "claude-sonnet-4-5",
                    "name": "Claude Sonnet 4.5 (Proxy)",
                    "api": "anthropic-messages",
                    "reasoning": false,
                    "input": ["text"],
                    "cost": {
                        "input": 0,
                        "output": 0,
                        "cacheRead": 0,
                        "cacheWrite": 0
                    },
                    "contextWindow": 200000,
                    "maxTokens": 8192
                }
            ];

        .models //= {}
        | .models.providers //= {}
        | .models.providers["claude-code-proxy"] = {
            "baseUrl": ("http://localhost:" + $proxy_port),
            "apiKey": "proxy-no-key-needed",
            "api": "anthropic-messages",
            "headers": {},
            "models": proxy_models
        }
        | .agents //= {}
        | .agents.defaults //= {}
        | .agents.defaults.models //= {}
        | .agents.defaults.models["claude-code-proxy/claude-opus-4-5"] = { "alias": "opus" }
        | .agents.defaults.models["claude-code-proxy/claude-sonnet-4-5"] = { "alias": "sonnet" }
        ' "$OPENCLAW_CONFIG" > "$tmp_file"

    mv "$tmp_file" "$OPENCLAW_CONFIG"
    echo "✅ Patched $OPENCLAW_CONFIG"
}

install_user_service() {
    mkdir -p "$SYSTEMD_USER_DIR"

    cat > "$SYSTEMD_SERVICE_PATH" <<EOF
[Unit]
Description=Claude Code Proxy for OpenClaw
After=default.target

[Service]
Type=simple
WorkingDirectory=${OPENCLAW_WORKSPACE}
ExecStart=${INSTALLED_SCRIPT} serve ${PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

    echo "✅ Installed user service at $SYSTEMD_SERVICE_PATH"
}

stop_existing_user_service() {
    if systemctl --user list-unit-files "$SYSTEMD_SERVICE_NAME" > /dev/null 2>&1; then
        systemctl --user stop "$SYSTEMD_SERVICE_NAME" 2> /dev/null || true
        echo "✅ Stopped existing user service"
    fi
}

enable_user_service() {
    systemctl --user daemon-reload
    systemctl --user enable "$SYSTEMD_SERVICE_NAME" > /dev/null
    systemctl --user start "$SYSTEMD_SERVICE_NAME"
    echo "✅ User service enabled and started"

    if command -v loginctl > /dev/null 2>&1; then
        if loginctl enable-linger "$USER" > /dev/null 2>&1; then
            echo "✅ Enabled linger for $USER"
        else
            echo "ℹ️  Could not enable linger automatically."
            echo "   If you need the proxy to start before login, run: sudo loginctl enable-linger $USER"
        fi
    fi
}

restart_gateway() {
    if command -v openclaw > /dev/null 2>&1; then
        echo "🔄 Restarting OpenClaw gateway..."
        openclaw gateway restart || echo "⚠️  Could not restart automatically. Run: openclaw gateway restart"
    else
        echo "⚠️  openclaw command not found. Please restart the gateway manually."
    fi
}

print_summary() {
    echo ""
    echo "============================================="
    echo "✅ Deployment complete"
    echo ""
    echo "Installed provider: claude-code-proxy -> http://localhost:${PORT}"
    echo "Proxy script: $INSTALLED_SCRIPT"
    echo "User service: $SYSTEMD_SERVICE_PATH"
    echo ""
    echo "Suggested default model update:"
    echo "  agents.defaults.model.primary = claude-code-proxy/claude-opus-4-5"
    echo "  or"
    echo "  agents.defaults.model.primary = claude-code-proxy/claude-sonnet-4-5"
    echo ""
    echo "Useful commands:"
    echo "  systemctl --user status $SYSTEMD_SERVICE_NAME"
    echo "  systemctl --user restart $SYSTEMD_SERVICE_NAME"
    echo "  openclaw gateway restart"
    echo ""
}

run_proxy() {
    local proxy_js
    proxy_js="$(resolve_proxy_js)"

    require_command claude
    require_command node
    verify_claude

    mkdir -p "$OPENCLAW_WORKSPACE"
    cd "$OPENCLAW_WORKSPACE"

    export PORT

    echo "🚀 Starting Claude Code Proxy on port $PORT"
    echo "   Requests will be forwarded through the real Claude Code CLI"
    echo "   Press Ctrl+C to stop"
    echo ""

    exec node "$proxy_js"
}

install_proxy() {
    echo "🔧 Claude Code Proxy Setup for OpenClaw"
    echo "======================================="
    echo ""
    echo "This installs the proxy service on port ${PORT}, patches openclaw.json, and starts the user service."
    echo ""

    if [ ! -f "$OPENCLAW_CONFIG" ]; then
        echo "❌ OpenClaw config not found at $OPENCLAW_CONFIG"
        echo "   Run 'openclaw wizard' first on the target machine."
        exit 1
    fi

    require_command jq
    require_command node
    require_command claude
    require_command systemctl
    verify_claude

    backup_file "$OPENCLAW_CONFIG"
    install_files
    patch_openclaw_config
    stop_existing_user_service
    install_user_service
    enable_user_service
    restart_gateway
    print_summary
}

case "$MODE" in
    install)
        install_proxy
        pause_if_interactive
        ;;
    serve)
        run_proxy
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "❌ Unknown mode: $MODE"
        echo ""
        usage
        exit 1
        ;;
esac
