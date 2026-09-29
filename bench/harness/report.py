"""The report: a run folder's results as docs/benchmarks/<date>/ (ADR D-063).

README.md has the method, the versions, the results by lane (speed with the native baselines beside it, quality,
tool calling), a generated "Where Quail is slower or worse" section, and the caveats the smoke test found.
summary.json has the same numbers for the website; raw/ keeps the results files the numbers came from; charts/
has the SVGs. Speed numbers are medians across rounds; a difference is only called one when D-063 allows it (more
than 5% and more than the spread between rounds; for accuracies, an exact McNemar test on the same items).
"""

from __future__ import annotations

import json
import shutil
import tomllib
from pathlib import Path

from . import config, records, stats, svg
from .engines import ENGINES

QUAIL = {"gguf": "quail-gguf", "mlx": "quail-mlx"}
LANES = {"gguf": "GGUF lane (same .gguf file)", "mlx": "MLX lane (same MLX folder)"}
TASK_TITLES = {"gsm8k_cot_llama": "GSM8K", "mmlu_pro": "MMLU-Pro"}


def title(engine: str) -> str:
    return ENGINES[engine].title if engine in ENGINES else engine


def ordered(engines: set[str], lane: str) -> list[str]:
    """Quail first, then the others in the roster's order."""
    roster = [name for name, e in ENGINES.items() if e.lane == lane]
    return sorted(engines, key=lambda e: (e != QUAIL[lane], roster.index(e) if e in roster else 99))


# --- Speed ----------------------------------------------------------------------------------------------------------


def speed_cells(rows: list[dict]) -> dict:
    """{(model, engine, level): {metric: [value per round]}} from the kept (not discarded) records."""
    cells: dict = {}
    for r in rows:
        if "error" in r or r.get("discarded") or "level" not in r:
            continue
        cell = cells.setdefault((r["model"], r["engine"], r["level"]), {})
        for metric, value in (("tps", r.get("output_tokens_per_second")),
                              ("ttft", (r.get("ttft_ms") or {}).get("p50")),
                              ("itl", (r.get("itl_ms") or {}).get("p50")),
                              ("memory", r.get("peak_resident_bytes") or r.get("peak_footprint_bytes")),
                              ("watts", r.get("mean_watts")),
                              ("short", r.get("short_requests"))):
            cell.setdefault(metric, []).append(value)
    return cells


def levels_of(rows: list[dict]) -> list[str]:
    seen = []
    for r in rows:
        if r.get("level") and r["level"] not in seen:
            seen.append(r["level"])
    return sorted(seen, key=lambda name: (int(name.split("x")[0]), int(name.split("-c")[1])))


def fmt(value, digits: int = 1, unit: str = "") -> str:
    return "—" if value is None else f"{value:,.{digits}f}{unit}"


def speed_section(rows: list[dict], native_rows: list[dict], model: config.Model, charts: Path) -> list[str]:
    cells = speed_cells(rows)
    levels = levels_of(rows)
    out = []
    for lane in ("gguf", "mlx"):
        engines = ordered({e for (m, e, _) in cells if m == model.id and ENGINES.get(e) and ENGINES[e].lane == lane},
                          lane)
        if not engines:
            continue
        out += [f"#### {LANES[lane]}", "",
                "Output tokens per second over each level (median across rounds), and time to first token (p50). "
                "Peak memory is resident memory: the server's own plus the model file pages it maps.", "",
                "| Engine | " + " | ".join(levels) + " | Peak memory |",
                "|---|" + "---:|" * len(levels) + "---:|"]
        for engine in engines:
            parts = []
            for level in levels:
                cell = cells.get((model.id, engine, level), {})
                tps, ttft = stats.median(cell.get("tps", [])), stats.median(cell.get("ttft", []))
                parts.append("—" if tps is None else f"{tps:,.1f} ({fmt(ttft, 0)} ms)")
            memory = max((v for lvl in levels for v in cells.get((model.id, engine, lvl), {}).get("memory", [])
                          if v), default=None)
            out.append(f"| {title(engine)} | " + " | ".join(parts) + f" | {fmt(memory and memory / 2**30, 1, ' GB')} |")
        out.append("")
        concurrency = [lvl for lvl in levels if lvl.startswith(levels[0].split("-c")[0])]
        series = {title(e): [stats.median(cells.get((model.id, e, lvl), {}).get("tps", [])) for lvl in concurrency]
                  for e in engines}
        name = f"speed-{model.id}-{lane}.svg"
        (charts / name).write_text(svg.lines(f"{model.name}, {lane.upper()}: output tokens/s by requests at once",
                                             [lvl.split("-c")[1] for lvl in concurrency], series, "tokens/s"))
        out += [f"![{model.name} {lane.upper()} throughput](charts/{name})", ""]
        native = native_lines(native_rows, model, lane)
        if native:
            out += native + [""]
    return out


