#!/bin/bash
# OpenCode Agent Shell — 一键部署到 VPS
# 用法: bash deploy.sh [--port 4096] [--auth user:pass]
set -euo pipefail

PORT="${1:-4096}"
AUTH="${2:-}"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
SERVICE_NAME="opencode-agent"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🚀 OpenCode Agent Shell 部署"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. 确认 opencode 已装
if ! command -v opencode &>/dev/null; then
    echo "❌ opencode 未安装。请先安装: curl -fsSL https://opencode.ai/install | bash"
    exit 1
fi
echo "✓ opencode: $(which opencode)"

# 2. 拷 agent_shell.py 到系统目录
INSTALL_DIR="/opt/opencode-agent"
sudo mkdir -p "$INSTALL_DIR"
sudo cp "$SCRIPT_DIR/agent_shell.py" "$INSTALL_DIR/"
sudo chmod +x "$INSTALL_DIR/agent_shell.py"
echo "✓ agent_shell.py → $INSTALL_DIR/"

# 3. 写 systemd 服务
AUTH_ARG=""
[ -n "$AUTH" ] && AUTH_ARG="--auth $AUTH"

sudo tee "/etc/systemd/system/$SERVICE_NAME.service" > /dev/null << EOF
[Unit]
Description=OpenCode Agent Shell (轻量握手)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_DIR/agent_shell.py --port $PORT $AUTH_ARG
Restart=always
RestartSec=10
User=root
Environment="HOME=/root"
Environment="OPENCODE_BIN=$(which opencode)"

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"
sleep 2

# 4. 验证
echo ""
if curl -sf "http://127.0.0.1:$PORT/health" > /dev/null 2>&1; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ 部署成功"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  地址: http://$(hostname -I | awk '{print $1}'):$PORT"
    echo "  状态: $(sudo systemctl is-active $SERVICE_NAME)"
    echo ""
    echo "  本地验证:"
    echo "  curl http://127.0.0.1:$PORT/health"
    echo ""
    echo "  在 Mac 上用握手 skill 注册:"
    echo "  bash accept.sh $(hostname) http://VPS公网IP:$PORT $AUTH"
else
    echo "❌ 服务启动失败，查看日志:"
    echo "  sudo journalctl -u $SERVICE_NAME -n 20"
fi
