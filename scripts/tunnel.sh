#!/bin/bash
# Manage a Cloudflare Quick Tunnel for a local agent HTTP service.
# Usage: tunnel.sh [start|stop|status] [port]
set -euo pipefail

ACTION="${1:-start}"
LOCAL_PORT="${2:-${OPENCODE_PORT:-4096}}"
AUTH="${OPENCODE_AUTH:-${AGENT_SHELL_AUTH:-}}"
START_TIMEOUT="${OPENCODE_TUNNEL_TIMEOUT:-30}"
TUNNEL_PROTOCOL="${OPENCODE_TUNNEL_PROTOCOL:-http2}"
MAX_RESPONSE_BYTES=1048576
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SKILL_DIR="${OPENCODE_SKILL_DIR:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}"
STATE_DIR="${OPENCODE_TUNNEL_STATE_DIR:-${TMPDIR:-/tmp}/opencode-tunnel-${UID:-$(id -u)}}"
PID_FILE="$STATE_DIR/opencode-tunnel.pid"
URL_FILE="$STATE_DIR/opencode-tunnel.url"
LOG_FILE="$STATE_DIR/opencode-tunnel.log"
HEALTH_FILE="$STATE_DIR/opencode-tunnel.health"
BIN_FILE="$STATE_DIR/opencode-tunnel.bin"
CONFIG_FILE="$STATE_DIR/cloudflared.yml"
LOCK_FILE="$STATE_DIR/.lock"
LOCK_HELD=0
START_PID=""
START_BINARY=""
START_COMPLETE=0

if [ "$ACTION" = "--help" ] || [ "$ACTION" = "-h" ]; then
    echo "用法: tunnel.sh [start|stop|status] [port]"
    echo "环境变量: OPENCODE_AUTH AGENT_SHELL_AUTH OPENCODE_TUNNEL_PROTOCOL OPENCODE_TUNNEL_TIMEOUT OPENCODE_TUNNEL_STATE_DIR"
    exit 0
fi

case "$LOCAL_PORT" in
    ''|*[!0-9]*) echo "无效端口: $LOCAL_PORT" >&2; exit 2 ;;
esac
if [ "$LOCAL_PORT" -lt 1 ] || [ "$LOCAL_PORT" -gt 65535 ]; then
    echo "端口必须在 1-65535 之间" >&2
    exit 2
fi
case "$START_TIMEOUT" in
    ''|*[!0-9]*|0) echo "无效隧道启动超时: $START_TIMEOUT" >&2; exit 2 ;;
esac
case "$TUNNEL_PROTOCOL" in
    auto|quic|http2) ;;
    *) echo "无效隧道传输协议: $TUNNEL_PROTOCOL (可选 auto|quic|http2)" >&2; exit 2 ;;
esac

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

release_state_lock() {
    if [ "$LOCK_HELD" -eq 1 ]; then
        rm -f "$LOCK_FILE"
        LOCK_HELD=0
    fi
}

acquire_state_lock() {
    local owner_file="$STATE_DIR/.lock.$$"
    printf '%s\n' "$$" > "$owner_file"
    if ln "$owner_file" "$LOCK_FILE" 2>/dev/null; then
        rm -f "$owner_file"
        chmod 600 "$LOCK_FILE"
        LOCK_HELD=1
        return 0
    fi
    rm -f "$owner_file"
    local lock_pid=""
    lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    case "$lock_pid" in
        ''|*[!0-9]*) lock_pid="" ;;
    esac
    if [ -z "$lock_pid" ] || ! kill -0 "$lock_pid" 2>/dev/null; then
        rm -f "$LOCK_FILE"
        owner_file="$STATE_DIR/.lock.$$"
        printf '%s\n' "$$" > "$owner_file"
        if ln "$owner_file" "$LOCK_FILE" 2>/dev/null; then
            rm -f "$owner_file"
            chmod 600 "$LOCK_FILE"
            LOCK_HELD=1
            return 0
        fi
        rm -f "$owner_file"
    fi
    echo "隧道状态正在被另一个操作使用 (PID: ${lock_pid:-unknown})" >&2
    return 1
}

detect_cloudflared() {
    if command -v cloudflared >/dev/null 2>&1; then
        command -v cloudflared
        return 0
    fi
    for candidate in /usr/local/bin/cloudflared /usr/bin/cloudflared /opt/homebrew/bin/cloudflared; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

install_cloudflared() {
    local system architecture url temp_file
    system="$(uname -s)"
    architecture="$(uname -m)"
    case "$system" in
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                brew install cloudflared
                return
            fi
            echo "macOS 请先安装 Homebrew，再运行: brew install cloudflared" >&2
            return 1
            ;;
        Linux)
            case "$architecture" in
                x86_64|amd64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
                aarch64|arm64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
                armv7l|armv7) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
                *) echo "不支持的 Linux 架构: $architecture" >&2; return 1 ;;
            esac
            temp_file="$(mktemp "$STATE_DIR/cloudflared.XXXXXX")"
            if ! curl -fsSL "$url" -o "$temp_file"; then
                rm -f "$temp_file"
                return 1
            fi
            chmod 755 "$temp_file"
            sudo install -m 755 "$temp_file" /usr/local/bin/cloudflared
            rm -f "$temp_file"
            ;;
        *)
            echo "不支持的系统: $system" >&2
            return 1
            ;;
    esac
}

