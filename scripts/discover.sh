#!/bin/bash
# OpenCode 快速握手 — 网络发现脚本
# 扫描本地和局域网中的 OpenCode Serve 实例，检测公网地址
set -euo pipefail

DISCOVER_PORT="${OPENCODE_PORT:-4096}"
TIMEOUT="${OPENCODE_DISCOVER_TIMEOUT:-3}"
MAX_RESPONSE_BYTES=1048576
DISCOVER_JSON_FILE="${OPENCODE_DISCOVER_FILE:-/tmp/opencode-discover.json}"
DISCOVER_CONCURRENCY="${OPENCODE_DISCOVER_CONCURRENCY:-32}"
if [ -n "${AGENT_HANDSHAKE_CONFIG:-}" ]; then
    CONFIG_FILE="$AGENT_HANDSHAKE_CONFIG"
elif [ -f "$HOME/.agent-handshake" ]; then
    CONFIG_FILE="$HOME/.agent-handshake"
elif [ -f "$HOME/.opencode-handshake" ]; then
    CONFIG_FILE="$HOME/.opencode-handshake"
else
    CONFIG_FILE="$HOME/.agent-handshake"
fi
[ -f "$CONFIG_FILE" ] && chmod 600 "$CONFIG_FILE" 2>/dev/null || true
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SKILL_DIR="${OPENCODE_SKILL_DIR:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}"
DISCOVER_AUTH="${OPENCODE_AUTH:-${AGENT_SHELL_AUTH:-}}"
if [ -z "$DISCOVER_AUTH" ] && [ -f "$CONFIG_FILE" ]; then
    DISCOVER_AUTH="$(sed -n 's/^AUTH=//p' "$CONFIG_FILE" | head -1)"
fi

case "${1:-}" in
    '') ;;
    --help|-h)
        echo "用法: discover.sh"
        echo "环境变量: OPENCODE_PORT OPENCODE_AUTH OPENCODE_DISCOVER_TIMEOUT OPENCODE_DISCOVER_CONCURRENCY OPENCODE_DISCOVER_FILE"
        exit 0
        ;;
    *)
        echo "未知参数: $1" >&2
        exit 2
        ;;
esac

case "$DISCOVER_PORT" in
    ''|*[!0-9]*)
        echo "❌ 无效端口: $DISCOVER_PORT" >&2
        exit 2
        ;;
esac
if ! python3 - "$DISCOVER_PORT" <<'PY' >/dev/null 2>&1
import sys
value = int(sys.argv[1])
raise SystemExit(0 if 1 <= value <= 65535 else 1)
PY
then
    echo "❌ 端口必须在 1-65535 之间" >&2
    exit 2
fi
case "$DISCOVER_CONCURRENCY" in
    ''|*[!0-9]*|0) echo "❌ 无效并发数: $DISCOVER_CONCURRENCY" >&2; exit 2 ;;
esac
if ! python3 - "$DISCOVER_CONCURRENCY" <<'PY' >/dev/null 2>&1
import sys
value = int(sys.argv[1])
raise SystemExit(0 if 1 <= value <= 256 else 1)
PY
then
    echo "❌ 并发数必须在 1-256 之间" >&2
    exit 2
fi

echo "=== OpenCode 握手地址发现 ==="
echo ""

json_object() {
    python3 -c 'import json,sys; value=json.load(sys.stdin); raise SystemExit(0 if isinstance(value, dict) else 1)' \
        <<<"$1" 2>/dev/null
}

json_version() {
    python3 -c 'import json,sys; value=json.load(sys.stdin); print(value.get("version", "?"))' \
        <<<"$1" 2>/dev/null || printf '?\n'
}

has_healthy_status() {
    python3 -c 'import json,sys; value=json.load(sys.stdin); raise SystemExit(0 if isinstance(value, dict) and (value.get("healthy") is True or value.get("status") in ("ok", "healthy", True)) else 1)' \
        <<<"$1" 2>/dev/null
}

