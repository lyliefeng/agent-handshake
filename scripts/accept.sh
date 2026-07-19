#!/bin/bash
# OpenCode 快速握手 — 本地侧接受服务器身份牌
# 接收 register.sh 生成的身份 JSON，验证可达性，保存到 skill 记忆
# 用法: accept.sh < <identity.json>
#       accept.sh <server-hostname> <address> [auth]
set -euo pipefail

SKILL_DIR="${OPENCODE_SKILL_DIR:-$(dirname "$(dirname "$(realpath "$0")")")}"
SERVERS_DIR="$SKILL_DIR/references/servers"
mkdir -p "$SERVERS_DIR"
AUTH="${OPENCODE_AUTH:-opencode:opencode123}"

IDENTITY=""
HOSTNAME=""
ADDRESS=""

# ── 解析输入 ──
if [ $# -ge 2 ]; then
    # 快捷模式: accept.sh <hostname> <address> [auth]
    HOSTNAME="$1"
    ADDRESS="${2%/}"
    [ -n "${3:-}" ] && AUTH="$3"
    
    # 验证可达性
    echo "▸ 验证 $ADDRESS ..."
    if ! curl -sf --max-time 5 -u "$AUTH" "$ADDRESS/global/health" > /dev/null 2>&1; then
        echo "  ❌ $ADDRESS 不可达"
        exit 1
    fi
    
    # 采集送达服务器的信息
    SERVE_VER=$(curl -sf --max-time 5 -u "$AUTH" "$ADDRESS/global/health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
    
    # 构建简化身份牌
    IDENTITY=$(python3 -c "
import json
identity = {
    'hostname': '$HOSTNAME',
    'address': '$ADDRESS',
    'port': ${ADDRESS##*:},
    'opencode': {
        'serve_version': '$SERVE_VER',
        'serve_running': True
    },
    'accepted_at': '$(date '+%Y-%m-%d %H:%M:%S %Z')',
    'accepted_unix': $(date +%s)
}
print(json.dumps(identity, ensure_ascii=False, indent=2))
")
else
    # 完整模式: 从 stdin 读取 register.sh 输出的 JSON
    IDENTITY=$(cat)
    HOSTNAME=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('hostname','unknown'))" 2>/dev/null || echo "unknown")
    
    # 从身份牌提取最佳地址验证
    ADDRESS=""
    for ip in $(echo "$IDENTITY" | python3 -c "
import sys,json
d = json.load(sys.stdin)
ips = d.get('network',{}).get('lan_ips',[])
for ip in ips:
    print(ip)
" 2>/dev/null); do
        PORT="${OPENCODE_PORT:-4096}"
        if curl -sf --max-time 3 -u "$AUTH" "http://$ip:$PORT/global/health" > /dev/null 2>&1; then
            ADDRESS="http://$ip:$PORT"
            break
        fi
    done
    
    if [ -z "$ADDRESS" ]; then
        echo "  ❌ 无法连接到 $HOSTNAME 的任何 IP"
        echo "  (请确认 OpenCode Serve 在运行且网络可达)"
        exit 1
    fi
fi

# ── 保存身份牌到 skill 记忆 ──
IDENTITY_FILE="$SERVERS_DIR/$HOSTNAME.json"
echo "$IDENTITY" > "$IDENTITY_FILE"

# ── 同时保存到全局配置（跨 skill 使用） ──
CONFIG_FILE="$HOME/.agent-handshake"
if [ -n "$ADDRESS" ]; then
    cat > "$CONFIG_FILE" << CFGEOF
# OpenCode 快速握手配置（由 accept.sh 自动生成）
ADDRESS=$ADDRESS
AUTH=$AUTH
HOSTNAME=$HOSTNAME
SAVED_AT=$(date '+%Y-%m-%d %H:%M:%S')
CFGEOF
fi

# ── 更新服务器索引 ──
INDEX_FILE="$SERVERS_DIR/_index.json"
python3 -c "
import json, os, glob

servers = {}
for f in sorted(glob.glob('$SERVERS_DIR/*.json')):
    if os.path.basename(f).startswith('_'): continue
    try:
        with open(f) as fh:
            data = json.load(fh)
        hn = data.get('hostname', os.path.basename(f).replace('.json',''))
        servers[hn] = {
            'hostname': hn,
            'address': data.get('address', ''),
            'version': data.get('opencode',{}).get('serve_version','?'),
            'accepted_at': data.get('accepted_at',''),
            'file': os.path.basename(f)
        }
    except: pass

with open('$INDEX_FILE', 'w') as f:
    json.dump({'servers': servers, 'total': len(servers)}, f, ensure_ascii=False, indent=2)

with open('$INDEX_FILE') as f:
    print(f.read())
" 2>/dev/null

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ 服务器已接受并存入 skill 记忆"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  主机名:   $HOSTNAME"
echo "  地址:     $ADDRESS"
echo "  身份牌:   $IDENTITY_FILE"
echo "  全局配置: $CONFIG_FILE"
echo ""
echo "  ▸ 已知服务器列表: $SERVERS_DIR/"
echo "  ▸ 索引文件:       $SERVERS_DIR/_index.json"
echo ""
echo "  现在可以一键握手:"
echo "  handshake.sh auto \"你的问题\""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
