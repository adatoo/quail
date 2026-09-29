"""Results files (one JSON record per line), and what a resumed run can skip."""

from __future__ import annotations

import json
from pathlib import Path


def read(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def append(path: Path, record: dict) -> None:
    with path.open("a") as f:
        f.write(json.dumps(record) + "\n")


def done(path: Path, fields: tuple[str, ...], need: str | None = None, count: int = 1) -> set[tuple]:
    """The `fields` combinations already finished in `path`: `count` records without an error (or, if `need`
    names a field, `count` distinct values of it: every level, task or category)."""
    seen: dict[tuple, list] = {}
    for record in read(path):
        if "error" in record or record.get("discarded"):
            continue
        seen.setdefault(tuple(record.get(f) for f in fields), []).append(record.get(need) if need else None)
    return {key for key, values in seen.items() if len(set(values) if need else values) >= count}
