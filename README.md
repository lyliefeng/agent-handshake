# Agent Handshake Skill

通用 Agent 握手通道 —— 一行命令发现、注册、打通任意服务器上的 AI Agent。

## 能力

- 🔍 **自动发现**：局域网扫描 + 公网检测 + 隧道穿透，自动识别 OpenCode/LangChain/CrewAI/通用FastAPI/MCP
- 🖥️ **服务器注册**：生成机器身份牌（hostname/OS/CPU/IP/SSH/agent类型），本地持久化记忆
- 🔗 **一键握手**：HTTP 直连替代 SSH，本地智能体无需 SSH 即可调用远程 agent 执行任务
- 🌍 **隧道打通**：Cloudflare Quick Tunnel 一行命令穿透 NAT，零账号零配置
- 🐳 **VPS 轻量部署**：agent_shell.py ~40MB 常驻，POST /run 替代 SSH 命令执行

## 快速开始

```bash
# 服务器侧：注册身份
bash scripts/register.sh

# 本地侧：接受服务器 + 握手
bash scripts/accept.sh <hostname> <address>
bash scripts/handshake.sh auto "你的任务"

# 无公网 IP？隧道打通
bash scripts/tunnel.sh start
```

## 集群

已记忆 3 台服务器：NAS (lvliefeng) + 海外 VPS + 香港 VPS，全部 Zen 免费模型，统一 HTTP 握手。

## 文件结构

```
agent-handshake/
├── SKILL.md              # Skill 说明书
├── README.md
├── scripts/
│   ├── register.sh       # 服务器侧：生成身份牌
│   ├── accept.sh         # 本地侧：接受+记忆服务器
│   ├── discover.sh       # 网络发现扫描
│   ├── handshake.sh      # 一键握手
│   ├── tunnel.sh         # Cloudflare 隧道
│   ├── deploy.sh         # VPS 一键部署
│   ├── config.sh         # 配置管理
│   └── agent_shell.py    # VPS 轻量 Agent 壳
└── references/
    └── servers/          # 服务器记忆（_index.json + 身份牌）
```