def native_lines(rows: list[dict], model: config.Model, lane: str) -> list[str]:
    tool = {"gguf": "llama-batched-bench", "mlx": "mlx_lm.benchmark"}[lane]
    mine = [r for r in rows if r.get("model") == model.id and r.get("tool") == tool and "error" not in r
            and r.get("prompt_tokens") == 512]
    if not mine:
        return []
    by = {r["sequences"]: r["generated_tokens_per_second"] for r in mine}
    text = ", ".join(f"{n} → {by[n]:,.1f}" for n in sorted(by))
    return [f"Engine-native ceiling ({tool}, no server): generated tokens/s by sequences at once: {text}."]


# --- Quality and tool calling -----------------------------------------------------------------------------------------


def local(path: str, run_dir: Path) -> Path:
    """A path recorded on the Mac that ran the benchmark, found again in this copy of its run folder."""
    parts = Path(path).parts
    if run_dir.name in parts:
        return run_dir.joinpath(*parts[parts.index(run_dir.name) + 1:])
    return Path(path)


def lm_eval_items(record: dict, run_dir: Path) -> dict:
    """{(subtask, doc_id): correct} from lm-eval's samples files, for the record's metric filter."""
    metric, _, wanted = (record.get("metric") or "").partition(",")
    items = {}
    for recorded in record.get("samples") or []:
        path = local(recorded, run_dir)
        subtask = Path(path).name.split("samples_", 1)[-1].rsplit("_20", 1)[0]
        for line in path.read_text().splitlines():
            if not line.strip():
                continue
            sample = json.loads(line)
            if sample.get("filter") == wanted and metric in sample:
                items[(subtask, sample["doc_id"])] = float(sample[metric]) >= 1.0
    return items


def bfcl_items(record: dict, run_dir: Path) -> dict:
    """{case id: correct}: every case BFCL generated, less the ones its score file lists as failed."""
    score = local(record.get("score_file", ""), run_dir)
    if not score.exists():
        return {}
    failed = {json.loads(line)["id"] for line in score.read_text().splitlines()[1:] if line.strip()}
    # <workdir>/score/<model>/<group>/X_score.json beside <workdir>/result/<model>/<group>/X_result.json
    result = next(iter(score.parents[3].joinpath("result").rglob(score.name.replace("_score", "_result"))), None)
    if result is None:
        return {}
    ids = [json.loads(line)["id"] for line in result.read_text().splitlines() if line.strip()]
    return {i: i not in failed for i in ids}


