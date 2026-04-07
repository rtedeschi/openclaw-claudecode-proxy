#!/bin/bash
# Claude Code Proxy installer and service manager for OpenClaw on Ubuntu.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CURRENT_SCRIPT="${SCRIPT_DIR}/$(basename "$0")"
SOURCE_PACKAGE_ROOT_DEFAULT="$(cd "${SCRIPT_DIR}/.." 2> /dev/null && pwd || true)"
export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:${HOME}/.bun/bin:${HOME}/bin:${PATH}"
OPENCLAW_HOME="${HOME}/.openclaw"
OPENCLAW_CONFIG="${OPENCLAW_HOME}/openclaw.json"
OPENCLAW_WORKSPACE="${OPENCLAW_HOME}/workspace"
INSTALL_DIR="${OPENCLAW_HOME}/workspace/scripts"
INSTALL_CORE_DIR="${INSTALL_DIR}/Core"
INSTALLED_SCRIPT="${INSTALL_DIR}/claude-code-proxy.sh"
INSTALLED_PROXY_JS="${INSTALL_CORE_DIR}/claude-code-proxy.js"
INSTALL_STATE_PATH="${INSTALL_DIR}/claude-code-proxy-install-state.json"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SYSTEMD_SERVICE_NAME="claude-code-proxy.service"
SYSTEMD_SERVICE_PATH="${SYSTEMD_USER_DIR}/${SYSTEMD_SERVICE_NAME}"
SYSTEMD_CLEANUP_SERVICE_NAME="claude-code-proxy-cleanup.service"
SYSTEMD_CLEANUP_SERVICE_PATH="${SYSTEMD_USER_DIR}/${SYSTEMD_CLEANUP_SERVICE_NAME}"
SYSTEMD_CLEANUP_TIMER_NAME="claude-code-proxy-cleanup.timer"
SYSTEMD_CLEANUP_TIMER_PATH="${SYSTEMD_USER_DIR}/${SYSTEMD_CLEANUP_TIMER_NAME}"
DEBUG_LOG_PATH="${TMPDIR:-/tmp}/claude-code-proxy-debug.log"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DEFAULT_PORT="${PROXY_PORT:-8787}"
DEFAULT_LOG_LINES="${OC_PROXY_LOG_LINES:-200}"
NO_PAUSE="${OC_PROXY_NO_PAUSE:-0}"
FOLLOW_LOGS=0
LOG_LINES="$DEFAULT_LOG_LINES"

MODE="${1:-install}"
PORT="$DEFAULT_PORT"

usage() {
    cat <<EOF
Usage:
  ./claude-code-proxy.sh
  ./claude-code-proxy.sh install [port]
  ./claude-code-proxy.sh uninstall
  ./claude-code-proxy.sh serve [port]
  ./claude-code-proxy.sh start
  ./claude-code-proxy.sh stop
  ./claude-code-proxy.sh restart
  ./claude-code-proxy.sh status
  ./claude-code-proxy.sh logs [-f] [lines]
  ./claude-code-proxy.sh cleanup-if-package-missing

Modes:
  install                   Install the proxy, patch openclaw.json, install the user service, and start it.
  uninstall                 Stop and remove the service, clean OpenClaw config entries, and delete installed files.
  serve                     Run the proxy in the foreground. This is the mode used by systemd.
  start|stop|restart        Control the user systemd service.
  status                    Show the service status, install metadata, and key file paths.
  logs                      Show recent journal logs for the service. Use -f to follow.
  cleanup-if-package-missing
                            Internal mode used by the cleanup timer after npm package removal.
EOF
}

if [[ "$MODE" =~ ^[0-9]+$ ]]; then
    PORT="$MODE"
    MODE="install"
    shift || true
else
    shift || true
fi

while (($# > 0)); do
    case "$MODE:$1" in
        install:[0-9]*|serve:[0-9]*)
            PORT="$1"
            ;;
        logs:[0-9]*)
            LOG_LINES="$1"
            ;;
        *:--no-pause)
            NO_PAUSE=1
            ;;
        logs:--follow|logs:-f)
            FOLLOW_LOGS=1
            ;;
        *)
            echo "Unknown argument for $MODE: $1"
            echo ""
            usage
            exit 1
            ;;
    esac

    shift
done

pause_if_interactive() {
    if [ "$NO_PAUSE" = "1" ]; then
        return
    fi

    if [ -t 0 ] && [ -t 1 ]; then
        read -r -n 1 -s -p "Press any key to continue . . . "
        echo ""
    fi
}

