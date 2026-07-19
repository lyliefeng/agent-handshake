# Agent Handshake

一个面向本地电脑和远程 Agent 的 HTTP 连接器。客户端会先探测服务协议，再选择 Agent Shell 的 `/run` 或原生 OpenCode 的会话 API。所有请求使用标准 JSON 编码，支持 HTTP/HTTPS 和 Basic Auth。

## 安装

```bash
git clone https://github.com/lyliefeng/agent-handshake.git <你的 skill 目录>
cd <你的 skill 目录>
```

需要 Python 3、Bash、curl。macOS 使用系统 Bash 3.2 也可以运行脚本；脚本不依赖 `realpath`、GNU `grep -P` 或第三方 Python 包。

## 远程端：Agent Shell

这是最直接的本地电脑到远程端路径。Agent Shell 调用当前 OpenCode CLI 的非交互 `run` 命令，提供 `/health` 和 `/run`；stdout/stderr 有大小上限，超限会返回错误。

在远程主机运行：

```bash
python3 scripts/agent_shell.py \
  --host 0.0.0.0 \
  --port 4096 \
  --auth 'user:pass'
```

非 loopback 监听必须提供 `--auth`。直接 HTTP 只适用于受控 LAN/VPN，防火墙只放行可信来源；公网必须使用 HTTPS 反向代理或 Quick Tunnel，不要把 Basic Auth 通过未加密 HTTP 暴露到互联网。

客户端注册并握手：

```bash
bash scripts/accept.sh remote-host http://REMOTE_HOST:4096 'user:pass' agent-shell
bash scripts/handshake.sh auto '列出远程项目目录'
```

也可以直接执行：

```bash
bash scripts/handshake.sh http://REMOTE_HOST:4096 'say "hello" and use C:\\tmp'
```

## 原生 OpenCode Serve

如果远程端已经运行原生 OpenCode Serve，明确指定可达地址和密码。`opencode serve` 默认只监听 `127.0.0.1`，不能直接被局域网客户端发现。

```bash
export OPENCODE_SERVER_USERNAME=opencode
export OPENCODE_SERVER_PASSWORD='strong-password'
opencode serve --hostname 0.0.0.0 --port 4096
```

客户端：

```bash
bash scripts/accept.sh remote-host http://REMOTE_HOST:4096 'opencode:strong-password' opencode
bash scripts/handshake.sh auto '检查服务状态'
```

## 无公网 IP：Quick Tunnel

Quick Tunnel 适合临时测试，不提供生产 SLA。远程 Agent Shell 必须先监听本机端口并启用认证：

```bash
export OPENCODE_AUTH='user:pass'  # tunnel 必须使用非空认证
export AGENT_SHELL_AUTH='user:pass'  # 与 Agent Shell 的 --auth 保持一致
bash scripts/tunnel.sh start 4096
```

脚本会输出类似 `https://random-name.trycloudflare.com` 的地址。客户端 URL 不需要端口：

```bash
bash scripts/accept.sh remote-host https://random-name.trycloudflare.com 'user:pass' agent-shell
bash scripts/handshake.sh auto '检查远程服务'
```

macOS 建议先安装官方 Homebrew 包：

```bash
brew install cloudflared
```

停止和查看状态：

```bash
bash scripts/tunnel.sh status
bash scripts/tunnel.sh stop
```

## 自动发现

```bash
OPENCODE_PORT=4096 bash scripts/discover.sh
```

发现结果默认写入 `/tmp/opencode-discover.json`，可用 `OPENCODE_DISCOVER_FILE` 改路径。LAN 扫描只探测 RFC1918 私有 IPv4，且不会向未验证的 LAN 地址发送 `OPENCODE_AUTH`；认证服务会被标记为需要认证，随后由 `accept.sh`/`handshake.sh` 对已选地址验证。脚本支持 OpenCode、Agent Shell、通用 `/health`、FastAPI 特征和 MCP 健康端点；MCP 这里只做健康发现，不能用本连接器直接执行自然语言任务。自动发现候选默认不携带任何凭据；如确实要对发现结果尝试认证，显式设置 `OPENCODE_DISCOVERY_AUTH`。

## 配置

```bash
bash scripts/config.sh https://remote.example.com 'user:pass' agent-shell
bash scripts/handshake.sh auto '你好'
```

配置保存到 `~/.agent-handshake`，权限为 `0600`；自动握手也兼容旧的 `~/.opencode-handshake` 并在读取时收紧权限。可用环境变量覆盖配置：

| 变量 | 作用 |
|---|---|
| `OPENCODE_AUTH` | Basic Auth，格式为 `user:pass` |
| `AGENT_SHELL_AUTH` | Agent Shell 的 Basic Auth；未设置 `OPENCODE_AUTH` 时供本机注册/发现回退使用 |
| `OPENCODE_DISCOVERY_AUTH` | 可选；显式允许自动发现候选使用的 Basic Auth，默认不发送 |
| `OPENCODE_PROTOCOL` | `agent-shell` 或 `opencode` 等协议提示 |
| `OPENCODE_PORT` | 发现和隧道默认端口，默认 `4096` |
| `OPENCODE_PROVIDER` | 可选；显式覆盖原生 OpenCode provider，需与 model 同时设置 |
| `OPENCODE_MODEL` | 可选；显式覆盖原生 OpenCode model，未设置时使用远端默认模型 |
| `OPENCODE_DISCOVER_FILE` | 发现 JSON 输出路径 |
| `OPENCODE_TUNNEL_PROTOCOL` | Quick Tunnel 出站协议：`http2`（默认）、`auto` 或 `quic` |
| `AGENT_SHELL_WORKING_DIR` | systemd 部署后的任务工作目录，默认服务用户 home |
| `AGENT_SHELL_MAX_CONNECTIONS` | Agent Shell 最大并发连接，默认 `32` |
| `AGENT_SHELL_MAX_TASKS` | Agent Shell 最大并发任务，默认 `2` |
| `AGENT_SHELL_MAX_OUTPUT_BYTES` | 单任务 stdout/stderr 上限，默认 `1048576` |
| `AGENT_SHELL_TASK_TIMEOUT` | 单任务最长执行秒数，默认 `120`，最大 `3600` |

## 部署脚本

Linux + systemd 主机可以使用：

```bash
bash scripts/deploy.sh --port 4096 --auth 'user:pass' --host 0.0.0.0
```

脚本会把认证写入权限为 `0600` 的 systemd EnvironmentFile，并在健康检查失败时返回非零退出码。可用 `--user` 指定服务用户。

## 测试

测试只使用本地回环和 mock HTTP 服务，不访问外网：

```bash
python3 -m unittest discover -s tests -v
bash -n scripts/*.sh
python3 -m py_compile scripts/*.py
```

## 文件

| 文件 | 作用 |
|---|---|
| `scripts/agent_shell.py` | 远程轻量 Agent HTTP 服务 |
| `scripts/handshake_client.py` | 协议探测、JSON 请求和任务执行客户端 |
| `scripts/handshake.sh` | 面向用户的握手入口 |
| `scripts/accept.sh` | 验证并保存远程身份 |
| `scripts/config.sh` | 保存地址、认证和协议 |
| `scripts/discover.sh` | 本机和局域网发现 |
| `scripts/register.sh` | 远程机器身份牌生成 |
| `scripts/tunnel.sh` | Cloudflare Quick Tunnel 生命周期 |
| `scripts/deploy.sh` | Linux systemd 部署 |

MIT License
