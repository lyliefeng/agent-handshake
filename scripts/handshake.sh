#!/bin/bash
# Agent Handshake — probe and execute a task against a remote agent.
# Usage: handshake.sh [address|auto] [message]
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
DISCOVER_FILE="${OPENCODE_DISCOVER_FILE:-/tmp/opencode-discover.json}"

REQUESTED_ADDRESS="${1:-auto}"
ADDRESS="$REQUESTED_ADDRESS"
MESSAGE="${2:-握手测试：你好，请用中文回复一个字}"
EXPLICIT_AUTH="${OPENCODE_AUTH:-}"
EXPLICIT_PROTOCOL="${OPENCODE_PROTOCOL:-}"
DISCOVERY_AUTH="${OPENCODE_DISCOVERY_AUTH:-}"
AUTH="$EXPLICIT_AUTH"
PROTOCOL="$EXPLICIT_PROTOCOL"
PROVIDER="${OPENCODE_PROVIDER:-}"
MODEL="${OPENCODE_MODEL:-}"
TIMEOUT="${OPENCODE_HANDSHAKE_TIMEOUT:-120}"
SAVED_ADDRESS=""
SAVED_AUTH=""
SAVED_PROTOCOL=""

read_config_value() {
    local key="$1"
    [ -f "$CONFIG_FILE" ] || return 0
    sed -n "s/^${key}=//p" "$CONFIG_FILE" | head -1
}

if [ "$REQUESTED_ADDRESS" = "auto" ] && [ -f "$CONFIG_FILE" ]; then
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    SAVED_ADDRESS="$(read_config_value ADDRESS)"
    SAVED_AUTH="$(read_config_value AUTH)"
    SAVED_PROTOCOL="$(read_config_value PROTOCOL)"
    if [ -n "$SAVED_ADDRESS" ]; then
        ADDRESS="$SAVED_ADDRESS"
    fi
fi

discovery_candidates() {
    [ -f "$DISCOVER_FILE" ] || return 0
    python3 - "$DISCOVER_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

addresses = []
public = data.get("public", {})
if public.get("reachable") and public.get("ip"):
    addresses.append(("http://{}:{}".format(public["ip"], public.get("port", 4096)), ""))

for item in data.get("lan", []):
    address = item.get("addr") or item.get("address")
    if address:
        if not address.startswith(("http://", "https://")):
            address = "http://" + address
        addresses.append((address, str(item.get("protocol", ""))))

local = data.get("local", {})
if local.get("reachable"):
    addresses.append(("http://127.0.0.1:{}".format(local.get("port", 4096)), ""))

seen = set()
for address, protocol in addresses:
    key = (address, protocol)
    if key in seen:
        continue
    seen.add(key)
    print("{}\t{}".format(address, protocol))
PY
}

probe_address() {
    local candidate="$1"
    local probe_args=(probe --address "$candidate" --auth "$AUTH")
    [ -n "$PROTOCOL" ] && probe_args+=(--protocol "$PROTOCOL")
    python3 "$CLIENT" "${probe_args[@]}"
}

PROBE_JSON=""
LAST_PROBE_ERROR=""

try_address() {
    local candidate="$1"
    local candidate_auth="${2:-}"
    local candidate_protocol="${3:-}"
    local probe_output=""
    local old_auth="$AUTH"
    local old_protocol="$PROTOCOL"
    AUTH="$candidate_auth"
    PROTOCOL="$candidate_protocol"
    if probe_output="$(probe_address "$candidate" 2>&1)"; then
        ADDRESS="$candidate"
        PROBE_JSON="$probe_output"
        return 0
    fi
    AUTH="$old_auth"
    PROTOCOL="$old_protocol"
    LAST_PROBE_ERROR="$probe_output"
    return 1
}

probe_protocol() {
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("protocol", "generic"))'
}

if [ "$REQUESTED_ADDRESS" != "auto" ]; then
    try_address "$ADDRESS" "$EXPLICIT_AUTH" "$EXPLICIT_PROTOCOL" || true
