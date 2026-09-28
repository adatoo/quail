"""A small HTTP client over urllib: JSON requests and server-sent events. Standard library only."""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from collections.abc import Iterator
from dataclasses import dataclass, field


class HTTPError(Exception):
    def __init__(self, status: int, body: str):
        super().__init__(f"HTTP {status}: {body[:300]}")
        self.status = status
        self.body = body


def _request(method: str, url: str, body: dict | None, key: str | None, timeout: float) -> urllib.request.Request:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    if key:
        request.add_header("Authorization", f"Bearer {key}")
        request.add_header("x-api-key", key)
    return request


def call(method: str, url: str, body: dict | None = None, key: str | None = None, timeout: float = 60) -> dict:
    """A JSON request; the parsed reply, or HTTPError with the server's own message."""
    try:
        with urllib.request.urlopen(_request(method, url, body, key, timeout), timeout=timeout) as response:
            text = response.read().decode()
    except urllib.error.HTTPError as error:
        raise HTTPError(error.code, error.read().decode(errors="replace")) from None
    return json.loads(text) if text.strip() else {}


def get(url: str, key: str | None = None, timeout: float = 10) -> dict:
    return call("GET", url, key=key, timeout=timeout)


def post(url: str, body: dict, key: str | None = None, timeout: float = 600) -> dict:
    return call("POST", url, body, key=key, timeout=timeout)


def reachable(url: str, key: str | None = None, timeout: float = 2) -> bool:
    try:
        get(url, key=key, timeout=timeout)
        return True
    except HTTPError as error:
        # Up but refusing (a key, a route it lacks): still reachable.
        return error.status < 500
    except OSError:
        return False


@dataclass
class Stream:
    """One streamed chat completion, as a client sees it."""

    started: float
    first_byte: float | None = None
    first_token: float | None = None
    ended: float | None = None
    content: str = ""
    reasoning: str = ""
    tool_calls: list = field(default_factory=list)
    usage: dict | None = None
    chunks: int = 0
    finish_reason: str | None = None


def stream_chat(url: str, body: dict, key: str | None = None, timeout: float = 600) -> Stream:
    """POSTs a streaming chat completion and times it on the client, as GuideLLM does."""
    body = dict(body, stream=True)
    body.setdefault("stream_options", {"include_usage": True})
    result = Stream(started=time.perf_counter())
    try:
        with urllib.request.urlopen(_request("POST", url, body, key, timeout), timeout=timeout) as response:
            for data in _events(response):
                now = time.perf_counter()
                if result.first_byte is None:
                    result.first_byte = now
                if data == "[DONE]":
                    break
                chunk = json.loads(data)
                if chunk.get("usage"):
                    result.usage = chunk["usage"]
                for choice in chunk.get("choices") or []:
                    delta = choice.get("delta") or {}
                    text = delta.get("content") or ""
                    thought = delta.get("reasoning_content") or delta.get("reasoning") or ""
                    if (text or thought) and result.first_token is None:
                        result.first_token = now
                    result.content += text
                    result.reasoning += thought
                    result.tool_calls.extend(delta.get("tool_calls") or [])
                    if choice.get("finish_reason"):
                        result.finish_reason = choice["finish_reason"]
                result.chunks += 1
    except urllib.error.HTTPError as error:
        raise HTTPError(error.code, error.read().decode(errors="replace")) from None
    result.ended = time.perf_counter()
    return result


def _events(response) -> Iterator[str]:
    """The `data:` payloads of an SSE stream, one per event."""
    lines: list[str] = []
    for raw in response:
        line = raw.decode().rstrip("\r\n")
        if not line:
            if lines:
                yield "\n".join(lines)
                lines = []
            continue
        if line.startswith("data:"):
            lines.append(line[5:].lstrip())
    if lines:
        yield "\n".join(lines)
