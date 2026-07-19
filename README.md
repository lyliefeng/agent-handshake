# Agent Handshake Skill

> 通用 Agent 握手通道 —— 一行命令发现、注册、打通任意服务器上的 AI Agent。
> 替代 SSH，HTTP 直连，Cloudflare 隧道穿透 NAT。

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS-lightgrey)]()

---

## 安装

### 方式一：WorkBuddy 一句话安装（推荐）

在 WorkBuddy 对话中直接说：

```
安装 agent-handshake 技能
```

系统将自动从推荐市场拉取并安装。

### 方式二：GitHub 手动安装

```bash
git clone https://github.com/lyliefeng/agent-handshake.git ~/.workbuddy/skills/agent-handshake
```

### 方式三：URL 导入

在 WorkBuddy 技能管理面板 → 点击 "通过 URL 导入" → 填入：

```
https://github.com/lyliefeng/agent-handshake
```

---

## 这是什么

当你有多台服务器（NAS、VPS、云主机），每台都跑了 AI Agent（OpenCode、LangChain、CrewAI...），你需要一个统一的握手通道来发现它们、记住它们的身份、随时调用它们执行任务——**不需要 SSH**。

`agent-handshake` 就是这个通道。

## 前置条件

**本 Skill 是握手连接器，不是 AI Agent 本身。** 使用前，你需要在自己的服务器上先部署一个 AI Agent。

### 推荐：OpenCode CLI

最轻量的选择，内置 Zen 免费模型（零 API Key、零费用），一条命令安装：

```bash
curl -fsSL https://opencode.ai/install | bash
```

装完即可运行 `opencode serve`，本 Skill 自动发现并握手。

### 其他兼容 Agent

只要你的 Agent 提供 `GET /health` 端点（返回 HTTP 200 + JSON），就能被自动发现：

| Agent | 安装方式 | 端口 |
|---|---|---|
| OpenCode CLI | `curl -fsSL https://opencode.ai/install \| bash` | 4096 |
| LangChain (LangServe) | `pip install langserve && uvicorn app:app` | 8000 |
| CrewAI | `pip install crewai && crewai serve` | 8000 |
| 自建 FastAPI Agent | 任意 Python/Node.js HTTP 服务 | 任意 |

> 不限制 Agent 类型——只要它能通过 HTTP 接收任务并执行，`agent-handshake` 就能发现、注册、握手。

```
Mac (本地智能体)                         NAS (OpenCode Serve)
  │  HTTP 握手 ──────────────────────────→  读文件 / 跑命令 / AI 推理
  │                                          ↓
  │  HTTP 握手 ──────────────────────────→  VPS (agent_shell)
  │                                          ↓
  │  Cloudflare 隧道 ────────────────────→  内网服务器 (NAT 后)
```

## 能力矩阵

| 能力 | 说明 |
|---|---|
| 🔍 **自动发现** | 扫描 localhost + 局域网（254 IP 并发）+ 公网 IP 检测，自动识别 agent 类型 |
| 🖥️ **服务器注册** | 生成机器身份牌（hostname / OS / CPU / IP / SSH 指纹 / agent 类型），本地持久化 |
| 🔗 **一键握手** | `handshake.sh auto "任务"` 一句命令完成发现→建会话→执行→返回 |
| 🌍 **隧道穿透** | Cloudflare Quick Tunnel，零账号零配置，一行命令打通 NAT |
| 🐳 **VPS 轻量部署** | `agent_shell.py` ~40MB 常驻，`POST /run` 替代 SSH 命令执行 |
| 🔄 **多 Agent 兼容** | 支持 OpenCode / LangChain / CrewAI / 通用 FastAPI / MCP |
| 💰 **零成本运行** | 内置 OpenCode Zen 免费模型，无需 API Key |

## 支持的 Agent 类型

| agent_type | 健康检查端点 | 检测方式 |
|---|---|---|
| `opencode` | `GET /global/health` | 返回 `{"healthy":true}` |
| `langchain` | `GET /health` | `/openapi.json` 含 langchain/langserve |
| `crewai` | `GET /health` | `/openapi.json` 含 crewai |
| `generic-fastapi` | `GET /health` | FastAPI 自动文档 |
| `generic` | `GET /health` | 任意返回 `{"status":"ok"}` 的 HTTP agent |
| `mcp` | `GET /health` | `/mcp` 端点 |

**通用原则**：只要 agent 提供 `GET /health` 端点（HTTP 200 + JSON），就能被自动发现和注册。

## 快速开始

### 首次部署（服务器 + 本地 双向）

```bash
# 服务器侧：生成身份牌（自动检测 agent 类型）
bash scripts/register.sh

# 本地侧：接收服务器身份 + 验证可达性 + 持久化记忆
bash scripts/accept.sh <hostname> <address> [auth]

# 一键握手——自动选最优地址，展示服务器详情
bash scripts/handshake.sh auto "你的任务"
```

### 无公网 IP？Cloudflare 隧道

