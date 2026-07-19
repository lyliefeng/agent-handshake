---
name: agent-handshake
description: 连接本地电脑与远程 Agent。先探测协议，再通过 Agent Shell /run 或原生 OpenCode 会话 API 执行任务；支持注册、发现、HTTPS 和 Cloudflare Quick Tunnel。
agent_created: true
---

# Agent Handshake

当用户说“握手”“连接远程 agent”“发现服务器”“注册服务器”“打通隧道”时使用本 Skill。

## 连接契约

客户端先调用健康端点：

- Agent Shell：认证的 `GET /health`，随后 `POST /run`，body 为 `{"task":"..."}`。
- 原生 OpenCode：`GET /global/health`，随后 `POST /session` 和 `POST /session/:id/message`。
- 通用 HTTP Agent：`GET /health`，任务端点优先尝试 `/run`，其次 `/chat`。
- MCP：只探测 JSON `/mcp` 健康端点；自然语言任务必须使用专用 MCP 客户端。

不要把 Agent Shell 当成原生 OpenCode Serve；两者的端点不同，客户端必须先探测协议。

## 首次连接

远程端（推荐 Agent Shell）：

```bash
python3 scripts/agent_shell.py --host 0.0.0.0 --port 4096 --auth 'user:pass'
```

本地电脑：

```bash
bash scripts/accept.sh remote-host http://REMOTE_HOST:4096 'user:pass' agent-shell
bash scripts/handshake.sh auto '你的任务'
```

远程监听没有认证时，Agent Shell 会拒绝启动。直接 HTTP 只适用于受控 LAN/VPN；公网连接应使用 HTTPS 反向代理或 Cloudflare Tunnel，不要把未加密 HTTP 暴露到互联网。

## 原生 OpenCode

原生服务默认监听 loopback。远程使用时要显式指定主机名，并设置服务端密码：

```bash
export OPENCODE_SERVER_USERNAME=opencode
export OPENCODE_SERVER_PASSWORD='strong-password'
opencode serve --hostname 0.0.0.0 --port 4096
bash scripts/accept.sh remote-host http://REMOTE_HOST:4096 'opencode:strong-password' opencode
```

## Quick Tunnel

Quick Tunnel 只用于临时测试，不提供生产 SLA。先确保本地服务已启动并设置 `OPENCODE_AUTH` 或 `AGENT_SHELL_AUTH`：

```bash
export OPENCODE_AUTH='user:pass'  # tunnel 必须使用非空认证
export AGENT_SHELL_AUTH='user:pass'
bash scripts/tunnel.sh start 4096
bash scripts/accept.sh remote-host https://random-name.trycloudflare.com 'user:pass' agent-shell
```

Tunnel URL 没有端口时可以直接传给 `accept.sh`。脚本默认用 TCP `http2` 出站，受限网络可避免 QUIC/UDP 阻断；可用 `OPENCODE_TUNNEL_PROTOCOL=auto|quic|http2` 覆盖。用 `bash scripts/tunnel.sh status` 查看状态，用 `bash scripts/tunnel.sh stop` 清理进程和身份牌状态。

## 发现与注册

```bash
OPENCODE_PORT=4096 bash scripts/discover.sh
bash scripts/register.sh auto
```

发现结果写入 `/tmp/opencode-discover.json`，可用 `OPENCODE_DISCOVER_FILE` 覆盖。LAN 扫描只探测 RFC1918 私有 IPv4，不向未验证地址发送认证；身份牌保存在 `references/servers/`，本地配置保存在 `~/.agent-handshake` 并使用 `0600` 权限，同时兼容旧的 `~/.opencode-handshake`。

## 配置优先级

命令行地址优先于自动发现；自动模式依次尝试保存配置和发现文件。保存配置中的认证只绑定保存地址，不会自动转发给其他发现候选；需要对发现候选尝试认证时，显式设置 `OPENCODE_DISCOVERY_AUTH`。`OPENCODE_AUTH`、`OPENCODE_PROTOCOL`、`OPENCODE_PROVIDER`、`OPENCODE_MODEL` 可覆盖保存值。

## 验证

systemd 部署默认在服务用户 home 执行任务；可用 `AGENT_SHELL_WORKING_DIR` 指定项目目录。
Agent Shell 单任务默认最多运行 120 秒，可用 `AGENT_SHELL_TASK_TIMEOUT` 调整（上限 3600 秒）。

修改连接逻辑后运行：

```bash
python3 -m unittest discover -s tests -v
bash -n scripts/*.sh
python3 -m py_compile scripts/*.py
```

测试使用回环 mock，不代表任意公网、防火墙或 Cloudflare 账号环境都已验证；真实远程环境仍需确认 DNS、端口/隧道和服务端凭据。
