"""The website's comparison page (website/compare.html): the sourced feature table from config/features.toml, and,
once a report exists, its headline results, each written between its markers so the rest of the hand-written page
is left alone (ADR D-062, D-063)."""

from __future__ import annotations

import json
import re
import shutil
import tomllib
from html import escape
from pathlib import Path

from . import config

PAGE = config.REPO / "website" / "compare.html"
COLUMNS = [("quail", "Quail"), ("ollama", "Ollama"), ("omlx", "oMLX"), ("rapid-mlx", "Rapid-MLX")]
ENGINE_TITLES = {"quail-gguf": "Quail", "llama-server": "llama-server", "ollama-gguf": "Ollama",
                 "quail-mlx": "Quail", "omlx": "oMLX", "rapid-mlx": "Rapid-MLX", "ollama-mlx": "Ollama"}
LANE_ENGINES = {"gguf": ["quail-gguf", "llama-server", "ollama-gguf"],
                "mlx": ["quail-mlx", "omlx", "rapid-mlx", "ollama-mlx"]}


def replace_between(text: str, name: str, body: str) -> str:
    pattern = re.compile(rf"(<!-- bench:{name} -->)(.*?)(<!-- /bench:{name} -->)", re.DOTALL)
    if not pattern.search(text):
        raise ValueError(f"no <!-- bench:{name} --> … <!-- /bench:{name} --> markers in the page")
    return pattern.sub(lambda m: f"{m.group(1)}\n{body}\n{m.group(3)}", text)


def features_html(features: dict) -> str:
    versions = features["versions"]
    head = "".join(f'<th scope="col">{title}<span class="ver">{escape(versions[key])}</span></th>'
                   for key, title in COLUMNS)
    rows = []
    for row in features["row"]:
        cells = []
        for key, _ in COLUMNS:
            cell = row[key]
            cells.append(f'<td>{escape(cell["text"])} <a class="src" href="{escape(cell["source"])}" '
                         f'title="Source">source</a></td>')
        rows.append(f'<tr><th scope="row">{escape(row["feature"])}</th>{"".join(cells)}</tr>')
    return (f'<table class="compare-table">\n<thead><tr><th scope="col">Feature</th>{head}</tr></thead>\n<tbody>\n'
            + "\n".join(rows) + "\n</tbody>\n</table>\n"
            f'<p class="sub">Checked {escape(features["checked"])} against each project\'s own docs, source or '
            "release notes at the version shown. Something wrong or out of date? "
            '<a href="https://github.com/adatoo/quail/issues/new/choose">Tell us</a>.</p>')


def results_html(report_dir: Path | None) -> str:
    if report_dir is None or not (report_dir / "summary.json").exists():
        return ('<p class="note">Measured results (speed, quality and tool calling on the same weights, including '
                "where Quail is slower or worse) will appear here with the full report.</p>")
    summary = json.loads((report_dir / "summary.json").read_text())
    machine = summary.get("machine", {})
    date = report_dir.name
    assets = config.REPO / "website" / "assets" / "bench" / date
    assets.mkdir(parents=True, exist_ok=True)
    out = [f'<p class="sub">Measured {escape(date)} on {escape(str(machine.get("chip")))}, '
           f'{machine.get("memory_bytes", 0) // 2**30} GB, macOS {escape(str(machine.get("macos")))}. '
           f'<a href="https://github.com/adatoo/quail/tree/main/docs/benchmarks/{escape(date)}">The full report</a> '
           "has every level, the intervals and the caveats.</p>"]
    names = {m.id: m.name for m in config.models()}
    for model_id, data in summary.get("models", {}).items():
        out.append(f"<h3>{escape(names.get(model_id, model_id))}</h3>")
        for lane, engines in LANE_ENGINES.items():
            present = [e for e in engines if any(k.startswith(e + "|") for k in data.get("speed", {}))]
            if not present:
                continue
            chart = f"speed-{model_id}-{lane}.svg"
            if (report_dir / "charts" / chart).exists():
                shutil.copy(report_dir / "charts" / chart, assets / chart)
                out.append(f'<img class="chart" src="assets/bench/{escape(date)}/{chart}" alt="Output tokens per second '
                           f'by requests at once, {lane.upper()} lane">')
            out.append('<table class="compare-table results"><thead><tr><th scope="col">'
                       f'{lane.upper()} lane</th><th scope="col">1 request, tok/s</th>'
                       '<th scope="col">8 at once, tok/s</th><th scope="col">First token (1 request)</th>'
                       '<th scope="col">GSM8K</th><th scope="col">MMLU-Pro</th><th scope="col">BFCL</th></tr></thead><tbody>')
            for engine in present:
                speed = data["speed"]
                one, eight = speed.get(f"{engine}|512x256-c1", {}), speed.get(f"{engine}|512x256-c8", {})
                quality = {r["task"]: r for r in data.get("quality", []) if r.get("engine") == engine and "score" in r}
                tools = [r for r in data.get("tools", []) if r.get("engine") == engine and "correct" in r]
                bfcl = (sum(r["correct"] for r in tools) / sum(r["total"] for r in tools)) if tools else None
                cells = [fmt(one.get("tps")), fmt(eight.get("tps")), fmt(one.get("ttft"), 0, " ms"),
                         pct(quality.get("gsm8k_cot_llama", {}).get("score")),
                         pct(quality.get("mmlu_pro", {}).get("score")), pct(bfcl)]
                out.append(f'<tr><th scope="row">{escape(ENGINE_TITLES.get(engine, engine))}</th>'
                           + "".join(f"<td>{c}</td>" for c in cells) + "</tr>")
            out.append("</tbody></table>")
    return "\n".join(out)


def fmt(value, digits: int = 1, unit: str = "") -> str:
    return "—" if value is None else f"{value:,.{digits}f}{unit}"


def pct(value) -> str:
    return "—" if value is None else f"{value:.0%}"


def write(report_dir: Path | None = None, page: Path = PAGE) -> Path:
    with open(config.CONFIG / "features.toml", "rb") as f:
        features = tomllib.load(f)
    text = page.read_text()
    text = replace_between(text, "features", features_html(features))
    text = replace_between(text, "results", results_html(report_dir))
    page.write_text(text)
    return page
