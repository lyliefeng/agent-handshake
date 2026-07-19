#!/bin/bash
# Agent Handshake — accept and persist a server identity.
# Usage: accept.sh <hostname> <address> [auth] [protocol]
#        cat identity.json | accept.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CLIENT="$SCRIPT_DIR/handshake_client.py"
SKILL_DIR="${OPENCODE_SKILL_DIR:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}"
SERVERS_DIR="$SKILL_DIR/references/servers"
CONFIG_FILE="${AGENT_HANDSHAKE_CONFIG:-$HOME/.agent-handshake}"
AUTH="${OPENCODE_AUTH:-}"
mkdir -p "$SERVERS_DIR"

if [ "$#" -gt 4 ]; then
    echo "用法: accept.sh <hostname> <address> [auth] [protocol]" >&2
    exit 2
fi

validate_hostname() {
    case "$HOSTNAME" in
        ''|*[!A-Za-z0-9._-]*)
            echo "❌ 非法主机名: $HOSTNAME" >&2
            exit 2
            ;;
    esac
}

if [ "$#" -ge 2 ]; then
    HOSTNAME="$1"
    validate_hostname
    ADDRESS="${2%/}"
    [ -n "${3:-}" ] && AUTH="$3"
    PROTOCOL_HINT="${4:-}"
    IDENTITY_JSON=""
else
    IDENTITY_JSON="$(cat)"
    HOSTNAME="$(printf '%s' "$IDENTITY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hostname", "unknown"))')"
    validate_hostname
    PROTOCOL_HINT="$(printf '%s' "$IDENTITY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("agent_type", ""))')"
    [ -n "$AUTH" ] || AUTH="$(printf '%s' "$IDENTITY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("auth", ""))')"
    ADDRESS="$(IDENTITY_JSON="$IDENTITY_JSON" python3 - "${OPENCODE_PORT:-4096}" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["IDENTITY_JSON"])
network = data.get("network", {})
port = str(data.get("opencode", {}).get("serve_port") or sys.argv[1] or "4096")
addresses = []
if isinstance(data.get("address"), str) and data["address"].strip():
    addresses.append(data["address"].strip().rstrip("/"))
for ip in network.get("lan_ips", []):
    addresses.append("http://{}:{}".format(ip, port))
if network.get("public_ip"):
    addresses.append("http://{}:{}".format(network["public_ip"], port))
tunnel = data.get("tunnel") or {}
if tunnel.get("url"):
    addresses.insert(0, tunnel["url"].rstrip("/"))
print("\n".join(dict.fromkeys(addresses)))
PY
    )"
    ADDRESS="$(printf '%s\n' "$ADDRESS" | while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if python3 "$CLIENT" probe --address "$candidate" --auth "$AUTH" --protocol "$PROTOCOL_HINT" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            break
        fi
    done | head -1)"
    [ -n "$ADDRESS" ] || {
        echo "❌ 无法连接到 $HOSTNAME 的任何已记录地址" >&2
        exit 1
    }
fi

echo "▸ 验证 $ADDRESS ..."
PROBE_ARGS=(probe --address "$ADDRESS" --auth "$AUTH")
[ -n "$PROTOCOL_HINT" ] && PROBE_ARGS+=(--protocol "$PROTOCOL_HINT")
if ! PROBE_JSON="$(python3 "$CLIENT" "${PROBE_ARGS[@]}" 2>&1)"; then
    echo "  ❌ 地址验证失败"
    echo "     $PROBE_JSON"
    exit 1
fi

NORMALIZED_ADDRESS="$(printf '%s' "$PROBE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["address"])')"
PROTOCOL="$(printf '%s' "$PROBE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("protocol", "generic"))')"
VERSION="$(printf '%s' "$PROBE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version", "?"))')"

case "$AUTH$NORMALIZED_ADDRESS$PROTOCOL" in
    *$'\n'*|*$'\r'*)
        echo "❌ 配置值不能包含换行" >&2
        exit 2
        ;;
esac

if [ -z "$IDENTITY_JSON" ]; then
    IDENTITY_JSON="$(python3 - "$HOSTNAME" "$NORMALIZED_ADDRESS" "$PROTOCOL" "$VERSION" <<'PY'
import json
import sys
from datetime import datetime

hostname, address, protocol, version = sys.argv[1:]
print(json.dumps({
    "hostname": hostname,
    "address": address,
    "protocol": protocol,
    "opencode": {"serve_version": version, "serve_running": True},
    "accepted_at": datetime.now().astimezone().isoformat(timespec="seconds"),
}, ensure_ascii=False, indent=2))
PY
    )"