```bash
# 服务器侧：一行命令打通
bash scripts/tunnel.sh start
# → https://random-name.trycloudflare.com

# 本地侧：用隧道地址注册
bash scripts/accept.sh my-server https://random-name.trycloudflare.com
```

### VPS 一键部署（替代 SSH）

```bash
# 在 VPS 上（已安装 opencode CLI）
bash scripts/deploy.sh 4096 user:pass
```

部署后 VPS 上的 agent 通过 `POST /run` 执行任意命令，效果等同 SSH 但不暴露 22 端口。

## 脚本清单

| 脚本 | 位置 | 作用 |
|---|---|---|
| `register.sh` | 服务器侧 | 采集机器身份 + 自动检测 agent 类型，生成 JSON 身份牌 |
| `accept.sh` | 本地侧 | 接收服务器身份，验证可达性，持久化到 skill 记忆 |
| `discover.sh` | 本地侧 | 三层网络扫描 + agent 类型识别 + 匹配已知服务器 |
| `handshake.sh` | 本地侧 | 一键握手——健康检查→建会话→发任务→展示结果 |
| `tunnel.sh` | 服务器侧 | 启动/停止/查看 Cloudflare Quick Tunnel |
| `deploy.sh` | 服务器侧 | 一键部署 agent_shell.py + systemd 自启 |
| `config.sh` | 本地侧 | 手动保存/查看握手配置 |
| `agent_shell.py` | 服务器侧 | 轻量 HTTP Agent 壳，替代 SSH |

## 握手三步（HTTP API）

```
① GET  /health              → 验证服务存活
② POST /session              → 创建会话（OpenCode）或直接 POST /run（通用 agent）
③ POST /session/:id/message  → 发送任务，agent 自动用工具执行，返回结果
```

## 隧道方案对比

| 方案 | 需要账号 | 需要公网服务器 | 命令数 | 加密 |
|---|---|---|---|---|
| **Cloudflare Quick Tunnel** | ❌ | ❌ | 1 行 | ✅ HTTPS |
| frp | ❌ | ✅ | 多配置 | 可选 |
| Tailscale | ✅ | ❌ | 1 行 | ✅ |
| bore | ❌ | ❌ | 1 行 | ❌ |

本 Skill 内置 Cloudflare Quick Tunnel 支持——零依赖、零配置、一行命令。

## 架构

```
┌────────────────────────────────────────────────────────────┐
│                   Agent Handshake Skill                     │
├────────────────────────────────────────────────────────────┤
│  ① 发现层: discover.sh                                      │
│     localhost:4096 → 局域网 192.168.x/24 并发扫描 → 公网 IP │
│     → 输出 /tmp/opencode-discover.json                      │
├────────────────────────────────────────────────────────────┤
│  ② 注册层: register.sh + accept.sh                         │
│     服务器生成身份牌 → 本地验证 + 存入 references/servers/   │
│     → 持久化: hostname/OS/CPU/IP/agent_type/protocol       │
├────────────────────────────────────────────────────────────┤
│  ③ 握手层: handshake.sh                                     │
│     auto 自动选最优地址 → 健康检查 → 建会话 → 发任务 → 收结果│
│     → 展示块式面板告知"连接的是哪台服务器"                    │
├────────────────────────────────────────────────────────────┤
│  ④ 隧道层: tunnel.sh                                        │
│     cloudflared tunnel → trycloudflare.com → 穿透任意 NAT   │
└────────────────────────────────────────────────────────────┘
```

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `OPENCODE_AUTH` | `opencode:opencode123` | Basic Auth 认证 |
| `OPENCODE_PORT` | `4096` | 服务端口 |
| `OPENCODE_PROVIDER` | `zen` | AI 模型提供商 |
| `OPENCODE_MODEL` | `deepseek-v4-flash-free` | 模型 ID（Zen 免费） |

## 文件结构

```
agent-handshake/
├── SKILL.md              # Skill 说明书（含完整触发词、工作流程）
├── README.md             # 本文件
├── .gitignore            # 排除服务器身份牌（敏感信息）
├── scripts/
│   ├── register.sh       # 服务器侧：生成身份牌（6 种 agent 类型自动检测）
│   ├── accept.sh         # 本地侧：接受+记忆服务器
│   ├── discover.sh       # 网络发现扫描（三层 + agent 识别）
│   ├── handshake.sh      # 一键握手 + 块式面板
│   ├── tunnel.sh         # Cloudflare 隧道管理
│   ├── deploy.sh         # VPS 一键部署（agent_shell + systemd）
│   ├── config.sh         # 配置管理
│   └── agent_shell.py    # VPS 轻量 Agent 壳（~40MB）
└── references/
    └── servers/           # 服务器记忆（gitignored，部署后自动生成）
```

## 安装

```bash
# 从 GitHub 安装到本地 Skill 目录
git clone https://github.com/lyliefeng/agent-handshake.git ~/.workbuddy/skills/agent-handshake

# 或从 SkillHub / ClawHub 一键安装（即将上架）
```

## 许可证

MIT
