"""The statistics the report uses: medians and spreads across rounds, Wilson intervals for accuracies, and an exact
McNemar test for two engines scored on the same items (ADR D-063)."""

from __future__ import annotations

import math
import statistics


def median(values: list[float]) -> float | None:
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def spread(values: list[float]) -> float:
    """Max minus min: the spread between rounds (0 for a single round)."""
    values = [v for v in values if v is not None]
    return (max(values) - min(values)) if len(values) > 1 else 0.0


def wilson(correct: int, total: int, z: float = 1.959964) -> tuple[float, float]:
    """The 95% Wilson score interval for `correct` out of `total`."""
    if total == 0:
        return (0.0, 1.0)
    p = correct / total
    denominator = 1 + z * z / total
    centre = (p + z * z / (2 * total)) / denominator
    half = z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total)) / denominator
    return (max(0.0, centre - half), min(1.0, centre + half))


def mcnemar(a: dict, b: dict) -> tuple[int, int, float]:
    """Two engines' per-item results ({item: bool}) on the items both answered: (items only `a` got right, items
    only `b` got right, the exact two-sided p-value that they're equally good)."""
    shared = a.keys() & b.keys()
    only_a = sum(1 for k in shared if a[k] and not b[k])
    only_b = sum(1 for k in shared if b[k] and not a[k])
    n = only_a + only_b
    if n == 0:
        return (0, 0, 1.0)
    tail = sum(math.comb(n, i) for i in range(0, min(only_a, only_b) + 1)) / 2**n
    return (only_a, only_b, min(1.0, 2 * tail))


def meaningful_speed_gap(ours: list[float], theirs: list[float], higher_is_better: bool,
                         threshold: float = 0.05) -> float | None:
    """How much better `theirs` is than `ours` (a fraction of ours), if it's a difference D-063 lets the report
    claim: more than `threshold` and more than the spread between rounds on either side. Otherwise None."""
    a, b = median(ours), median(theirs)
    if a is None or b is None or a == 0:
        return None
    gap = (b - a) if higher_is_better else (a - b)
    if gap / abs(a) <= threshold or gap <= max(spread(ours), spread(theirs)):
        return None
    return gap / abs(a)
