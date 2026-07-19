#!/bin/bash
# Deploy the Agent Shell on a Linux host with systemd.
# Usage: deploy.sh [--port PORT] [--auth USER:PASS] [--host HOST] [--user USER]
# Legacy positional form is also accepted: deploy.sh PORT USER:PASS [HOST]
set -euo pipefail

PORT="4096"
AUTH="${AGENT_SHELL_AUTH:-}"
HOST="0.0.0.0"
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    DEFAULT_AGENT_USER="$SUDO_USER"
else
    DEFAULT_AGENT_USER="$(id -un)"
fi
AGENT_USER="${AGENT_SHELL_USER:-$DEFAULT_AGENT_USER}"
INSTALL_DIR="${AGENT_SHELL_INSTALL_DIR:-/opt/opencode-agent}"
WORKING_DIR="${AGENT_SHELL_WORKING_DIR:-}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SERVICE_NAME="${AGENT_SHELL_SERVICE:-opencode-agent}"
MAX_RESPONSE_BYTES=1048576
POSITIONAL_INDEX=0
OPTION_MODE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --port)
            OPTION_MODE=1
            [ "$#" -ge 2 ] || { echo "--port 需要参数" >&2; exit 2; }
            PORT="$2"; shift 2
            ;;
        --auth)
            OPTION_MODE=1
            [ "$#" -ge 2 ] || { echo "--auth 需要参数" >&2; exit 2; }
            AUTH="$2"; shift 2
            ;;
        --host)
            OPTION_MODE=1
            [ "$#" -ge 2 ] || { echo "--host 需要参数" >&2; exit 2; }
            HOST="$2"; shift 2
            ;;
        --user)
            OPTION_MODE=1
            [ "$#" -ge 2 ] || { echo "--user 需要参数" >&2; exit 2; }
            AGENT_USER="$2"; shift 2
            ;;
        --install-dir)
            OPTION_MODE=1
            [ "$#" -ge 2 ] || { echo "--install-dir 需要参数" >&2; exit 2; }
            INSTALL_DIR="$2"; shift 2
            ;;
        --help|-h)
            sed -n '2,4p' "$0"
            exit 0
            ;;
        --*)
            echo "未知参数: $1" >&2
            exit 2
            ;;
        *)
            if [ "$OPTION_MODE" -eq 1 ]; then
                echo "位置参数形式不能与 --port/--auth/--host 等选项混用" >&2
                exit 2
            fi
            case "$POSITIONAL_INDEX" in
                0) PORT="$1" ;;
                1) AUTH="$1" ;;
                2) HOST="$1" ;;
                *) echo "多余参数: $1" >&2; exit 2 ;;
            esac
            POSITIONAL_INDEX=$((POSITIONAL_INDEX + 1))
            shift
            ;;
    esac
done

case "$PORT" in
    ''|*[!0-9]*) echo "无效端口: $PORT" >&2; exit 2 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "端口必须在 1-65535 之间" >&2
    exit 2
fi

case "$AUTH" in
    *[[:space:]]*|*'"'*|*'\\'*)
        echo "认证值不能包含空白、引号或反斜杠" >&2
        exit 2
        ;;
esac

case "$HOST" in
    *[[:space:]]*|*'"'*|*'\\'*)
        echo "监听地址不能包含空白、引号或反斜杠" >&2
        exit 2
        ;;
