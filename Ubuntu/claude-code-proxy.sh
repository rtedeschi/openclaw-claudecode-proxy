#!/bin/bash
# Claude Code Proxy installer and service manager for OpenClaw on Ubuntu.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CURRENT_SCRIPT="${SCRIPT_DIR}/$(basename "$0")"
SOURCE_PACKAGE_ROOT_DEFAULT="$(cd "${SCRIPT_DIR}/.." 2> /dev/null && pwd || true)"
BASE_PATH="$PATH"
export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:${HOME}/.bun/bin:${HOME}/bin:${BASE_PATH}"
TARGET_OPENCLAW_USER=""
TARGET_USER_HOME=""
TARGET_USER_RUNTIME_DIR=""
TARGET_USER_PATH=""
OPENCLAW_HOME=""
OPENCLAW_CONFIG=""
OPENCLAW_WORKSPACE=""
INSTALL_DIR=""
INSTALL_CORE_DIR=""
INSTALLED_SCRIPT=""
INSTALLED_PROXY_JS=""
INSTALL_STATE_PATH=""
SYSTEMD_USER_DIR=""
SYSTEMD_SERVICE_NAME="claude-code-proxy.service"
SYSTEMD_SERVICE_PATH=""
LEGACY_CLEANUP_SERVICE_NAME="claude-code-proxy-cleanup.service"
LEGACY_CLEANUP_TIMER_NAME="claude-code-proxy-cleanup.timer"
DEBUG_LOG_PATH="${TMPDIR:-/tmp}/claude-code-proxy-debug.log"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DEFAULT_PORT="${PROXY_PORT:-8787}"
if [ -n "${OC_PROXY_REQUEST_TIMEOUT_MS:-}" ]; then
    DEFAULT_TIMEOUT_SECONDS="$(( (OC_PROXY_REQUEST_TIMEOUT_MS + 999) / 1000 ))"
else
    DEFAULT_TIMEOUT_SECONDS="${OC_PROXY_TIMEOUT_SECONDS:-900}"
fi
DEFAULT_LOG_LINES="${OC_PROXY_LOG_LINES:-200}"
NO_PAUSE="${OC_PROXY_NO_PAUSE:-0}"
FOLLOW_LOGS=0
LOG_LINES="$DEFAULT_LOG_LINES"
TIMEOUT_SECONDS="$DEFAULT_TIMEOUT_SECONDS"

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

Modes:
    install                   Install the proxy, patch openclaw.json, set timeoutSeconds and llm.idleTimeoutSeconds, install the user service, and start it.
  uninstall                 Stop and remove the service, clean OpenClaw config entries, and delete installed files.
  serve                     Run the proxy in the foreground. This is the mode used by systemd.
  start|stop|restart        Control the user systemd service.
  status                    Show the service status, install metadata, and key file paths.
  logs                      Show recent journal logs for the service. Use -f to follow.
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

target_user_has_command() {
    local command_name="$1"

    run_as_target_user bash -lc "command -v '$command_name' > /dev/null 2>&1"
}

require_target_command() {
    local command_name="$1"

    if ! target_user_has_command "$command_name"; then
        echo "❌ Required command not found for ${TARGET_OPENCLAW_USER}: $command_name"
        exit 1
    fi
}

verify_target_claude() {
    if ! run_as_target_user claude --version > /dev/null 2>&1; then
        echo "❌ Claude Code CLI is installed but not usable for ${TARGET_OPENCLAW_USER}. Run 'claude' to finish setup."
        exit 1
    fi
}

get_user_home() {
    local user_name="$1"

    if [ -z "$user_name" ]; then
        return 1
    fi

    if [ "$user_name" = "root" ]; then
        printf '%s\n' "/root"
        return 0
    fi

    if command -v getent > /dev/null 2>&1; then
        local passwd_entry
        passwd_entry="$(getent passwd "$user_name" || true)"

        if [ -n "$passwd_entry" ]; then
            printf '%s\n' "$passwd_entry" | cut -d: -f6
            return 0
        fi
    fi

    if [ "$user_name" = "$(id -un)" ]; then
        printf '%s\n' "$HOME"
        return 0
    fi

    return 1
}

