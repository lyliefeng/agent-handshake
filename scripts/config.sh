#!/bin/bash
# OpenCode 快速握手 — 地址保存脚本
# 用法: config.sh <address> [auth]
#        config.sh http://192.168.5.2:4096
#        config.sh http://1.2.3.4:4096 "user:pass"
set -euo pipefail

ADDRESS="${1:-}"
AUTH="${2:-opencode:opencode123}"

if [ -z "$ADDRESS" ]; then
    echo "用法: config.sh <address> [auth]"
    echo "示例: config.sh http://192.168.5.2:4096"
    echo "      config.sh http://1.2.3.4:4096 user:pass"
    echo ""
    echo "当前配置:"
    if [ -f ~/.agent-handshake ]; then
        cat ~/.agent-handshake
    else
        echo "  (无)"
    fi
    exit 0
fi

# 清理地址
ADDRESS="${ADDRESS%/}"
CONFIG_FILE="$HOME/.agent-handshake"

# 验证可达性
echo "▸ 验证 $ADDRESS ..."
if curl -sf --max-time 5 -u "$AUTH" "$ADDRESS/global/health" > /dev/null 2>&1; then
    VER=$(curl -sf --max-time 5 -u "$AUTH" "$ADDRESS/global/health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
    echo "  ✅ OpenCode v$VER 可达"
else
    echo "  ❌ $ADDRESS 不可达"
    exit 1
fi

# 保存配置
cat > "$CONFIG_FILE" << EOF
# OpenCode 快速握手配置
ADDRESS=$ADDRESS
AUTH=$AUTH
SAVED_AT=$(date '+%Y-%m-%d %H:%M:%S')
VERSION=$VER
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ 配置已保存"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  地址: $ADDRESS"
echo "  版本: v$VER"
echo "  文件: $CONFIG_FILE"
echo ""
echo "  现在可以一键握手:"
echo "  handshake.sh auto \"你的问题\""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