def accuracy_section(rows: list[dict], model: config.Model, key: str, titles: dict, items_of, charts: Path,
                     kind: str, run_dir: Path) -> tuple[list[str], dict]:
    """A table per lane of accuracy with 95% intervals, and each engine's per-item results for the losses list."""
    out, per_item = [], {}
    for lane in ("gguf", "mlx"):
        mine = [r for r in rows if r.get("model") == model.id and ENGINES.get(r.get("engine"))
                and ENGINES[r["engine"]].lane == lane and "error" not in r]
        engines = ordered({r["engine"] for r in mine}, lane)
        if not engines:
            continue
        columns = [c for c in titles if any(r.get(key) == c for r in mine)]
        out += [f"#### {LANES[lane]}", "", "| Engine | " + " | ".join(titles[c] for c in columns) + " |",
                "|---|" + "---:|" * len(columns)]
        chart_rows = []
        for engine in engines:
            parts = []
            for column in columns:
                record = next((r for r in mine if r["engine"] == engine and r.get(key) == column), None)
                if record is None:
                    parts.append("—")
                    continue
                correct, total = counts(record)
                low, high = stats.wilson(correct, total)
                parts.append(f"{correct / total:.1%} ({low:.0%}–{high:.0%}, n={total})" if total else "—")
                per_item[(engine, column)] = items_of(record, run_dir)
                chart_rows.append((f"{title(engine)} · {titles[column]}", correct / total if total else 0, low, high))
            out.append(f"| {title(engine)} | " + " | ".join(parts) + " |")
        out.append("")
        name = f"{kind}-{model.id}-{lane}.svg"
        (charts / name).write_text(svg.bars(f"{model.name}, {lane.upper()}: {kind} (95% interval)", chart_rows, "",
                                            maximum=1.0))
        out += [f"![{model.name} {lane.upper()} {kind}](charts/{name})", ""]
    return out, per_item


def counts(record: dict) -> tuple[int, int]:
    if "correct" in record:
        return record["correct"], record["total"]
    total = record.get("items") or 0
    return round((record.get("score") or 0) * total), total


# --- Losses and caveats -----------------------------------------------------------------------------------------------


def speed_losses(rows: list[dict], model: config.Model) -> list[str]:
    cells = speed_cells(rows)
    out = []
    for lane, quail in QUAIL.items():
        for level in levels_of(rows):
            ours = cells.get((model.id, quail, level))
            if not ours:
                continue
            for (m, engine, lvl), theirs in cells.items():
                if m != model.id or lvl != level or engine == quail or ENGINES.get(engine) is None \
                        or ENGINES[engine].lane != lane:
                    continue
                metrics = [("tps", "throughput", True), ("ttft", "time to first token", False)]
                # With several requests at once, an engine that serves them one after another has short gaps
                # between tokens and long waits for the first: only throughput and first token compare fairly.
                if level.endswith("-c1"):
                    metrics.append(("itl", "time between tokens", False))
                for metric, label, higher in metrics:
                    gap = stats.meaningful_speed_gap(ours.get(metric, []), theirs.get(metric, []), higher)
                    if gap is not None:
                        out.append(f"{model.name}, {lane.upper()}, {level}: {title(engine)}'s {label} is "
                                   f"{gap:.0%} better than {title(quail)}'s.")
    return out


def accuracy_losses(per_item: dict, model: config.Model, titles: dict) -> list[str]:
    out = []
    for lane, quail in QUAIL.items():
        for (engine, column), theirs in per_item.items():
            if engine == quail or ENGINES.get(engine) is None or ENGINES[engine].lane != lane:
                continue
            ours = per_item.get((quail, column))
            if not ours:
                continue
            only_ours, only_theirs, p = stats.mcnemar(ours, theirs)
            if only_theirs > only_ours and p < 0.05:
                out.append(f"{model.name}, {lane.upper()}, {titles[column]}: {title(engine)} got {only_theirs} items "
                           f"right that {title(quail)} missed, against {only_ours} the other way (McNemar p={p:.3f}).")
    return out


PROBE_CAVEATS = {
    "ignore_eos": "ignores `ignore_eos`, so its replies' lengths were held by the prompts",
    "stream_usage": "doesn't report usage on a stream",
    "tools_chat": "didn't return a parsed tool call on /v1/chat/completions",
    "tools_messages": "didn't return a tool_use block on /v1/messages",
}


