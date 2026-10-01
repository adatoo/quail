"""The quality benchmark: EleutherAI's lm-evaluation-harness on GSM8K (chain of thought, 8-shot, in chat turns)
and MMLU-Pro (5-shot chain of thought, 14 subjects), through the request shim (ADR D-063).

Every engine answers the same items: `--limit` takes the first N of each task (per subject for MMLU-Pro), and
lm-eval's own seed fixes the few-shot examples. `--log_samples` keeps each item's answer and score, so the report
can compare two engines on the same items (McNemar) rather than only their totals. Speed doesn't matter here, so
lm-eval sends as many requests at once as the engine has slots.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from . import config, records
from .config import Model
from .engines import Engine, EngineUnavailable
from .shim import Shim

LM_EVAL = config.TOOLS / "lmeval" / ".venv" / "bin" / "lm_eval"

# task, the budget key that limits it, the filter whose score counts, extra generation settings
TASKS = [
    ("gsm8k_cot_llama", "gsm8k_limit", "exact_match,strict-match", "max_gen_toks=512"),
    ("mmlu_pro", "mmlu_pro_limit", "exact_match,custom-extract", None),
]


def tool_env() -> dict:
    home = config.WORK / "tool-home"
    home.mkdir(parents=True, exist_ok=True)
    # Online: lm-eval fetches its datasets from Hugging Face the first time, into this cache.
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home), "HF_HOME": str(home / "hf"),
            "TOKENIZERS_PARALLELISM": "false", "LANG": "en_US.UTF-8"}


def command(task: str, limit: int, gen_kwargs: str | None, shim: Shim, served: str, slots: int, seed: int,
            out: Path) -> list[str]:
    argv = [
        str(LM_EVAL), "run", "--model", "local-chat-completions",
        "--model_args", f"model={served},base_url={shim.base}/v1/chat/completions,num_concurrent={slots},"
                        "max_retries=3,tokenized_requests=False,timeout=1800",
        "--tasks", task, "--apply_chat_template", "--fewshot_as_multiturn",
        "--output_path", str(out), "--log_samples", "--seed", str(seed),
    ]
    if limit:
        argv += ["--limit", str(limit)]
    if gen_kwargs:
        argv += ["--gen_kwargs", gen_kwargs]
    return argv


def read_results(out: Path, task: str, metric: str) -> dict:
    """The score, its standard error and the item count for `task`, from lm-eval's newest results file."""
    files = sorted(out.rglob("results_*.json"))
    if not files:
        raise RuntimeError(f"lm-eval wrote no results in {out}")
    report = json.loads(files[-1].read_text())
    scores = report["results"][task]
    name, _, filter_name = metric.partition(",")
    samples = report.get("n-samples", {})
    count = samples.get(task, {}).get("effective")
    if count is None:  # a group (MMLU-Pro): the sum over its subjects
        count = sum(v.get("effective", 0) for k, v in samples.items() if k.startswith(task + "_"))
    return {
        "score": scores.get(metric),
        "stderr": stderr if isinstance(stderr := scores.get(f"{name}_stderr,{filter_name}"), float) else None,
        "items": count,
        "results_file": str(files[-1]),
        "samples": [str(p) for p in sorted(out.rglob("samples_*.jsonl"))],
    }


def quality(engines: list[Engine], models: list[Model], budget_name: str, run_dir: Path, log=print) -> Path:
    fairness = config.fairness()
    budget = config.budget(budget_name)
    results = run_dir / "quality.jsonl"
    finished = records.done(results, ("model", "engine"), need="task", count=len(TASKS))
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
            workdir = run_dir / "quality" / f"{engine.name}--{model.id}"
            workdir.mkdir(parents=True, exist_ok=True)
            server = shim = None
            try:
                server = engine.start(model, run_dir / "quality-servers", log=log)
                shim = Shim(server, fairness, workdir / "requests.jsonl").start()
                for task, limit_key, metric, gen_kwargs in TASKS:
                    out = workdir / task
                    argv = command(task, budget[limit_key], gen_kwargs, shim, server.served, model.slot_count(fairness),
                                   fairness["sampling"]["seed"], out)
                    with open(workdir / f"{task}.log", "w") as console:
                        done = subprocess.run(argv, env=tool_env(), stdout=console, stderr=subprocess.STDOUT)
                    if done.returncode != 0:
                        record = {**base, "task": task, "error": f"lm-eval exited {done.returncode}; see "
                                                                   f"{workdir / (task + '.log')}"}
                    else:
                        record = {**base, "task": task, "metric": metric, **read_results(out, task, metric)}
                    records.append(results, record)
                    score = record.get("score")
                    log(f"    {engine.title:<16} {model.name:<18} {task:<16} "
                        + (f"{score:.3f} on {record['items']} items" if score is not None else record.get("error", "?")))
            except Exception as error:  # an engine failing is a result, not the end of the run
                records.append(results, {**base, "error": f"{type(error).__name__}: {error}"})
                log(f"    {engine.title} × {model.name}: {error}")
            finally:
                if shim:
                    shim.stop()
                if server:
                    engine.stop(server)
    return results