set_openclaw_target() {
    local user_name="$1"
    local user_home="$2"

    TARGET_OPENCLAW_USER="$user_name"
    TARGET_USER_HOME="$user_home"
    TARGET_USER_RUNTIME_DIR="/run/user/$(id -u "$user_name")"
    TARGET_USER_PATH="${TARGET_USER_HOME}/.local/bin:${TARGET_USER_HOME}/.npm-global/bin:${TARGET_USER_HOME}/.bun/bin:${TARGET_USER_HOME}/bin:${BASE_PATH}"
    OPENCLAW_HOME="${TARGET_USER_HOME}/.openclaw"
    OPENCLAW_CONFIG="${OPENCLAW_HOME}/openclaw.json"
    OPENCLAW_WORKSPACE="${OPENCLAW_HOME}/workspace"
    INSTALL_DIR="${OPENCLAW_WORKSPACE}/scripts"
    INSTALL_CORE_DIR="${INSTALL_DIR}/Core"
    INSTALLED_SCRIPT="${INSTALL_DIR}/claude-code-proxy.sh"
    INSTALLED_PROXY_JS="${INSTALL_CORE_DIR}/claude-code-proxy.js"
    INSTALL_STATE_PATH="${INSTALL_DIR}/claude-code-proxy-install-state.json"
    SYSTEMD_USER_DIR="${TARGET_USER_HOME}/.config/systemd/user"
    SYSTEMD_SERVICE_PATH="${SYSTEMD_USER_DIR}/${SYSTEMD_SERVICE_NAME}"
}

candidate_has_config() {
    local user_home="$1"
    [ -f "${user_home}/.openclaw/openclaw.json" ]
}

candidate_has_install_state() {
    local user_home="$1"
    [ -f "${user_home}/.openclaw/workspace/scripts/claude-code-proxy-install-state.json" ]
}

candidate_matches_target() {
    local user_home="$1"

    if [ "$MODE" = "install" ]; then
        candidate_has_config "$user_home"
        return $?
    fi

    if candidate_has_config "$user_home" || candidate_has_install_state "$user_home"; then
        return 0
    fi

    return 1
}

resolve_openclaw_target() {
    local preferred_user
    local preferred_home
    local effective_user
    local effective_home
    local root_home="/root"

    preferred_user="${SUDO_USER:-$(id -un)}"
    preferred_home="$(get_user_home "$preferred_user" || true)"

    if [ -n "$preferred_home" ] && candidate_matches_target "$preferred_home"; then
        set_openclaw_target "$preferred_user" "$preferred_home"
        return 0
    fi

    effective_user="$(id -un)"
    effective_home="$(get_user_home "$effective_user" || true)"

    if [ -n "$effective_home" ] && [ "$effective_user" != "$preferred_user" ] && candidate_matches_target "$effective_home"; then
        set_openclaw_target "$effective_user" "$effective_home"
        return 0
    fi

    if candidate_matches_target "$root_home"; then
        set_openclaw_target "root" "$root_home"
        return 0
    fi

    return 1
}

require_target_resolution() {
    if resolve_openclaw_target; then
        return 0
    fi

    echo "❌ OpenClaw installation not found for the current user or root."
    echo "   Checked:"
    echo "   - ${SUDO_USER:-$(id -un)}: $(get_user_home "${SUDO_USER:-$(id -un)}" || printf '%s' '<unknown>')/.openclaw/openclaw.json"
    echo "   - root: /root/.openclaw/openclaw.json"
    echo "   Run 'openclaw wizard' for the intended target first."
    exit 1
}