def caveats(capabilities: dict, models: list[config.Model], run_dir: Path) -> list[str]:
    """The smoke test's findings and the requests an engine refused, one line per engine and finding, naming the
    models it applies to."""
    names = {m.id: m.name for m in models}
    found: dict[tuple[str, str], list[str]] = {}

    def note(engine: str, text: str, model_id: str) -> None:
        models_for = found.setdefault((engine, text), [])
        if names[model_id] not in models_for:
            models_for.append(names[model_id])

    for engine, per_model in capabilities.items():
        for model_id, result in per_model.items():
            if model_id not in names or "skipped" in result:
                continue
            if "error" in result:
                note(engine, "couldn't start: " + short_error(result["error"]), model_id)
                continue
            for probe, text in PROBE_CAVEATS.items():
                if isinstance(result.get(probe), dict) and not result[probe].get("ok", True):
                    note(engine, text, model_id)
            if (result.get("chat") or {}).get("thinking_off") is False:
                note(engine, "couldn't have thinking switched off", model_id)
    for phase, label in (("quality", "quality"), ("tools", "BFCL")):
        for log in sorted((run_dir / phase).glob("*/requests.jsonl")):
            engine, _, model_id = log.parent.name.partition("--")
            if model_id not in names:
                continue
            rows = records.read(log)
            refused = [r for r in rows if r.get("status") != 200]
            if refused:
                note(engine, f"refused {len(refused)} of {len(rows)} {label} requests "
                             f"(HTTP {refused[0].get('status')}: {short_error(refused[0].get('error', ''))})", model_id)
            deferred = [r for r in rows if r.get("retries")]
            if deferred:
                note(engine, f"asked for {len(deferred)} of {len(rows)} {label} requests to be sent again later "
                             "(429 or 503 with Retry-After); they were, as a client would", model_id)
    return [f"{title(engine)} {text} — {', '.join(models_for)}." for (engine, text), models_for in found.items()]


def short_error(text: str) -> str:
    """An engine's error, without the JSON around it (which the logs may have cut short), in a sentence or two."""
    import re

    match = re.search(r'"message"\s*:\s*"((?:[^"\\]|\\.)*)', text) or re.search(r'"error"\s*:\s*"((?:[^"\\]|\\.)*)', text)
    if match:
        text = match.group(1).replace('\\"', '"')
    text = " ".join(str(text).split())
    return text if len(text) <= 160 else text[:157] + "…"


# --- The whole report ------------------------------------------------------------------------------------------------


def versions(*row_sets: list[dict]) -> dict:
    found = {}
    for rows in row_sets:
        for r in rows:
            if r.get("engine") and r.get("version"):
                found.setdefault(r["engine"], r["version"])
    return found