curl_request() {
    if [ -n "$AUTH" ]; then
        curl -fsS --max-time 5 --max-redirs 0 --max-filesize "$MAX_RESPONSE_BYTES" -u "$AUTH" "$@"
    else
        curl -fsS --max-time 5 --max-redirs 0 --max-filesize "$MAX_RESPONSE_BYTES" "$@"
    fi
}

probe_local_health() {
    local base="http://127.0.0.1:$LOCAL_PORT"
    local path
    for path in /global/health /health; do
        if curl_request "$base$path" >/dev/null 2>&1; then
            if curl -fsS --max-time 5 --max-redirs 0 --max-filesize "$MAX_RESPONSE_BYTES" "$base$path" >/dev/null 2>&1; then
                echo "本地服务 $path 未拒绝匿名请求；拒绝公开未认证服务" >&2
                return 1
            fi
            printf '%s\n' "$path"
            return 0
        fi
    done
    return 1
}

is_owned_process() {
    local pid="$1"
    local expected_binary="$2"
    local command_line=""
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$expected_binary" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command_line" in
        *"$expected_binary"*tunnel*--url*) return 0 ;;
        *) return 1 ;;
    esac
}

process_running() {
    [ -f "$PID_FILE" ] && [ -f "$BIN_FILE" ] || return 1
    local pid expected_binary
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    expected_binary="$(cat "$BIN_FILE" 2>/dev/null || true)"
    is_owned_process "$pid" "$expected_binary"
}

