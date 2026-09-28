"""Engine-native baselines: what each lane's own benchmark tool gets from the same weights with no server in the
way (ADR D-063). They bound what a server on that engine can reach; they aren't a server comparison.

- GGUF: `llama-bench` (prompt processing and generation, one sequence) and `llama-batched-bench` (1, 2, 4 and 8
  sequences at once), from the llama.cpp release Quail bundles (`task vendor:llama-tools`).
- MLX: `mlx_lm.benchmark` at batch 1, 2, 4 and 8, from the mlx-lm that oMLX and Rapid-MLX run on
  (bench/tools/mlxlm).

The sizes are the speed benchmark's: 512 prompt tokens with 256 generated, and 4096 with 128.
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

from . import config, machine
from .config import Model

MLX_PYTHON = config.TOOLS / "mlxlm" / ".venv" / "bin" / "python"
AVERAGES = re.compile(r"Averages:\s*(.+)")


def llama_tools() -> Path:
    tag = (config.VENDOR / "llama.version").read_text().strip()
    return config.VENDOR / "llama-tools" / tag


def env() -> dict:
    home = config.WORK / "native-home"
    home.mkdir(parents=True, exist_ok=True)
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home), "HF_HOME": str(home / "hf"),
            "HF_HUB_OFFLINE": "1", "LANG": "en_US.UTF-8"}


def run(argv: list[str], log_path: Path, timeout: float = 3600, merge: bool = False) -> str:
    """The tool's stdout (with its stderr too if `merge`: llama.cpp's LOG goes there)."""
    done = subprocess.run(argv, env=env(), capture_output=True, text=True, timeout=timeout)
    log_path.write_text(f"$ {' '.join(argv)}\n\n{done.stdout}\n--- stderr ---\n{done.stderr}")
    if done.returncode != 0:
        raise RuntimeError(f"{Path(argv[0]).name} exited {done.returncode}; see {log_path}")
    return done.stdout + ("\n" + done.stderr if merge else "")


def parse_llama_bench(text: str) -> list[dict]:
    rows = json.loads(text)
    return [{"prompt_tokens": r["n_prompt"], "generated_tokens": r["n_gen"], "tokens_per_second": r["avg_ts"],
             "stddev": r["stddev_ts"]} for r in rows]


def parse_batched_bench(text: str) -> list[dict]:
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("{"):
            r = json.loads(line)
            rows.append({"sequences": r["pl"], "prompt_tokens": r["pp"], "generated_tokens": r["tg"],
                         "prompt_tokens_per_second": r["speed_pp"], "generated_tokens_per_second": r["speed_tg"]})
    return rows


def parse_mlx_benchmark(text: str) -> dict:
    match = AVERAGES.search(text)
    if not match:
        raise ValueError("no Averages line in mlx_lm.benchmark's output")
    values = dict(part.strip().split("=") for part in match.group(1).split(","))
    return {"prompt_tokens_per_second": float(values["prompt_tps"]),
            "generated_tokens_per_second": float(values["generation_tps"]),
            "peak_memory_gb": float(values["peak_memory"])}


def native(models: list[Model], budget_name: str, run_dir: Path, log=print) -> Path:
    fairness = config.fairness()
    speed = fairness["speed"]
    trials = max(2, config.budget(budget_name)["speed_rounds"] + 1)
    batches = speed["levels"]
    results = run_dir / "native.jsonl"
    out = run_dir / "native"
    out.mkdir(parents=True, exist_ok=True)
    tools = llama_tools()

    def record(entry: dict) -> None:
        with results.open("a") as f:
            f.write(json.dumps(entry) + "\n")

    for model in models:
        if model.gguf.exists() and (tools / "llama-bench").exists():
            machine.wait_until_cool(fairness["thermal"], log=log)
            try:
                text = run([str(tools / "llama-bench"), "-m", str(model.gguf), "-ngl", "99", "-fa", "on",
                            "-p", f"{speed['prompt_tokens']},{speed['long_prompt_tokens']}",
                            "-n", f"{speed['output_tokens']},{speed['long_output_tokens']}",
                            "-r", str(trials), "-o", "json"], out / f"llama-bench--{model.id}.log")
                for row in parse_llama_bench(text):
                    record({"model": model.id, "tool": "llama-bench", **row})
                log(f"  llama-bench × {model.name}: done")
            except Exception as error:
                record({"model": model.id, "tool": "llama-bench", "error": str(error)})
                log(f"  llama-bench × {model.name}: {error}")
            machine.wait_until_cool(fairness["thermal"], log=log)
            try:
                context = fairness["slots"] * fairness["context_per_slot"]
                text = run([str(tools / "llama-batched-bench"), "-m", str(model.gguf), "-ngl", "99", "-fa", "on",
                            "-c", str(context), "-npp", str(speed["prompt_tokens"]),
                            "-ntg", str(speed["output_tokens"]), "-npl", ",".join(map(str, batches)),
                            "--output-format", "jsonl"], out / f"llama-batched-bench--{model.id}.log", merge=True)
                for row in parse_batched_bench(text):
                    record({"model": model.id, "tool": "llama-batched-bench", **row})
                log(f"  llama-batched-bench × {model.name}: done")
            except Exception as error:
                record({"model": model.id, "tool": "llama-batched-bench", "error": str(error)})
                log(f"  llama-batched-bench × {model.name}: {error}")
        if model.mlx.exists() and MLX_PYTHON.exists():
            shapes = [(speed["prompt_tokens"], speed["output_tokens"], b) for b in batches]
            shapes.append((speed["long_prompt_tokens"], speed["long_output_tokens"], 1))
            for prompt, generated, batch in shapes:
                machine.wait_until_cool(fairness["thermal"], log=log)
                name = f"mlx_lm.benchmark--{model.id}--{prompt}x{generated}-b{batch}"
                try:
                    text = run([str(MLX_PYTHON), "-m", "mlx_lm.benchmark", "--model", str(model.mlx),
                                "-p", str(prompt), "-g", str(generated), "-b", str(batch), "-n", str(trials)],
                               out / f"{name}.log")
                    record({"model": model.id, "tool": "mlx_lm.benchmark", "prompt_tokens": prompt,
                            "generated_tokens": generated, "sequences": batch, **parse_mlx_benchmark(text)})
                except Exception as error:
                    record({"model": model.id, "tool": "mlx_lm.benchmark", "prompt_tokens": prompt,
                            "generated_tokens": generated, "sequences": batch, "error": str(error)})
                    log(f"  mlx_lm.benchmark × {model.name} ({prompt}x{generated}, {batch}): {error}")
            log(f"  mlx_lm.benchmark × {model.name}: done")
    return results
