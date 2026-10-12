# ADR-0019: Recommend what runs comfortably, not what's in the RAM tier

**Date:** 2026-09-23 · **Status:** Accepted

**Decision:** "Recommended for this Mac" is every curated, GGUF-capable, non-smoke-test/embedding family whose real fit verdict is Comfortable — any size — sorted by `rank` then larger-first, capped at 5. The cheap pre-filter is `FitEstimator.approxMaxParamsB` on the measured GPU ceiling, not the catalog's `ramTiersGB`.
**Alternatives:** Keep ARCHITECTURE §7's three tiers (16 GB → 4–8B, 32–48 GB → 14–32B, 64 GB+ → 70B-class).
**Why:** Live testing on a 64 GB M4 Pro: the "large" tier (35B+) recommended only one model and hid Gemma 4 31B and Qwen3.8 27B, both Comfortable. The per-model verdict already answers "does it run well here"; a second, coarser size band on top only removed good answers. User decision.
**Follow-up (same day):** ranks had been set per tier, and size broke ties — an older Qwen3 32B landed above its successor Qwen3.8 27B. Catalog revision 3 re-ranks by generation (rank = best of its kind today, regardless of size; a model never outranks its successor), and ties now break by estimated tok/s on this Mac, then size.
**Trade-off:** rank is a hand judgement, re-checked with each catalog refresh; speed is an estimate from memory bandwidth.
**Revisit if:** the catalog grows enough that "top 5 comfortable" stops being a useful shortlist.
