"""The speed benchmark: GuideLLM's concurrent profile against each engine, the same prompts for every engine
(ADR D-063).

Per model, per round, per engine: start the server, warm it up, then run each level (512→256 tokens at
concurrency 1, 2, 4 and 8, and 4096→128 at 1). Before a level the Mac waits until it's cool; a level that ends
hotter than `rerun_above` is run once more and both are kept. Rounds alternate the engine order (A-B, B-A, …)
so that neither engine always runs on a warmer Mac.

Prompts are exact lengths in the model's own tokenizer, and none is used twice in a round: each level and each
warm-up has its own, so no engine gets a prefix-cache hit another doesn't. Every level sends exactly
`concurrency × requests_per_stream` requests, so each engine is measured on the same work; `max_seconds_per_level`
is only a cap. Nothing asks for `ignore_eos`, which only some engines honour: the prompts ask for a long
continuation instead, and any reply that stops short of `max_tokens` is counted in `short_requests`.
"""

from __future__ import annotations

import json
import os
import statistics
import subprocess
import time
from dataclasses import asdict, dataclass
from pathlib import Path

from . import config, httpc, machine, records
from .config import Model
from .engines import Engine, EngineUnavailable, Server
from .monitor import Monitor

GUIDELLM = config.TOOLS / "guidellm" / ".venv" / "bin" / "guidellm"
TOOL_PYTHON = config.TOOLS / "guidellm" / ".venv" / "bin" / "python"
MAKE_PROMPTS = Path(__file__).with_name("make_prompts.py")


@dataclass(frozen=True)
class Level:
    prompt_tokens: int
    output_tokens: int
    concurrency: int

    @property
    def name(self) -> str:
        return f"{self.prompt_tokens}x{self.output_tokens}-c{self.concurrency}"


def levels(fairness: dict) -> list[Level]:
    speed = fairness["speed"]
    result = [Level(speed["prompt_tokens"], speed["output_tokens"], c) for c in speed["levels"]]
    result.append(Level(speed["long_prompt_tokens"], speed["long_output_tokens"], 1))
    return result


def requests_for(level: Level, budget: dict) -> int:
    return level.concurrency * budget["requests_per_stream"]


# --- Prompts -------------------------------------------------------------------------------------------------------


def prompt_plan(model: Model, rounds: int, budget: dict, fairness: dict, directory: Path) -> tuple[dict, dict]:
    """The prompt sets for every round of one model: {(round, level name, "…-rerun" or "warmup"): path}, and the
    spec that make_prompts.py builds them from. Numbering runs on across sets, so every prompt opens differently;
    a level that has to be run again gets a set of its own, since the server has already seen the first."""
    sets, paths = [], {}
    first = 0
    speed = fairness["speed"]
    for round_index in range(rounds):
        wanted = [("warmup", speed["prompt_tokens"], fairness["warmup"]["requests"])]
        for level in levels(fairness):
            wanted.append((level.name, level.prompt_tokens, requests_for(level, budget)))
            wanted.append((level.name + "-rerun", level.prompt_tokens, requests_for(level, budget)))
        for name, tokens, count in wanted:
            path = directory / f"round-{round_index + 1}" / f"{name}.jsonl"
            sets.append({"path": str(path), "count": count, "tokens": tokens, "first": first})
            paths[(round_index, name)] = path
            first += count
    spec = {"tokenizer": str(model.mlx), "seed": fairness["sampling"]["seed"], "sets": sets}
    return paths, spec


