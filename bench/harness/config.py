"""Where things are, and the harness's configuration files (bench/config/*.toml)."""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass
from pathlib import Path

BENCH = Path(__file__).resolve().parents[1]
REPO = BENCH.parent
CONFIG = BENCH / "config"
# `.noindex`: Spotlight never indexes a folder with this suffix, so scratch model copies and caches don't wake
# mds in the middle of a timed run.
WORK = BENCH / ".work.noindex"
RUNS = BENCH / "runs"
TOOLS = BENCH / "tools"
VENDOR = REPO / "Vendor"


def load(name: str) -> dict:
    with open(CONFIG / f"{name}.toml", "rb") as f:
        return tomllib.load(f)


def store() -> Path:
    """Quail's model store, or QUAIL_BENCH_STORE."""
    configured = os.environ.get("QUAIL_BENCH_STORE")
    if configured:
        return Path(configured).expanduser()
    return Path("~/Library/Application Support/Quail/Models").expanduser()


@dataclass(frozen=True)
class Model:
    """One model, as each lane sees it."""

    id: str
    name: str
    catalog: str
    gguf: Path
    mlx: Path
    family: str

    def path(self, lane: str) -> Path:
        return self.gguf if lane == "gguf" else self.mlx

    def served_id(self, lane: str) -> str:
        """The id every engine in a lane serves the model under, so requests are identical across engines."""
        return f"{self.id}-{lane}"


def models(root: Path | None = None) -> list[Model]:
    root = root or store()
    result = []
    for model_id, entry in load("models").items():
        result.append(
            Model(
                id=model_id,
                name=entry["name"],
                catalog=entry.get("catalog", ""),
                gguf=_resolve(root, entry["gguf"]),
                mlx=_resolve(root, entry["mlx"]),
                family=entry.get("family", ""),
            )
        )
    return result


def _resolve(root: Path, value: str) -> Path:
    path = Path(value).expanduser()
    return path if path.is_absolute() else root / path


def fairness() -> dict:
    return load("fairness")


def budget(name: str) -> dict:
    budgets = fairness().get("budgets", {})
    if name not in budgets:
        raise SystemExit(f"no budget {name!r} in fairness.toml (have: {', '.join(budgets)})")
    return budgets[name]
