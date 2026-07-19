#!/bin/bash
# OpenCode 快速握手 — 服务器侧身份注册
# 在安装了 OpenCode CLI 的服务器上运行，生成机器身份牌
# 用法: register.sh
# 输出: 块式身份牌 + 保存到 references/servers/<hostname>.json
set -euo pipefail

AGENT_TYPE="${1:-auto}"  # auto | opencode | langchain | crewai | generic | mcp
SKILL_DIR="${OPENCODE_SKILL_DIR:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
SERVERS_DIR="$SKILL_DIR/references/servers"
AUTH="${OPENCODE_AUTH:-${AGENT_SHELL_AUTH:-}}"
MAX_RESPONSE_BYTES=1048576
mkdir -p "$SERVERS_DIR"

curl_local() {
    if [ -n "$AUTH" ]; then
        curl -sf --max-time 3 --max-redirs 0 --max-filesize "$MAX_RESPONSE_BYTES" -u "$AUTH" "$@"
    else
        curl -sf --max-time 3 --max-redirs 0 --max-filesize "$MAX_RESPONSE_BYTES" "$@"
    fi
}

# ── 采集机器身份 ──
HOSTNAME=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")
case "$HOSTNAME" in
    ''|*[!A-Za-z0-9._-]*)
        echo "❌ 非法主机名，无法生成安全文件名: $HOSTNAME" >&2
        exit 2
        ;;
esac
OS=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || uname -s)
KERNEL=$(uname -r)
ARCH=$(uname -m)
CPU=$(lscpu 2>/dev/null | grep "Model name" | cut -d: -f2 | xargs || echo "unknown")
MEM=$(free -h 2>/dev/null | awk '/Mem:/{print $2}' || echo "unknown")
DISK=$(df -h / 2>/dev/null | awk 'NR==2{print $2", 已用"$3", 可用"$4}' || echo "unknown")
UPTIME=$(uptime -p 2>/dev/null | sed 's/up //' || uptime 2>/dev/null | awk -F'up' '{print $2}' | awk -F',' '{print $1}' | xargs)

# ── 网络 ──
if command -v ip >/dev/null 2>&1; then
    LAN_IPS=$(ip -4 addr show 2>/dev/null | awk '/inet / {sub(/\/.*/, "", $2); if ($2 !~ /^127\./) print $2}' | head -5 || true)
else
    LAN_IPS=$(ifconfig 2>/dev/null | awk '/inet / {if ($2 !~ /^127\./) print $2}' | head -5 || true)
fi
if [ "${OPENCODE_SKIP_PUBLIC_IP:-0}" = "1" ]; then
    PUBLIC_IP=""
else
    PUBLIC_IP=$(curl -sf --max-time 5 --max-filesize "$MAX_RESPONSE_BYTES" https://ifconfig.me 2>/dev/null ||
                curl -sf --max-time 5 --max-filesize "$MAX_RESPONSE_BYTES" https://api.ipify.org 2>/dev/null || echo "")
fi

# ── OpenCode 检测 ──
OPENCODE_PATH=$(command -v opencode 2>/dev/null || echo "")
if [ -n "$OPENCODE_PATH" ]; then
    OPENCODE_VER=$(opencode --version 2>/dev/null | head -1 || echo "?")
else
    OPENCODE_VER="未安装"
fi

# ── OpenCode Serve 检测 ──
SERVE_PORT="${OPENCODE_PORT:-4096}"
case "$SERVE_PORT" in
    ''|*[!0-9]*) echo "❌ 无效端口: $SERVE_PORT" >&2; exit 2 ;;
esac
if [ "$SERVE_PORT" -lt 1 ] || [ "$SERVE_PORT" -gt 65535 ]; then
    echo "❌ 端口必须在 1-65535 之间" >&2
    exit 2
