#!/bin/bash
# Claude Code Local API Setup for OpenClaw
#
# This script installs the local Claude Code proxy on port 8787, configures it
# to start automatically as a user service, and points OpenClaw at the proxy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENCLAW_HOME="${HOME}/.openclaw"
OPENCLAW_CONFIG="${OPENCLAW_HOME}/openclaw.json"
RUNTIME_MODELS_CONFIG="${OPENCLAW_HOME}/agents/main/agent/models.json"
PROXY_SOURCE="${SCRIPT_DIR}/claude-code-proxy.sh"
PROXY_SCRIPT="${OPENCLAW_HOME}/workspace/scripts/claude-code-proxy.sh"
PROXY_PORT="${PROXY_PORT:-8787}"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SYSTEMD_SERVICE_NAME="claude-code-proxy.service"
SYSTEMD_SERVICE_PATH="${SYSTEMD_USER_DIR}/${SYSTEMD_SERVICE_NAME}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

require_command() {
        if ! command -v "$1" > /dev/null 2>&1; then
                echo "❌ Required command not found: $1"
                exit 1
        fi
}

backup_file() {
        local file_path="$1"

        if [ -f "$file_path" ]; then
                cp "$file_path" "${file_path}.backup.${TIMESTAMP}"
                echo "✅ Backed up $file_path"
        fi
}

install_proxy_script() {
        if [ ! -f "$PROXY_SOURCE" ]; then
                echo "❌ Proxy source script not found at $PROXY_SOURCE"
                exit 1
        fi

        mkdir -p "$(dirname "$PROXY_SCRIPT")"

        if [ "$PROXY_SOURCE" != "$PROXY_SCRIPT" ]; then
                cp "$PROXY_SOURCE" "$PROXY_SCRIPT"
        fi

        chmod +x "$PROXY_SCRIPT"
        echo "✅ Proxy script installed at $PROXY_SCRIPT"
}

install_user_service() {
        mkdir -p "$SYSTEMD_USER_DIR"

        cat > "$SYSTEMD_SERVICE_PATH" <<EOF
[Unit]
Description=Claude Code Proxy for OpenClaw
After=default.target

[Service]
Type=simple
ExecStart=${PROXY_SCRIPT} ${PROXY_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

        echo "✅ User service installed at $SYSTEMD_SERVICE_PATH"
}

enable_user_service() {
        if ! command -v systemctl > /dev/null 2>&1; then
                echo "⚠️  systemctl not found. Start the proxy manually: $PROXY_SCRIPT $PROXY_PORT"
                return
        fi

        if systemctl --user daemon-reload && systemctl --user enable --now "$SYSTEMD_SERVICE_NAME"; then
                echo "✅ User service enabled and started"
        else
                echo "⚠️  Could not enable the user service automatically."
                echo "   Run: systemctl --user daemon-reload"
                echo "   Run: systemctl --user enable --now $SYSTEMD_SERVICE_NAME"
        fi

        if command -v loginctl > /dev/null 2>&1; then
                if loginctl enable-linger "$USER" > /dev/null 2>&1; then
                        echo "✅ Enabled linger for $USER"
                else
                        echo "ℹ️  Could not enable linger automatically."
                        echo "   If you need the proxy to start before login, run: sudo loginctl enable-linger $USER"
                fi
        fi
}

patch_openclaw_config() {
        local tmp_file

        tmp_file="$(mktemp)"

        jq \
                --arg proxy_port "$PROXY_PORT" \
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
                def ensure_unique(items):
                    reduce items[] as $item ([]; if index($item) then . else . + [$item] end);

                .secrets.providers = ((.secrets.providers // {}) | del(.["claude-token"]))
                | .models.providers //= {}
                | .models.providers["claude-code"] = {
                        "baseUrl": ("http://localhost:" + $proxy_port),
                        "apiKey": "proxy-no-key-needed",
                        "api": "anthropic-messages",
                        "headers": {},
                        "models": proxy_models
                    }
                | del(.models.providers["claude-code-proxy"])
                | .agents.defaults.model.primary = "claude-code/claude-opus-4-5"
                | .agents.defaults.model.fallbacks = (
                        ["claude-code/claude-sonnet-4-5"]
                        + ((.agents.defaults.model.fallbacks // [])
                            | map(select((test("^(anthropic|claude-code|claude-code-proxy)/claude-(opus|sonnet|haiku)-4-[56]$") | not))))
                        | ensure_unique(.)
                    )
                | .agents.defaults.models["claude-code/claude-opus-4-5"] = { "alias": "opus" }
                | .agents.defaults.models["claude-code/claude-sonnet-4-5"] = { "alias": "sonnet" }
                | del(.agents.defaults.models["claude-code/claude-haiku-4-5"])
                ' "$OPENCLAW_CONFIG" > "$tmp_file"

        mv "$tmp_file" "$OPENCLAW_CONFIG"
        echo "✅ Patched $OPENCLAW_CONFIG"
}

patch_runtime_models() {
        local tmp_file

        mkdir -p "$(dirname "$RUNTIME_MODELS_CONFIG")"

        if [ ! -f "$RUNTIME_MODELS_CONFIG" ]; then
                printf '{\n  "providers": {}\n}\n' > "$RUNTIME_MODELS_CONFIG"
        fi

        tmp_file="$(mktemp)"

        jq \
                --arg proxy_port "$PROXY_PORT" \
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

                .providers //= {}
                | .providers["claude-code"] = {
                        "baseUrl": ("http://localhost:" + $proxy_port),
                        "apiKey": "proxy-no-key-needed",
                        "api": "anthropic-messages",
                        "headers": {},
                        "models": proxy_models
                    }
                | del(.providers["claude-code-proxy"])
                ' "$RUNTIME_MODELS_CONFIG" > "$tmp_file"

        mv "$tmp_file" "$RUNTIME_MODELS_CONFIG"
        echo "✅ Patched $RUNTIME_MODELS_CONFIG"
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
        echo "Installed provider: claude-code -> http://localhost:${PROXY_PORT}"
        echo "Proxy script: $PROXY_SCRIPT"
        echo "User service: $SYSTEMD_SERVICE_PATH"
        echo "Primary model: claude-code/claude-opus-4-5"
        echo "Fallbacks include: claude-code/claude-sonnet-4-5"
        echo ""
        echo "Useful commands:"
        echo "  systemctl --user status $SYSTEMD_SERVICE_NAME"
        echo "  systemctl --user restart $SYSTEMD_SERVICE_NAME"
        echo "  openclaw gateway restart"
        echo ""
}

echo "🔧 Claude Code Local API Setup for OpenClaw"
echo "============================================="
echo ""
echo "This installs the local Claude Code API on port ${PROXY_PORT} and points OpenClaw at it."
echo ""

if [ ! -f "$OPENCLAW_CONFIG" ]; then
        echo "❌ OpenClaw config not found at $OPENCLAW_CONFIG"
        echo "   Run 'openclaw wizard' first on the target machine."
        exit 1
fi

require_command jq
require_command node
require_command claude

if ! claude --version > /dev/null 2>&1; then
        echo "❌ Claude Code CLI is installed but not usable. Run 'claude' to finish setup."
        exit 1
fi

backup_file "$OPENCLAW_CONFIG"
backup_file "$RUNTIME_MODELS_CONFIG"

install_proxy_script
install_user_service
enable_user_service
patch_openclaw_config
patch_runtime_models
restart_gateway
print_summary
