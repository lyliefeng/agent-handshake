#!/usr/bin/env python3
"""Small stdlib HTTP client for the agent-handshake protocol.

The shell scripts deliberately keep presentation and persistence concerns out
of this module.  This module owns URL handling, JSON encoding, protocol
negotiation, authentication, and actionable transport errors.
"""

from __future__ import print_function

import argparse
import base64
from http.client import HTTPException, IncompleteRead
import json
import sys
import time
from datetime import datetime
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


MAX_RESPONSE_BYTES = 16 * 1024 * 1024
MAX_ERROR_RESPONSE_BYTES = 64 * 1024


class ClientError(Exception):
    def __init__(self, message, status=None):
        Exception.__init__(self, message)
        self.status = status


def _origin(value):
    """Return a normalized URL origin for redirect credential checks."""
    parts = urlsplit(value)
    if parts.username is not None or parts.password is not None or not parts.hostname:
        raise ValueError("URL contains credentials or no host")
    scheme = parts.scheme.lower()
    hostname = parts.hostname.lower()
    port = parts.port
    if port is None:
        port = 443 if scheme == "https" else 80
    return scheme, hostname, port


class _SafeRedirectHandler(HTTPRedirectHandler):
    """Follow redirects only when they stay on the requested origin."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        try:
            same_origin = _origin(req.full_url) == _origin(newurl)
        except ValueError:
            same_origin = False
        if not same_origin:
            raise ClientError("refusing redirect to a different origin")
        return HTTPRedirectHandler.redirect_request(
            self, req, fp, code, msg, headers, newurl
        )


HTTP_OPENER = build_opener(_SafeRedirectHandler())


class _ResponseTooLarge(Exception):
    pass


def _read_limited(response, limit):
    """Read an HTTP response without allowing unbounded memory growth."""
    headers = getattr(response, "headers", None) or {}
    content_length = headers.get("Content-Length")
    expected_length = None
    if content_length:
        try:
            expected_length = int(content_length)
            if expected_length > limit or expected_length < 0:
                raise _ResponseTooLarge()
        except ValueError:
            expected_length = None
    chunks = []
    total = 0
    while True:
        chunk = response.read(min(65536, limit - total + 1))
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise _ResponseTooLarge()
        chunks.append(chunk)
    if expected_length is not None and total != expected_length:
        raise IncompleteRead(b"".join(chunks), expected_length - total)
    return b"".join(chunks)


def _clean_address(address):
    if not address or not address.strip():
        raise ClientError("address is empty")
    value = address.strip().rstrip("/")
    try:
        parts = urlsplit(value)
        if parts.scheme not in ("http", "https"):
            raise ClientError("address must use http:// or https://")
        if not parts.netloc:
            raise ClientError("address has no host")
        if parts.username is not None or parts.password is not None:
            raise ClientError("put credentials in --auth, not in the URL")
        if parts.query or parts.fragment:
            raise ClientError("address must not contain a query or fragment")
        return urlunsplit((parts.scheme, parts.netloc, parts.path.rstrip("/"), "", ""))
    except ClientError:
        raise
    except ValueError as exc:
        raise ClientError("invalid address: {}".format(exc))


def _endpoint(address, path):
    base = _clean_address(address)
    return base + "/" + path.lstrip("/")


def _auth_header(auth):
    if not auth:
        return None
    encoded = base64.b64encode(auth.encode("utf-8")).decode("ascii")
    return "Basic " + encoded


def _short_body(raw):
    if not raw:
        return ""
    text = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else raw
    text = " ".join(text.split())
    return text[:240]


def _request(method, address, path, auth, payload, timeout):
    url = _endpoint(address, path)
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    authorization = _auth_header(auth)
    if authorization:
        headers["Authorization"] = authorization
    request = Request(url, data=data, headers=headers, method=method)
    try:
        response = HTTP_OPENER.open(request, timeout=timeout)
        try:
            raw = _read_limited(response, MAX_RESPONSE_BYTES)
            status = getattr(response, "status", response.getcode())
        finally:
            response.close()
    except HTTPError as exc:
        try:
            detail = _short_body(_read_limited(exc, MAX_ERROR_RESPONSE_BYTES))
        except _ResponseTooLarge:
            detail = "error response body exceeds {} bytes".format(MAX_ERROR_RESPONSE_BYTES)
        except (HTTPException, OSError, ValueError):
            detail = ""
        finally:
            exc.close()
        suffix = (": " + detail) if detail else ""
        raise ClientError("HTTP {} from {}{}".format(exc.code, path, suffix), exc.code)
    except _ResponseTooLarge:
        raise ClientError(
            "response from {} exceeds {} bytes".format(path, MAX_RESPONSE_BYTES)
        )
    except (HTTPException, URLError, OSError, ValueError) as exc:
        reason = getattr(exc, "reason", exc)
        raise ClientError("request {} {} failed: {}".format(method, path, reason))
    if status < 200 or status >= 300:
        raise ClientError("HTTP {} from {}".format(status, path), status)
    if not raw:
        return None
    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise ClientError("invalid JSON from {}: {}".format(path, exc))


def _protocol_name(hint):
    if not hint:
        return ""
    value = hint.strip()
    try:
        parsed = json.loads(value)
    except (TypeError, ValueError):
        parsed = None
    if isinstance(parsed, dict):
        health = str(parsed.get("health", ""))
        if "global/health" in health:
            return "opencode"
        if parsed.get("chat") or parsed.get("run") or "/health" in health:
            return "generic"
        return ""
    value = " ".join(value.split()).lower()
    if len(value) > 64:
        return ""
    if value in ("opencode", "open-code"):
        return "opencode"
    if value in ("agent-shell", "agent_shell", "opencode-shell", "shell"):
        return "agent-shell"
    if value in ("langchain", "crewai", "generic-fastapi", "generic", "mcp"):
        return value
    return value


def _safe_version(value):
    """Keep server-advertised version text safe for shell/config output."""
    if value is None:
        return "?"
    return " ".join(str(value).split())[:120] or "?"


def _health_ok(kind, data):
    if not isinstance(data, dict):
        return False
    if data.get("error"):
        return False
    if kind == "opencode":
        return data.get("healthy") is True
    status = data.get("status")
    if status is None:
        return True
    return str(status).lower() in ("ok", "healthy", "running", "ready", "true", "1")


def probe(address, auth="", protocol="", timeout=5.0):
    """Return negotiated protocol and health data, or raise ClientError."""
    address = _clean_address(address)
    hint = _protocol_name(protocol)
    if hint == "opencode":
        candidates = [("opencode", "/global/health"), ("generic", "/health")]
    elif hint == "mcp":
        candidates = [("mcp", "/mcp"), ("generic", "/health"), ("opencode", "/global/health")]
    elif hint:
        candidates = [(hint, "/health"), ("opencode", "/global/health")]
    else:
        candidates = [
            ("opencode", "/global/health"),
            ("generic", "/health"),
            ("mcp", "/mcp"),
        ]

    errors = []
    for kind, path in candidates:
        try:
            data = _request("GET", address, path, auth, None, timeout)
        except ClientError as exc:
            errors.append(str(exc))
            continue
        if not _health_ok(kind, data):
            errors.append("{} returned an unhealthy status".format(path))
            continue
        negotiated = kind
        if kind == "generic" and isinstance(data, dict):
            advertised = _protocol_name(str(data.get("protocol", data.get("agent", ""))))
            if advertised:
                negotiated = advertised
        if kind == "generic" and hint == "agent-shell":
            negotiated = "agent-shell"
        version = "?"
        if isinstance(data, dict):
            version = _safe_version(data.get("version", data.get("serve_version", "?")))
        return {
            "address": address,
            "protocol": negotiated,
            "health_path": path,
            "version": version,
            "health": data,
        }
    detail = "; ".join(errors) if errors else "no usable health endpoint"
    raise ClientError("health probe failed for {} ({})".format(address, detail))


def _extract_text(data):
    if not isinstance(data, dict):
        if isinstance(data, (str, int, float)):
            return str(data)
        raise ClientError("agent response is not a JSON object")
    if data.get("error"):
        error = data.get("error")
        if isinstance(error, dict):
            error = error.get("message", error)
        raise ClientError("agent returned an error: {}".format(error))
    if data.get("success") is False:
        raise ClientError("agent task failed: {}".format(data.get("output", "unknown error")))
    parts = data.get("parts")
    if isinstance(parts, list):
        for part in parts:
            if isinstance(part, dict) and part.get("type") == "text":
                return str(part.get("text", ""))
    for key in ("output", "reply", "response", "message", "text"):
        value = data.get(key)
        if isinstance(value, str):
            return value
    result = data.get("result")
    if isinstance(result, str):
        return result
    if isinstance(result, dict):
        return _extract_text(result)
    raise ClientError("agent response contains no reply text")


def _run_opencode(address, auth, message, provider, model, timeout):
    session = _request(
        "POST",
        address,
        "/session",
        auth,
        {"title": "agent-handshake-{}".format(datetime.now().strftime("%H%M%S"))},
        timeout,
    )
    if not isinstance(session, dict) or not session.get("id"):
        raise ClientError("OpenCode /session response has no id")
    session_id = str(session["id"])
    message_payload = {
        "parts": [{"type": "text", "text": message}],
        "noReply": False,
    }
    if provider and model:
        message_payload["model"] = {"providerID": provider, "modelID": model}
    elif provider or model:
        raise ClientError("--provider and --model must be supplied together")

    response = _request(
        "POST",
        address,
        "/session/{}/message".format(session_id),
        auth,
        message_payload,
        timeout,
    )
    reply = _extract_text(response)
    info = response.get("info", {}) if isinstance(response, dict) else {}
    return {
        "reply": reply,
        "session_id": session_id,
        "model": "{}/{}".format(
            info.get("providerID") or provider or "?",
            info.get("modelID") or model or "?",
        ),
        "cost": info.get("cost", "?"),
    }


def _run_generic(address, auth, message, protocol, timeout):
    hint = _protocol_name(protocol)
    paths = [("/chat", {"message": message}), ("/run", {"task": message})]
    if hint in ("generic", "agent-shell"):
        paths = [("/run", {"task": message}), ("/chat", {"message": message})]
    last_error = None
    for path, payload in paths:
        try:
            response = _request("POST", address, path, auth, payload, timeout)
            return {"reply": _extract_text(response), "session_id": "", "model": "?/?", "cost": "?", "endpoint": path}
        except ClientError as exc:
            last_error = exc
            if exc.status not in (404, 405):
                raise
    if last_error is not None:
        raise ClientError("generic agent has no usable task endpoint: {}".format(last_error))
    raise ClientError("generic agent has no usable task endpoint")


def run_task(address, auth, message, protocol="", provider="", model="", timeout=120.0):
    negotiated = probe(address, auth, protocol, min(timeout, 10.0))
    name = negotiated["protocol"]
    if name == "mcp":
        raise ClientError(
            "MCP endpoint detected; this connector supports health discovery only, "
            "not arbitrary natural-language task execution"
        )
    if name == "opencode":
        result = _run_opencode(address, auth, message, provider, model, timeout)
    else:
        result = _run_generic(address, auth, message, name, timeout)
    result.update(
        {
            "address": negotiated["address"],
            "protocol": name,
            "health_path": negotiated["health_path"],
            "version": negotiated["version"],
        }
    )
    return result


def _parser():
    parser = argparse.ArgumentParser(description="agent-handshake HTTP client")
    sub = parser.add_subparsers(dest="command")

    probe_parser = sub.add_parser("probe", help="probe a health endpoint")
    probe_parser.add_argument("--address", required=True)
    probe_parser.add_argument("--auth", default="")
    probe_parser.add_argument("--protocol", default="")
    probe_parser.add_argument("--timeout", type=float, default=5.0)

    run_parser = sub.add_parser("run", help="probe and execute a task")
    run_parser.add_argument("--address", required=True)
    run_parser.add_argument("--message", required=True)
    run_parser.add_argument("--auth", default="")
    run_parser.add_argument("--protocol", default="")
    run_parser.add_argument("--provider", default="")
    run_parser.add_argument("--model", default="")
    run_parser.add_argument("--timeout", type=float, default=120.0)
    return parser


def main(argv=None):
    parser = _parser()
    args = parser.parse_args(argv)
    if args.command == "probe":
        result = probe(args.address, args.auth, args.protocol, args.timeout)
    elif args.command == "run":
        result = run_task(args.address, args.auth, args.message, args.protocol, args.provider, args.model, args.timeout)
    else:
        parser.error("a command is required")
        return 2
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ClientError as exc:
        print("error: {}".format(exc), file=sys.stderr)
        sys.exit(2)
    except KeyboardInterrupt:
        print("error: interrupted", file=sys.stderr)
        sys.exit(130)
