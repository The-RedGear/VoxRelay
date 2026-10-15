"""Small urllib helpers shared by cloud TTS engines."""
from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


class HttpError(RuntimeError):
    def __init__(self, message: str, status: int = 0, body: str = ""):
        super().__init__(message)
        self.status = status
        self.body = body


def _timeout(value: float) -> float:
    return max(1.0, min(600.0, float(value)))


def request(
    method: str,
    url: str,
    *,
    headers: dict[str, str] | None = None,
    data: bytes | None = None,
    timeout: float = 30,
) -> tuple[int, bytes, dict[str, str]]:
    req = urllib.request.Request(url, data=data, method=method.upper(), headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=_timeout(timeout)) as response:
            payload = response.read()
            meta = {key.lower(): value for key, value in response.headers.items()}
            return int(response.status), payload, meta
    except urllib.error.HTTPError as exc:
        body = exc.read() if hasattr(exc, "read") else b""
        text = body.decode("utf-8", "replace")
        raise HttpError(f"HTTP {exc.code} for {url}: {text[:400]}", status=int(exc.code), body=text) from exc
    except urllib.error.URLError as exc:
        raise HttpError(f"Could not reach {url}: {exc.reason}") from exc


def get_bytes(url: str, *, headers: dict[str, str] | None = None, timeout: float = 30) -> bytes:
    _, payload, _ = request("GET", url, headers=headers, timeout=timeout)
    return payload


def get_json(url: str, *, headers: dict[str, str] | None = None, timeout: float = 30) -> Any:
    _, payload, _ = request("GET", url, headers=headers, timeout=timeout)
    return json.loads(payload.decode("utf-8"))


def post_json(
    url: str,
    body: dict | list,
    *,
    headers: dict[str, str] | None = None,
    timeout: float = 30,
    expect_json: bool = True,
) -> Any:
    payload = json.dumps(body).encode("utf-8")
    merged = {**(headers or {}), "Content-Type": "application/json"}
    status, data, _ = request("POST", url, headers=merged, data=payload, timeout=timeout)
    if not expect_json:
        return data
    if not data:
        return {}
    return json.loads(data.decode("utf-8"))


def post_form(
    url: str,
    fields: dict[str, str],
    *,
    headers: dict[str, str] | None = None,
    timeout: float = 30,
) -> Any:
    payload = urllib.parse.urlencode(fields).encode("utf-8")
    merged = {**(headers or {}), "Content-Type": "application/x-www-form-urlencoded"}
    _, data, _ = request("POST", url, headers=merged, data=payload, timeout=timeout)
    text = data.decode("utf-8", "replace")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def post_bytes(
    url: str,
    data: bytes,
    *,
    content_type: str,
    headers: dict[str, str] | None = None,
    timeout: float = 30,
) -> bytes:
    merged = {**(headers or {}), "Content-Type": content_type}
    _, payload, _ = request("POST", url, headers=merged, data=data, timeout=timeout)
    return payload


def basic_auth_header(username: str, password: str) -> str:
    import base64

    token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    return f"Basic {token}"
