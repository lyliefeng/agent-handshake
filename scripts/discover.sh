#!/bin/bash
# OpenCode 快速握手 — 网络发现脚本
# 扫描本地和局域网中的 OpenCode Serve 实例，检测公网地址
set -euo pipefail

DISCOVER_PORT="${OPENCODE_PORT:-4096}"
TIMEOUT=3

echo "=== OpenCode 握手地址发现 ==="
echo ""

# ── Agent 检测函数 ──
detect_agent() {
    local addr="$1"
    local port="${2:-4096}"
    local resp=""
    
    # 试 OpenCode 端点
    resp=$(curl -sf --max-time 2 "http://$addr:$port/global/health" 2>/dev/null || echo "")
    if echo "$resp" | grep -q '"healthy"'; then
        echo "opencode|$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")"
        return
    fi
    
    # 试通用 /health
    resp=$(curl -sf --max-time 2 "http://$addr:$port/health" 2>/dev/null || echo "")
    if echo "$resp" | grep -q '"status"'; then
        if curl -sf --max-time 2 "http://$addr:$port/openapi.json" > /dev/null 2>&1; then
            local openapi=$(curl -sf --max-time 2 "http://$addr:$port/openapi.json" 2>/dev/null || echo "")
            if echo "$openapi" | grep -qi "langchain\|langserve\|langgraph"; then
                echo "langchain|$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")"
                return
            fi
            if echo "$openapi" | grep -qi "crewai\|crew"; then
                echo "crewai|$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")"
                return
            fi
        fi
        echo "generic|$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")"
        return
    fi
    
    echo ""
}

# ── 1. localhost ──
echo "▸ 探测 localhost ..."
AGENT_INFO=$(detect_agent "127.0.0.1" "$DISCOVER_PORT")
if [ -n "$AGENT_INFO" ]; then
    AGENT_TYPE=$(echo "$AGENT_INFO" | cut -d'|' -f1)
    AGENT_VER=$(echo "$AGENT_INFO" | cut -d'|' -f2)
    echo "  ✅ localhost:$DISCOVER_PORT → $AGENT_TYPE v$AGENT_VER"
    LOCAL_OK=1
else
    echo "  ❌ 无 Agent 服务"
    LOCAL_OK=0
fi

# ── 2. 局域网扫描 ──
echo ""
echo "▸ 扫描局域网 ..."
LAN_FOUND=()

