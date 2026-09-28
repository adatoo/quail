"""The smoke test: what each engine really does with each model, before anything is timed (ADR D-063).

It records, in capabilities.json, the things the fairness rules depend on and the report's caveats come from:
whether a request's length can be held (`ignore_eos`), whether usage arrives on a stream, whether thinking is
really off, whether tool calls come back parsed (OpenAI and Anthropic routes), how many tokens the same prompt
counts as, and whether a repeated prompt hits a prefix cache.
"""

from __future__ import annotations

import json
import time
import traceback
from pathlib import Path

from . import config, httpc
from .config import Model
from .engines import Engine, EngineUnavailable, Server

WEATHER_TOOL = {
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string", "description": "The city, e.g. Paris"}},
            "required": ["city"],
        },
    },
}

# About 1,200 tokens of plain prose, to count and to repeat for the prefix-cache probe.
PASSAGE = (
    "The quail is a small ground-dwelling bird. It walks more often than it flies, and when it does fly it bursts "
    "up from cover with a whirr of short wings before gliding back down a little way off. "
) * 30


def request(server: Server, messages: list, **fields) -> dict:
    sampling = config.fairness()["sampling"]
    body = {
        "model": server.served,
        "messages": messages,
        "temperature": sampling["temperature"],
        "top_p": sampling["top_p"],
        "seed": sampling["seed"],
    }
    body.update(server.engine.request_fields(server.model))
    body.update(fields)
    return body


def probe(name: str, results: dict, fn) -> None:
    started = time.perf_counter()
    try:
        results[name] = fn()
    except httpc.HTTPError as error:
        results[name] = {"ok": False, "error": f"HTTP {error.status}: {error.body[:300]}"}
    except Exception as error:  # a probe failing is a finding, not a crash
        results[name] = {"ok": False, "error": f"{type(error).__name__}: {error}"}
    results[name]["seconds"] = round(time.perf_counter() - started, 2)


def run_probes(server: Server) -> dict:
    results: dict = {}

    def chat():
        reply = httpc.post(server.chat_url, request(server, [
            {"role": "user", "content": "Reply with the single word: ready"}], max_tokens=32), key=server.key)
        message = reply["choices"][0]["message"]
        content = message.get("content") or ""
        reasoning = message.get("reasoning_content") or message.get("reasoning") or ""
        thinking_off = not reasoning and "<think>" not in content
        return {"ok": bool(content.strip()), "content": content[:200], "usage": reply.get("usage"),
                "thinking_off": thinking_off, "reasoning_chars": len(reasoning)}

    def stream_usage():
        stream = httpc.stream_chat(server.chat_url, request(server, [
            {"role": "user", "content": "Count from one to ten in words."}], max_tokens=48), key=server.key)
        return {"ok": stream.usage is not None, "usage": stream.usage, "chunks": stream.chunks,
                "ttft_ms": round((stream.first_token - stream.started) * 1000, 1) if stream.first_token else None}

    def ignore_eos():
        want = 64
        reply = httpc.post(server.chat_url, request(server, [
            {"role": "user", "content": "Reply with OK."}], max_tokens=want, ignore_eos=True), key=server.key)
        got = (reply.get("usage") or {}).get("completion_tokens")
        return {"ok": got == want, "asked": want, "completion_tokens": got}

    def tools_chat():
        reply = httpc.post(server.chat_url, request(server, [
            {"role": "user", "content": "What's the weather in Paris right now? Use the tool."}],
            tools=[WEATHER_TOOL], max_tokens=256), key=server.key)
        calls = reply["choices"][0]["message"].get("tool_calls") or []
        names = [c.get("function", {}).get("name") for c in calls]
        arguments = [c.get("function", {}).get("arguments") for c in calls]
        return {"ok": "get_weather" in names and any("paris" in (a or "").lower() for a in arguments),
                "calls": calls[:3], "content": (reply["choices"][0]["message"].get("content") or "")[:200]}

    def tools_messages():
        body = {
            "model": server.served, "max_tokens": 256,
            "messages": [{"role": "user", "content": "What's the weather in Paris right now? Use the tool."}],
            "tools": [{"name": "get_weather", "description": WEATHER_TOOL["function"]["description"],
                       "input_schema": WEATHER_TOOL["function"]["parameters"]}],
        }
        reply = httpc.post(server.messages_url, body, key=server.key)
        uses = [b for b in reply.get("content", []) if b.get("type") == "tool_use"]
        return {"ok": any(b.get("name") == "get_weather" for b in uses), "tool_use": uses[:3],
                "stop_reason": reply.get("stop_reason")}

    def prompt_tokens():
        reply = httpc.post(server.chat_url, request(server, [{"role": "user", "content": PASSAGE}], max_tokens=1),
                           key=server.key)
        return {"ok": True, "prompt_tokens": (reply.get("usage") or {}).get("prompt_tokens")}

    def prefix_cache():
        body = request(server, [{"role": "user", "content": "Summarise in one line: " + PASSAGE}], max_tokens=1)
        first = httpc.stream_chat(server.chat_url, body, key=server.key)
        second = httpc.stream_chat(server.chat_url, body, key=server.key)
        details = (second.usage or {}).get("prompt_tokens_details") or {}
        cached = details.get("cached_tokens")

        def ttft(s):
            return round(((s.first_token or s.ended) - s.started) * 1000, 1)

        return {"ok": True, "cached_tokens": cached, "first_ttft_ms": ttft(first), "second_ttft_ms": ttft(second),
                "hit": (cached or 0) > 0 or ttft(second) < ttft(first) * 0.5}

    for name, fn in [("chat", chat), ("stream_usage", stream_usage), ("ignore_eos", ignore_eos),
                     ("tools_chat", tools_chat), ("tools_messages", tools_messages),
                     ("prompt_tokens", prompt_tokens), ("prefix_cache", prefix_cache)]:
        probe(name, results, fn)
    return results


def smoke(engines: list[Engine], models: list[Model], run_dir: Path, log=print) -> dict:
    capabilities: dict = {}
    path = run_dir / "capabilities.json"
    for model in models:
        for engine in engines:
            entry = capabilities.setdefault(engine.name, {})
            if not model.path(engine.lane).exists():
                entry[model.id] = {"skipped": f"missing {model.path(engine.lane)}"}
                log(f"  skip {engine.title} × {model.name}: {model.path(engine.lane)} isn't there")
                continue
            try:
                engine.locate()
            except EngineUnavailable as error:
                entry[model.id] = {"skipped": str(error)}
                log(f"  skip {engine.title}: {error}")
                continue
            server = None
            try:
                server = engine.start(model, run_dir, log=log)
                load = json.loads((server.workdir / "load.json").read_text())
                results = run_probes(server)
                results["load_seconds"] = round(load["load_seconds"], 1)
                results["version"] = engine.version()
                entry[model.id] = results
                failed = [k for k, v in results.items() if isinstance(v, dict) and not v.get("ok", True)]
                thinking = results.get("chat", {}).get("thinking_off")
                log(f"  {engine.title} × {model.name}: "
                    + ("all probes passed" if not failed else "failed: " + ", ".join(failed))
                    + ("" if thinking in (True, None) else "; thinking NOT off"))
            except Exception as error:
                entry[model.id] = {"error": f"{type(error).__name__}: {error}",
                                   "trace": traceback.format_exc()[-2000:]}
                log(f"  {engine.title} × {model.name}: couldn't start ({error})")
            finally:
                if server:
                    engine.stop(server)
            path.write_text(json.dumps(capabilities, indent=2))
    return capabilities
