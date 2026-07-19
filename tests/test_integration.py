#!/usr/bin/env python3
"""Offline integration tests for the local-to-remote handshake contract."""

import base64
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))
import handshake_client  # noqa: E402


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def auth_header(value):
    return "Basic " + base64.b64encode(value.encode()).decode()


def request_json(url, payload=None, auth="", timeout=3):
    body = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        body = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    if auth:
        headers["Authorization"] = auth_header(auth)
    request = Request(url, data=body, headers=headers)
    try:
        with urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read().decode())
    except HTTPError as exc:
        try:
            raw = exc.read().decode()
            return exc.code, json.loads(raw) if raw else {}
        finally:
            exc.close()


def wait_for_health(url, auth="", timeout=8):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            return request_json(url, auth=auth, timeout=1)
        except (URLError, OSError, ValueError) as exc:
            last_error = exc
            time.sleep(0.05)
    raise AssertionError(f"service did not become ready: {last_error}")


class NativeOpenCodeHandler(BaseHTTPRequestHandler):
    server_version = "NativeMock/1"
    last_message_payload = None

    def log_message(self, *_args):
        pass

    def respond(self, status, payload):
        raw = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == "/global/health":
            self.respond(200, {"healthy": True, "version": "mock-native"})
        else:
            self.respond(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/session":
            self.respond(200, {"id": "session-test"})
        elif self.path == "/session/session-test/message":
            type(self).last_message_payload = payload
            text = payload["parts"][0]["text"]
            self.respond(200, {
                "parts": [{"type": "text", "text": text}],
                "info": {"providerID": "mock", "modelID": "native", "cost": 0},
            })
        else:
            self.respond(404, {"error": "not found"})


class TruncatedHealthHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        raw = b'{"status":"ok"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw) + 20))
        self.end_headers()
        self.wfile.write(raw)
        self.close_connection = True


class OversizedHealthHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(handshake_client.MAX_RESPONSE_BYTES + 1))
        self.end_headers()
        self.close_connection = True


class RedirectHandler(BaseHTTPRequestHandler):
    target = ""

    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.send_response(302)
        self.send_header("Location", type(self).target + self.path)
        self.send_header("Content-Length", "0")
        self.end_headers()


