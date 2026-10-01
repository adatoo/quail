"""Where things are, and the harness's configuration files (bench/config/*.toml)."""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field
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
    # Fields every request to it carries in place of the engine's own thinking-off fields (`request = { … }`),
    # for a template with another switch: gpt-oss's lowest reasoning effort.
    request: dict | None = field(default=None, hash=False)
    # Fewer requests at once than fairness.toml's `slots`, for a model whose cache for all of them won't fit the
    # GPU (Gemma 4 31B on a 64 GB Mac). Concurrency doesn't change a temperature-0 answer, only how long a run takes.
    slots: int | None = None

    def slot_count(self, fairness: dict) -> int:
        return self.slots or fairness["slots"]

    def path(self, lane: str) -> Path:
        return self.gguf if lane == "gguf" else self.mlx

    def served_id(self, lane: str) -> str:
        """The id every engine in a lane serves the model under, so requests are identical across engines."""
        return f"{self.id}-{lane}"


# A lane a model isn't in: a path that never exists, so every step skips it.
ABSENT = Path("/nonexistent/quail-bench")


def models(root: Path | None = None) -> list[Model]:
    """config/models.toml, the engine comparison's three models, or the file QUAIL_BENCH_MODELS names
    (`catalog-models` for the catalog's own scores, ADR D-070)."""
    root = root or store()
    result = []
    for model_id, entry in load(os.environ.get("QUAIL_BENCH_MODELS") or "models").items():
        result.append(
            Model(
                id=model_id,
                name=entry["name"],
                catalog=entry.get("catalog", ""),
                gguf=_resolve(root, entry["gguf"]) if "gguf" in entry else ABSENT,
                mlx=_resolve(root, entry["mlx"]) if "mlx" in entry else ABSENT,
                family=entry.get("family", ""),
                request=entry.get("request"),
                slots=entry.get("slots"),
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
