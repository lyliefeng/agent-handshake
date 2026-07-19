#!/usr/bin/env python3
"""
OpenCode 轻量 Agent 壳 — 替代 SSH 的 HTTP 握手接口
部署到 VPS 后，Mac 通过 handshake skill 直接 HTTP 调 agent 执行任务。
常驻内存 ~40MB，每次任务 fork opencode 子进程，跑完释放。

用法:
  python3 agent_shell.py --port 4096
  python3 agent_shell.py --port 4096 --auth user:pass

握手端点:
  GET  /health              → {"status":"ok","agent":"opencode-shell","hostname":"xxx"}
  POST /run                 → {"task":"你的任务"} → opencode exec 执行 → 返回结果
"""

import subprocess, json, os, socket, sys, base64, argparse
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

# ── 配置 ──
HOSTNAME = socket.gethostname()
OPENCODE_BIN = os.environ.get("OPENCODE_BIN", "opencode")

def parse_args():
    p = argparse.ArgumentParser(description="OpenCode Agent Shell")
    p.add_argument("--port", type=int, default=4096, help="监听端口")
    p.add_argument("--auth", type=str, default="", help="Basic Auth (user:pass)")
    p.add_argument("--host", type=str, default="0.0.0.0", help="绑定地址")
    return p.parse_args()

ARGS = parse_args()

def check_auth(handler):
    """Basic Auth 校验"""
    if not ARGS.auth:
        return True
    auth_header = handler.headers.get("Authorization", "")
    if not auth_header.startswith("Basic "):
        return False
    try:
        decoded = base64.b64decode(auth_header[6:]).decode()
        return decoded == ARGS.auth
    except:
        return False

def run_opencode(task: str) -> dict:
    """调 opencode exec 执行任务"""
    try:
        result = subprocess.run(
            [OPENCODE_BIN, "exec", "--skip-git-repo-check", task],
            capture_output=True, text=True, timeout=300,
            env={**os.environ, "HOME": os.path.expanduser("~")}
        )
        return {
            "success": result.returncode == 0,
            "output": result.stdout.strip() or result.stderr.strip() or "(empty)",
            "exit_code": result.returncode
        }
    except subprocess.TimeoutExpired:
        return {"success": False, "output": "任务超时 (300s)", "exit_code": -1}
    except FileNotFoundError:
        return {"success": False, "output": f"opencode 未找到: {OPENCODE_BIN}", "exit_code": -1}

class AgentHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # 静默日志

    def _json(self, data, code=200):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            self._json({
                "status": "ok",
                "agent": "opencode-shell",
                "hostname": HOSTNAME,
                "opencode": OPENCODE_BIN
            })
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        path = urlparse(self.path).path

        if not check_auth(self):
            self._json({"error": "unauthorized"}, 401)
            return

        if path == "/run":
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length)) if length > 0 else {}
            task = body.get("task", "")
            if not task:
                self._json({"error": "missing 'task' field"}, 400)
                return

            print(f"[{HOSTNAME}] 执行: {task[:80]}...")
            result = run_opencode(task)
            print(f"[{HOSTNAME}] 完成 (exit={result['exit_code']})")
            self._json(result)
        else:
            self._json({"error": "not found"}, 404)

if __name__ == "__main__":
    server = HTTPServer((ARGS.host, ARGS.port), AgentHandler)
    print(f"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print(f"  🖥️  OpenCode Agent Shell")
    print(f"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print(f"  主机: {HOSTNAME}")
    print(f"  地址: http://{ARGS.host}:{ARGS.port}")
    print(f"  认证: {'Basic ' + ARGS.auth if ARGS.auth else '无'}")
    print(f"  工具: {OPENCODE_BIN}")
    print(f"")
    print(f"  握手端点:")
    print(f"    GET  /health  → 健康检查")
    print(f"    POST /run     → 执行任务")
    print(f"")
    print(f"  示例:")
    print(f"    curl http://{ARGS.host}:{ARGS.port}/health")
    print(f"    curl -X POST http://{ARGS.host}:{ARGS.port}/run -d '{{\"task\":\"ls /\"}}'")
    print(f"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n停止服务")
        server.shutdown()