run_as_target_user() {
    if [ -z "$TARGET_OPENCLAW_USER" ] || [ -z "$TARGET_USER_HOME" ]; then
        echo "❌ Internal error: OpenClaw target is not resolved."
        exit 1
    fi

    if [ "$(id -un)" = "$TARGET_OPENCLAW_USER" ]; then
        env PATH="$TARGET_USER_PATH" HOME="$TARGET_USER_HOME" "$@"
        return 0
    fi

    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ Installing for ${TARGET_OPENCLAW_USER} requires root privileges."
        exit 1
    fi

    if command -v runuser > /dev/null 2>&1; then
        runuser -u "$TARGET_OPENCLAW_USER" -- env PATH="$TARGET_USER_PATH" HOME="$TARGET_USER_HOME" "$@"
        return 0
    fi

    if command -v sudo > /dev/null 2>&1; then
        sudo -H -u "$TARGET_OPENCLAW_USER" env PATH="$TARGET_USER_PATH" HOME="$TARGET_USER_HOME" "$@"
        return 0
    fi

    echo "❌ Could not switch to ${TARGET_OPENCLAW_USER}; install sudo or runuser."
    exit 1
}

run_target_systemctl() {
    if [ -d "$TARGET_USER_RUNTIME_DIR" ]; then
        run_as_target_user env XDG_RUNTIME_DIR="$TARGET_USER_RUNTIME_DIR" systemctl --user "$@"
        return 0
    fi

    run_as_target_user systemctl --user "$@"
}

run_target_journalctl() {
    if [ -d "$TARGET_USER_RUNTIME_DIR" ]; then
        run_as_target_user env XDG_RUNTIME_DIR="$TARGET_USER_RUNTIME_DIR" journalctl --user "$@"
        return 0
    fi

    run_as_target_user journalctl --user "$@"
}

ensure_target_ownership() {
    if [ "$(id -u)" -ne 0 ] || [ "$TARGET_OPENCLAW_USER" = "root" ]; then
        return 0
    fi

    chown "$TARGET_OPENCLAW_USER" "$@" 2> /dev/null || true
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

backup_file() {
    local file_path="$1"
    local backup_path

    if [ -f "$file_path" ]; then
        backup_path="${file_path}.backup.${TIMESTAMP}"
        cp "$file_path" "$backup_path"
        ensure_target_ownership "$backup_path"
        echo "✅ Backed up $file_path"
    fi
}

write_install_state() {
    mkdir -p "$INSTALL_DIR"

    jq -n \
        --arg installedAt "$(date --iso-8601=seconds)" \
        --arg port "$PORT" \
        --arg timeoutSeconds "$TIMEOUT_SECONDS" \
        --arg installedForUser "$TARGET_OPENCLAW_USER" \
        --arg openclawHome "$OPENCLAW_HOME" \
        --arg installedScript "$INSTALLED_SCRIPT" \
        --arg installedProxyJs "$INSTALLED_PROXY_JS" \
        --arg serviceName "$SYSTEMD_SERVICE_NAME" \
        '{
            installedAt: $installedAt,
            port: ($port | tonumber),
            timeoutSeconds: ($timeoutSeconds | tonumber),
            idleTimeoutSeconds: ($timeoutSeconds | tonumber),
            installedForUser: $installedForUser,
            openclawHome: $openclawHome,
            installedScript: $installedScript,
            installedProxyJs: $installedProxyJs,
            serviceName: $serviceName
        }' > "$INSTALL_STATE_PATH"

    ensure_target_ownership "$INSTALL_DIR" "$INSTALL_STATE_PATH"

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
    ensure_target_ownership "$OPENCLAW_WORKSPACE" "$INSTALL_DIR" "$INSTALL_CORE_DIR" "$INSTALLED_SCRIPT" "$INSTALLED_PROXY_JS"

    echo "✅ Installed script at $INSTALLED_SCRIPT"
    echo "✅ Installed proxy JS at $INSTALLED_PROXY_JS"
}

patch_openclaw_config() {
    local tmp_file
    tmp_file="$(mktemp)"

    jq \
        --arg proxy_port "$PORT" \
        --arg timeout_seconds "$TIMEOUT_SECONDS" \
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
        | .agents.defaults.timeoutSeconds = ($timeout_seconds | tonumber)
        | .agents.defaults.llm //= {}
        | .agents.defaults.llm.idleTimeoutSeconds = ($timeout_seconds | tonumber)
        | .agents.defaults.models //= {}
        | .agents.defaults.models["claude-code-proxy/claude-opus-4-5"] = { "alias": "opus" }
        | .agents.defaults.models["claude-code-proxy/claude-sonnet-4-5"] = { "alias": "sonnet" }
        ' "$OPENCLAW_CONFIG" > "$tmp_file"

    mv "$tmp_file" "$OPENCLAW_CONFIG"
    ensure_target_ownership "$OPENCLAW_CONFIG"
    echo "✅ Patched $OPENCLAW_CONFIG"
}