def report(run_dir: Path, smoke_dir: Path | None, out: Path, log=print) -> Path:
    speed_rows = records.read(run_dir / "speed.jsonl")
    native_rows = records.read(run_dir / "native.jsonl")
    quality_rows = records.read(run_dir / "quality.jsonl")
    tool_rows = records.read(run_dir / "tools.jsonl")
    machine = json.loads((run_dir / "machine.json").read_text())
    conditions = json.loads((run_dir / "conditions.json").read_text()) if (run_dir / "conditions.json").exists() else {}
    capabilities = json.loads((smoke_dir / "capabilities.json").read_text()) if smoke_dir else {}
    fairness_text = (config.CONFIG / "fairness.toml").read_text()
    fairness = tomllib.loads(fairness_text)

    out.mkdir(parents=True, exist_ok=True)
    charts = out / "charts"
    charts.mkdir(exist_ok=True)
    present = {r.get("model") for r in speed_rows + quality_rows + tool_rows}
    models = [m for m in config.models() if m.id in present]

    day = f"{run_dir.name[:4]}-{run_dir.name[4:6]}-{run_dir.name[6:8]}"
    lines = [f"# Quail against llama-server, Ollama, oMLX and Rapid-MLX — {day}", "",
             "Measured by the comparison harness in `bench/` (ADR D-063): the same weights in every engine of a lane, "
             "the same prompts, the same settings, one server at a time.", ""]
    if conditions.get("not_quiet"):
        lines += ["> **Not a clean run:** " + "; ".join(conditions["not_quiet"]) + ". These numbers don't count.", ""]
    lines += ["## The Mac", "",
              f"{machine.get('chip')} ({machine.get('model')}), {machine.get('memory_bytes', 0) // 2**30} GB, "
              f"macOS {machine.get('macos')}, on {'AC power' if (machine.get('power') or {}).get('ac') else 'battery'}. "
              f"Thermal state at the start: {machine.get('thermal') or 'unreadable'}.", "",
              "## Versions", "", "| Engine | Version |", "|---|---|"]
    for engine, version in versions(speed_rows, quality_rows, tool_rows).items():
        lines.append(f"| {title(engine)} | {version} |")
    lines += ["", "## Settings every engine is held to", "",
              f"{fairness['slots']} slots of {fairness['context_per_slot']:,} tokens; full-precision KV cache; "
              f"temperature {fairness['sampling']['temperature']}, seed {fairness['sampling']['seed']}, penalties 0; "
              "thinking off. The whole file is in `raw/fairness.toml`.", ""]

    losses: list[str] = []
    summary: dict = {"run": run_dir.name, "machine": machine, "models": {}}
    for model in models:
        lines += [f"## {model.name}", "", "### Speed", ""]
        lines += speed_section(speed_rows, native_rows, model, charts)
        losses += speed_losses(speed_rows, model)
        lines += ["### Quality", ""]
        quality_lines, quality_items = accuracy_section(quality_rows, model, "task", TASK_TITLES, lm_eval_items,
                                                        charts, "quality", run_dir)
        lines += quality_lines or ["No results.", ""]
        losses += accuracy_losses(quality_items, model, TASK_TITLES)
        lines += ["### Tool calling (BFCL)", ""]
        categories = {c: c.replace("_", " ") for c in
                      ["simple_python", "multiple", "parallel", "parallel_multiple", "irrelevance"]}
        tool_lines, tool_items = accuracy_section(tool_rows, model, "category", categories, bfcl_items, charts,
                                                  "tool-calling", run_dir)
        lines += tool_lines or ["No results.", ""]
        losses += accuracy_losses(tool_items, model, categories)
        summary["models"][model.id] = {
            "speed": {f"{e}|{lvl}": {k: stats.median(v) for k, v in cell.items()}
                      for (m, e, lvl), cell in speed_cells(speed_rows).items() if m == model.id},
            "quality": [r for r in quality_rows if r.get("model") == model.id],
            "tools": [r for r in tool_rows if r.get("model") == model.id],
        }

    lines += ["## Where Quail is slower or worse", ""]
    lines += [f"- {text}" for text in losses] or ["Nowhere by a margin D-063 lets this report claim."]
    lines += ["", "## Caveats", ""]
    notes = caveats(capabilities, models, run_dir)
    lines += [f"- {text}" for text in notes] or ["None found by the smoke test."]
    lines += ["", "## Reproducing it", "",
              "```", "task bench:setup && task bench:smoke", f"task bench:compare BUDGET={conditions.get('budget', 'night')}",
              f"task bench:report RUN=<the run folder> SMOKE=<the smoke folder>", "```", ""]

    (out / "README.md").write_text("\n".join(lines))
    (out / "summary.json").write_text(json.dumps(summary, indent=1, default=str))
    raw = out / "raw"
    raw.mkdir(exist_ok=True)
    for name in ("speed.jsonl", "native.jsonl", "quality.jsonl", "tools.jsonl", "machine.json", "conditions.json"):
        if (run_dir / name).exists():
            shutil.copy(run_dir / name, raw / name)
    if smoke_dir:
        shutil.copy(smoke_dir / "capabilities.json", raw / "capabilities.json")
    (raw / "fairness.toml").write_text(fairness_text)
    log(f"report: {out / 'README.md'}")
    return out
