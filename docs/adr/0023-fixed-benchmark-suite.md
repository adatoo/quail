# ADR-0023: A fixed, versioned benchmark suite; its result is the sharing format

**Date:** 2026-09-23 · **Status:** Accepted

**Decision:** Benchmarks run one fixed suite, `quail-bench-1` (`BenchmarkSuite.swift`): exact-length prompts sent as token ids, the server's own `timings`, deterministic settings, no prompt cache, 1 warm-up + 3 runs. Any change to what it measures or how is a new suite id, never an edit. `BenchmarkResult` (schema v1, in `Shared/`) carries the hardware, model file (incl. sha256), engine build and conditions with the numbers, and is the format later sharing will upload.
**Alternatives:** llama.cpp's own `llama-bench` (measures the engine, not the endpoint users actually hit, and would mean shipping a second binary); a configurable suite (results stop being comparable).
**Why:** The point is comparing across machines, models and later runtimes — which only works if every result was produced the same way and says exactly what it ran on. Measuring through the running endpoint means the numbers are the ones a client will see, and the same suite can run against the MLX runtimes in Phase 3.
**Trade-off:** llama.cpp-specific today (`/tokenize`, `/models/unload`, `timings`); Phase 3's adapters need their own `BenchmarkClient`.
**Revisit if:** the suite proves too slow for large models, or a runtime can't report its own timings.