fi
SERVE_RUNNING=0
if curl_local "http://127.0.0.1:$SERVE_PORT/global/health" > /dev/null 2>&1; then
    SERVE_RUNNING=1
    SERVE_VER=$(curl_local "http://127.0.0.1:$SERVE_PORT/global/health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
elif curl_local "http://127.0.0.1:$SERVE_PORT/health" > /dev/null 2>&1; then
    SERVE_RUNNING=1
    SERVE_VER=$(curl_local "http://127.0.0.1:$SERVE_PORT/health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
else
    SERVE_VER="?"
fi

# ── Agent 类型检测 ──
DETECT_AGENT_TYPE() {
    local port="${1:-$SERVE_PORT}"
    local resp=""
    
    # Try OpenCode-specific health endpoint
    resp=$(curl_local "http://127.0.0.1:$port/global/health" 2>/dev/null || echo "")
    if printf '%s' "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("healthy") is True else 1)' 2>/dev/null; then
        echo "opencode"
        return
    fi
    
    # Try generic /health
    resp=$(curl_local "http://127.0.0.1:$port/health" 2>/dev/null || echo "")
    if printf '%s' "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("status") in ("ok", "healthy", "ready", True) else 1)' 2>/dev/null; then
        HEALTH_PROTOCOL=$(printf '%s' "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("protocol", d.get("agent", "")))' 2>/dev/null || true)
        case "$HEALTH_PROTOCOL" in
            agent-shell|opencode-shell)
                echo "agent-shell"
                return
                ;;
        esac
        # Check for framework-specific signatures
        if curl_local "http://127.0.0.1:$port/openapi.json" > /dev/null 2>&1; then
            OPENAPI=$(curl_local "http://127.0.0.1:$port/openapi.json" 2>/dev/null || echo "")
            if echo "$OPENAPI" | grep -q "langserve\|langgraph\|langchain"; then
                echo "langchain"
                return
            fi
            if echo "$OPENAPI" | grep -q "crewai\|crew"; then
                echo "crewai"
                return
            fi
        fi
        if curl_local "http://127.0.0.1:$port/docs" > /dev/null 2>&1; then
            echo "generic-fastapi"
            return
        fi
        echo "generic"
        return
    fi
    
    # Try MCP
    resp=$(curl_local "http://127.0.0.1:$port/mcp" 2>/dev/null || echo "")
    if [ -n "$resp" ] && printf '%s' "$resp" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        echo "mcp"
        return
    fi
    
    echo "unknown"
}

if [ "$AGENT_TYPE" = "auto" ]; then
    AGENT_TYPE=$(DETECT_AGENT_TYPE "$SERVE_PORT")
fi

# ── 协议信息（按 agent 类型） ──
case "$AGENT_TYPE" in
    opencode)
        PROTOCOL='{"health":"GET /global/health","session":"POST /session","message":"POST /session/:id/message","auth":"Basic"}'
        ;;
    agent-shell)
        PROTOCOL='{"health":"GET /health","run":"POST /run","auth":"Basic"}'
        ;;
    langchain|generic-fastapi)
        PROTOCOL='{"health":"GET /health","chat":"POST /chat","auth":"none"}'
        ;;
    crewai)
        PROTOCOL='{"health":"GET /health","chat":"POST /chat","auth":"none"}'
        ;;
    mcp)
        PROTOCOL='{"health":"GET /mcp","tools":"MCP protocol","auth":"configured"}'
        ;;
    generic)
        PROTOCOL='{"health":"GET /health","auth":"none"}'
        ;;
    *)
        PROTOCOL='{"health":"GET /health","auth":"unknown"}'
        ;;
esac