else
    IDENTITY_JSON="$(IDENTITY_JSON="$IDENTITY_JSON" python3 - "$NORMALIZED_ADDRESS" "$PROTOCOL" "$VERSION" <<'PY'
import json
import os
import sys
from datetime import datetime

data = json.loads(os.environ["IDENTITY_JSON"])
verified_address, verified_protocol, verified_version = sys.argv[1:]
reported_address = data.get("address")
if reported_address and reported_address != verified_address:
    data["reported_address"] = reported_address
reported_protocol = data.get("protocol")
if reported_protocol and reported_protocol != verified_protocol:
    data["reported_protocol"] = reported_protocol
data["address"] = verified_address
data["protocol"] = verified_protocol
data.setdefault("opencode", {})
reported_version = data["opencode"].get("serve_version")
if reported_version and reported_version != verified_version:
    data["opencode"]["reported_serve_version"] = reported_version
data["opencode"]["serve_version"] = verified_version
data.setdefault("accepted_at", datetime.now().astimezone().isoformat(timespec="seconds"))
print(json.dumps(data, ensure_ascii=False, indent=2))
PY
    )"
fi

OLD_UMASK="$(umask)"
umask 077
IDENTITY_FILE="$SERVERS_DIR/$HOSTNAME.json"
SAVED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
ACCEPT_IDENTITY_JSON="$IDENTITY_JSON" \
ACCEPT_ADDRESS="$NORMALIZED_ADDRESS" \
ACCEPT_AUTH="$AUTH" \
ACCEPT_PROTOCOL="$PROTOCOL" \
ACCEPT_HOSTNAME="$HOSTNAME" \
ACCEPT_VERSION="$VERSION" \
ACCEPT_SAVED_AT="$SAVED_AT" \
python3 - "$IDENTITY_FILE" "$CONFIG_FILE" <<'PY'
import os
import sys
import tempfile

identity_path, config_path = sys.argv[1:]

def atomic_write(path, content):
    directory = os.path.dirname(path) or "."
    fd, temporary = tempfile.mkstemp(prefix=".agent-handshake.", dir=directory, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise

atomic_write(identity_path, os.environ["ACCEPT_IDENTITY_JSON"].rstrip("\n") + "\n")
config = "\n".join([
    "# Agent Handshake configuration",
    "ADDRESS=" + os.environ["ACCEPT_ADDRESS"],
    "AUTH=" + os.environ["ACCEPT_AUTH"],
    "PROTOCOL=" + os.environ["ACCEPT_PROTOCOL"],
    "HOSTNAME=" + os.environ["ACCEPT_HOSTNAME"],
    "SAVED_AT=" + os.environ["ACCEPT_SAVED_AT"],
    "VERSION=" + os.environ["ACCEPT_VERSION"],
    "",
])
atomic_write(config_path, config)
PY
umask "$OLD_UMASK"

INDEX_FILE="$SERVERS_DIR/_index.json"
python3 - "$SERVERS_DIR" "$INDEX_FILE" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

servers_dir = Path(sys.argv[1])
index_file = Path(sys.argv[2])
servers = {}
for path in sorted(servers_dir.glob("*.json")):
    if path.name.startswith("_"):
        continue
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        continue
    hostname = data.get("hostname", path.stem)
    servers[hostname] = {
        "hostname": hostname,
        "address": data.get("address", ""),
        "protocol": data.get("protocol", data.get("agent_type", "generic")),
        "version": data.get("opencode", {}).get("serve_version", data.get("version", "?")),
        "accepted_at": data.get("accepted_at", ""),
        "file": path.name,
    }
payload = json.dumps({"servers": servers, "total": len(servers)}, ensure_ascii=False, indent=2) + "\n"
fd, temporary = tempfile.mkstemp(prefix=".agent-index.", dir=str(index_file.parent), text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(payload)
    os.chmod(temporary, 0o600)
    os.replace(temporary, index_file)
except Exception:
    try:
        os.unlink(temporary)
    except OSError:
        pass
    raise
PY
chmod 600 "$INDEX_FILE" "$IDENTITY_FILE"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ 服务器已接受并存入 skill 记忆"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  主机名:   $HOSTNAME"
echo "  地址:     $NORMALIZED_ADDRESS"
echo "  协议:     $PROTOCOL v$VERSION"
echo "  身份牌:   $IDENTITY_FILE"
echo "  全局配置: $CONFIG_FILE (0600)"
echo ""
echo "  现在可以一键握手:"
echo "  bash scripts/handshake.sh auto \"你的问题\""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
