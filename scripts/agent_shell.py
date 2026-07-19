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
  POST /run                 → {"task":"你的任务"} → opencode run 执行 → 返回结果
"""

import argparse
import base64
import hmac
import ipaddress
import json
import os
import select
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


HOSTNAME = socket.gethostname()
OPENCODE_BIN = os.environ.get("OPENCODE_BIN", "opencode")
MAX_BODY_BYTES = 1024 * 1024
REQUEST_TIMEOUT_SECONDS = 15
OPENCODE_TIMEOUT_SECONDS = 120
MAX_CONNECTIONS = 32
MAX_CONCURRENT_TASKS = 2
MAX_OUTPUT_BYTES = 1024 * 1024
ACTIVE_PROCESSES = set()
ACTIVE_PROCESSES_LOCK = threading.Lock()
SHUTTING_DOWN = threading.Event()

# Keep imports usable in tests without parsing the test runner's arguments.
ARGS = argparse.Namespace(host="127.0.0.1", port=4096, auth="")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="OpenCode Agent Shell")
    parser.add_argument("--port", type=int, default=4096, help="监听端口")
    parser.add_argument(
        "--auth",
        type=str,
        default=os.environ.get("AGENT_SHELL_AUTH", os.environ.get("OPENCODE_AUTH", "")),
        help="Basic Auth (user:pass)",
    )
    parser.add_argument("--host", type=str, default="127.0.0.1", help="绑定地址")
    return parser.parse_args(argv)


def _is_loopback_host(host):
    normalized = (host or "").strip().lower()
    if normalized == "localhost":
        return True
    if normalized.startswith("[") and normalized.endswith("]"):
        normalized = normalized[1:-1]
    try:
        return ipaddress.ip_address(normalized).is_loopback
    except ValueError:
        return False


def check_auth(handler):
    """Basic Auth 校验"""
    if not ARGS.auth:
        return True
    auth_header = handler.headers.get("Authorization", "")
    if not auth_header.startswith("Basic "):
        return False
    try:
        decoded = base64.b64decode(auth_header[6:], validate=True)
        expected = ARGS.auth.encode("utf-8")
        return hmac.compare_digest(decoded, expected)
    except (TypeError, ValueError, UnicodeError):
        return False


def _as_text(value):
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def _combine_output(stdout, stderr):
    stdout_text = _as_text(stdout).strip()
    stderr_text = _as_text(stderr).strip()
    if stdout_text and stderr_text:
        return stdout_text + "\n[stderr]\n" + stderr_text
    return stdout_text or stderr_text or "(empty)"


def _bounded_env_int(name, default, minimum=1, maximum=None):
    try:
        value = int(os.environ.get(name, str(default)))
    except (TypeError, ValueError):
        return default
    if value < minimum or (maximum is not None and value > maximum):
        return default
    return value


def _register_process(process):
    with ACTIVE_PROCESSES_LOCK:
        ACTIVE_PROCESSES.add(process)


def _unregister_process(process):
    with ACTIVE_PROCESSES_LOCK:
        ACTIVE_PROCESSES.discard(process)


def _terminate_active_processes():
    SHUTTING_DOWN.set()
    with ACTIVE_PROCESSES_LOCK:
        processes = list(ACTIVE_PROCESSES)
    for process in processes:
        if process.poll() is None:
            _kill_process_group(process)
    for process in processes:
        try:
            process.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            pass


def _capture_stream(stream, chunks, state, lock):
    try:
        while True:
            chunk = stream.read(65536)
            if not chunk:
                return
            with lock:
                remaining = MAX_OUTPUT_BYTES - state["total"]
                if remaining <= 0:
                    state["limited"] = True
                    return
                chunks.append(chunk[:remaining])
                state["total"] += len(chunk)
                if len(chunk) > remaining:
                    state["limited"] = True
                    return
    except (OSError, ValueError):
        return


def _kill_process_group(process):
    """Terminate the child and descendants after a timeout."""
    if os.name == "nt":
        try:
            subprocess.run(
                ["taskkill", "/F", "/T", "/PID", str(process.pid)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=5,
            )
        except (OSError, subprocess.SubprocessError):
            pass
        try:
            process.kill()
        except (OSError, ProcessLookupError):
            pass
        return

    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        try:
            process.kill()
        except (OSError, ProcessLookupError):
            pass


def _spawn_kwargs():
    if os.name == "nt":
        return {
            "creationflags": getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0),
        }
    return {"start_new_session": True}


def run_opencode(task, cancel_check=None):
    """调当前 OpenCode CLI 执行任务，并保留两路输出。"""
    process = None
    stdout_chunks = []
    stderr_chunks = []
    capture_state = {"total": 0, "limited": False}
    capture_lock = threading.Lock()
    stdout_thread = None
    stderr_thread = None
    try:
        child_env = {
            key: value
            for key, value in os.environ.items()
            if key not in ("AGENT_SHELL_AUTH", "OPENCODE_AUTH")
        }
        child_env["HOME"] = os.path.expanduser("~")
        process = subprocess.Popen(
            [OPENCODE_BIN, "run", task],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=False,
            env=child_env,
            **_spawn_kwargs(),
        )
        _register_process(process)
        if SHUTTING_DOWN.is_set():
            _kill_process_group(process)
            try:
                process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                pass
            return {
                "success": False,
                "output": "Agent Shell 正在停止",
                "exit_code": -1,
                "error_kind": "shutdown",
            }
        stdout_thread = threading.Thread(
            target=_capture_stream,
            args=(process.stdout, stdout_chunks, capture_state, capture_lock),
            daemon=True,
        )
        stderr_thread = threading.Thread(
            target=_capture_stream,
            args=(process.stderr, stderr_chunks, capture_state, capture_lock),
            daemon=True,
        )
        stdout_thread.start()
        stderr_thread.start()
        deadline = time.monotonic() + OPENCODE_TIMEOUT_SECONDS
        reason = ""
        while process.poll() is None:
            if cancel_check is not None:
                try:
                    disconnected = cancel_check()
                except (OSError, ValueError):
                    disconnected = True
                if disconnected:
                    reason = "client_disconnected"
                    _kill_process_group(process)
                    break
            if capture_state["limited"]:
                reason = "output_limit"
                _kill_process_group(process)
                break
            if time.monotonic() >= deadline:
                reason = "timeout"
                _kill_process_group(process)
                break
            time.sleep(0.02)
        if reason:
            try:
                process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                pass
        else:
            process.wait()
        if stdout_thread is not None:
            stdout_thread.join(timeout=5)
        if stderr_thread is not None:
            stderr_thread.join(timeout=5)
        stdout = b"".join(stdout_chunks)
        stderr = b"".join(stderr_chunks)
        output = _combine_output(stdout, stderr)
        if capture_state["limited"] and not reason:
            reason = "output_limit"
        if reason == "timeout":
            timeout_message = "任务超时 ({}s)".format(OPENCODE_TIMEOUT_SECONDS)
            output = timeout_message if output == "(empty)" else output + "\n" + timeout_message
            return {"success": False, "output": output, "exit_code": -1, "error_kind": reason}
        if reason == "output_limit":
            limit_message = "任务输出超过限制 ({} bytes)".format(MAX_OUTPUT_BYTES)
            output = limit_message if output == "(empty)" else output + "\n" + limit_message
            return {"success": False, "output": output, "exit_code": -1, "error_kind": reason}
        if reason == "client_disconnected":
            return {
                "success": False,
                "output": "客户端已断开，任务已终止",
                "exit_code": -1,
                "error_kind": reason,
            }
        return {
            "success": process.returncode == 0,
            "output": output,
            "exit_code": process.returncode,
        }
    except FileNotFoundError:
        return {
            "success": False,
            "output": "opencode 未找到: {}".format(OPENCODE_BIN),
            "exit_code": -1,
        }
    except (OSError, TypeError, ValueError, UnicodeError) as error:
        if process is not None and process.poll() is None:
            _kill_process_group(process)
            try:
                process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                pass
        return {
            "success": False,
            "output": "启动 opencode 失败: {}".format(error),
            "exit_code": -1,
        }
    finally:
        if process is not None:
            _unregister_process(process)
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    try:
                        stream.close()
                    except OSError:
                        pass


def _http_status_for_result(result):
    if result.get("success"):
        return 200
    if result.get("exit_code") == -1:
        if result.get("error_kind") == "timeout" or "任务超时" in result.get("output", ""):
            return 504
        if result.get("error_kind") == "output_limit":
            return 502
        return 503
    return 502


class AgentHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def setup(self):
        super().setup()
        self.connection.settimeout(REQUEST_TIMEOUT_SECONDS)
        self._request_timer = None
        self._start_request_timer()

    def _start_request_timer(self):
        self._cancel_request_timer()
        self._request_timer = threading.Timer(REQUEST_TIMEOUT_SECONDS, self._expire_request)
        self._request_timer.daemon = True
        self._request_timer.start()

    def _cancel_request_timer(self):
        timer = getattr(self, "_request_timer", None)
        if timer is not None:
            timer.cancel()
            self._request_timer = None

    def _expire_request(self):
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def _client_disconnected(self):
        try:
            readable, _, _ = select.select([self.connection], [], [], 0)
            if not readable:
                return False
            return self.connection.recv(1, socket.MSG_PEEK) == b""
        except (OSError, ValueError):
            return True

    def finish(self):
        self._cancel_request_timer()
        super().finish()

    def log_message(self, fmt, *args):
        pass  # 静默日志

    def _json(self, data, code=200, extra_headers=None):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass

    def do_GET(self):
        self._cancel_request_timer()
        path = urlparse(self.path).path
        if path == "/health":
            if not check_auth(self):
                self._json(
                    {"error": "unauthorized"},
                    401,
                    {"WWW-Authenticate": 'Basic realm="agent-shell"'},
                )
                return
            available = (
                os.path.isfile(OPENCODE_BIN) and os.access(OPENCODE_BIN, os.X_OK)
                if os.path.sep in OPENCODE_BIN
                else shutil.which(OPENCODE_BIN) is not None
            )
            self._json(
                {
                    "status": "ok" if available else "degraded",
                    "agent": "opencode-shell",
                    "protocol": "agent-shell",
                    "run_endpoint": "/run",
                    "hostname": HOSTNAME,
                    "opencode_available": available,
                },
                200 if available else 503,
            )
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        self._cancel_request_timer()
        path = urlparse(self.path).path

        if not check_auth(self):
            self._json({"error": "unauthorized"}, 401)
            return

        if path != "/run":
            self._json({"error": "not found"}, 404)
            return

        raw_length = self.headers.get("Content-Length", "0")
        try:
            length = int(raw_length)
        except (TypeError, ValueError):
            self._json({"error": "invalid Content-Length"}, 400)
            return

        if length < 0:
            self._json({"error": "invalid Content-Length"}, 400)
            return
        if length > MAX_BODY_BYTES:
            self._json(
                {"error": "request body too large", "max_bytes": MAX_BODY_BYTES},
                413,
            )
            return

        self._start_request_timer()
        try:
            raw_body = self.rfile.read(length) if length else b""
        except socket.timeout:
            self._json({"error": "request body read timed out"}, 408)
            return
        finally:
            self._cancel_request_timer()

        if len(raw_body) != length:
            self._json({"error": "incomplete request body"}, 400)
            return

        try:
            body = json.loads(raw_body) if raw_body else {}
        except (json.JSONDecodeError, UnicodeDecodeError, RecursionError):
            self._json({"error": "invalid JSON body"}, 400)
            return

        if not isinstance(body, dict):
            self._json({"error": "JSON body must be an object"}, 400)
            return

        task = body.get("task", "")
        if not isinstance(task, str):
            self._json({"error": "'task' must be a string"}, 400)
            return
        if not task:
            self._json({"error": "missing 'task' field"}, 400)
            return

        if SHUTTING_DOWN.is_set():
            self._json({"error": "server is shutting down"}, 503)
            return

        if not self.server.task_slots.acquire(False):
            self._json({"error": "too many concurrent tasks"}, 429, {"Retry-After": "1"})
            return
        print("[{}] 执行任务 ({} chars)".format(HOSTNAME, len(task)))
        try:
            result = run_opencode(task, cancel_check=self._client_disconnected)
            print("[{}] 完成 (exit={})".format(HOSTNAME, result["exit_code"]))
            self._json(result, _http_status_for_result(result))
        finally:
            self.server.task_slots.release()


class AgentHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, server_address, handler_class):
        super().__init__(server_address, handler_class)
        self.connection_slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
        self.task_slots = threading.BoundedSemaphore(MAX_CONCURRENT_TASKS)

    def process_request(self, request, client_address):
        if not self.connection_slots.acquire(False):
            body = b'{"error":"too many connections"}'
            try:
                request.sendall(
                    b"HTTP/1.0 503 Service Unavailable\r\n"
                    b"Content-Type: application/json\r\n"
                    b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n\r\n" + body
                )
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.connection_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.connection_slots.release()


class AgentHTTPServerV6(AgentHTTPServer):
    address_family = socket.AF_INET6


def main(argv=None):
    global ARGS
    ARGS = parse_args(argv)
    SHUTTING_DOWN.clear()
    global MAX_CONNECTIONS, MAX_CONCURRENT_TASKS, MAX_OUTPUT_BYTES, OPENCODE_TIMEOUT_SECONDS
    MAX_CONNECTIONS = _bounded_env_int("AGENT_SHELL_MAX_CONNECTIONS", MAX_CONNECTIONS, maximum=256)
    MAX_CONCURRENT_TASKS = _bounded_env_int("AGENT_SHELL_MAX_TASKS", MAX_CONCURRENT_TASKS, maximum=32)
    MAX_OUTPUT_BYTES = _bounded_env_int(
        "AGENT_SHELL_MAX_OUTPUT_BYTES", MAX_OUTPUT_BYTES, maximum=64 * 1024 * 1024
    )
    OPENCODE_TIMEOUT_SECONDS = _bounded_env_int(
        "AGENT_SHELL_TASK_TIMEOUT", OPENCODE_TIMEOUT_SECONDS, maximum=3600
    )

    if ARGS.port < 1 or ARGS.port > 65535:
        print("--port must be between 1 and 65535", file=sys.stderr)
        return 2

    if not _is_loopback_host(ARGS.host) and not ARGS.auth:
        print("--auth is required when --host is not loopback", file=sys.stderr)
        return 2

    bind_host = ARGS.host
    if bind_host.startswith("[") and bind_host.endswith("]"):
        bind_host = bind_host[1:-1]
    server_class = AgentHTTPServerV6 if ":" in bind_host else AgentHTTPServer
    server = server_class((bind_host, ARGS.port), AgentHandler)
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("  🖥️  OpenCode Agent Shell")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("  主机: {}".format(HOSTNAME))
    print("  地址: http://{}:{}".format(ARGS.host, ARGS.port))
    print("  认证: {}".format("enabled" if ARGS.auth else "disabled"))
    print("  工具: {}".format(OPENCODE_BIN))
    print("")
    print("  握手端点:")
    print("    GET  /health  → 健康检查")
    print("    POST /run     → 执行任务")
    print("")
    print("  示例:")
    print("    curl http://{}:{}/health".format(ARGS.host, ARGS.port))
    print(
        "    curl -X POST http://{}:{}/run -d '{{\"task\":\"ls /\"}}'".format(
            ARGS.host, ARGS.port
        )
    )
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    def raise_keyboard_interrupt(_signum, _frame):
        SHUTTING_DOWN.set()
        raise KeyboardInterrupt()

    previous_handlers = {}
    for signal_number in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[signal_number] = signal.getsignal(signal_number)
        signal.signal(signal_number, raise_keyboard_interrupt)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n停止服务")
    finally:
        _terminate_active_processes()
        server.server_close()
        for signal_number, handler in previous_handlers.items():
            signal.signal(signal_number, handler)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