# ── 隧道检测 ──
TUNNEL_URL=""
TUNNEL_TYPE=""
OPENCODE_TUNNEL_STATE_DIR="${OPENCODE_TUNNEL_STATE_DIR:-${TMPDIR:-/tmp}/opencode-tunnel-${UID:-$(id -u)}}"
TUNNEL_STATE_DIR="$OPENCODE_TUNNEL_STATE_DIR"
TUNNEL_URL_FILE="$TUNNEL_STATE_DIR/opencode-tunnel.url"
TUNNEL_PID_FILE="$TUNNEL_STATE_DIR/opencode-tunnel.pid"
TUNNEL_BIN_FILE="$TUNNEL_STATE_DIR/opencode-tunnel.bin"
if [ -f "$TUNNEL_URL_FILE" ] && [ -f "$TUNNEL_PID_FILE" ] && [ -f "$TUNNEL_BIN_FILE" ]; then
    TUNNEL_PID=$(cat "$TUNNEL_PID_FILE" 2>/dev/null || true)
    TUNNEL_BIN=$(cat "$TUNNEL_BIN_FILE" 2>/dev/null || true)
    case "$TUNNEL_PID" in
        ''|*[!0-9]*) TUNNEL_PID="" ;;
    esac
    TUNNEL_COMMAND=""
    [ -z "$TUNNEL_PID" ] || TUNNEL_COMMAND=$(ps -p "$TUNNEL_PID" -o command= 2>/dev/null || true)
    if [ -n "$TUNNEL_BIN" ]; then
        case "$TUNNEL_COMMAND" in
            *"$TUNNEL_BIN"*tunnel*--url*)
                CANDIDATE_TUNNEL_URL=$(cat "$TUNNEL_URL_FILE" 2>/dev/null || true)
                case "$CANDIDATE_TUNNEL_URL" in
                    https://[[:alnum:]-]*.trycloudflare.com)
                        if curl_local "$CANDIDATE_TUNNEL_URL/health" >/dev/null 2>&1 || \
                           curl_local "$CANDIDATE_TUNNEL_URL/global/health" >/dev/null 2>&1; then
                            TUNNEL_URL="$CANDIDATE_TUNNEL_URL"
                            TUNNEL_TYPE="cloudflare-quick"
                        fi
                        ;;
                esac
                ;;
        esac
    fi
fi

# ── SSH 指纹 ──
SSH_FP=""
for f in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
    if [ -f "$f" ]; then
        SSH_FP=$(ssh-keygen -lf "$f" 2>/dev/null | awk '{print $2}' || echo "")
        [ -n "$SSH_FP" ] && break
    fi
done

# ── 生成时间戳 ──
GEN_TIME=$(date '+%Y-%m-%d %H:%M:%S %Z')
GEN_UNIX=$(date +%s)

# ── 输出 JSON 身份牌 ──
IDENTITY_FILE="$SERVERS_DIR/$HOSTNAME.json"

REGISTER_HOSTNAME="$HOSTNAME" \
REGISTER_AGENT_TYPE="$AGENT_TYPE" \
REGISTER_PROTOCOL="$PROTOCOL" \
REGISTER_OS="$OS" \
REGISTER_KERNEL="$KERNEL" \
REGISTER_ARCH="$ARCH" \
REGISTER_CPU="$CPU" \
REGISTER_MEMORY="$MEM" \
REGISTER_DISK="$DISK" \
REGISTER_UPTIME="$UPTIME" \
REGISTER_LAN_IPS="$LAN_IPS" \
REGISTER_PUBLIC_IP="$PUBLIC_IP" \
REGISTER_OPENCODE_PATH="$OPENCODE_PATH" \
REGISTER_OPENCODE_VER="$OPENCODE_VER" \
REGISTER_SERVE_PORT="$SERVE_PORT" \
REGISTER_SERVE_RUNNING="$SERVE_RUNNING" \
REGISTER_SERVE_VER="$SERVE_VER" \
REGISTER_SSH_FP="$SSH_FP" \
REGISTER_TUNNEL_URL="$TUNNEL_URL" \
REGISTER_TUNNEL_TYPE="$TUNNEL_TYPE" \
REGISTER_GEN_TIME="$GEN_TIME" \
REGISTER_GEN_UNIX="$GEN_UNIX" \
python3 - "$IDENTITY_FILE" <<'PY'
import json
import os
import sys

