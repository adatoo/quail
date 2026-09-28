# The comparison harness

Measures Quail against llama-server, Ollama, oMLX and Rapid-MLX on the same Mac and the same weights, with standard
benchmarks. The method and its reasons are in ADR D-063 (`docs/DECISIONS.md`); the settings every engine is held
to are in `config/fairness.toml`. Nothing here ships in the app.

## Getting started

```
task bench:setup     # oMLX's environment (bench/tools/omlx) and Ollama's official build (Vendor/bench)
task bench:doctor    # what's installed and missing, and how quiet the Mac is
task bench:smoke     # start every engine with every model; writes bench/runs/<run>/capabilities.json
```

Narrow a run with `ENGINES=quail-mlx,omlx MODELS=qwen3-8b task bench:smoke`. Engines: `quail-gguf`,
`llama-server`, `ollama-gguf` (the GGUF lane) and `quail-mlx`, `omlx`, `rapid-mlx`, `ollama-mlx` (the MLX lane).

## What it needs

- A **Release** build of Quail: `/Applications/Quail.app`, `~/Apps/Quail.app` (`task install`), or
  `QUAIL_BENCH_APP=…`. It runs that app's `quail-server` and `llama-server` directly, not the app.
- The models in Quail's store (`config/models.toml`); `bench:doctor` says which `quail pull` fetches a missing one.
- `uv`, and Rapid-MLX installed (`brew install rapid-mlx`).
- For timed runs: passwordless `sudo` for `/usr/bin/powermetrics` (the thermal gate) and `/usr/bin/mdutil`
  (pausing Spotlight). Without them the run still goes, and records that it couldn't.
- About 100 GB free: Ollama copies each imported model into its own store (`.work.noindex/ollama-models`).

## What it never does

- Touch your own Quail, Ollama or oMLX settings or models: every engine gets a scratch `HOME` and scratch folders
  under `bench/.work.noindex/` (the `.noindex` keeps Spotlight out).
- Stop your apps: a timed run refuses to start while another LLM server runs, and says which.
- Leave the Mac paused: Spotlight and the analysis daemons it pauses are recorded first and always resumed.
  If a run was killed, `task bench:restore` puts them back.

## Layout

```
config/       models, engines, fairness rules and budgets
harness/      the driver (standard library only): engines, machine control, smoke test, tests
tools/<tool>/ one uv-locked environment per tool (oMLX now; GuideLLM, lm-eval and BFCL next)
runs/         results (git-ignored); the report goes to docs/benchmarks/<date>/
```
