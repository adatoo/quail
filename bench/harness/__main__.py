"""Quail's comparison harness (ADR D-063). Run through Task: `task bench:doctor`, `task bench:smoke`, …

    python -m harness doctor                    what's installed, what's missing, how the Mac is
    python -m harness smoke [--engines …] [--models …]
                                                start each engine with each model and record what it can do
    python -m harness restore                   resume anything a killed run left paused
"""

from __future__ import annotations

import argparse
import datetime
import json
import shutil
import subprocess
import sys

from . import config, engines, machine
from .smoke import smoke


def new_run(kind: str):
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = config.RUNS / f"{stamp}-{kind}"
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "machine.json").write_text(json.dumps(machine.describe(), indent=2))
    git = subprocess.run(["git", "-C", str(config.REPO), "rev-parse", "HEAD"], capture_output=True, text=True)
    (run_dir / "repo.txt").write_text(git.stdout.strip() + "\n")
    return run_dir


def pick_models(names: str | None) -> list[config.Model]:
    all_models = config.models()
    if not names:
        return all_models
    wanted = [n.strip() for n in names.split(",") if n.strip()]
    chosen = [m for m in all_models if m.id in wanted]
    missing = set(wanted) - {m.id for m in chosen}
    if missing:
        raise SystemExit(f"unknown model(s) {', '.join(sorted(missing))}; have: "
                         + ", ".join(m.id for m in all_models))
    return chosen


def doctor(_args) -> int:
    problems = 0
    facts = machine.describe()
    print(f"Mac: {facts['chip']} ({facts['model']}), {facts['memory_bytes'] // 2**30} GB, macOS {facts['macos']}")
    power = facts["power"]
    print(f"Power: {'AC' if power['ac'] else 'battery'}"
          + (", Low Power Mode ON (timed runs refuse it)" if power["low_power_mode"] else ""))
    print(f"Thermal: {facts['thermal'] or 'unreadable (needs passwordless sudo for /usr/bin/powermetrics)'}")
    mdutil = subprocess.run(["sudo", "-n", "-l", "/usr/bin/mdutil"], capture_output=True).returncode == 0
    print(f"Spotlight pausing: {'available' if mdutil else 'unavailable (needs passwordless sudo for mdutil)'}")
    free = shutil.disk_usage(config.BENCH).free // 2**30
    print(f"Free disk: {free} GB" + ("" if free >= 100 else "  (the Ollama imports want about 100 GB)"))
    others = machine.competing_servers()
    if others:
        print("Other LLM servers running (quit them before a timed run): " + ", ".join(others))
    if machine.time_machine_running():
        print("A Time Machine backup is running: wait for it before a timed run.")

    print("\nEngines:")
    for engine in engines.ENGINES.values():
        try:
            engine.locate()
            print(f"  ✓ {engine.title:<16} {engine.version()}")
        except engines.EngineUnavailable as error:
            problems += 1
            print(f"  ✗ {engine.title:<16} {error}")

    print(f"\nModels (store: {config.store()}):")
    for model in config.models():
        for lane in ("gguf", "mlx"):
            path = model.path(lane)
            if path.exists():
                print(f"  ✓ {model.name:<18} {lane.upper():<4} {path.name}")
            else:
                problems += 1
                hint = f"  → quail pull {model.catalog}" if lane == "gguf" and model.catalog else ""
                print(f"  ✗ {model.name:<18} {lane.upper():<4} missing {path}{hint}")
    print("\n" + ("Ready." if problems == 0 else f"{problems} thing(s) to fix before a full run."))
    return 0 if problems == 0 else 1


def run_smoke(args) -> int:
    others = machine.competing_servers()
    if others:
        print("Note: other LLM servers are running (" + ", ".join(others) + "). The smoke test isn't timed, "
              "so it goes ahead; quit them before a timed run.")
    run_dir = new_run("smoke")
    print(f"Smoke test → {run_dir}")
    capabilities = smoke(engines.select(args.engines), pick_models(args.models), run_dir)
    ok = all(
        all(v.get("ok", True) for v in result.values() if isinstance(v, dict))
        for per_model in capabilities.values() for result in per_model.values()
        if "error" not in result and "skipped" not in result
    )
    print(f"\ncapabilities.json: {run_dir / 'capabilities.json'}")
    return 0 if ok else 1


def restore(_args) -> int:
    machine.restore()
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="harness", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("doctor", help="what's installed, what's missing").set_defaults(fn=doctor)
    smoke_parser = sub.add_parser("smoke", help="record what each engine can do with each model")
    smoke_parser.add_argument("--engines", help=f"comma-separated, from: {', '.join(engines.ENGINES)}")
    smoke_parser.add_argument("--models", help="comma-separated model ids from config/models.toml")
    smoke_parser.set_defaults(fn=run_smoke)
    sub.add_parser("restore", help="resume anything a killed run left paused").set_defaults(fn=restore)
    args = parser.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