# 获取本机局域网 IP 段
MY_IPS=$(ifconfig 2>/dev/null | grep -E 'inet (192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | awk '{print $2}' || true)

for MY_IP in $MY_IPS; do
    PREFIX=$(echo "$MY_IP" | sed 's/\.[0-9]*$//')
    echo "  扫描网段: $PREFIX.0/24 ..."
    
    # 并发扫描 .1 ~ .254（只扫常用段，加速）
    for i in $(seq 1 254); do
        TARGET="$PREFIX.$i"
        [ "$TARGET" = "$MY_IP" ] && continue  # 跳过自己
        
        if curl -sf --max-time 1 "http://$TARGET:$DISCOVER_PORT/global/health" > /dev/null 2>&1 || \
           curl -sf --max-time 1 "http://$TARGET:$DISCOVER_PORT/health" > /dev/null 2>&1; then
            AGENT_INFO=$(detect_agent "$TARGET" "$DISCOVER_PORT")
            AGENT_TYPE=$(echo "$AGENT_INFO" | cut -d'|' -f1)
            AGENT_VER=$(echo "$AGENT_INFO" | cut -d'|' -f2)
            HOSTNAME=$(ssh -o ConnectTimeout=2 -o BatchMode=yes "$TARGET" hostname 2>/dev/null || echo "$TARGET")
            echo "  ✅ $TARGET:$DISCOVER_PORT → $HOSTNAME ($AGENT_TYPE v$AGENT_VER)"
            LAN_FOUND+=("$TARGET:$DISCOVER_PORT|$HOSTNAME|$AGENT_VER|$AGENT_TYPE")
        fi
    done &
done
wait

LAN_COUNT=${#LAN_FOUND[@]}
[ "$LAN_COUNT" -eq 0 ] && echo "  ❌ 局域网无 OpenCode 服务"

# ── 3. 公网地址 ──
echo ""
echo "▸ 检测公网地址 ..."

# 尝试获取公网 IP
PUBLIC_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || \
            curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || \
            curl -sf --max-time 5 https://ipv4.icanhazip.com 2>/dev/null || echo "")

if [ -n "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '[:space:]')
    echo "  公网 IP: $PUBLIC_IP"
    
    # 检查公网端口是否可达
    if curl -sf --max-time "$TIMEOUT" "http://$PUBLIC_IP:$DISCOVER_PORT/global/health" > /dev/null 2>&1; then
        echo "  ✅ $PUBLIC_IP:$DISCOVER_PORT 公网可达"
        PUBLIC_OK=1
    else
        echo "  ⚠️  $PUBLIC_IP:$DISCOVER_PORT 公网不可达（需端口转发）"
        PUBLIC_OK=0
    fi
else
    echo "  ❌ 无法获取公网 IP（可能无公网或网络受限）"
    PUBLIC_OK=0
    PUBLIC_IP=""
fi

# ── 4. 已有配置检测 ──
echo ""
echo "▸ 检测已保存配置 ..."
if [ -f ~/.agent-handshake ]; then
    echo "  📄 ~/.agent-handshake 存在"
    cat ~/.agent-handshake 2>/dev/null
    SAVED_OK=1
else
    echo "  ❌ 无已有配置"
    SAVED_OK=0
fi

# ── 5. 查 skill 记忆中的已知服务器 ──
echo ""
echo "▸ 读取 skill 记忆中的已知服务器 ..."
SKILL_DIR="${OPENCODE_SKILL_DIR:-$(dirname "$(dirname "$(realpath "$0")")")}"
SERVERS_DIR="$SKILL_DIR/references/servers"

KNOWN_SERVERS="{}"
TUNNEL_ADDRS=()
if [ -f "$SERVERS_DIR/_index.json" ]; then
    KNOWN_SERVERS=$(cat "$SERVERS_DIR/_index.json")
    TOTAL=$(echo "$KNOWN_SERVERS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo "0")
    echo "  📚 已记忆 $TOTAL 台服务器"
    
    # 列出已知服务器 + 检测隧道地址
    echo "$KNOWN_SERVERS" | python3 -c "
import sys, json, os
data = json.load(sys.stdin)
for hn, s in data.get('servers',{}).items():
    addr = s.get('address','?')
    ver = s.get('version','?')
    since = s.get('accepted_at','?')
    # 读完整身份牌查隧道
    identity_file = os.path.join('$SERVERS_DIR', s.get('file',''))
    tunnel_url = ''
    if os.path.exists(identity_file):
        try:
            with open(identity_file) as f:
                id_data = json.load(f)
            t = id_data.get('tunnel')
            if t and t.get('active'):
                tunnel_url = t.get('url','')
        except: pass
    tunnel_mark = f' 🔗{tunnel_url}' if tunnel_url else ''
    print(f'     → {hn} ({addr}) v{ver} | {since}{tunnel_mark}')
" 2>/dev/null
    
    # 尝试隧道地址可达性
    for f in "$SERVERS_DIR"/*.json; do
        [ ! -f "$f" ] && continue
        [ "$(basename "$f")" = "_index.json" ] && continue
        TUNNEL_URL=$(python3 -c "
import json
with open('$f') as fh:
    d = json.load(fh)
t = d.get('tunnel')
if t and t.get('active') and t.get('url'):
    print(t['url'])
" 2>/dev/null || echo "")
        if [ -n "$TUNNEL_URL" ]; then
            if curl -sf --max-time 5 "$TUNNEL_URL/global/health" > /dev/null 2>&1; then
                TUNNEL_ADDRS+=("$TUNNEL_URL")
                echo "  🔗 隧道可达: $TUNNEL_URL"
            fi
        fi
    done
else
    echo "  ❌ 无已知服务器记忆"
fi

# ── 6. 匹配发现结果到已知服务器 ──
echo ""
echo "▸ 匹配发现结果到已知身份牌 ..."
MATCHED=()
for entry in "${LAN_FOUND[@]}"; do
    IFS='|' read -r addr host ver <<< "$entry"
    # 查是否有匹配的身份牌文件
    MATCH_FILE=""
    for f in "$SERVERS_DIR"/*.json; do
        [ ! -f "$f" ] && continue
        [ "$(basename "$f")" = "_index.json" ] && continue
        # 匹配 hostname
        FILE_HOST=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('hostname',''))" 2>/dev/null || echo "")
        if [ "$FILE_HOST" = "$host" ]; then
            MATCH_FILE="$f"
            break
        fi
    done
    if [ -n "$MATCH_FILE" ]; then
        MATCHED+=("$entry|$MATCH_FILE")
    fi
done

MATCH_COUNT=${#MATCHED[@]}
[ "$MATCH_COUNT" -gt 0 ] && echo "  ✅ $MATCH_COUNT 台服务器已匹配身份牌" || echo "  (无匹配，可运行 register.sh 在服务器侧生成身份牌)"

# ── 汇总 ──
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  握手地址汇总"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$PUBLIC_OK" -eq 1 ]; then
    echo "  🌍 公网: http://$PUBLIC_IP:$DISCOVER_PORT"
fi

for entry in "${TUNNEL_ADDRS[@]}"; do
    echo "  🔗 隧道: $entry"
done

for entry in "${LAN_FOUND[@]}"; do
    IFS='|' read -r addr host ver agent_type <<< "$entry"
    # 标记是否已匹配
    MATCHED_MARK=""
    for m in "${MATCHED[@]}"; do
        IFS='|' read -r m_addr m_host m_ver m_file <<< "$m"
        [ "$m_host" = "$host" ] && MATCHED_MARK=" 📋已记忆" && break
    done
    echo "  🏠 局域网: http://$addr ($host) $agent_type v$ver$MATCHED_MARK"
done

if [ "$LOCAL_OK" -eq 1 ]; then
    echo "  💻 本机: http://127.0.0.1:$DISCOVER_PORT"
fi

if [ "$SAVED_OK" -eq 1 ]; then
    echo "  📄 配置: ~/.agent-handshake"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 输出 JSON 给调用方解析（写到 stderr 不干扰主输出）
cat > /tmp/opencode-discover.json << JSONEOF
{
    "public": {"ip": "$PUBLIC_IP", "port": $DISCOVER_PORT, "reachable": $([ "$PUBLIC_OK" -eq 1 ] && echo "true" || echo "false")},
    "local": {"reachable": $([ "$LOCAL_OK" -eq 1 ] && echo "true" || echo "false"), "port": $DISCOVER_PORT},
    "lan": $(printf '%s\n' "${LAN_FOUND[@]}" | python3 -c "
import sys, json
entries = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    parts = line.split('|')
    if len(parts) >= 3:
        entries.append({'addr': parts[0], 'host': parts[1], 'version': parts[2]})
print(json.dumps(entries))
" 2>/dev/null || echo "[]"),
    "saved": $([ "$SAVED_OK" -eq 1 ] && echo "true" || echo "false")
}
JSONEOF