else
    if [ "$ADDRESS" != "auto" ]; then
        echo "📄 尝试已保存配置: $ADDRESS"
        SAVED_TRY_AUTH="$EXPLICIT_AUTH"
        [ -n "$SAVED_TRY_AUTH" ] || SAVED_TRY_AUTH="$SAVED_AUTH"
        SAVED_TRY_PROTOCOL="$EXPLICIT_PROTOCOL"
        [ -n "$SAVED_TRY_PROTOCOL" ] || SAVED_TRY_PROTOCOL="$SAVED_PROTOCOL"
        try_address "$ADDRESS" "$SAVED_TRY_AUTH" "$SAVED_TRY_PROTOCOL" || true
        if [ -n "$PROBE_JSON" ] && [ "$(probe_protocol "$PROBE_JSON")" = "mcp" ]; then
            echo "⚠️ 已保存地址仅提供 MCP 健康发现，跳过自然语言任务"
            LAST_PROBE_ERROR="MCP endpoint is discovery-only"
            PROBE_JSON=""
        fi
    fi
    if [ -z "$PROBE_JSON" ]; then
        while IFS=$'\t' read -r discovered discovered_protocol; do
            [ -n "$discovered" ] || continue
            [ "$discovered" = "$ADDRESS" ] && continue
            echo "🔍 尝试发现地址: $discovered"
            CANDIDATE_PROTOCOL="$discovered_protocol"
            [ -n "$CANDIDATE_PROTOCOL" ] || CANDIDATE_PROTOCOL="$EXPLICIT_PROTOCOL"
            if try_address "$discovered" "$DISCOVERY_AUTH" "$CANDIDATE_PROTOCOL"; then
                if [ "$(probe_protocol "$PROBE_JSON")" = "mcp" ]; then
                    echo "⚠️ 跳过 MCP 健康发现候选: $discovered"
                    LAST_PROBE_ERROR="MCP endpoint is discovery-only"
                    PROBE_JSON=""
                    continue
                fi
                break
            fi
        done < <(discovery_candidates 2>/dev/null || true)
    fi
fi

if [ -z "${PROBE_JSON:-}" ]; then
    if [ "$REQUESTED_ADDRESS" = "auto" ] && [ "$ADDRESS" = "auto" ]; then
        echo "❌ 没有可用地址；请先运行 discover.sh 或指定 address" >&2
    else
        echo "❌ 握手失败：$ADDRESS 不可达或协议不兼容" >&2
    fi
    [ -n "$LAST_PROBE_ERROR" ] && echo "   $LAST_PROBE_ERROR" >&2
    exit 1
fi

NEGOTIATED="$(printf '%s' "$PROBE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("protocol", "generic"))')"
VERSION="$(printf '%s' "$PROBE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version", "?"))')"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔗 Agent 快速握手"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  地址: $ADDRESS"
echo "  协议: $NEGOTIATED"
echo "  版本: $VERSION"
echo "  消息: $MESSAGE"
echo ""
echo "  ✓ 服务在线"

if { [ -n "$PROVIDER" ] && [ -z "$MODEL" ]; } || { [ -z "$PROVIDER" ] && [ -n "$MODEL" ]; }; then
    echo "❌ OPENCODE_PROVIDER 和 OPENCODE_MODEL 必须同时设置" >&2
    exit 2
fi

RUN_ARGS=(run --address "$ADDRESS" --message "$MESSAGE" --auth "$AUTH" --timeout "$TIMEOUT")
[ -n "$PROVIDER" ] && RUN_ARGS+=(--provider "$PROVIDER" --model "$MODEL")
[ -n "$PROTOCOL" ] && RUN_ARGS+=(--protocol "$PROTOCOL")
if ! RESULT_JSON="$(python3 "$CLIENT" "${RUN_ARGS[@]}" 2>&1)"; then
    echo "  ❌ 任务执行失败"
    echo "     $RESULT_JSON"
    exit 1
fi

REPLY="$(printf '%s' "$RESULT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reply", ""))')"
SESSION_ID="$(printf '%s' "$RESULT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id", ""))')"
MODEL_USED="$(printf '%s' "$RESULT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("model", "?/?"))')"
COST="$(printf '%s' "$RESULT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("cost", "?"))')"

if [ -n "$SESSION_ID" ]; then
    echo "  ✓ 会话: $SESSION_ID"
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📨 回复"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  $REPLY"
echo ""
echo "  模型: $MODEL_USED"
echo "  成本: $COST"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