on_exit_pause_if_needed() {
    local status=$?

    if [ "$status" -ne 0 ] && [ "${MODE:-install}" != "serve" ] && [ "${MODE:-install}" != "cleanup-if-package-missing" ]; then
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

resolve_source_package_root() {
    if [ -n "${OC_PROXY_SOURCE_PACKAGE_ROOT:-}" ] && [ -f "${OC_PROXY_SOURCE_PACKAGE_ROOT}/package.json" ]; then
        printf '%s\n' "$OC_PROXY_SOURCE_PACKAGE_ROOT"
        return 0
    fi

    if [ -n "$SOURCE_PACKAGE_ROOT_DEFAULT" ] && [ -f "${SOURCE_PACKAGE_ROOT_DEFAULT}/package.json" ] && [ -d "${SOURCE_PACKAGE_ROOT_DEFAULT}/Ubuntu" ] && [ -d "${SOURCE_PACKAGE_ROOT_DEFAULT}/Core" ]; then
        printf '%s\n' "$SOURCE_PACKAGE_ROOT_DEFAULT"
        return 0
    fi

    printf '%s\n' ""
}

read_install_state_value() {
    local jq_filter="$1"

    if [ ! -f "$INSTALL_STATE_PATH" ]; then
        return 1
    fi

    jq -r "$jq_filter // empty" "$INSTALL_STATE_PATH"
}

backup_file() {
    local file_path="$1"

    if [ -f "$file_path" ]; then
        cp "$file_path" "${file_path}.backup.${TIMESTAMP}"
        echo "✅ Backed up $file_path"
    fi
}

write_install_state() {
    local source_package_root
    source_package_root="$(resolve_source_package_root)"

    mkdir -p "$INSTALL_DIR"

    jq -n \
        --arg installedAt "$(date --iso-8601=seconds)" \
        --arg packageRoot "$source_package_root" \
        --arg port "$PORT" \
        --arg installedScript "$INSTALLED_SCRIPT" \
        --arg installedProxyJs "$INSTALLED_PROXY_JS" \
        --arg serviceName "$SYSTEMD_SERVICE_NAME" \
        --arg cleanupTimerName "$SYSTEMD_CLEANUP_TIMER_NAME" \
        '{
            installedAt: $installedAt,
            packageRoot: $packageRoot,
            port: ($port | tonumber),
            installedScript: $installedScript,
            installedProxyJs: $installedProxyJs,
            serviceName: $serviceName,
            cleanupTimerName: $cleanupTimerName
        }' > "$INSTALL_STATE_PATH"

    echo "✅ Wrote install state at $INSTALL_STATE_PATH"
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

remove_proxy_config_entries() {
    local tmp_file
    tmp_file="$(mktemp)"

    jq '
        .models //= {}
        | .models.providers = ((.models.providers // {}) | del(."claude-code-proxy"))
        | .agents //= {}
        | .agents.defaults //= {}
        | .agents.defaults.models = ((.agents.defaults.models // {})
            | del(."claude-code-proxy/claude-opus-4-5")
            | del(."claude-code-proxy/claude-sonnet-4-5"))
        ' "$OPENCLAW_CONFIG" > "$tmp_file"

    mv "$tmp_file" "$OPENCLAW_CONFIG"
    echo "✅ Removed proxy entries from $OPENCLAW_CONFIG"
}

install_systemd_units() {
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

    cat > "$SYSTEMD_CLEANUP_SERVICE_PATH" <<EOF
[Unit]
Description=Cleanup Claude Code Proxy after package removal
After=default.target

[Service]
Type=oneshot
ExecStart=${INSTALLED_SCRIPT} cleanup-if-package-missing --no-pause
EOF

    cat > "$SYSTEMD_CLEANUP_TIMER_PATH" <<EOF
[Unit]
Description=Check whether the Claude Code Proxy npm package was removed

[Timer]
OnBootSec=10s
OnUnitActiveSec=5s
Unit=${SYSTEMD_CLEANUP_SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF

    echo "✅ Installed user service at $SYSTEMD_SERVICE_PATH"
    echo "✅ Installed cleanup service at $SYSTEMD_CLEANUP_SERVICE_PATH"
    echo "✅ Installed cleanup timer at $SYSTEMD_CLEANUP_TIMER_PATH"
}

stop_existing_units() {
    systemctl --user stop "$SYSTEMD_SERVICE_NAME" 2> /dev/null || true
    systemctl --user stop "$SYSTEMD_CLEANUP_TIMER_NAME" 2> /dev/null || true
    systemctl --user stop "$SYSTEMD_CLEANUP_SERVICE_NAME" 2> /dev/null || true
}

remove_systemd_units() {
    stop_existing_units

    systemctl --user disable "$SYSTEMD_SERVICE_NAME" > /dev/null 2>&1 || true
    systemctl --user disable "$SYSTEMD_CLEANUP_TIMER_NAME" > /dev/null 2>&1 || true

    rm -f "$SYSTEMD_SERVICE_PATH" "$SYSTEMD_CLEANUP_SERVICE_PATH" "$SYSTEMD_CLEANUP_TIMER_PATH"

    systemctl --user daemon-reload || true
    systemctl --user reset-failed "$SYSTEMD_SERVICE_NAME" > /dev/null 2>&1 || true
    systemctl --user reset-failed "$SYSTEMD_CLEANUP_SERVICE_NAME" > /dev/null 2>&1 || true

    echo "✅ Removed systemd units"
}

enable_systemd_units() {
    systemctl --user daemon-reload
    systemctl --user enable "$SYSTEMD_SERVICE_NAME" > /dev/null
    systemctl --user enable "$SYSTEMD_CLEANUP_TIMER_NAME" > /dev/null
    systemctl --user start "$SYSTEMD_SERVICE_NAME"
    systemctl --user start "$SYSTEMD_CLEANUP_TIMER_NAME"
    echo "✅ User service enabled and started"
    echo "✅ Cleanup timer enabled and started"

    if command -v loginctl > /dev/null 2>&1; then
        if loginctl enable-linger "$USER" > /dev/null 2>&1; then
            echo "✅ Enabled linger for $USER"
        else
            echo "ℹ️  Could not enable linger automatically."
            echo "   If you need the proxy to start before login, run: sudo loginctl enable-linger $USER"
        fi
    fi
}

cleanup_installed_files() {
    rm -f "$INSTALLED_SCRIPT" "$INSTALLED_PROXY_JS" "$INSTALL_STATE_PATH"
    rmdir "$INSTALL_CORE_DIR" 2> /dev/null || true
    echo "✅ Removed installed proxy files"
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
    echo "Cleanup timer: $SYSTEMD_CLEANUP_TIMER_PATH"
    echo ""
    echo "Suggested default model update:"
    echo "  agents.defaults.model.primary = claude-code-proxy/claude-opus-4-5"
    echo "  or"
    echo "  agents.defaults.model.primary = claude-code-proxy/claude-sonnet-4-5"
    echo ""
    echo "Useful commands:"
    echo "  ${INSTALLED_SCRIPT} status"
    echo "  ${INSTALLED_SCRIPT} logs -f"
    echo "  ${INSTALLED_SCRIPT} restart"
    echo "  ${INSTALLED_SCRIPT} uninstall"
    echo ""
}

print_uninstall_summary() {
    echo ""
    echo "============================================="
    echo "✅ Cleanup complete"
    echo ""
    echo "Removed systemd service, cleanup timer, installed proxy files, and OpenClaw proxy config entries."
    echo ""
}

show_status() {
    echo "Claude Code Proxy status"
    echo "========================"
    echo ""

    if [ -f "$INSTALL_STATE_PATH" ]; then
        echo "Install state: $INSTALL_STATE_PATH"
        jq '.' "$INSTALL_STATE_PATH"
        echo ""
    else
        echo "Install state: not found"
        echo ""
    fi

    echo "Service unit: $SYSTEMD_SERVICE_PATH"
    echo "Cleanup timer: $SYSTEMD_CLEANUP_TIMER_PATH"
    echo "Debug log: $DEBUG_LOG_PATH"
    echo ""

    systemctl --user --no-pager status "$SYSTEMD_SERVICE_NAME" || true
    echo ""
    systemctl --user --no-pager status "$SYSTEMD_CLEANUP_TIMER_NAME" || true
}

show_logs() {
    require_command journalctl

    if [ "$FOLLOW_LOGS" = "1" ]; then
        journalctl --user -u "$SYSTEMD_SERVICE_NAME" -u "$SYSTEMD_CLEANUP_SERVICE_NAME" -n "$LOG_LINES" -f -o short-iso
        return 0
    fi

    journalctl --user -u "$SYSTEMD_SERVICE_NAME" -u "$SYSTEMD_CLEANUP_SERVICE_NAME" -n "$LOG_LINES" --no-pager -o short-iso
}

service_control() {
    local action="$1"

    require_command systemctl
    systemctl --user "$action" "$SYSTEMD_SERVICE_NAME"
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
    write_install_state
    patch_openclaw_config
    stop_existing_units
    install_systemd_units
    enable_systemd_units
    restart_gateway
    print_summary
}

uninstall_proxy() {
    echo "🧹 Removing Claude Code Proxy for OpenClaw"
    echo "=========================================="
    echo ""

    require_command systemctl
    require_command jq

    if [ -f "$OPENCLAW_CONFIG" ]; then
        backup_file "$OPENCLAW_CONFIG"
        remove_proxy_config_entries
    else
        echo "ℹ️  OpenClaw config not found at $OPENCLAW_CONFIG; skipping config cleanup."
    fi

    remove_systemd_units
    cleanup_installed_files
    restart_gateway
    print_uninstall_summary
}

cleanup_if_package_missing() {
    local package_root

    if [ ! -f "$INSTALL_STATE_PATH" ]; then
        exit 0
    fi

    package_root="$(read_install_state_value '.packageRoot')"

    if [ -z "$package_root" ] || [ -f "$package_root/package.json" ]; then
        exit 0
    fi

    echo "Detected removed package root at $package_root"
    uninstall_proxy
}

case "$MODE" in
    install)
        install_proxy
        pause_if_interactive
        ;;
    uninstall)
        uninstall_proxy
        pause_if_interactive
        ;;
    serve)
        run_proxy
        ;;
    start)
        service_control start
        ;;
    stop)
        service_control stop
        ;;
    restart)
        service_control restart
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    cleanup-if-package-missing)
        cleanup_if_package_missing
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
