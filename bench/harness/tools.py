"""The tool-calling benchmark: BFCL's function-calling categories through the request shim (ADR D-063).

Five categories that don't need executable backends or multiple turns: simple (Python), multiple (pick one of
several functions), parallel (several calls to one function), parallel multiple, and irrelevance (don't call
anything). Each engine answers the first `bfcl_per_category` cases of each, in BFCL's own order, and BFCL's AST
checker scores them. This measures what an agent sees: the engine's chat template, its tool-call parser and the
model together.
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

from . import config, records
from .config import Model
from .engines import Engine, EngineUnavailable
from .shim import Shim

BFCL_PYTHON = config.TOOLS / "bfcl" / ".venv" / "bin" / "python"
RUN_BFCL = Path(__file__).with_name("run_bfcl.py")
CATEGORIES = ["simple_python", "multiple", "parallel", "parallel_multiple", "irrelevance"]
SUMMARY = re.compile(r"^BFCL-SUMMARY (.+)$", re.MULTILINE)


def tool_env(root: Path, shim: Shim) -> dict:
    home = config.WORK / "tool-home"
    home.mkdir(parents=True, exist_ok=True)
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home), "HF_HOME": str(home / "hf"),
            "LANG": "en_US.UTF-8", "BFCL_PROJECT_ROOT": str(root), "OPENAI_BASE_URL": f"{shim.base}/v1",
            "OPENAI_API_KEY": "shim"}


def parse_summary(text: str) -> dict:
    match = SUMMARY.search(text)
    if not match:
        raise ValueError("run_bfcl.py printed no summary")
    return json.loads(match.group(1))


def tool_calling(engines: list[Engine], models: list[Model], budget_name: str, run_dir: Path, log=print) -> Path:
    fairness = config.fairness()
    per_category = config.budget(budget_name)["bfcl_per_category"]
    results = run_dir / "tools.jsonl"
    finished = records.done(results, ("model", "engine"), need="category", count=len(CATEGORIES))
    for model in models:
        for engine in engines:
            if not model.path(engine.lane).exists() or (model.id, engine.name) in finished:
                continue
            try:
                engine.locate()
            except EngineUnavailable as error:
                log(f"  skip {engine.title}: {error}")
                continue
            base = {"model": model.id, "engine": engine.name, "lane": engine.lane, "version": engine.version()}
            workdir = run_dir / "tools" / f"{engine.name}--{model.id}"
            workdir.mkdir(parents=True, exist_ok=True)
            server = shim = None
            try:
                server = engine.start(model, run_dir / "tools-servers", log=log)
                shim = Shim(server, fairness, workdir / "requests.jsonl").start()
                spec = {"served": server.served, "categories": CATEGORIES, "per_category": per_category,
                        "threads": fairness["slots"]}
                (workdir / "spec.json").write_text(json.dumps(spec, indent=1))
                done = subprocess.run([str(BFCL_PYTHON), str(RUN_BFCL), str(workdir / "spec.json")],
                                      env=tool_env(workdir, shim), capture_output=True, text=True)
                (workdir / "bfcl.log").write_text(done.stdout + "\n--- stderr ---\n" + done.stderr)
                if done.returncode != 0:
                    raise RuntimeError(f"BFCL exited {done.returncode}; see {workdir / 'bfcl.log'}")
                for category, score in parse_summary(done.stdout).items():
                    records.append(results, {**base, "category": category, **score})
                    accuracy = score.get("accuracy")
                    log(f"    {engine.title:<16} {model.name:<18} {category:<18} "
                        + (f"{accuracy:.3f} ({score['correct']}/{score['total']})" if accuracy is not None
                           else score.get("error", "?")))
            except Exception as error:  # an engine failing is a result, not the end of the run
                records.append(results, {**base, "error": f"{type(error).__name__}: {error}"})
                log(f"    {engine.title} × {model.name}: {error}")
            finally:
                if shim:
                    shim.stop()
                if server:
                    engine.stop(server)
    return results