class CaptureHealthHandler(BaseHTTPRequestHandler):
    authorization_headers = []

    def log_message(self, *_args):
        pass

    def do_GET(self):
        type(self).authorization_headers.append(self.headers.get("Authorization"))
        raw = json.dumps({"healthy": True, "version": "capture"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


class CaptureGenericHandler(BaseHTTPRequestHandler):
    authorization_headers = []

    def log_message(self, *_args):
        pass

    def _capture(self):
        type(self).authorization_headers.append(self.headers.get("Authorization"))

    def _respond(self, status, payload):
        raw = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self._capture()
        if self.path == "/health":
            self._respond(200, {"status": "ok", "protocol": "agent-shell"})
        else:
            self._respond(404, {"error": "not found"})

    def do_POST(self):
        self._capture()
        self._respond(404, {"error": "not found"})


class McpHealthHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path != "/mcp":
            self.send_response(404)
            self.end_headers()
            return
        raw = json.dumps({"jsonrpc": "2.0", "result": {"capabilities": {}}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.tmp = Path(self.temp.name)
        self.skill_dir = self.tmp / "skill"
        (self.skill_dir / "references" / "servers").mkdir(parents=True)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.server_process = None

    def tearDown(self):
        if self.server_process is not None:
            self.server_process.terminate()
            try:
                self.server_process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.server_process.kill()
                self.server_process.wait(timeout=3)
            if self.server_process.stdout is not None:
                self.server_process.stdout.close()
            if self.server_process.stderr is not None:
                self.server_process.stderr.close()
        self.temp.cleanup()

    def mock_cli(self):
        path = self.tmp / "mock-opencode.py"
        log = self.tmp / "cli-args.json"
        path.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys, time\n"
            "path = os.environ.get('MOCK_ARGS_FILE')\n"
            "if path:\n"
            "    open(path, 'w').write(json.dumps(sys.argv[1:]))\n"
            "child = None\n"
            "child_file = os.environ.get('MOCK_CHILD_PID_FILE')\n"
            "if child_file:\n"
            "    import subprocess\n"
            "    child = subprocess.Popen(['sleep', '30'])\n"
            "    open(child_file, 'w').write(str(child.pid))\n"
            "try:\n"
            "    time.sleep(float(os.environ.get('MOCK_DELAY', '0')))\n"
            "    print('mock stdout')\n"
            "    print('mock stderr', file=sys.stderr)\n"
            "finally:\n"
            "    if child is not None:\n"
            "        child.terminate()\n"
            "        child.wait()\n"
            "raise SystemExit(int(os.environ.get('MOCK_EXIT_CODE', '0')))\n"
        )
        path.chmod(0o755)
        return path, log

    def start_agent_shell(self, auth="user:pass", exit_code=0, delay=0, opencode_bin=None, extra_env=None):
        cli, log = self.mock_cli()
        port = free_port()
        env = os.environ.copy()
        env["OPENCODE_BIN"] = str(opencode_bin or cli)
        env["MOCK_ARGS_FILE"] = str(log)
        env["MOCK_EXIT_CODE"] = str(exit_code)
        env["MOCK_DELAY"] = str(delay)
        if extra_env:
            env.update(extra_env)
        self.server_process = subprocess.Popen(
            [sys.executable, str(SCRIPTS / "agent_shell.py"),
             "--host", "127.0.0.1", "--port", str(port), "--auth", auth],
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        url = f"http://127.0.0.1:{port}"
        wait_for_health(url + "/health", auth=auth)
        return url, log

    def run_script(self, name, *args, auth="", extra_env=None, input_text=None):
        env = os.environ.copy()
        env["HOME"] = str(self.home)
        env["OPENCODE_SKILL_DIR"] = str(self.skill_dir)
        if auth:
            env["OPENCODE_AUTH"] = auth
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["bash", str(SCRIPTS / name), *args],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            input=input_text,
            timeout=20,
        )

    def test_agent_shell_and_handshake_support_quoted_task(self):
        url, args_file = self.start_agent_shell()
        status, health = request_json(url + "/health", auth="user:pass")
        self.assertEqual(status, 200)
        self.assertEqual(health["protocol"], "agent-shell")
        self.assertEqual(health["run_endpoint"], "/run")

        status, result = request_json(
            url + "/run",
            {"task": 'say "hello"\\nnext'},
            auth="user:pass",
        )
        self.assertEqual(status, 200)
        self.assertTrue(result["success"])
        self.assertIn("mock stdout", result["output"])
        args = json.loads(args_file.read_text())
        self.assertEqual(args, ["run", 'say "hello"\\nnext'])

        status, denied = request_json(url + "/run", {"task": "x"}, auth="wrong:pass")
        self.assertEqual(status, 401)
        self.assertEqual(denied["error"], "unauthorized")

        status, bad = request_json(url + "/run", payload={}, auth="user:pass")
        self.assertEqual(status, 400)
        self.assertIn("task", bad["error"])

        result = self.run_script("handshake.sh", url, 'say "hello"\\nnext', auth="user:pass")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("say", result.stdout)

        accepted = self.run_script("accept.sh", "mock-node", url, "user:pass")
        self.assertEqual(accepted.returncode, 0, accepted.stderr + accepted.stdout)
        config = (self.home / ".agent-handshake")
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)
        self.assertTrue((self.skill_dir / "references" / "servers" / "mock-node.json").exists())

        port = int(url.rsplit(":", 1)[1])
        identity = {
            "hostname": "full-node",
            "agent_type": "agent-shell",
            "auth": "user:pass",
            "network": {"lan_ips": ["127.0.0.1"]},
            "opencode": {"serve_port": port},
        }
        accepted_full = self.run_script(
            "accept.sh",
            input_text=json.dumps(identity),
            extra_env={"OPENCODE_PORT": "1"},
        )
        self.assertEqual(accepted_full.returncode, 0, accepted_full.stderr + accepted_full.stdout)
        index = json.loads((self.skill_dir / "references" / "servers" / "_index.json").read_text())
        self.assertEqual(index["servers"]["full-node"]["address"], url)

        stale_identity = {
            "hostname": "stale-node",
            "address": "http://127.0.0.1:1",
            "agent_type": "agent-shell",
            "auth": "user:pass",
            "network": {"lan_ips": ["127.0.0.1"]},
            "opencode": {"serve_port": port, "serve_version": "old"},
        }
        accepted_stale = self.run_script(
            "accept.sh",
            input_text=json.dumps(stale_identity),
        )
        self.assertEqual(accepted_stale.returncode, 0, accepted_stale.stderr + accepted_stale.stdout)
        stored_stale = json.loads(
            (self.skill_dir / "references" / "servers" / "stale-node.json").read_text()
        )
        self.assertEqual(stored_stale["address"], url)
        self.assertEqual(stored_stale["reported_address"], "http://127.0.0.1:1")
        self.assertEqual(stored_stale["opencode"]["serve_version"], "?")
        self.assertEqual(stored_stale["opencode"]["reported_serve_version"], "old")

        direct_identity = {
            "hostname": "direct-node",
            "address": url,
            "agent_type": "agent-shell",
            "auth": "user:pass",
        }
        accepted_direct = self.run_script(
            "accept.sh",
            input_text=json.dumps(direct_identity),
        )
        self.assertEqual(
            accepted_direct.returncode,
            0,
            accepted_direct.stderr + accepted_direct.stdout,
        )

        automatic = self.run_script("handshake.sh", "auto", 'auto "quoted"', auth="user:pass")
        self.assertEqual(automatic.returncode, 0, automatic.stderr + automatic.stdout)

        legacy_home = self.tmp / "legacy-home"
        legacy_home.mkdir()
        legacy_config = legacy_home / ".opencode-handshake"
        legacy_config.write_text(
            "ADDRESS={}\nAUTH=user:pass\nPROTOCOL=agent-shell\n".format(url)
        )
        legacy_config.chmod(0o644)
        legacy = self.run_script(
            "handshake.sh",
            "auto",
            "legacy config task",
            extra_env={"HOME": str(legacy_home), "OPENCODE_DISCOVER_FILE": str(self.tmp / "missing.json")},
        )
        self.assertEqual(legacy.returncode, 0, legacy.stderr + legacy.stdout)
        self.assertEqual(legacy_config.stat().st_mode & 0o777, 0o600)

        fresh_home = self.tmp / "fresh-home"
        fresh_home.mkdir()
        discovery_file = self.tmp / "stale-first-discovery.json"
        discovery_file.write_text(json.dumps({
            "public": {"ip": "127.0.0.1", "port": 1, "reachable": True},
            "lan": [{"addr": url, "host": "live-node", "protocol": "agent-shell"}],
            "local": {"reachable": False, "port": 1},
        }))
        fallback = self.run_script(
            "handshake.sh",
            "auto",
            "fallback task",
            auth="user:pass",
            extra_env={
                "HOME": str(fresh_home),
                "OPENCODE_DISCOVER_FILE": str(discovery_file),
                "OPENCODE_DISCOVERY_AUTH": "user:pass",
            },
        )
        self.assertEqual(fallback.returncode, 0, fallback.stderr + fallback.stdout)
        self.assertIn("http://127.0.0.1:1", fallback.stdout)
        self.assertIn(url, fallback.stdout)

        stale_tunnel = self.tmp / "stale-tunnel"
        stale_tunnel.mkdir()
        (stale_tunnel / "opencode-tunnel.url").write_text(
            "https://stale-name.trycloudflare.com\n"
        )
        (stale_tunnel / "opencode-tunnel.pid").write_text("999999\n")
        (stale_tunnel / "opencode-tunnel.bin").write_text("/tmp/cloudflared\n")
        registered = self.run_script(
            "register.sh",
            "auto",
            auth="user:pass",
            extra_env={
                "OPENCODE_PORT": str(port),
                "OPENCODE_SKIP_PUBLIC_IP": "1",
                "OPENCODE_TUNNEL_STATE_DIR": str(self.tmp / "stale-tunnel"),
            },
        )
        self.assertEqual(registered.returncode, 0, registered.stderr + registered.stdout)
        self.assertIn('"agent_type": "agent-shell"', registered.stdout)
        registered_identity = self.skill_dir / "references" / "servers" / f"{socket.gethostname()}.json"
        self.assertEqual(registered_identity.stat().st_mode & 0o777, 0o600)
        self.assertIn('"tunnel": null', registered.stdout)

    def test_native_opencode_protocol(self):
        NativeOpenCodeHandler.last_message_payload = None
        port = free_port()
        server = ThreadingHTTPServer(("127.0.0.1", port), NativeOpenCodeHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = self.run_script(
                "handshake.sh", f"http://127.0.0.1:{port}", 'native "task"'
            )
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn("native", result.stdout)
            self.assertNotIn("model", NativeOpenCodeHandler.last_message_payload)
        finally:
            server.shutdown()
            thread.join(timeout=3)
            server.server_close()

    def test_mcp_health_is_discovery_only(self):
        port = free_port()
        server = ThreadingHTTPServer(("127.0.0.1", port), McpHealthHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            address = f"http://127.0.0.1:{port}"
            result = handshake_client.probe(address, protocol="mcp")
            self.assertEqual(result["protocol"], "mcp")
            self.assertEqual(result["health_path"], "/mcp")
            with self.assertRaises(handshake_client.ClientError) as caught:
                handshake_client.run_task(address, "", "do work", protocol="mcp")
            self.assertIn("health discovery only", str(caught.exception))
        finally:
            server.shutdown()
            thread.join(timeout=3)
            server.server_close()

    def test_address_normalization_accepts_https_without_port(self):
        self.assertEqual(
            handshake_client._clean_address("https://remote.example.com/"),
            "https://remote.example.com",
        )
        with self.assertRaises(handshake_client.ClientError):
            handshake_client._clean_address("https://user:pass@remote.example.com")
        with self.assertRaises(handshake_client.ClientError):
            handshake_client._clean_address("http://[invalid")

    def test_truncated_http_response_is_reported_without_traceback(self):
        port = free_port()
        server = ThreadingHTTPServer(("127.0.0.1", port), TruncatedHealthHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPTS / "handshake_client.py"),
                    "probe",
                    "--address",
                    f"http://127.0.0.1:{port}",
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                timeout=5,
            )
            self.assertEqual(result.returncode, 2)
            self.assertNotIn("Traceback", result.stderr)
            self.assertIn("health probe failed", result.stderr)
        finally:
            server.shutdown()
            thread.join(timeout=3)
            server.server_close()

    def test_oversized_http_response_is_rejected(self):
        port = free_port()
        server = ThreadingHTTPServer(("127.0.0.1", port), OversizedHealthHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with self.assertRaises(handshake_client.ClientError) as caught:
                handshake_client.probe(f"http://127.0.0.1:{port}")
            self.assertIn("exceeds", str(caught.exception))
        finally:
            server.shutdown()
            thread.join(timeout=3)
            server.server_close()

    def test_authenticated_redirect_cannot_forward_credentials_cross_origin(self):
        capture_port = free_port()
        capture = ThreadingHTTPServer(("127.0.0.1", capture_port), CaptureHealthHandler)
        capture_thread = threading.Thread(target=capture.serve_forever, daemon=True)
        capture_thread.start()
        redirect_port = free_port()
        RedirectHandler.target = f"http://127.0.0.1:{capture_port}"
        redirect = ThreadingHTTPServer(("127.0.0.1", redirect_port), RedirectHandler)
        redirect_thread = threading.Thread(target=redirect.serve_forever, daemon=True)
        redirect_thread.start()
        CaptureHealthHandler.authorization_headers = []
        try:
            with self.assertRaises(handshake_client.ClientError) as caught:
                handshake_client.probe(
                    f"http://127.0.0.1:{redirect_port}",
                    auth="audit:secret",
                )
            self.assertIn("different origin", str(caught.exception))
            self.assertEqual(CaptureHealthHandler.authorization_headers, [])
            with self.assertRaises(handshake_client.ClientError):
                handshake_client.probe(f"http://127.0.0.1:{redirect_port}")
            self.assertEqual(CaptureHealthHandler.authorization_headers, [])
        finally:
            redirect.shutdown()
            redirect_thread.join(timeout=3)
            redirect.server_close()
            capture.shutdown()
            capture_thread.join(timeout=3)
            capture.server_close()

    def test_auto_discovery_does_not_reuse_saved_auth_for_other_address(self):
        CaptureGenericHandler.authorization_headers = []
        port = free_port()
        server = ThreadingHTTPServer(("127.0.0.1", port), CaptureGenericHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            custom_home = self.tmp / "saved-auth-home"
            custom_home.mkdir()
            (custom_home / ".agent-handshake").write_text(
                "ADDRESS=http://127.0.0.1:1\n"
                "AUTH=audit:secret\n"
                "PROTOCOL=agent-shell\n"
            )
            discovery_file = self.tmp / "saved-auth-discovery.json"
            discovery_file.write_text(json.dumps({
                "public": {"reachable": False},
                "local": {"reachable": False},
                "lan": [{
                    "addr": f"http://127.0.0.1:{port}",
                    "protocol": "agent-shell",
                }],
            }))
            result = self.run_script(
                "handshake.sh",
                "auto",
                "do not run",
                extra_env={
                    "HOME": str(custom_home),
                    "OPENCODE_DISCOVER_FILE": str(discovery_file),
                },
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(CaptureGenericHandler.authorization_headers)
            self.assertTrue(
                all(header in (None, "") for header in CaptureGenericHandler.authorization_headers)
            )
        finally:
            server.shutdown()
            thread.join(timeout=3)
            server.server_close()

    def test_agent_shell_failure_and_request_validation(self):
        url, _ = self.start_agent_shell(exit_code=7)
        status, result = request_json(url + "/run", {"task": "fail"}, auth="user:pass")
        self.assertEqual(status, 502)
        self.assertFalse(result["success"])
        self.assertIn("mock stdout", result["output"])
        self.assertIn("mock stderr", result["output"])

        request = Request(
            url + "/run",
            data=b"{",
            headers={
                "Content-Type": "application/json",
                "Authorization": auth_header("user:pass"),
            },
            method="POST",
        )
        with self.assertRaises(HTTPError) as caught:
            urlopen(request, timeout=3)
        self.assertEqual(caught.exception.code, 400)
        caught.exception.close()

        failed = self.run_script("handshake.sh", url, "fail", auth="user:pass")
        self.assertNotEqual(failed.returncode, 0)

    def test_agent_shell_health_rejects_non_file_binary(self):
        url, _ = self.start_agent_shell(opencode_bin="/tmp")
        status, health = request_json(url + "/health", auth="user:pass")
        self.assertEqual(status, 503)
        self.assertEqual(health["status"], "degraded")

    def test_agent_shell_rejects_invalid_port_without_traceback(self):
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPTS / "agent_shell.py"),
                "--host",
                "127.0.0.1",
                "--port",
                "0",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("Traceback", result.stderr)

    def test_agent_shell_handles_unicode_auth_and_output_limit(self):
        url, _ = self.start_agent_shell(auth="用户:密码")
        status, health = request_json(url + "/health", auth="用户:密码")
        self.assertEqual(status, 200)
        self.assertEqual(health["status"], "ok")

        yes_path = "/usr/bin/yes"
        if not Path(yes_path).exists():
            self.skipTest("/usr/bin/yes is unavailable")
        old_process = self.server_process
        old_process.terminate()
        old_process.wait(timeout=3)
        if old_process.stdout is not None:
            old_process.stdout.close()
        if old_process.stderr is not None:
            old_process.stderr.close()
        self.server_process = None
        url, _ = self.start_agent_shell(
            auth="user:pass",
            opencode_bin=yes_path,
            extra_env={"AGENT_SHELL_MAX_OUTPUT_BYTES": "4096"},
        )
        status, result = request_json(url + "/run", {"task": "noise"}, auth="user:pass")
        self.assertEqual(status, 502)
        self.assertIn("输出超过限制", result["output"])
        self.assertLess(len(result["output"]), 10000)

    def test_agent_shell_limits_concurrent_tasks(self):
        url, _ = self.start_agent_shell(
            delay=1,
            extra_env={"AGENT_SHELL_MAX_TASKS": "1"},
        )
        first = []

        def run_first():
            first.append(request_json(url + "/run", {"task": "first"}, auth="user:pass"))

        thread = threading.Thread(target=run_first)
        thread.start()
        time.sleep(0.15)
        status, result = request_json(url + "/run", {"task": "second"}, auth="user:pass")
        thread.join(timeout=3)
        self.assertEqual(status, 429)
        self.assertIn("concurrent", result["error"])
        self.assertEqual(first[0][0], 200)

    def test_agent_shell_shutdown_cleans_active_process_group(self):
        child_file = self.tmp / "active-child.pid"
        url, _ = self.start_agent_shell(
            delay=30,
            extra_env={"MOCK_CHILD_PID_FILE": str(child_file)},
        )
        outcome = []

        def run_task():
            try:
                outcome.append(request_json(url + "/run", {"task": "long"}, auth="user:pass"))
            except (OSError, URLError):
                outcome.append(None)

        thread = threading.Thread(target=run_task)
        thread.start()
        deadline = time.monotonic() + 3
        while not child_file.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(child_file.exists())
        child_pid = int(child_file.read_text())
        server_process = self.server_process
        server_process.send_signal(signal.SIGTERM)
        server_process.wait(timeout=5)
        thread.join(timeout=5)
        if server_process.stdout is not None:
            server_process.stdout.close()
        if server_process.stderr is not None:
            server_process.stderr.close()
        self.server_process = None
        for _ in range(20):
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            state = subprocess.run(
                ["ps", "-p", str(child_pid), "-o", "stat="],
                text=True,
                capture_output=True,
            ).stdout.strip()
            if not state or "Z" in state:
                break
            time.sleep(0.05)
        else:
            self.fail("active child process survived Agent Shell shutdown")

    def test_agent_shell_cancels_task_when_client_disconnects(self):
        child_file = self.tmp / "disconnect-child.pid"
        url, _ = self.start_agent_shell(
            delay=30,
            extra_env={"MOCK_CHILD_PID_FILE": str(child_file)},
        )
        port = int(url.rsplit(":", 1)[1])
        body = json.dumps({"task": "disconnect"}).encode()
        sock = socket.create_connection(("127.0.0.1", port), timeout=3)
        sock.sendall(
            (
                "POST /run HTTP/1.0\r\n"
                "Host: localhost\r\n"
                "Content-Type: application/json\r\n"
                "Content-Length: {}\r\n"
                "Authorization: {}\r\n\r\n"
            ).format(len(body), auth_header("user:pass")).encode()
            + body
        )
        deadline = time.monotonic() + 3
        while not child_file.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(child_file.exists())
        child_pid = int(child_file.read_text())
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()
        for _ in range(60):
            state = subprocess.run(
                ["ps", "-p", str(child_pid), "-o", "stat="],
                text=True,
                capture_output=True,
            ).stdout.strip()
            if not state or "Z" in state:
                break
            time.sleep(0.05)
        else:
            self.fail("task child survived client disconnect")

    def test_agent_shell_health_remains_concurrent(self):
        url, _ = self.start_agent_shell(delay=1)
        outcome = []

        def run_slow_task():
            outcome.append(request_json(url + "/run", {"task": "slow"}, auth="user:pass"))

        thread = threading.Thread(target=run_slow_task)
        thread.start()
        time.sleep(0.1)
        started = time.monotonic()
        status, _ = request_json(url + "/health", auth="user:pass")
        elapsed = time.monotonic() - started
        thread.join(timeout=3)
        self.assertEqual(status, 200)
        self.assertLess(elapsed, 0.5)
        self.assertEqual(outcome[0][0], 200)

    def test_discover_preserves_lan_results_without_gnu_tools(self):
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "ip").write_text(
            "#!/bin/sh\nprintf '%s\\n' 'inet 192.168.50.1/24 br0'\n"
        )
        (bin_dir / "ssh").write_text("#!/bin/sh\nprintf '%s\\n' mock-node\n")
        (bin_dir / "curl").write_text(
            "#!/bin/sh\n"
            "if [ -n \"$MOCK_CURL_LOG\" ]; then printf '%s\\n' \"$*\" >> \"$MOCK_CURL_LOG\"; fi\n"
            "url=''\n"
            "for arg in \"$@\"; do case \"$arg\" in http://*|https://*) url=\"$arg\";; esac; done\n"
            "case \"$url\" in\n"
            "  *192.168.50.2:4677/health) printf '%s\\n' '{\"status\":\"ok\",\"version\":\"mock\"}'; exit 0;;\n"
            "  *) exit 1;;\n"
            "esac\n"
        )
        for path in bin_dir.iterdir():
            path.chmod(0o755)
        output_file = self.tmp / "discover.json"
        curl_log = self.tmp / "discover-curl.log"
        env = {
            "PATH": str(bin_dir) + os.pathsep + os.environ.get("PATH", ""),
            "OPENCODE_PORT": "4677",
            "OPENCODE_DISCOVER_TIMEOUT": "0.2",
            "OPENCODE_DISCOVER_CONCURRENCY": "64",
            "OPENCODE_DISCOVER_FILE": str(output_file),
            "MOCK_CURL_LOG": str(curl_log),
        }
        result = self.run_script("discover.sh", auth="audit:secret", extra_env=env)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        data = json.loads(output_file.read_text())
        self.assertEqual(len(data["lan"]), 1)
        self.assertEqual(data["lan"][0]["addr"], "192.168.50.2:4677")
        self.assertEqual(output_file.stat().st_mode & 0o777, 0o600)
        lan_requests = [
            line for line in curl_log.read_text().splitlines() if "192.168.50." in line
        ]
        self.assertTrue(lan_requests)
        self.assertTrue(all("audit:secret" not in line for line in lan_requests))

    def test_discover_rejects_out_of_range_port(self):
        result = self.run_script(
            "discover.sh",
            extra_env={
                "OPENCODE_PORT": "65536",
                "OPENCODE_SKIP_PUBLIC_IP": "1",
                "OPENCODE_DISCOVER_FILE": str(self.tmp / "invalid-port.json"),
            },
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("1-65535", result.stderr)

    def test_discover_uses_saved_auth_only_for_trusted_targets(self):
        bin_dir = self.tmp / "saved-auth-bin"
        bin_dir.mkdir()
        curl_log = self.tmp / "saved-auth-curl.log"
        (bin_dir / "ip").write_text(
            "#!/bin/sh\nprintf '%s\\n' 'inet 192.168.51.1/24 br0'\n"
        )
        (bin_dir / "ssh").write_text("#!/bin/sh\nprintf '%s\\n' mock-node\n")
        (bin_dir / "curl").write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$*\" >> \"$MOCK_CURL_LOG\"\n"
            "url=''\n"
            "auth=''\n"
            "previous=''\n"
            "for arg in \"$@\"; do\n"
            "  case \"$previous\" in -u) auth=\"$arg\";; esac\n"
            "  case \"$arg\" in http://*|https://*) url=\"$arg\";; esac\n"
            "  previous=\"$arg\"\n"
            "done\n"
            "case \"$url|$auth\" in\n"
            "  http://127.0.0.1:4678/global/health\\|audit:secret) printf '%s\\n' '{\"healthy\":true,\"version\":\"mock\"}'; exit 0;;\n"
            "  http://192.168.51.2:4678/health\\|) printf '%s\\n' '{\"status\":\"ok\",\"version\":\"lan\"}'; exit 0;;\n"
            "  *) exit 1;;\n"
            "esac\n"
        )
        for path in bin_dir.iterdir():
            path.chmod(0o755)
        (self.home / ".agent-handshake").write_text(
            "ADDRESS=http://127.0.0.1:4678\nAUTH=audit:secret\nPROTOCOL=opencode\n"
        )
        output_file = self.tmp / "saved-auth-discover.json"
        result = self.run_script(
            "discover.sh",
            extra_env={
                "PATH": str(bin_dir) + os.pathsep + os.environ.get("PATH", ""),
                "OPENCODE_PORT": "4678",
                "OPENCODE_DISCOVER_TIMEOUT": "0.2",
                "OPENCODE_DISCOVER_CONCURRENCY": "64",
                "OPENCODE_DISCOVER_FILE": str(output_file),
                "OPENCODE_SKIP_PUBLIC_IP": "1",
                "MOCK_CURL_LOG": str(curl_log),
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        data = json.loads(output_file.read_text())
        self.assertTrue(data["local"]["reachable"])
        self.assertEqual(len(data["lan"]), 1)
        log_lines = curl_log.read_text().splitlines()
        local_lines = [line for line in log_lines if "127.0.0.1" in line]
        lan_lines = [line for line in log_lines if "192.168.51." in line]
        self.assertTrue(any("audit:secret" in line for line in local_lines))
        self.assertTrue(lan_lines)
        self.assertTrue(all("audit:secret" not in line for line in lan_lines))

    def test_tunnel_lifecycle_has_single_owned_process(self):
        bin_dir = self.tmp / "tunnel-bin"
        bin_dir.mkdir()
        (bin_dir / "curl").write_text(
            "#!/bin/sh\n"
            "url=''\n"
            "auth=''\n"
            "previous=''\n"
            "for arg in \"$@\"; do\n"
            "  case \"$previous\" in -u) auth=\"$arg\";; esac\n"
            "  case \"$arg\" in http://*|https://*) url=\"$arg\";; esac\n"
            "  previous=\"$arg\"\n"
            "done\n"
            "case \"$url\" in\n"
            "  http://127.0.0.1:4688/health|https://fake-name.trycloudflare.com/health)\n"
            "    if [ \"$MOCK_ALLOW_ANON\" = 1 ] && [ \"$url\" = 'http://127.0.0.1:4688/health' ]; then auth='user:pass'; fi\n"
            "    [ \"$auth\" = 'user:pass' ] || exit 1\n"
            "    printf '%s\\n' '{\"status\":\"ok\"}'\n"
            "    exit 0\n"
            "    ;;\n"
            "  *) exit 1;;\n"
            "esac\n"
        )
        (bin_dir / "cloudflared").write_text(
            "#!/bin/sh\n"
            "if [ -n \"$MOCK_TUNNEL_MARK\" ]; then : > \"$MOCK_TUNNEL_MARK\"; fi\n"
            "if [ -n \"$MOCK_TUNNEL_ARGS\" ]; then printf '%s\\n' \"$*\" > \"$MOCK_TUNNEL_ARGS\"; fi\n"
            "printf '%s\\n' 'INF https://fake-name.trycloudflare.com'\n"
            "trap 'exit 0' INT TERM\n"
            "while :; do sleep 1; done\n"
        )
        for path in bin_dir.iterdir():
            path.chmod(0o755)
        env = {
            "PATH": str(bin_dir) + os.pathsep + os.environ.get("PATH", ""),
            "OPENCODE_PORT": "4688",
            "OPENCODE_AUTH": "user:pass",
            "OPENCODE_TUNNEL_STATE_DIR": str(self.tmp / "tunnel-state"),
            "MOCK_TUNNEL_MARK": str(self.tmp / "tunnel-invoked"),
            "MOCK_TUNNEL_ARGS": str(self.tmp / "tunnel-args"),
        }
        denied_env = dict(env)
        denied_env.pop("OPENCODE_AUTH")
        denied = self.run_script("tunnel.sh", "start", "4688", extra_env=denied_env)
        self.assertEqual(denied.returncode, 2)
        self.assertFalse((self.tmp / "tunnel-invoked").exists())
        anonymous_env = dict(env)
        anonymous_env["MOCK_ALLOW_ANON"] = "1"
        anonymous = self.run_script("tunnel.sh", "start", "4688", extra_env=anonymous_env)
        self.assertNotEqual(anonymous.returncode, 0)
        self.assertFalse((self.tmp / "tunnel-invoked").exists())
        started = self.run_script("tunnel.sh", "start", "4688", extra_env=env)
        self.assertEqual(started.returncode, 0, started.stderr + started.stdout)
        self.assertIn("fake-name.trycloudflare.com", started.stdout)
        self.assertIn("--protocol http2", (self.tmp / "tunnel-args").read_text())
        duplicate = self.run_script("tunnel.sh", "start", "4688", extra_env=env)
        self.assertNotEqual(duplicate.returncode, 0)
        status = self.run_script("tunnel.sh", "status", "4688", extra_env=env)
        self.assertEqual(status.returncode, 0, status.stderr + status.stdout)
        stopped = self.run_script("tunnel.sh", "stop", "4688", extra_env=env)
        self.assertEqual(stopped.returncode, 0, stopped.stderr + stopped.stdout)
        after = self.run_script("tunnel.sh", "status", "4688", extra_env=env)
        self.assertEqual(after.returncode, 0, after.stderr + after.stdout)
        self.assertIn("未运行", after.stdout)

        fake_pid = subprocess.Popen(["sleep", "30"])
        state_dir = Path(env["OPENCODE_TUNNEL_STATE_DIR"])
        state_dir.mkdir(exist_ok=True)
        (state_dir / "opencode-tunnel.pid").write_text(str(fake_pid.pid))
        (state_dir / "opencode-tunnel.bin").write_text(str(bin_dir / "cloudflared"))
        (state_dir / "opencode-tunnel.url").write_text("https://fake-name.trycloudflare.com\n")
        not_owned = self.run_script("tunnel.sh", "stop", "4688", extra_env=env)
        self.assertEqual(not_owned.returncode, 0, not_owned.stderr + not_owned.stdout)
        self.assertIsNone(fake_pid.poll())
        fake_pid.terminate()
        fake_pid.wait(timeout=3)

        race_env = os.environ.copy()
        race_env.update(env)
        race_env["HOME"] = str(self.home)
        race_env["OPENCODE_SKILL_DIR"] = str(self.skill_dir)
        command = ["bash", str(SCRIPTS / "tunnel.sh"), "start", "4688"]
        first = subprocess.Popen(command, cwd=ROOT, env=race_env, text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        second = subprocess.Popen(command, cwd=ROOT, env=race_env, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        first.communicate(timeout=10)
        second.communicate(timeout=10)
        self.assertEqual(sorted([first.returncode, second.returncode])[0], 0)
        self.assertNotEqual(first.returncode, second.returncode)
        race_stop = self.run_script("tunnel.sh", "stop", "4688", extra_env=env)
        self.assertEqual(race_stop.returncode, 0, race_stop.stderr + race_stop.stdout)

    def test_deploy_argument_and_remote_listener_contract(self):
        bin_dir = self.tmp / "deploy-bin"
        bin_dir.mkdir()
        sudo_dir = self.tmp / "sudo-output"
        sudo_dir.mkdir()
        (bin_dir / "opencode").write_text("#!/bin/sh\nprintf '%s\\n' 1.18.3\n")
        (bin_dir / "curl").write_text("#!/bin/sh\nprintf '%s\\n' '{\"status\":\"ok\"}'\n")
        (bin_dir / "sleep").write_text("#!/bin/sh\nexit 0\n")
        (bin_dir / "sudo").write_text(
            "#!/bin/sh\n"
            "case \"$1\" in\n"
            "  -u) shift 2; \"$@\";;\n"
            "  tee) shift; target=\"$(basename \"$1\")\"; cat > \"$MOCK_SUDO_DIR/$target\";;\n"
            "  chmod) mode=\"$2\"; target=\"$(basename \"$3\")\"; chmod \"$mode\" \"$MOCK_SUDO_DIR/$target\";;\n"
            "  systemctl) [ \"$2\" = is-active ] && printf '%s\\n' active; exit 0;;\n"
            "  *) \"$@\";;\n"
            "esac\n"
        )
        for path in bin_dir.iterdir():
            path.chmod(0o755)
        env = {
            "PATH": str(bin_dir) + os.pathsep + os.environ.get("PATH", ""),
            "MOCK_SUDO_DIR": str(sudo_dir),
            "SUDO_USER": os.environ.get("USER", "root"),
            "AGENT_SHELL_WORKING_DIR": str(self.home),
        }
        denied = self.run_script(
            "deploy.sh",
            "--host", "0.0.0.0",
            "--install-dir", str(self.tmp / "install-denied"),
            extra_env=env,
        )
        self.assertEqual(denied.returncode, 2)
        deployed = self.run_script(
            "deploy.sh",
            "--port", "4690",
            "--auth", "user:pass",
            "--host", "0.0.0.0",
            "--install-dir", str(self.tmp / "install"),
            extra_env=env,
        )
        self.assertEqual(deployed.returncode, 0, deployed.stderr + deployed.stdout)
        self.assertTrue((self.tmp / "install" / "agent_shell.py").exists())
        unit = (sudo_dir / "opencode-agent.service").read_text()
        env_file = (sudo_dir / "opencode-agent.env").read_text()
        self.assertIn('--host "0.0.0.0" --port "4690"', unit)
        self.assertIn(f'User={env["SUDO_USER"]}', unit)
        self.assertIn(f'WorkingDirectory={self.home}', unit)
        self.assertNotIn('user:pass', unit)
        self.assertIn('AGENT_SHELL_AUTH=user:pass', env_file)

        legacy_env = dict(env)
        legacy_env["AGENT_SHELL_INSTALL_DIR"] = str(self.tmp / "legacy-install")
        legacy = self.run_script(
            "deploy.sh",
            "4691",
            "user:pass",
            "127.0.0.1",
            extra_env=legacy_env,
        )
        self.assertEqual(legacy.returncode, 0, legacy.stderr + legacy.stdout)
        legacy_unit = (sudo_dir / "opencode-agent.service").read_text()
        self.assertIn('--host "127.0.0.1" --port "4691"', legacy_unit)


if __name__ == "__main__":
    unittest.main()