terminate_owned_process() {
    local pid="$1"
    local expected_binary="$2"
    local i=0
    is_owned_process "$pid" "$expected_binary" || return 1
    if command -v pkill >/dev/null 2>&1; then
        pkill -TERM -P "$pid" 2>/dev/null || true
    fi
    kill "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 30 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

terminate_started_process() {
    local pid="$1"
    local i=0
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    if command -v pkill >/dev/null 2>&1; then
        pkill -TERM -P "$pid" 2>/dev/null || true
    fi
    kill "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 30 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

remove_state() {
    rm -f "$PID_FILE" "$URL_FILE" "$HEALTH_FILE" "$BIN_FILE" "$CONFIG_FILE" "$LOG_FILE"
}

cleanup_incomplete_start() {
    local exit_code=$?
    if [ "$START_COMPLETE" -ne 1 ] && [ -n "$START_PID" ]; then
        terminate_started_process "$START_PID" || true
        remove_state
        update_identity false "" >/dev/null 2>&1 || true
    fi
    release_state_lock
    return "$exit_code"
}

update_identity() {
    local active="$1"
    local tunnel_url="${2:-}"
    local hostname identity_file
    hostname="$(hostname 2>/dev/null || printf unknown)"
    case "$hostname" in
        ''|*[!A-Za-z0-9._-]*) return 0 ;;
    esac
    identity_file="$SKILL_DIR/references/servers/$hostname.json"
    [ -f "$identity_file" ] || return 0
    TUNNEL_ACTIVE="$active" TUNNEL_URL="$tunnel_url" TUNNEL_PORT="$LOCAL_PORT" \
        python3 - "$identity_file" <<'PY'
import json
import os
import sys
from datetime import datetime
import tempfile

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
active = os.environ["TUNNEL_ACTIVE"] == "true"
data["tunnel"] = {
    "url": os.environ.get("TUNNEL_URL", ""),
    "type": "cloudflare-quick",
    "port": int(os.environ["TUNNEL_PORT"]),
    "active": active,
    "updated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
}
directory = os.path.dirname(path) or "."
mode = os.stat(path).st_mode & 0o777
fd, temporary = tempfile.mkstemp(prefix=".tunnel-identity.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(temporary, mode or 0o600)
    os.replace(temporary, path)
except Exception:
    try:
        os.unlink(temporary)
    except OSError:
        pass
    raise
PY
}

start_tunnel() {
    if [ -z "$AUTH" ]; then
        echo "Quick Tunnel 必须设置 OPENCODE_AUTH 或 AGENT_SHELL_AUTH；拒绝公开未认证服务" >&2
        return 2
    fi
    if process_running; then
        echo "隧道已运行 (PID: $(cat "$PID_FILE"))；请先执行 stop" >&2
        return 1
    fi
    remove_state

    local health_path cloudflared pid tunnel_url i remote_ready
    if ! health_path="$(probe_local_health)"; then
        echo "本地端口 $LOCAL_PORT 没有可用的 /global/health 或 /health 服务" >&2
        return 1
    fi

    cloudflared="$(detect_cloudflared || true)"
    if [ -z "$cloudflared" ]; then
        install_cloudflared
        cloudflared="$(detect_cloudflared || true)"
    fi
    [ -n "$cloudflared" ] || { echo "cloudflared 未安装" >&2; return 1; }

    : > "$LOG_FILE"
    printf '%s\n' '{}' > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    printf '%s\n' "$cloudflared" > "$BIN_FILE"
    START_BINARY="$cloudflared"
    START_COMPLETE=0
    trap cleanup_incomplete_start EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    "$cloudflared" tunnel --config "$CONFIG_FILE" --url "http://127.0.0.1:$LOCAL_PORT" \
        --protocol "$TUNNEL_PROTOCOL" --no-autoupdate >"$LOG_FILE" 2>&1 &
    pid=$!
    START_PID="$pid"
    printf '%s\n' "$pid" > "$PID_FILE"
    printf '%s\n' "$health_path" > "$HEALTH_FILE"

    tunnel_url=""
    i=0
    while [ "$i" -lt "$START_TIMEOUT" ]; do
        sleep 1
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        tunnel_url="$(sed -nE 's#.*(https://[[:alnum:]-]+\.trycloudflare\.com).*#\1#p' "$LOG_FILE" | head -1)"
        [ -n "$tunnel_url" ] && break
        i=$((i + 1))
    done

    if [ -z "$tunnel_url" ]; then
        echo "隧道建立失败；最后日志：" >&2
        tail -10 "$LOG_FILE" >&2 || true
        return 1
    fi

    remote_ready=0
    i=0
    while [ "$i" -lt "$START_TIMEOUT" ]; do
        if curl_request "$tunnel_url$health_path" >/dev/null 2>&1; then
            remote_ready=1
            break
        fi
        is_owned_process "$pid" "$cloudflared" || break
        sleep 1
        i=$((i + 1))
    done
    if [ "$remote_ready" -ne 1 ]; then
        echo "隧道 URL 已生成，但远程健康检查未通过: $tunnel_url$health_path" >&2
        return 1
    fi

    printf '%s\n' "$tunnel_url" > "$URL_FILE"
    chmod 600 "$PID_FILE" "$URL_FILE" "$HEALTH_FILE" "$LOG_FILE" "$BIN_FILE"
    update_identity true "$tunnel_url"
    START_COMPLETE=1
    START_PID=""
    trap - EXIT INT TERM
    release_state_lock

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ Cloudflare Quick Tunnel 已建立"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  公网地址: $tunnel_url"
    echo "  本地服务: http://127.0.0.1:$LOCAL_PORT$health_path"
    echo "  PID:      $pid"
    echo ""
    echo "  本地电脑注册:"
    echo "  bash scripts/accept.sh $(hostname) $tunnel_url '<user:pass>'"
    echo ""
    echo "  注意: Quick Tunnel 仅适合测试和临时连接，不提供生产 SLA。"
}

stop_tunnel() {
    local pid=""
    if [ -f "$PID_FILE" ]; then
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    fi
    if process_running; then
        terminate_owned_process "$pid" "$(cat "$BIN_FILE")" || true
        echo "✅ 隧道已停止 (PID: $pid)"
    else
        echo "隧道未运行；未终止任何非本脚本进程"
    fi
    remove_state
    update_identity false ""
}

status_tunnel() {
    local url="" health_path="/health"
    [ -f "$URL_FILE" ] && url="$(cat "$URL_FILE")"
    [ -f "$HEALTH_FILE" ] && health_path="$(cat "$HEALTH_FILE")"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔗 隧道状态"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if process_running; then
        echo "  状态: 运行中 (PID: $(cat "$PID_FILE"))"
    else
        echo "  状态: 未运行"
        [ -n "$url" ] && echo "  URL:  $url (陈旧状态)"
        [ -n "$url" ] && return 1
    fi
    echo "  URL:  ${url:-(无记录)}"
    if [ -n "$url" ]; then
        if curl_request "$url$health_path" >/dev/null 2>&1; then
            echo "  连通: 可达"
        else
            echo "  连通: 不可达"
            return 1
        fi
    fi
}

case "$ACTION" in
    start|stop|status)
        acquire_state_lock || exit 1
        trap release_state_lock EXIT
        "$ACTION"_tunnel
        release_state_lock
        trap - EXIT
        ;;
    *)
        echo "用法: tunnel.sh [start|stop|status] [port]" >&2
        exit 2
        ;;
esac