remove_proxy_config_entries() {
    local tmp_file
    tmp_file="$(mktemp)"

    jq --arg timeout_seconds "$TIMEOUT_SECONDS" '
        .models //= {}
        | .models.providers = ((.models.providers // {}) | del(."claude-code-proxy"))
        | .agents //= {}
        | .agents.defaults //= {}
        | if (.agents.defaults.timeoutSeconds // null) == ($timeout_seconds | tonumber)
          then .agents.defaults |= del(.timeoutSeconds)
          else .
          end
                | if (.agents.defaults.llm.idleTimeoutSeconds // null) == ($timeout_seconds | tonumber)
                    then .agents.defaults.llm |= del(.idleTimeoutSeconds)
                    else .
                    end
                | if ((.agents.defaults.llm // {}) | keys | length) == 0
                    then .agents.defaults |= del(.llm)
                    else .
                    end
        | .agents.defaults.models = ((.agents.defaults.models // {})
            | del(."claude-code-proxy/claude-opus-4-5")
            | del(."claude-code-proxy/claude-sonnet-4-5"))
        ' "$OPENCLAW_CONFIG" > "$tmp_file"

    mv "$tmp_file" "$OPENCLAW_CONFIG"
    ensure_target_ownership "$OPENCLAW_CONFIG"
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

    ensure_target_ownership "$SYSTEMD_USER_DIR" "$SYSTEMD_SERVICE_PATH"

    echo "✅ Installed user service at $SYSTEMD_SERVICE_PATH"
}

stop_existing_units() {
    run_target_systemctl stop "$SYSTEMD_SERVICE_NAME" 2> /dev/null || true
}

remove_legacy_cleanup_units() {
    local legacy_cleanup_service_path="${SYSTEMD_USER_DIR}/${LEGACY_CLEANUP_SERVICE_NAME}"
    local legacy_cleanup_timer_path="${SYSTEMD_USER_DIR}/${LEGACY_CLEANUP_TIMER_NAME}"

    run_target_systemctl stop "$LEGACY_CLEANUP_TIMER_NAME" 2> /dev/null || true
    run_target_systemctl stop "$LEGACY_CLEANUP_SERVICE_NAME" 2> /dev/null || true
    run_target_systemctl disable "$LEGACY_CLEANUP_TIMER_NAME" > /dev/null 2>&1 || true

    rm -f "$legacy_cleanup_service_path" "$legacy_cleanup_timer_path"

    run_target_systemctl reset-failed "$LEGACY_CLEANUP_SERVICE_NAME" > /dev/null 2>&1 || true
}

remove_systemd_units() {
    stop_existing_units
    remove_legacy_cleanup_units

    run_target_systemctl disable "$SYSTEMD_SERVICE_NAME" > /dev/null 2>&1 || true

    rm -f "$SYSTEMD_SERVICE_PATH"

    run_target_systemctl daemon-reload || true
    run_target_systemctl reset-failed "$SYSTEMD_SERVICE_NAME" > /dev/null 2>&1 || true

    echo "✅ Removed systemd units"
}

enable_systemd_units() {
    run_target_systemctl daemon-reload
    run_target_systemctl enable "$SYSTEMD_SERVICE_NAME" > /dev/null
    run_target_systemctl start "$SYSTEMD_SERVICE_NAME"
    echo "✅ User service enabled and started"

    if command -v loginctl > /dev/null 2>&1; then
        if loginctl enable-linger "$TARGET_OPENCLAW_USER" > /dev/null 2>&1; then
            echo "✅ Enabled linger for $TARGET_OPENCLAW_USER"
        else
            echo "ℹ️  Could not enable linger automatically."
            echo "   If you need the proxy to start before login, run: sudo loginctl enable-linger $TARGET_OPENCLAW_USER"
        fi
    fi
}

cleanup_installed_files() {
    rm -f "$INSTALLED_SCRIPT" "$INSTALLED_PROXY_JS" "$INSTALL_STATE_PATH"
    rmdir "$INSTALL_CORE_DIR" 2> /dev/null || true
    echo "✅ Removed installed proxy files"
}

restart_gateway() {
    if target_user_has_command openclaw; then
        echo "🔄 Restarting OpenClaw gateway..."
        run_as_target_user openclaw gateway restart || echo "⚠️  Could not restart automatically. Run: openclaw gateway restart"
    else
        echo "⚠️  openclaw command not found. Please restart the gateway manually."
    fi
}

print_summary() {
    echo ""
    echo "============================================="
    echo "✅ Deployment complete"
    echo ""
    echo "Target user: $TARGET_OPENCLAW_USER"
    echo "OpenClaw home: $OPENCLAW_HOME"
    echo "Installed provider: claude-code-proxy -> http://localhost:${PORT}"
    echo "Configured timeoutSeconds: ${TIMEOUT_SECONDS}"
    echo "Configured llm.idleTimeoutSeconds: ${TIMEOUT_SECONDS}"
    echo "Proxy script: $INSTALLED_SCRIPT"
    echo "User service: $SYSTEMD_SERVICE_PATH"
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
    echo "Removed systemd service, installed proxy files, and OpenClaw proxy config entries."
    echo ""
}

show_status() {
    echo "Claude Code Proxy status"
    echo "========================"
    echo ""
    echo "Target user: $TARGET_OPENCLAW_USER"
    echo "OpenClaw home: $OPENCLAW_HOME"
    echo "OpenClaw config: $OPENCLAW_CONFIG"
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
    echo "Debug log: $DEBUG_LOG_PATH"
    echo ""

    run_target_systemctl --no-pager status "$SYSTEMD_SERVICE_NAME" || true
}

show_logs() {
    require_command journalctl

    if [ "$FOLLOW_LOGS" = "1" ]; then
        run_target_journalctl -u "$SYSTEMD_SERVICE_NAME" -n "$LOG_LINES" -f -o short-iso
        return 0
    fi

    run_target_journalctl -u "$SYSTEMD_SERVICE_NAME" -n "$LOG_LINES" --no-pager -o short-iso
}

service_control() {
    local action="$1"

    require_command systemctl
    run_target_systemctl "$action" "$SYSTEMD_SERVICE_NAME"
}

run_proxy() {
    local proxy_js
    proxy_js="$(resolve_proxy_js)"

    require_target_command claude
    require_target_command node
    verify_target_claude

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
    echo "OpenClaw timeoutSeconds and llm.idleTimeoutSeconds will be set to ${TIMEOUT_SECONDS} to match the proxy request timeout."
    echo ""

    if [ ! -f "$OPENCLAW_CONFIG" ]; then
        echo "❌ OpenClaw config not found at $OPENCLAW_CONFIG"
        echo "   Run 'openclaw wizard' first on the target machine."
        exit 1
    fi

    require_command jq
    require_command systemctl
    require_target_command node
    require_target_command claude
    verify_target_claude

    echo "Using OpenClaw install for ${TARGET_OPENCLAW_USER}: $OPENCLAW_HOME"

    backup_file "$OPENCLAW_CONFIG"
    install_files
    write_install_state
    patch_openclaw_config
    stop_existing_units
    remove_legacy_cleanup_units
    run_target_systemctl daemon-reload || true
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

case "$MODE" in
    install)
        require_target_resolution
        install_proxy
        pause_if_interactive
        ;;
    uninstall)
        require_target_resolution
        uninstall_proxy
        pause_if_interactive
        ;;
    serve)
        require_target_resolution
        run_proxy
        ;;
    start)
        require_target_resolution
        service_control start
        ;;
    stop)
        require_target_resolution
        service_control stop
        ;;
    restart)
        require_target_resolution
        service_control restart
        ;;
    status)
        require_target_resolution
        show_status
        ;;
    logs)
        require_target_resolution
        show_logs
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
