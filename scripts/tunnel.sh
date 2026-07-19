#!/bin/bash
# OpenCode 快速握手 — 隧道打通（Cloudflare Quick Tunnel）
# 在服务器上运行，一行命令打通公网隧道，返回公网握手地址
# 用法: tunnel.sh [start|stop|status]
#       tunnel.sh start          → 启动隧道，返回公网地址
#       tunnel.sh start 3000     → 指定本地端口
#       tunnel.sh stop           → 停止隧道
#       tunnel.sh status         → 查看隧道状态
set -euo pipefail

ACTION="${1:-start}"
LOCAL_PORT="${2:-${OPENCODE_PORT:-4096}}"
TUNNEL_PID_FILE="/tmp/opencode-tunnel.pid"
TUNNEL_URL_FILE="/tmp/opencode-tunnel.url"
TUNNEL_LOG="/tmp/opencode-tunnel.log"

# ── 检测 cloudflared ──
detect_cloudflared() {
    if command -v cloudflared &>/dev/null; then
        echo "$(command -v cloudflared)"
        return 0
    fi
    # 常见安装路径
    for p in /usr/local/bin/cloudflared /usr/bin/cloudflared /opt/homebrew/bin/cloudflared; do
        if [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

install_cloudflared() {
    echo "▸ cloudflared 未安装，正在安装..."
    OS=$(uname -s)
    ARCH=$(uname -m)
    
    case "$OS" in
        Linux)
            case "$ARCH" in
                x86_64)  URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
                aarch64) URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
                armv7l)  URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
                *) echo "  ❌ 不支持的架构: $ARCH"; return 1 ;;
            esac
            DEST="/usr/local/bin/cloudflared"
            echo "  下载: $URL"
            if curl -fsSL "$URL" -o "$DEST" 2>/dev/null; then
                chmod +x "$DEST"
                echo "  ✅ 安装完成: $DEST"
            else
                # 尝试用包管理器
                if command -v apt &>/dev/null; then
                    echo "  改用 apt 安装..."
                    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg > /dev/null 2>&1 || true
                    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list > /dev/null 2>&1 || true
                    sudo apt update -qq && sudo apt install -y cloudflared
                elif command -v brew &>/dev/null; then
                    brew install cloudflared
                else
                    echo "  ❌ 自动安装失败，请手动安装: https://github.com/cloudflare/cloudflared/releases"
                    return 1
                fi
            fi
            ;;
        Darwin)
            if command -v brew &>/dev/null; then
                brew install cloudflared
            else
                URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64"
                DEST="/usr/local/bin/cloudflared"
                curl -fsSL "$URL" -o "$DEST" && chmod +x "$DEST"
            fi
            ;;
        *)
            echo "  ❌ 不支持的系统: $OS"
            return 1
            ;;
    esac
}

# ── 启动隧道 ──
start_tunnel() {
    # 确认本地服务在跑
    if ! curl -sf --max-time 3 "http://127.0.0.1:$LOCAL_PORT/global/health" > /dev/null 2>&1; then
        echo "⚠️  localhost:$LOCAL_PORT OpenCode 服务未检测到"
        echo "  尝试继续... (如果是其他服务端口请忽略)"
    fi
    
    CLOUDFLARED=$(detect_cloudflared) || {
        install_cloudflared
        CLOUDFLARED=$(detect_cloudflared) || {
            echo "❌ 无法安装 cloudflared"
            return 1
        }
    }
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔗 启动 Cloudflare 隧道"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  本地端口: $LOCAL_PORT"
    echo "  工具:     $CLOUDFLARED"
    echo ""
    
    # 后台启动，捕获 URL
    $CLOUDFLARED tunnel --url "http://localhost:$LOCAL_PORT" \
        --no-autoupdate \
        > "$TUNNEL_LOG" 2>&1 &
    
    TUNNEL_PID=$!
    echo "$TUNNEL_PID" > "$TUNNEL_PID_FILE"
    
    # 等待 URL 生成（最多 30 秒）
    echo "  等待隧道建立..."
    for i in $(seq 1 30); do
        sleep 1
        TUNNEL_URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || echo "")
        if [ -n "$TUNNEL_URL" ]; then
            echo "$TUNNEL_URL" > "$TUNNEL_URL_FILE"
            break
        fi
        [ $((i % 5)) -eq 0 ] && echo "  ... ${i}s"
    done
    
    if [ -z "${TUNNEL_URL:-}" ]; then
        echo "  ❌ 隧道建立超时，查看日志: $TUNNEL_LOG"
        cat "$TUNNEL_LOG" | tail -10
        return 1
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ 隧道已建立"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌍 公网地址: $TUNNEL_URL"
    echo "  📋 PID:      $TUNNEL_PID"
    echo ""
    echo "  本地握手地址:"
    echo "  handshake.sh $TUNNEL_URL \"你的问题\""
    echo ""
    echo "  停止隧道:"
    echo "  bash scripts/tunnel.sh stop"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 更新身份牌（如果存在）
    SKILL_DIR="${OPENCODE_SKILL_DIR:-$(dirname "$(dirname "$(realpath "$0")")")}"
    HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
    IDENTITY_FILE="$SKILL_DIR/references/servers/$HOSTNAME.json"
    if [ -f "$IDENTITY_FILE" ]; then
        python3 -c "