def make_prompts(spec: dict, directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    spec_path = directory / "spec.json"
    spec_path.write_text(json.dumps(spec, indent=1))
    done = subprocess.run([str(TOOL_PYTHON), str(MAKE_PROMPTS), str(spec_path)], env=tool_env(),
                          capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(f"couldn't make the prompts: {done.stderr.strip()[-500:]}")


def read_prompts(path: Path) -> list[str]:
    return [json.loads(line)["prompt"] for line in path.read_text().splitlines() if line.strip()]


def tool_env(extra: dict | None = None) -> dict:
    env = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(config.WORK / "tool-home"),
        "HF_HOME": str(config.WORK / "tool-home" / "hf"),
        "HF_HUB_OFFLINE": "1",
        "HF_DATASETS_OFFLINE": "1",
        "TOKENIZERS_PARALLELISM": "false",
        "LANG": "en_US.UTF-8",
    }
    env.update(extra or {})
    return env


# --- One level -----------------------------------------------------------------------------------------------------


def request_body(server: Server, fairness: dict, max_tokens: int) -> dict:
    """What every request carries besides the prompt: neutral sampling, the length, and thinking off."""
    sampling = fairness["sampling"]
    body = {
        "temperature": sampling["temperature"],
        "top_p": sampling["top_p"],
        "seed": sampling["seed"],
        "presence_penalty": sampling["presence_penalty"],
        "frequency_penalty": sampling["frequency_penalty"],
        "max_tokens": max_tokens,
    }
    body.update(server.engine.request_fields(server.model))
    return body


def warm_up(server: Server, prompts: list[str], fairness: dict) -> None:
    for prompt in prompts:
        body = dict(request_body(server, fairness, 32), model=server.served,
                    messages=[{"role": "user", "content": prompt}])
        httpc.post(server.chat_url, body, key=server.key, timeout=900)


def scenario(server: Server, level: Level, prompts: Path, count: int, budget: dict, fairness: dict,
             output: Path) -> dict:
    return {"spec": {
        "backend": {
            "kind": "openai_http", "target": server.base, "model": server.served,
            "request_format": "/v1/chat/completions", "stream": True, "http2": False, "timeout": 1800,
            "validate_backend": False,
            "extras": {"body": request_body(server, fairness, level.output_tokens)},
        },
        "profile": {"kind": "concurrent", "streams": [level.concurrency]},
        "constraints": [
            {"kind": "max_requests", "count": count},
            {"kind": "max_duration", "seconds": budget["max_seconds_per_level"]},
            {"kind": "max_errors", "count": max(3, count // 4)},
        ],
        "tokenizer": {"kind": "huggingface_auto", "model": str(server.model.mlx)},
        "data": [{"kind": "json_file", "path": str(prompts), "load_kwargs": {"split": "train"}}],
        "seed": {"kind": "static", "value": fairness["sampling"]["seed"]},
        "outputs": [{"kind": "json", "path": str(output)}],
        "metrics": {"kind": "generative"},
    }}


def run_level(server: Server, level: Level, prompts: Path, budget: dict, fairness: dict, out: Path,
              log=print) -> dict:
    out.mkdir(parents=True, exist_ok=True)
    count = requests_for(level, budget)
    report = out / "guidellm.json"
    (out / "scenario.json").write_text(json.dumps(scenario(server, level, prompts, count, budget, fairness, report),
                                                  indent=1))
    before = machine.wait_until_cool(fairness["thermal"], log=log)
    monitor = Monitor(server.process.pid, out / "monitor.json").start()
    started = time.time()
    with open(out / "guidellm.log", "w") as console:
        done = subprocess.run(
            [str(GUIDELLM), "run", "-c", str(out / "scenario.json"), "--disable-progress"],
            env=tool_env({"GUIDELLM__SPEC__BACKEND__API_KEY": server.key or "none"}),
            stdout=console, stderr=subprocess.STDOUT, timeout=budget["max_seconds_per_level"] + 900,
        )
    wall = time.time() - started
    resources = monitor.stop()
    after = machine.pressure()
    result = {"level": level.name, **asdict(level), "requests": count, "wall_seconds": round(wall, 1),
              "thermal_before": before, "thermal_after": after, **resources}
    if done.returncode != 0 or not report.exists():
        result["error"] = f"guidellm exited {done.returncode}; see {out / 'guidellm.log'}"
        return result
    result.update(summarise(json.loads(report.read_text()), level))
    return result


def _stat(metrics: dict, name: str) -> dict:
    values = (metrics.get(name) or {}).get("successful") or {}
    percentiles = values.get("percentiles") or {}
    return {"mean": values.get("mean"), "p50": percentiles.get("p50"), "p95": percentiles.get("p95")}


def summarise(report: dict, level: Level) -> dict:
    """The numbers the report uses, from GuideLLM's own statistics (its formulas for TTFT, ITL and TPOT) and from
    its per-request records (throughput over the measured window, and replies that stopped short)."""
    benchmark = report["benchmarks"][0]
    metrics = benchmark["metrics"]
    totals = metrics["request_totals"]
    ok = benchmark["requests"].get("successful") or []
    outputs = [r.get("output_tokens") or 0 for r in ok]
    starts = [r["request_start_time"] for r in ok if r.get("request_start_time")]
    ends = [r["request_end_time"] for r in ok if r.get("request_end_time")]
    window = (max(ends) - min(starts)) if starts and ends else None
    return {
        "successful": totals.get("successful", 0),
        "errored": totals.get("errored", 0),
        "incomplete": totals.get("incomplete", 0),
        "ttft_ms": _stat(metrics, "time_to_first_token_ms"),
        "itl_ms": _stat(metrics, "inter_token_latency_ms"),
        "tpot_ms": _stat(metrics, "time_per_output_token_ms"),
        "request_latency_s": _stat(metrics, "request_latency"),
        "measured_prompt_tokens": _stat(metrics, "prompt_token_count")["mean"],
        "output_tokens_mean": statistics.fmean(outputs) if outputs else None,
        "short_requests": sum(1 for n in outputs if n < level.output_tokens),
        "output_tokens_per_second": round(sum(outputs) / window, 2) if window else None,
        "guidellm_output_tokens_per_second": _stat(metrics, "output_tokens_per_second")["mean"],
    }


# --- The whole benchmark -------------------------------------------------------------------------------------------


def speed(engines: list[Engine], models: list[Model], budget_name: str, run_dir: Path, log=print) -> Path:
    fairness = config.fairness()
    budget = config.budget(budget_name)
    rounds = budget["speed_rounds"]
    results = run_dir / "speed.jsonl"
    finished = records.done(results, ("model", "engine", "round"), need="level", count=len(levels(fairness)))
    for model in models:
        available = []
        for engine in engines:
            if not model.path(engine.lane).exists():
                log(f"  skip {engine.title} × {model.name}: {model.path(engine.lane)} isn't there")
                continue
            try:
                engine.locate()
            except EngineUnavailable as error:
                log(f"  skip {engine.title}: {error}")
                continue
            available.append(engine)
        if not available:
            continue
        log(f"\n{model.name}: making prompts")
        paths, spec = prompt_plan(model, rounds, budget, fairness, run_dir / "prompts" / model.id)
        make_prompts(spec, run_dir / "prompts" / model.id)
        for round_index in range(rounds):
            order = available if round_index % 2 == 0 else list(reversed(available))
            for engine in order:
                if (model.id, engine.name, round_index + 1) in finished:
                    log(f"    {engine.title}: round {round_index + 1} already done")
                    continue
                record = {"model": model.id, "engine": engine.name, "lane": engine.lane, "round": round_index + 1,
                          "version": engine.version()}
                round_dir = run_dir / f"round-{round_index + 1}"
                server = None
                try:
                    server = engine.start(model, round_dir, log=log)
                    warm_up(server, read_prompts(paths[(round_index, "warmup")]), fairness)
                    for level in levels(fairness):
                        out = round_dir / "speed" / f"{engine.name}--{model.id}" / level.name
                        result = run_level(server, level, paths[(round_index, level.name)], budget, fairness, out,
                                           log=log)
                        if machine.hotter(result.get("thermal_after"), fairness["thermal"]["rerun_above"]):
                            log(f"    {level.name}: ended {result['thermal_after']}; running it again")
                            result["discarded"] = True
                            records.append(results, {**record, **result})
                            result = run_level(server, level, paths[(round_index, level.name + "-rerun")], budget,
                                               fairness, out.with_name(level.name + "-rerun"), log=log)
                        records.append(results, {**record, **result})
                        log(f"    {engine.title:<16} {level.name:<14} " + describe(result))
                except Exception as error:  # an engine failing is a result, not the end of the run
                    records.append(results, {**record, "error": f"{type(error).__name__}: {error}"})
                    log(f"    {engine.title}: {error}")
                finally:
                    if server:
                        engine.stop(server)
    return results



def describe(result: dict) -> str:
    if "error" in result:
        return "error: " + result["error"]
    tps = result.get("output_tokens_per_second")
    ttft = (result.get("ttft_ms") or {}).get("p50")
    itl = (result.get("itl_ms") or {}).get("p50")
    short = result.get("short_requests") or 0
    parts = [f"{tps:.1f} tok/s" if tps else "? tok/s",
             f"TTFT {ttft:.0f} ms" if ttft else "TTFT ?",
             f"ITL {itl:.1f} ms" if itl else "ITL ?"]
    if short:
        parts.append(f"{short} short")
    memory = result.get("peak_resident_bytes") or result.get("peak_footprint_bytes")
    if memory:
        parts.append(f"{memory / 2**30:.1f} GB")
    if result.get("mean_watts"):
        parts.append(f"{result['mean_watts']:.0f} W")
    return ", ".join(parts)
