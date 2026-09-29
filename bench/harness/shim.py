"""A request shim between a standard tool (lm-eval, BFCL) and the engine under test (ADR D-063).

The tools send OpenAI chat-completions requests the way they always do; the shim makes each one follow the
fairness rules before it reaches the engine: the served model id, neutral sampling (temperature 0, seed 42,
penalties 0), thinking off in the engine's own words, and the engine's API key. The tool's prompt, stop strings,
length limit and tools pass through untouched. An engine that answers 429 or 503 with Retry-After (Rapid-MLX's
memory admission gate does, under load) is asked again after the wait it gives, as a real client would, up to five
times; the retries are counted. Every request is logged (a hash of its messages, not the text), so a report can say
how many requests each engine answered, refused or deferred, and how long they ran.
"""

from __future__ import annotations

import hashlib
import json
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .engines import Server

ROUTES = ("/v1/chat/completions", "/chat/completions")
MAX_RETRIES = 5


def rewrite(body: dict, served: str, sampling: dict, fields: dict) -> dict:
    """The request as the engine gets it."""
    body = dict(body)
    body["model"] = served
    body["temperature"] = sampling["temperature"]
    body["top_p"] = sampling["top_p"]
    body["seed"] = sampling["seed"]
    body["presence_penalty"] = sampling["presence_penalty"]
    body["frequency_penalty"] = sampling["frequency_penalty"]
    body.update(fields)
    return body


class Shim:
    def __init__(self, server: Server, fairness: dict, log_path: Path):
        self.server = server
        self.sampling = fairness["sampling"]
        self.fields = server.engine.request_fields(server.model)
        self.log_path = log_path
        self._lock = threading.Lock()
        self._http: ThreadingHTTPServer | None = None
        self.requests = 0
        self.errors = 0

    @property
    def base(self) -> str:
        assert self._http
        return f"http://127.0.0.1:{self._http.server_address[1]}"

    def start(self) -> Shim:
        shim = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):  # the shim keeps its own log
                pass

            def do_GET(self):
                if self.path.rstrip("/") in ("/v1/models", "/models"):
                    self._reply(200, {"object": "list", "data": [{"id": shim.server.served, "object": "model"}]})
                else:
                    self._reply(404, {"error": {"message": f"no route {self.path}"}})

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length)
                if self.path.split("?")[0] not in ROUTES:
                    self._reply(404, {"error": {"message": f"the shim only forwards {ROUTES[0]}"}})
                    return
                try:
                    body = json.loads(raw)
                except json.JSONDecodeError as error:
                    self._reply(400, {"error": {"message": f"invalid JSON: {error}"}})
                    return
                status, reply = shim.forward(body)
                self._reply(status, reply)

            def _reply(self, status: int, payload):
                data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self._http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._http.daemon_threads = True
        threading.Thread(target=self._http.serve_forever, daemon=True).start()
        return self

    def forward(self, body: dict) -> tuple[int, bytes]:
        request = rewrite(body, self.server.served, self.sampling, self.fields)
        request.pop("stream", None)  # the tools read whole replies; a stream would only be buffered here
        request.pop("stream_options", None)
        data = json.dumps(request).encode()
        upstream = urllib.request.Request(self.server.chat_url, data=data, method="POST",
                                          headers={"Content-Type": "application/json"})
        if self.server.key:
            upstream.add_header("Authorization", f"Bearer {self.server.key}")
        started = time.perf_counter()
        retries = 0
        while True:
            retry_after = None
            try:
                with urllib.request.urlopen(upstream, timeout=1800) as response:
                    status, payload = response.status, response.read()
            except urllib.error.HTTPError as error:
                status, payload = error.code, error.read()
                retry_after = error.headers.get("Retry-After") if error.headers else None
            except OSError as error:
                status, payload = 502, json.dumps({"error": {"message": f"the engine didn't answer: {error}"}}).encode()
            if status in (429, 503) and retry_after is not None and retries < MAX_RETRIES:
                retries += 1
                time.sleep(min(max(float(retry_after) if retry_after.replace(".", "", 1).isdigit() else 1.0, 0.1),
                               30.0))
                continue
            break
        self._log(request, status, payload, time.perf_counter() - started, retries)
        return status, payload

    def _log(self, request: dict, status: int, payload: bytes, seconds: float, retries: int = 0) -> None:
        entry = {
            "retries": retries,
            "messages_sha": hashlib.sha256(json.dumps(request.get("messages"), sort_keys=True).encode()).hexdigest()[:16],
            "max_tokens": request.get("max_tokens"),
            "tools": len(request.get("tools") or []),
            "status": status,
            "seconds": round(seconds, 3),
        }
        if status == 200:
            try:
                reply = json.loads(payload)
                choice = (reply.get("choices") or [{}])[0]
                entry["finish_reason"] = choice.get("finish_reason")
                entry["usage"] = reply.get("usage")
                entry["tool_calls"] = len((choice.get("message") or {}).get("tool_calls") or [])
            except (json.JSONDecodeError, AttributeError):
                entry["unparsed"] = True
        else:
            entry["error"] = payload[:300].decode(errors="replace")
        with self._lock:
            self.requests += 1
            self.errors += status != 200
            with self.log_path.open("a") as f:
                f.write(json.dumps(entry) + "\n")

    def stop(self) -> None:
        if self._http:
            self._http.shutdown()
            self._http.server_close()