import json
with open('$IDENTITY_FILE') as f:
    d = json.load(f)
d['tunnel'] = {
    'url': '$TUNNEL_URL',
    'type': 'cloudflare-quick',
    'port': $LOCAL_PORT,
    'pid': $TUNNEL_PID,
    'started_at': '$(date '+%Y-%m-%d %H:%M:%S %Z')'
}
with open('$IDENTITY_FILE', 'w') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
print('  📄 身份牌已更新: $IDENTITY_FILE')
" 2>/dev/null
    fi
}

# ── 停止隧道 ──
stop_tunnel() {
    if [ -f "$TUNNEL_PID_FILE" ]; then
        PID=$(cat "$TUNNEL_PID_FILE")
        if kill "$PID" 2>/dev/null; then
            echo "✅ 隧道已停止 (PID: $PID)"
        else
            echo "⚠️  进程 $PID 已不存在"
        fi
        rm -f "$TUNNEL_PID_FILE"
    else
        # 尝试找到并杀掉所有 cloudflared 隧道进程
        PIDS=$(pgrep -f "cloudflared.*tunnel.*url.*$LOCAL_PORT" 2>/dev/null || echo "")
        if [ -n "$PIDS" ]; then
            echo "$PIDS" | xargs kill 2>/dev/null
            echo "✅ 隧道进程已清理"
        else
            echo "⚠️  未找到运行中的隧道"
        fi
    fi
    rm -f "$TUNNEL_URL_FILE"
}

# ── 查看状态 ──
status_tunnel() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔗 隧道状态"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 进程状态
    if [ -f "$TUNNEL_PID_FILE" ]; then
        PID=$(cat "$TUNNEL_PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            echo "  状态: 🟢 运行中 (PID: $PID)"
        else
            echo "  状态: 🔴 已停止 (PID 文件残留)"
        fi
    else
        RUNNING=$(pgrep -f "cloudflared.*tunnel.*url" 2>/dev/null || echo "")
        if [ -n "$RUNNING" ]; then
            echo "  状态: 🟢 运行中 (PID: $(echo $RUNNING | head -1))"
        else
            echo "  状态: ⚪ 未运行"
        fi
    fi
    
    # URL 状态
    if [ -f "$TUNNEL_URL_FILE" ]; then
        URL=$(cat "$TUNNEL_URL_FILE")
        echo "  URL:  $URL"
        
        # 验证可达性
        if curl -sf --max-time 5 "$URL/global/health" > /dev/null 2>&1; then
            echo "  连通: ✅ 可达"
        else
            echo "  连通: ❌ 不可达（隧道可能已过期）"
        fi
    else
        echo "  URL:  (无记录)"
    fi
    
    # cloudflared 版本
    if CLOUDFLARED=$(detect_cloudflared); then
        VER=$($CLOUDFLARED --version 2>/dev/null | head -1 || echo "?")
        echo "  工具: $VER"
    else
        echo "  工具: 未安装"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── 主入口 ──
case "$ACTION" in
    start)  start_tunnel ;;
    stop)   stop_tunnel ;;
    status) status_tunnel ;;
    *)
        echo "用法: tunnel.sh [start|stop|status] [port]"
        echo ""
        echo "  start [port]  — 启动 Cloudflare Quick Tunnel"
        echo "  stop          — 停止隧道"
        echo "  status        — 查看隧道状态"
        echo ""
        echo "示例:"
        echo "  tunnel.sh start        # 默认 4096 端口"
        echo "  tunnel.sh start 3000   # 自定义端口"
        echo "  tunnel.sh stop"
        echo "  tunnel.sh status"
        ;;
esac