probe_health() {
    local base="$1"
    local trust="${2:-trusted}"
    if curl_json "$trust" "$base/global/health" > /dev/null 2>&1; then
        printf '/global/health\n'
        return 0
    fi
    if curl_json "$trust" "$base/health" > /dev/null 2>&1; then
        printf '/health\n'
        return 0
    fi
    return 1
}

curl_json() {
    local trust="$1"
    shift
    if [ "$trust" = "trusted" ] && [ -n "$DISCOVER_AUTH" ]; then
        curl -sf --max-time "$TIMEOUT" --max-redirs 0 --max-filesize "$MAX_RESPONSE_BYTES" -u "$DISCOVER_AUTH" "$@"
    else
        curl -sf --max-time "$TIMEOUT" --max-redirs 0 --max-filesize "$MAX_RESPONSE_BYTES" "$@"
    fi
}

http_status() {
    curl -sS --max-time "$TIMEOUT" --max-redirs 0 --max-filesize "$MAX_RESPONSE_BYTES" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || printf '000'
}

# ── Agent 检测函数 ──
detect_agent() {
    local addr="$1"
    local port="${2:-$DISCOVER_PORT}"
    local trust="${3:-trusted}"
    local base="http://$addr:$port"
    local resp=""
    local openapi=""
    local version="?"

    resp=$(curl_json "$trust" "$base/global/health" 2>/dev/null || true)
    if [ -n "$resp" ] && has_healthy_status "$resp"; then
        version=$(json_version "$resp")
        printf 'opencode|%s\n' "$version"
        return 0
    fi
    if [ "$trust" = "untrusted" ]; then
        case "$(http_status "$base/global/health")" in
            401|403) printf 'opencode-auth|?\n'; return 0 ;;
        esac
    fi

    resp=$(curl_json "$trust" "$base/health" 2>/dev/null || true)
    if [ -n "$resp" ] && json_object "$resp"; then
        version=$(json_version "$resp")
        openapi=$(curl_json "$trust" "$base/openapi.json" 2>/dev/null || true)
        if [ -n "$openapi" ] && printf '%s' "$openapi" | grep -Eqi 'langchain|langserve|langgraph'; then
            printf 'langchain|%s\n' "$version"
            return 0
        fi
        if [ -n "$openapi" ] && printf '%s' "$openapi" | grep -Eqi 'crewai|crew'; then
            printf 'crewai|%s\n' "$version"
            return 0
        fi
        if [ -n "$openapi" ] && curl_json "$trust" "$base/docs" > /dev/null 2>&1; then
            printf 'generic-fastapi|%s\n' "$version"
            return 0
        fi
        printf 'generic|%s\n' "$version"
        return 0
    fi
    if [ "$trust" = "untrusted" ]; then
        case "$(http_status "$base/health")" in
            401|403) printf 'agent-auth|?\n'; return 0 ;;
        esac
    fi

    mcp_response="$(curl_json "$trust" "$base/mcp" 2>/dev/null || true)"
    if [ -n "$mcp_response" ] && json_object "$mcp_response"; then
        printf 'mcp|?\n'
        return 0
    fi
    return 1
}