def env(name, default=""):
    return os.environ.get(name, default)

tunnel_url = env("REGISTER_TUNNEL_URL")
identity = {
    "hostname": env("REGISTER_HOSTNAME"),
    "agent_type": env("REGISTER_AGENT_TYPE"),
    "protocol": json.loads(env("REGISTER_PROTOCOL", "{}")),
    "os": env("REGISTER_OS"),
    "kernel": env("REGISTER_KERNEL"),
    "arch": env("REGISTER_ARCH"),
    "cpu": env("REGISTER_CPU"),
    "memory": env("REGISTER_MEMORY"),
    "disk": env("REGISTER_DISK"),
    "uptime": env("REGISTER_UPTIME"),
    "network": {
        "lan_ips": [ip for ip in env("REGISTER_LAN_IPS").split() if ip],
        "public_ip": env("REGISTER_PUBLIC_IP").strip() or None,
    },
    "opencode": {
        "path": env("REGISTER_OPENCODE_PATH"),
        "version": env("REGISTER_OPENCODE_VER"),
        "serve_port": int(env("REGISTER_SERVE_PORT", "4096")),
        "serve_running": env("REGISTER_SERVE_RUNNING") == "1",
        "serve_version": env("REGISTER_SERVE_VER"),
    },
    "ssh_fingerprint": env("REGISTER_SSH_FP"),
    "tunnel": {
        "url": tunnel_url,
        "type": env("REGISTER_TUNNEL_TYPE"),
        "active": bool(tunnel_url),
    } if tunnel_url else None,
    "generated_at": env("REGISTER_GEN_TIME"),
    "generated_unix": int(env("REGISTER_GEN_UNIX", "0")),
}

with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(identity, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
print(json.dumps(identity, ensure_ascii=False, indent=2))
PY
chmod 600 "$IDENTITY_FILE"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🖥️  服务器身份牌已生成"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  主机名:   $HOSTNAME"
echo "  系统:     $OS ($KERNEL)"
echo "  架构:     $ARCH | $CPU"
echo "  内存:     $MEM"
echo "  Agent:    $AGENT_TYPE"

case "$AGENT_TYPE" in
    opencode)
        echo "  协议:     GET /global/health → POST /session → /message"
        ;;
    langchain)
        echo "  协议:     GET /health → POST /chat (FastAPI + OpenAPI)"
        ;;
    generic)
        echo "  协议:     GET /health (通用 HTTP)"
        ;;
    mcp)
        echo "  协议:     GET /mcp → MCP 健康发现（任务需专用 MCP 客户端）"
        ;;
esac
echo ""

if [ "$SERVE_RUNNING" -eq 1 ]; then
    echo "  🔗 OpenCode Serve 在跑 (v$SERVE_VER, :$SERVE_PORT)"
else
    echo "  ⚠️  OpenCode Serve 未运行"
fi

echo ""
echo "  🌐 局域网 IP:"
for ip in $LAN_IPS; do
    echo "     → $ip:$SERVE_PORT"
done

if [ -n "$PUBLIC_IP" ]; then
    echo "  🌍 公网 IP: $PUBLIC_IP:$SERVE_PORT"
fi

if [ -n "$TUNNEL_URL" ]; then
    echo ""
    echo "  🔗 隧道已激活:"
    echo "     → $TUNNEL_URL"
    echo "     (Cloudflare Quick Tunnel, 无需公网 IP)"
fi

echo ""
echo "  📄 身份牌已保存: $IDENTITY_FILE"
echo ""
echo "  ▸ 将此文件复制到本地主机的 skill 目录:"
echo "    references/servers/$HOSTNAME.json"
echo ""
echo "  ▸ 或本地主机执行接受命令:"
echo "    echo '上述 JSON' | scripts/accept.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
