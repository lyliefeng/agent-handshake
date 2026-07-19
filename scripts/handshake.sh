#!/bin/bash
# OpenCode 快速握手 — 执行握手的核心脚本
# 用法: handshake.sh [address] [message]
#        handshake.sh http://192.168.5.2:4096 "帮我查磁盘"
#        handshake.sh auto "直接握手"     ← auto 模式自动选地址
set -euo pipefail

ADDRESS="${1:-auto}"
MESSAGE="${2:-握手测试：你好，请用中文回复一个字}"

# ── auth 认证 ──
AUTH="${OPENCODE_AUTH:-opencode:opencode123}"

# ── auto 模式：自动选最优地址 ──
if [ "$ADDRESS" = "auto" ]; then
    # 优先用已保存配置
    if [ -f ~/.agent-handshake ]; then
        ADDRESS=$(grep -oP 'ADDRESS=\K.*' ~/.agent-handshake 2>/dev/null | head -1 || echo "")
        [ -n "$ADDRESS" ] && echo "📄 使用已保存配置: $ADDRESS"
    fi
    # 其次公网
    if [ -z "$ADDRESS" ] || ! curl -sf --max-time 3 "$ADDRESS/global/health" > /dev/null 2>&1; then
        ADDRESS=$(python3 -c "
import json
try:
    with open('/tmp/opencode-discover.json') as f:
        data = json.load(f)
    if data.get('public',{}).get('reachable'):
        print('http://{}:{}'.format(data['public']['ip'], data['public']['port']))
    elif len(data.get('lan',[])) > 0:
        print('http://{}'.format(data['lan'][0]['addr']))
    elif data.get('local',{}).get('reachable'):
        print('http://127.0.0.1:{}'.format(data['local']['port']))
except: pass
" 2>/dev/null || echo "")
        [ -n "$ADDRESS" ] && echo "🔍 自动发现: $ADDRESS"
    fi
    # 最后用已知的默认地址
    [ -z "$ADDRESS" ] && ADDRESS="http://192.168.5.2:4096"
fi

# ── 清理地址（去掉末尾斜杠） ──
ADDRESS="${ADDRESS%/}"

# ── 握手三部曲 ──
# ── 查 skill 记忆中的服务器身份 ──
SKILL_DIR="${OPENCODE_SKILL_DIR:-$(dirname "$(dirname "$(realpath "$0")")")}"
SERVERS_DIR="$SKILL_DIR/references/servers"
SERVER_IDENTITY=""

# 从地址提取 IP
HANDLE_IP=$(echo "$ADDRESS" | sed 's|https\?://||' | cut -d: -f1)

# 遍历已知服务器，匹配 IP
if [ -d "$SERVERS_DIR" ]; then
    for f in "$SERVERS_DIR"/*.json; do
        [ ! -f "$f" ] && continue
        [ "$(basename "$f")" = "_index.json" ] && continue
        # 检查该服务器的 LAN IP 列表是否包含握手 IP
        MATCH=$(python3 -c "
import json, sys
with open('$f') as fh:
    d = json.load(fh)
ips = d.get('network',{}).get('lan_ips',[]) + ([d['network']['public_ip']] if d.get('network',{}).get('public_ip') else [])
if '$HANDLE_IP' in ips:
    print(d.get('hostname',''))
" 2>/dev/null || echo "")
        if [ -n "$MATCH" ]; then
            SERVER_IDENTITY=$(python3 -c "import json; print(json.dumps(json.load(open('$f')), ensure_ascii=False))" 2>/dev/null || echo "{}")
            break
        fi
    done
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔗 OpenCode 快速握手"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 判断地址类型
if echo "$ADDRESS" | grep -q "trycloudflare\.com"; then
    echo "  🌍 隧道: $ADDRESS (Cloudflare)"
elif echo "$ADDRESS" | grep -q "^https\?://\([0-9]\{1,3\}\.\)\{3\}"; then
    if echo "$ADDRESS" | grep -q "192\.168\|10\.\|172\.\(1[6-9]\|2[0-9]\|3[01]\)"; then
        echo "  🏠 局域网: $ADDRESS"
    else
        echo "  🌍 公网: $ADDRESS"
    fi
else
    echo "  🔗 地址: $ADDRESS"
fi
echo "  消息: $MESSAGE"

# 展示匹配到的服务器身份
if [ -n "$SERVER_IDENTITY" ] && [ "$SERVER_IDENTITY" != "{}" ]; then
    echo "$SERVER_IDENTITY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'  主机: {d[\"hostname\"]}  {d.get(\"os\",\"?\")} ({d.get(\"kernel\",\"?\")})')
print(f'  配置: {d.get(\"cpu\",\"?\")} | 内存 {d.get(\"memory\",\"?\")}')
oc = d.get('opencode', {})
print(f'  OpenCode: {oc.get(\"serve_version\",\"?\")} (serve端口:{oc.get(\"serve_port\",\"?\")})')
print(f'  SSH: {d.get(\"ssh_fingerprint\",\"?\")[:20]}')
" 2>/dev/null
fi
echo ""

# ① 健康检查
if ! curl -sf --max-time 5 -u "$AUTH" "$ADDRESS/global/health" > /dev/null 2>&1; then
    echo "  ❌ 握手失败: OpenCode 服务不可达"
    echo "     请确认 $ADDRESS 上 OpenCode serve 正在运行"
    exit 1
fi

VER=$(curl -sf --max-time 5 -u "$AUTH" "$ADDRESS/global/health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
echo "  ✓ 服务在线 (v$VER)"

# ② 建会话
SESSION_RAW=$(curl -sf --max-time 10 -u "$AUTH" -X POST "$ADDRESS/session" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"快速握手-$(date +%H%M%S)\"}" 2>&1)
SESSION_ID=$(echo "$SESSION_RAW" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")

if [ -z "$SESSION_ID" ]; then
    echo "  ❌ 会话创建失败"
    exit 1
fi
echo "  ✓ 会话: $SESSION_ID"

# ③ 发消息 + 收回复
MODEL_PROVIDER="${OPENCODE_PROVIDER:-zen}"
MODEL_ID="${OPENCODE_MODEL:-deepseek-v4-flash-free}"

RESP=$(curl -sf --max-time 120 -u "$AUTH" -X POST "$ADDRESS/session/$SESSION_ID/message" \
    -H "Content-Type: application/json" \
    -d "{\"model\":{\"providerID\":\"$MODEL_PROVIDER\",\"modelID\":\"$MODEL_ID\"},\"parts\":[{\"type\":\"text\",\"text\":\"$MESSAGE\"}],\"noReply\":false}" 2>&1)

# 抽 text 回复
REPLY=$(echo "$RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data.get('parts', []):
    if p.get('type') == 'text':
        print(p['text'])
        break
" 2>/dev/null || echo "(握手成功，回复解析异常)")

COST=$(echo "$RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
c = data.get('info',{}).get('cost', '?')
print(c)
" 2>/dev/null || echo "?")

MODEL_USED=$(echo "$RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('{}/{}'.format(
    data.get('info',{}).get('providerID','?'),
    data.get('info',{}).get('modelID','?')
))
" 2>/dev/null || echo "?/?")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📨 回复"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  $REPLY"
echo ""
echo "  模型: $MODEL_USED"
echo "  成本: $COST"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