# ── 1. localhost ──
echo "▸ 探测 localhost ..."
AGENT_INFO=$(detect_agent "127.0.0.1" "$DISCOVER_PORT" trusted || true)
if [ -n "$AGENT_INFO" ]; then
    AGENT_TYPE=${AGENT_INFO%%|*}
    AGENT_VER=${AGENT_INFO#*|}
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
if command -v ip >/dev/null 2>&1; then
    MY_IPS=$(ip -4 addr show 2>/dev/null | awk '/inet / {sub(/\/.*/, "", $2); print $2}' || true)
else
    MY_IPS=$(ifconfig 2>/dev/null | awk '/inet / {print $2}' || true)
fi

MY_IPS=$(printf '%s\n' "$MY_IPS" | python3 -c '
import ipaddress
import sys
networks = [ipaddress.ip_network("10.0.0.0/8"), ipaddress.ip_network("172.16.0.0/12"), ipaddress.ip_network("192.168.0.0/16")]
for line in sys.stdin:
    value = line.strip()
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        continue
    if any(ip in network for network in networks):
        print(ip)
' 2>/dev/null || true)

for MY_IP in $MY_IPS; do
    PREFIX=$(printf '%s' "$MY_IP" | sed 's/\.[0-9]*$//')
    echo "  扫描网段: $PREFIX.0/24 ..."
done

LAN_SCAN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-discover.XXXXXX")"
SCAN_PIDS=()
cleanup_scan_dir() {
    if [ "${#SCAN_PIDS[@]}" -gt 0 ]; then
        for scan_pid in "${SCAN_PIDS[@]}"; do
            if command -v pkill >/dev/null 2>&1; then
                pkill -TERM -P "$scan_pid" 2>/dev/null || true
            fi
            kill "$scan_pid" 2>/dev/null || true
            wait "$scan_pid" 2>/dev/null || true
        done
    fi
    rm -rf "$LAN_SCAN_DIR"
}
trap cleanup_scan_dir EXIT
trap 'exit 130' INT TERM

for MY_IP in $MY_IPS; do
    PREFIX=$(printf '%s' "$MY_IP" | sed 's/\.[0-9]*$//')
    i=1
    batch=0
    while [ "$i" -le 254 ]; do
        TARGET="$PREFIX.$i"
        if [ "$TARGET" != "$MY_IP" ]; then
            (
                AGENT_INFO=$(detect_agent "$TARGET" "$DISCOVER_PORT" untrusted || true)
                    if [ -n "$AGENT_INFO" ]; then
                        AGENT_TYPE=${AGENT_INFO%%|*}
                        AGENT_VER=${AGENT_INFO#*|}
                        if command -v ssh >/dev/null 2>&1; then
                            HOSTNAME=$(ssh -o ConnectTimeout=2 -o BatchMode=yes "$TARGET" hostname 2>/dev/null || printf '%s' "$TARGET")
                        else
                            HOSTNAME="$TARGET"
                        fi
                        case "$HOSTNAME" in
                            ''|*[!A-Za-z0-9._-]*) HOSTNAME="$TARGET" ;;
                        esac
                        printf '%s\n' "$TARGET:$DISCOVER_PORT|$HOSTNAME|$AGENT_VER|$AGENT_TYPE" > "$LAN_SCAN_DIR/${PREFIX//./_}-$i"
                    fi
            ) &
            SCAN_PIDS+=("$!")
            batch=$((batch + 1))
            if [ "$batch" -ge "$DISCOVER_CONCURRENCY" ]; then
                wait || true
                SCAN_PIDS=()
                batch=0
            fi
        fi
        i=$((i + 1))
    done
    wait || true
    SCAN_PIDS=()
done

LAN_SCAN_OUTPUT="$(find "$LAN_SCAN_DIR" -type f -exec cat {} \; 2>/dev/null || true)"

while IFS= read -r entry; do
    [ -n "$entry" ] && LAN_FOUND+=("$entry")
done <<< "$LAN_SCAN_OUTPUT"

LAN_COUNT=${#LAN_FOUND[@]}
[ "$LAN_COUNT" -eq 0 ] && echo "  ❌ 局域网无 OpenCode 服务"

# ── 3. 公网地址 ──
echo ""
echo "▸ 检测公网地址 ..."

# 尝试获取公网 IP
if [ "${OPENCODE_SKIP_PUBLIC_IP:-0}" = "1" ]; then
    PUBLIC_IP=""
else
    PUBLIC_IP=$(curl -sf --max-time 5 --max-filesize "$MAX_RESPONSE_BYTES" https://ifconfig.me 2>/dev/null || \
                curl -sf --max-time 5 --max-filesize "$MAX_RESPONSE_BYTES" https://api.ipify.org 2>/dev/null || \
                curl -sf --max-time 5 --max-filesize "$MAX_RESPONSE_BYTES" https://ipv4.icanhazip.com 2>/dev/null || echo "")
fi

if [ -n "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '[:space:]')
    if ! python3 - "$PUBLIC_IP" <<'PY' >/dev/null 2>&1
import ipaddress
import sys
address = ipaddress.ip_address(sys.argv[1])
raise SystemExit(0 if address.version == 4 else 1)
PY
    then
        echo "  ⚠️  公网 IP 响应无效，忽略: $PUBLIC_IP"
        PUBLIC_IP=""
    fi
fi

if [ -n "$PUBLIC_IP" ]; then
    echo "  公网 IP: $PUBLIC_IP"
    
    # 检查公网端口是否可达
    if probe_health "http://$PUBLIC_IP:$DISCOVER_PORT" >/dev/null 2>&1; then
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
if [ -f "$CONFIG_FILE" ]; then
    echo "  📄 $CONFIG_FILE 存在"
    sed -n -e 's/^ADDRESS=/     地址: /p' -e 's/^PROTOCOL=/     协议: /p' "$CONFIG_FILE"
    SAVED_OK=1
else
    echo "  ❌ 无已有配置"
    SAVED_OK=0
fi

# ── 5. 查 skill 记忆中的已知服务器 ──
echo ""
echo "▸ 读取 skill 记忆中的已知服务器 ..."
SERVERS_DIR="$SKILL_DIR/references/servers"

KNOWN_SERVERS="{}"
TUNNEL_ADDRS=()
if [ -f "$SERVERS_DIR/_index.json" ]; then
    KNOWN_SERVERS=$(cat "$SERVERS_DIR/_index.json")
    TOTAL=$(echo "$KNOWN_SERVERS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo "0")
    echo "  📚 已记忆 $TOTAL 台服务器"
    
    # 列出已知服务器 + 检测隧道地址
    python3 - "$SERVERS_DIR/_index.json" "$SERVERS_DIR" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding='utf-8') as fh:
    data = json.load(fh)
servers_dir = sys.argv[2]
for hn, s in data.get('servers',{}).items():
    addr = s.get('address','?')
    ver = s.get('version','?')
    since = s.get('accepted_at','?')
    # 读完整身份牌查隧道
    identity_file = os.path.join(servers_dir, os.path.basename(s.get('file','')))
    tunnel_url = ''
    if os.path.exists(identity_file):
        try:
            with open(identity_file) as f:
                id_data = json.load(f)
            t = id_data.get('tunnel')
            if t and t.get('active'):
                tunnel_url = t.get('url','')
        except (OSError, ValueError): pass
    tunnel_mark = f' 🔗{tunnel_url}' if tunnel_url else ''
    print(f'     → {hn} ({addr}) v{ver} | {since}{tunnel_mark}')
PY
    
    # 尝试隧道地址可达性
    for f in "$SERVERS_DIR"/*.json; do
        [ ! -f "$f" ] && continue
        [ "$(basename "$f")" = "_index.json" ] && continue
        TUNNEL_URL=$(python3 - "$f" <<'PY'
import json
import sys
with open(sys.argv[1], encoding='utf-8') as fh:
    d = json.load(fh)
t = d.get('tunnel')
if t and t.get('active') and t.get('url'):
    print(t['url'])
PY
        )
        if [ -n "$TUNNEL_URL" ]; then
            if probe_health "$TUNNEL_URL" trusted >/dev/null 2>&1; then
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
if [ "$LAN_COUNT" -gt 0 ]; then
for entry in "${LAN_FOUND[@]}"; do
    IFS='|' read -r addr host ver <<< "$entry"
    # 查是否有匹配的身份牌文件
    MATCH_FILE=""
    for f in "$SERVERS_DIR"/*.json; do
        [ ! -f "$f" ] && continue
        [ "$(basename "$f")" = "_index.json" ] && continue
        # 匹配 hostname
        FILE_HOST=$(python3 - "$f" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        print(json.load(fh).get('hostname', ''))
except (OSError, ValueError):
    print('')
PY
        )
        if [ "$FILE_HOST" = "$host" ]; then
            MATCH_FILE="$f"
            break
        fi
    done
    if [ -n "$MATCH_FILE" ]; then
        MATCHED+=("$entry|$MATCH_FILE")
    fi
done
fi

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

if [ "${#TUNNEL_ADDRS[@]}" -gt 0 ]; then
    for entry in "${TUNNEL_ADDRS[@]}"; do
        echo "  🔗 隧道: $entry"
    done
fi

if [ "$LAN_COUNT" -gt 0 ]; then
for entry in "${LAN_FOUND[@]}"; do
    IFS='|' read -r addr host ver agent_type <<< "$entry"
    # 标记是否已匹配
    MATCHED_MARK=""
    if [ "${#MATCHED[@]}" -gt 0 ]; then
    for m in "${MATCHED[@]}"; do
        IFS='|' read -r m_addr m_host m_ver m_file <<< "$m"
        [ "$m_host" = "$host" ] && MATCHED_MARK=" 📋已记忆" && break
    done
    fi
    echo "  🏠 局域网: http://$addr ($host) $agent_type v$ver$MATCHED_MARK"
done
fi

if [ "$LOCAL_OK" -eq 1 ]; then
    echo "  💻 本机: http://127.0.0.1:$DISCOVER_PORT"
fi

if [ "$SAVED_OK" -eq 1 ]; then
    echo "  📄 配置: ~/.agent-handshake"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 输出 JSON 给调用方解析
LAN_JSON="[]"
if [ "$LAN_COUNT" -gt 0 ]; then
    LAN_JSON="$(printf '%s\n' "${LAN_FOUND[@]}" | python3 -c "
import sys, json
entries = []
for line in sys.stdin:
    parts = line.strip().split('|')
    if len(parts) >= 4:
        entries.append({'addr': parts[0], 'host': parts[1], 'version': parts[2], 'protocol': parts[3]})
print(json.dumps(entries))
")"
fi
mkdir -p "$(dirname "$DISCOVER_JSON_FILE")"
DISCOVER_PUBLIC_IP="$PUBLIC_IP" \
DISCOVER_PORT_VALUE="$DISCOVER_PORT" \
DISCOVER_PUBLIC_OK="$PUBLIC_OK" \
DISCOVER_LOCAL_OK="$LOCAL_OK" \
DISCOVER_LAN_JSON="$LAN_JSON" \
DISCOVER_SAVED_OK="$SAVED_OK" \
python3 - "$DISCOVER_JSON_FILE" <<'PY'
import json
import os
import sys
import tempfile

try:
    lan = json.loads(os.environ.get("DISCOVER_LAN_JSON", "[]"))
    port = int(os.environ["DISCOVER_PORT_VALUE"])
except (KeyError, ValueError, TypeError, json.JSONDecodeError):
    raise SystemExit("invalid discovery state")
payload = {
    "public": {
        "ip": os.environ.get("DISCOVER_PUBLIC_IP", ""),
        "port": port,
        "reachable": os.environ.get("DISCOVER_PUBLIC_OK") == "1",
    },
    "local": {
        "reachable": os.environ.get("DISCOVER_LOCAL_OK") == "1",
        "port": port,
    },
    "lan": lan,
    "saved": os.environ.get("DISCOVER_SAVED_OK") == "1",
}
target = os.path.abspath(sys.argv[1])
directory = os.path.dirname(target) or "."
os.makedirs(directory, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".agent-discover.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, target)
except Exception:
    try:
        os.unlink(temporary)
    except OSError:
        pass
    raise
PY