esac
case "$INSTALL_DIR" in
    /*) ;;
    *) echo "安装目录必须是绝对路径: $INSTALL_DIR" >&2; exit 2 ;;
esac
case "$INSTALL_DIR" in
    *[[:space:]]*|*'"'*|*'\\'*)
        echo "安装目录不能包含空白、引号或反斜杠" >&2
        exit 2
        ;;
esac
case "$SERVICE_NAME" in
    ''|*[!A-Za-z0-9_.@-]*)
        echo "无效服务名: $SERVICE_NAME" >&2
        exit 2
        ;;
esac
case "$AGENT_USER" in
    ''|*[!A-Za-z0-9._@-]*)
        echo "无效服务用户: $AGENT_USER" >&2
        exit 2
        ;;
esac

case "$HOST" in
    127.0.0.1|localhost|::1|\[::1\])
        ;;
    *)
        [ -n "$AUTH" ] || {
            echo "远程监听必须提供 --auth USER:PASS；或使用 --host 127.0.0.1" >&2
            exit 2
        }
        ;;
esac

OPENCODE_PATH="$(command -v opencode 2>/dev/null || true)"
[ -n "$OPENCODE_PATH" ] || {
    echo "opencode 未安装。请先安装 OpenCode CLI。" >&2
    exit 1
}
PYTHON_PATH="$(command -v python3 2>/dev/null || true)"
[ -n "$PYTHON_PATH" ] || {
    echo "python3 未安装。" >&2
    exit 1
}
AGENT_HOME="$("$PYTHON_PATH" - "$AGENT_USER" <<'PY' 2>/dev/null || true
import pwd
import sys

try:
    print(pwd.getpwnam(sys.argv[1]).pw_dir)
except KeyError:
    raise SystemExit(1)
PY
)"
[ -n "$AGENT_HOME" ] || {
    echo "服务用户不存在: $AGENT_USER" >&2
    exit 2
}
if [ "$(id -u)" -eq 0 ] && [ "$AGENT_USER" != "$(id -un)" ]; then
    sudo -u "$AGENT_USER" test -x "$OPENCODE_PATH" 2>/dev/null || {
        echo "服务用户 $AGENT_USER 无法执行 opencode: $OPENCODE_PATH" >&2
        exit 2
    }
fi
if [ -z "$WORKING_DIR" ]; then
    WORKING_DIR="$AGENT_HOME"
fi
case "$WORKING_DIR" in
    /*) ;;
    *) echo "工作目录必须是绝对路径: $WORKING_DIR" >&2; exit 2 ;;
esac
case "$WORKING_DIR" in
    *$'\n'*|*$'\r'*|*'"'*|*'\\'*)
        echo "工作目录不能包含换行、引号或反斜杠" >&2
        exit 2
        ;;
esac
[ -d "$WORKING_DIR" ] || {
    echo "工作目录不存在: $WORKING_DIR" >&2
    exit 2
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🚀 OpenCode Agent Shell 部署"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  opencode: $OPENCODE_PATH"
echo "  python3:  $PYTHON_PATH"
echo "  监听:     $HOST:$PORT"
echo "  认证:     $( [ -n "$AUTH" ] && echo enabled || echo disabled )"
echo "  用户:     $AGENT_USER"
echo "  工作目录: $WORKING_DIR"

sudo mkdir -p "$INSTALL_DIR"
sudo install -m 755 "$SCRIPT_DIR/agent_shell.py" "$INSTALL_DIR/agent_shell.py"

ENV_FILE="/etc/$SERVICE_NAME.env"
UNIT_FILE="/etc/systemd/system/$SERVICE_NAME.service"
sudo tee "$ENV_FILE" >/dev/null <<EOF
AGENT_SHELL_AUTH=$AUTH
OPENCODE_BIN=$OPENCODE_PATH
HOME=$AGENT_HOME
AGENT_SHELL_TASK_TIMEOUT=${AGENT_SHELL_TASK_TIMEOUT:-}
EOF
sudo chmod 600 "$ENV_FILE"

sudo tee "$UNIT_FILE" >/dev/null <<EOF
[Unit]
Description=OpenCode Agent Shell (HTTP handshake)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart="$PYTHON_PATH" "$INSTALL_DIR/agent_shell.py" --host "$HOST" --port "$PORT"
Restart=always
RestartSec=5
User=$AGENT_USER
WorkingDirectory=$WORKING_DIR

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"
sleep 2

check_local_health() {
    if [ -n "$AUTH" ]; then
        curl -fsS --max-time 5 --max-redirs 0 --max-filesize "$MAX_RESPONSE_BYTES" -u "$AUTH" "http://127.0.0.1:$PORT/health" >/dev/null 2>&1
    else
        curl -fsS --max-time 5 --max-redirs 0 --max-filesize "$MAX_RESPONSE_BYTES" "http://127.0.0.1:$PORT/health" >/dev/null 2>&1
    fi
}
if check_local_health; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ 部署成功"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  地址: http://$HOST:$PORT"
    echo "  状态: $(sudo systemctl is-active "$SERVICE_NAME")"
    echo ""
    echo "  本地验证:"
    if [ -n "$AUTH" ]; then
        echo "  curl -u '<user:pass>' http://127.0.0.1:$PORT/health"
    else
        echo "  curl http://127.0.0.1:$PORT/health"
    fi
    echo ""
    echo "  本地电脑注册:"
    echo "  bash scripts/accept.sh $(hostname) http://REMOTE_HOST:$PORT '<user:pass>' agent-shell"
else
    echo "❌ 服务启动失败，查看日志:"
    echo "  sudo journalctl -u $SERVICE_NAME -n 50 --no-pager" >&2
    exit 1
fi
