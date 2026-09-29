"""Runs BFCL (bfcl-eval) against the request shim in function-calling mode, and prints a JSON summary (ADR D-063).

Run with BFCL's environment, not the harness's standard-library Python:

    bench/tools/bfcl/.venv/bin/python bench/harness/run_bfcl.py SPEC.json

SPEC is {"served": <model id>, "categories": [...], "per_category": N (0: all), "threads": 8}. The environment
gives BFCL_PROJECT_ROOT (a scratch folder for its results and scores) and OPENAI_BASE_URL (the shim).

BFCL only knows the models in its own table, so this registers the served id there as an OpenAI-compatible model
in function-calling mode (BFCL's OpenAICompletionsHandler, the one its own OpenAI-compatible entries use), then runs
its `generate` and `evaluate` commands on the first N cases of each category, and scores only those.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def first_ids(category: str, count: int) -> list[str]:
    import bfcl_eval

    data = Path(bfcl_eval.__file__).parent / "data" / f"BFCL_v4_{category}.json"
    ids = []
    with data.open() as f:
        for line in f:
            if line.strip():
                ids.append(json.loads(line)["id"])
            if count and len(ids) >= count:
                break
    return ids


def run(argv: list[str]) -> None:
    from bfcl_eval.__main__ import cli

    try:
        cli(argv, standalone_mode=False)
    except SystemExit as exit_:
        if exit_.code not in (0, None):
            raise


def main() -> None:
    spec = json.loads(Path(sys.argv[1]).read_text())
    root = Path(os.environ["BFCL_PROJECT_ROOT"])
    served, categories = spec["served"], spec["categories"]

    from bfcl_eval.constants.model_config import MODEL_CONFIG_MAPPING, ModelConfig
    from bfcl_eval.model_handler.api_inference.openai_completion import OpenAICompletionsHandler

    MODEL_CONFIG_MAPPING[served] = ModelConfig(
        model_name=served, display_name=f"{served} (FC)", url="", org="", license="",
        model_handler=OpenAICompletionsHandler, input_price=None, output_price=None,
        is_fc_model=True, underscore_to_dot=True,
    )
    ids = {category: first_ids(category, spec["per_category"]) for category in categories}
    (root / "test_case_ids_to_generate.json").write_text(json.dumps(ids, indent=1))

    run(["generate", "--model", served, "--test-category", ",".join(categories), "--run-ids",
         "--num-threads", str(spec["threads"]), "--temperature", "0", "--allow-overwrite"])
    run(["evaluate", "--model", served, "--test-category", ",".join(categories), "--partial-eval"])

    summary = {}
    for category in categories:
        scores = list((root / "score").rglob(f"*_{category}_score.json"))
        if not scores:
            summary[category] = {"error": "no score file"}
            continue
        header = json.loads(scores[0].read_text().splitlines()[0])
        summary[category] = {"accuracy": header.get("accuracy"), "correct": header.get("correct_count"),
                             "total": header.get("total_count"), "score_file": str(scores[0])}
    print("BFCL-SUMMARY " + json.dumps(summary))


if __name__ == "__main__":
    main()
