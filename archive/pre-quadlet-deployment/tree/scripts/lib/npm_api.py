#!/usr/bin/env python3
"""Minimal, non-verbose NPM loopback API client. Secret values are file/stdin only."""
from __future__ import annotations
import argparse
import json
import os
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request

AUTH_REJECTED = 10
NOT_READY = 11
REQUEST_FAILED = 12

class SafeError(Exception):
    def __init__(self, code: int): self.code = code

def private_value(path: str) -> str:
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o600:
        raise SafeError(REQUEST_FAILED)
    if st.st_uid != os.getuid():
        raise SafeError(REQUEST_FAILED)
    with open(path, "r", encoding="utf-8") as handle:
        value = handle.read().rstrip("\r\n")
    if not value or "\n" in value or "\r" in value:
        raise SafeError(REQUEST_FAILED)
    return value

def base_url(value: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost") or parsed.port != 18081:
        raise SafeError(REQUEST_FAILED)
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment or parsed.username or parsed.password:
        raise SafeError(REQUEST_FAILED)
    return "http://127.0.0.1:18081"

def request(base: str, method: str, path: str, payload=None, token: str | None = None, auth=False):
    data = None if payload is None else json.dumps(payload, separators=(",", ":")).encode()
    headers = {"Accept": "application/json"}
    if data is not None: headers["Content-Type"] = "application/json"
    if token: headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            raw = response.read(1024 * 1024)
            if not raw: return {}
            value = json.loads(raw)
            if not isinstance(value, dict): raise SafeError(REQUEST_FAILED)
            return value
    except urllib.error.HTTPError as exc:
        # Do not read or print response bodies: they can reflect credentials.
        if auth and exc.code in (400, 401, 403): raise SafeError(AUTH_REJECTED)
        if exc.code in (502, 503, 504): raise SafeError(NOT_READY)
        raise SafeError(REQUEST_FAILED)
    except (urllib.error.URLError, TimeoutError):
        raise SafeError(NOT_READY)
    except (ValueError, OSError):
        raise SafeError(REQUEST_FAILED)

def authenticate(base: str, identity: str, secret: str):
    result = request(base, "POST", "/api/tokens", {"identity": identity, "secret": secret}, auth=True)
    token = result.get("token")
    if not isinstance(token, str) or not token: raise SafeError(REQUEST_FAILED)
    return token

def main() -> int:
    parser = argparse.ArgumentParser(add_help=True)
    sub = parser.add_subparsers(dest="operation", required=True)
    ready = sub.add_parser("ready"); ready.add_argument("--url", required=True)
    auth = sub.add_parser("auth"); auth.add_argument("--url", required=True); auth.add_argument("--identity-file", required=True); auth.add_argument("--password-file", required=True)
    change = sub.add_parser("change-password"); change.add_argument("--url", required=True); change.add_argument("--identity-file", required=True); change.add_argument("--current-file", required=True); change.add_argument("--new-file", required=True); change.add_argument("--new-identity-file", required=True)
    args = parser.parse_args()
    try:
        base = base_url(args.url)
        if args.operation == "ready":
            result = request(base, "GET", "/api/")
            if result.get("status") != "OK": raise SafeError(NOT_READY)
        elif args.operation == "auth":
            authenticate(base, private_value(args.identity_file), private_value(args.password_file))
        else:
            identity = private_value(args.identity_file)
            current = private_value(args.current_file)
            replacement = private_value(args.new_file)
            new_identity = private_value(args.new_identity_file)
            token = authenticate(base, identity, current)
            me = request(base, "GET", "/api/users/me", token=token)
            user_id = me.get("id")
            if not isinstance(user_id, int) or user_id < 1: raise SafeError(REQUEST_FAILED)
            # Change the password first. If interrupted before the identity update,
            # the lifecycle state machine can authenticate the transitional pair
            # and safely finish. Avoid a password call when only finishing identity.
            if replacement != current:
                request(base, "PUT", f"/api/users/{user_id}/auth", {"type": "password", "current": current, "secret": replacement}, token=token, auth=True)
            if new_identity != identity:
                request(base, "PUT", f"/api/users/{user_id}", {"email": new_identity}, token=token)
        print("OK")
        return 0
    except SafeError as exc:
        print(f"ERROR_{exc.code}", file=sys.stderr)
        return exc.code
    except Exception:
        print(f"ERROR_{REQUEST_FAILED}", file=sys.stderr)
        return REQUEST_FAILED

if __name__ == "__main__":
    raise SystemExit(main())
