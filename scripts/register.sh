#!/bin/bash
# OpenCode 快速握手 — 服务器侧身份注册
# 在安装了 OpenCode CLI 的服务器上运行，生成机器身份牌
# 用法: register.sh
# 输出: 块式身份牌 + 保存到 references/servers/<hostname>.json
set -euo pipefail

AGENT_TYPE="${1:-auto}"  # auto | opencode | langchain | crewai | generic | mcp
SKILL_DIR="${OPENCODE_SKILL_DIR:-$(dirname "$(dirname "$(realpath "$0")")")}"
SERVERS_DIR="$SKILL_DIR/references/servers"
mkdir -p "$SERVERS_DIR"

# ── 采集机器身份 ──
HOSTNAME=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")
OS=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || uname -s)
KERNEL=$(uname -r)
ARCH=$(uname -m)
CPU=$(lscpu 2>/dev/null | grep "Model name" | cut -d: -f2 | xargs || echo "unknown")
MEM=$(free -h 2>/dev/null | awk '/Mem:/{print $2}' || echo "unknown")
DISK=$(df -h / 2>/dev/null | awk 'NR==2{print $2", 已用"$3", 可用"$4}' || echo "unknown")
UPTIME=$(uptime -p 2>/dev/null | sed 's/up //' || uptime 2>/dev/null | awk -F'up' '{print $2}' | awk -F',' '{print $1}' | xargs)

# ── 网络 ──
LAN_IPS=$(ip -4 addr show 2>/dev/null | grep -oP 'inet \K[0-9.]*' | grep -v '127.0.0.1' | head -5 || 
          ifconfig 2>/dev/null | grep -oE 'inet [0-9.]+' | grep -v '127.0.0.1' | awk '{print $2}' | head -5)
PUBLIC_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || 
            curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "")

# ── OpenCode 检测 ──
OPENCODE_PATH=$(which opencode 2>/dev/null || echo "")
if [ -n "$OPENCODE_PATH" ]; then
    OPENCODE_VER=$(opencode --version 2>/dev/null | head -1 || echo "?")
else
    OPENCODE_VER="未安装"
fi

# ── OpenCode Serve 检测 ──
SERVE_PORT="${OPENCODE_PORT:-4096}"
SERVE_RUNNING=0
if curl -sf --max-time 3 "http://127.0.0.1:$SERVE_PORT/global/health" > /dev/null 2>&1; then
    SERVE_RUNNING=1
    SERVE_VER=$(curl -sf --max-time 3 "http://127.0.0.1:$SERVE_PORT/global/health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
else
    SERVE_VER="?"
fi

# ── Agent 类型检测 ──
DETECT_AGENT_TYPE() {
    local port="${1:-$SERVE_PORT}"
    local resp=""
    
    # Try OpenCode-specific health endpoint
    resp=$(curl -sf --max-time 3 "http://127.0.0.1:$port/global/health" 2>/dev/null || echo "")
    if echo "$resp" | grep -q '"healthy"'; then
        echo "opencode"
        return
    fi
    
    # Try generic /health
    resp=$(curl -sf --max-time 3 "http://127.0.0.1:$port/health" 2>/dev/null || echo "")
    if echo "$resp" | grep -q '"status"'; then
        # Check for framework-specific signatures
        if curl -sf --max-time 3 "http://127.0.0.1:$port/openapi.json" > /dev/null 2>&1; then
            OPENAPI=$(curl -sf --max-time 3 "http://127.0.0.1:$port/openapi.json" 2>/dev/null || echo "")
            if echo "$OPENAPI" | grep -q "langserve\|langgraph\|langchain"; then
                echo "langchain"
                return
            fi
            if echo "$OPENAPI" | grep -q "crewai\|crew"; then
                echo "crewai"
                return
            fi
        fi
        if curl -sf --max-time 3 "http://127.0.0.1:$port/docs" > /dev/null 2>&1; then
            echo "generic-fastapi"
            return
        fi
        echo "generic"
        return
    fi
    
    # Try MCP
    resp=$(curl -sf --max-time 3 "http://127.0.0.1:$port/mcp" 2>/dev/null || echo "")
    if [ -n "$resp" ]; then
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
    langchain|generic-fastapi)
        PROTOCOL='{"health":"GET /health","chat":"POST /chat","auth":"none"}'
        ;;
    crewai)
        PROTOCOL='{"health":"GET /health","chat":"POST /chat","auth":"none"}'
        ;;
    mcp)
        PROTOCOL='{"health":"GET /health","tools":"MCP protocol","auth":"none"}'
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
if [ -f /tmp/opencode-tunnel.url ]; then
    TUNNEL_URL=$(cat /tmp/opencode-tunnel.url)
    TUNNEL_TYPE="cloudflare-quick"
elif pgrep -f "cloudflared.*tunnel.*url" > /dev/null 2>&1; then
    TUNNEL_URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/opencode-tunnel.log 2>/dev/null | tail -1 || echo "")
    [ -n "$TUNNEL_URL" ] && TUNNEL_TYPE="cloudflare-quick"
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

python3 -c "
import json, sys

identity = {
    'hostname': '$HOSTNAME',
    'agent_type': '$AGENT_TYPE',
    'protocol': json.loads('''$PROTOCOL'''),
    'os': '$OS',
    'kernel': '$KERNEL',
    'arch': '$ARCH',
    'cpu': '$CPU',
    'memory': '$MEM',
    'disk': '$DISK',
    'uptime': '$UPTIME',
    'network': {
        'lan_ips': [ip for ip in '$LAN_IPS'.split() if ip],
        'public_ip': '$PUBLIC_IP'.strip() or None
    },
    'opencode': {
        'path': '$OPENCODE_PATH',
        'version': '$OPENCODE_VER',
        'serve_port': $SERVE_PORT,
        'serve_running': bool($SERVE_RUNNING),
        'serve_version': '$SERVE_VER'
    },
    'ssh_fingerprint': '$SSH_FP',
    'tunnel': {
        'url': '$TUNNEL_URL',
        'type': '$TUNNEL_TYPE',
        'active': bool('$TUNNEL_URL' != '')
    } if '$TUNNEL_URL' else None,
    'generated_at': '$GEN_TIME',
    'generated_unix': $GEN_UNIX
}

with open('$IDENTITY_FILE', 'w') as f:
    json.dump(identity, f, ensure_ascii=False, indent=2)

print(json.dumps(identity, ensure_ascii=False, indent=2))
"

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
        echo "  协议:     GET /health → MCP (Model Context Protocol)"
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
