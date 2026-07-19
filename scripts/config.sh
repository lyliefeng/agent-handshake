#!/bin/bash
# OpenCode 快速握手 — 地址保存脚本
# 用法: config.sh <address> [auth] [protocol]
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CLIENT="$SCRIPT_DIR/handshake_client.py"
if [ -n "${AGENT_HANDSHAKE_CONFIG:-}" ]; then
    CONFIG_FILE="$AGENT_HANDSHAKE_CONFIG"
elif [ -f "$HOME/.agent-handshake" ]; then
    CONFIG_FILE="$HOME/.agent-handshake"
elif [ -f "$HOME/.opencode-handshake" ]; then
    CONFIG_FILE="$HOME/.opencode-handshake"
else
    CONFIG_FILE="$HOME/.agent-handshake"
fi

if [ "$#" -eq 0 ]; then
    echo "用法: config.sh <address> [auth] [protocol]"
    echo "示例: config.sh https://random-name.trycloudflare.com user:pass opencode"
    echo ""
    echo "当前配置:"
    if [ -f "$CONFIG_FILE" ]; then
        sed -n -e 's/^ADDRESS=/  地址: /p' \
            -e 's/^PROTOCOL=/  协议: /p' \
            -e 's/^VERSION=/  版本: v/p' \
            "$CONFIG_FILE"
    else
        echo "  (无)"
    fi
    exit 0
fi

if [ "$#" -gt 3 ]; then
    echo "用法: config.sh <address> [auth] [protocol]" >&2
    exit 2
fi

ADDRESS="$1"
AUTH="${2:-${OPENCODE_AUTH:-}}"
PROTOCOL_HINT="${3:-}"

case "$ADDRESS$AUTH$PROTOCOL_HINT" in
    *$'\n'*|*$'\r'*)
        echo "配置值不能包含换行" >&2
        exit 2
        ;;
esac

echo "▸ 验证 $ADDRESS ..."
PROBE_ARGS=(probe --address "$ADDRESS" --auth "$AUTH")
if [ -n "$PROTOCOL_HINT" ]; then
    PROBE_ARGS+=(--protocol "$PROTOCOL_HINT")
fi
if ! PROBE_JSON=$(python3 "$CLIENT" "${PROBE_ARGS[@]}" 2>&1); then
    echo "  ❌ 地址验证失败"
    echo "$PROBE_JSON"
    exit 1
fi

if ! NORMALIZED_ADDRESS=$(printf '%s' "$PROBE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["address"])'); then
    echo "  ❌ 客户端返回了无效探测结果"
    exit 1
fi
if ! PROTOCOL=$(printf '%s' "$PROBE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("protocol", "generic"))'); then
    echo "  ❌ 无法读取探测协议"
    exit 1
fi
if ! VERSION=$(printf '%s' "$PROBE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version", "?"))'); then
    VERSION="?"
fi

OLD_UMASK=$(umask)
umask 077
cat > "$CONFIG_FILE" << EOF
# OpenCode 快速握手配置
ADDRESS=$NORMALIZED_ADDRESS
AUTH=$AUTH
PROTOCOL=$PROTOCOL
SAVED_AT=$(date '+%Y-%m-%d %H:%M:%S')
VERSION=$VERSION
EOF
chmod 600 "$CONFIG_FILE"
umask "$OLD_UMASK"

echo "  ✅ $PROTOCOL v$VERSION 可达"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ 配置已保存"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  地址: $NORMALIZED_ADDRESS"
echo "  协议: $PROTOCOL"
echo "  版本: v$VERSION"
echo "  文件: $CONFIG_FILE (0600)"
echo ""
echo "  现在可以一键握手:"
echo "  handshake.sh auto \"你的问题\""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
