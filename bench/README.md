# The comparison harness

Measures Quail against llama-server, Ollama, oMLX and Rapid-MLX on the same Mac and the same weights, with standard
benchmarks. The method and its reasons are in ADR D-063 (`docs/DECISIONS.md`); the settings every engine is held
to are in `config/fairness.toml`. Nothing here ships in the app.

## Getting started

```
task bench:setup     # the tool environments (bench/tools/*), Ollama's official build, llama.cpp's tools
task bench:doctor    # what's installed and missing, and how quiet the Mac is
task bench:smoke     # start every engine with every model; writes bench/runs/<run>/capabilities.json
task bench:speed     # the speed benchmark (GuideLLM); BUDGET=quick|night|full, writes speed.jsonl
task bench:native    # llama-bench, llama-batched-bench and mlx_lm.benchmark on the same weights
```

Narrow a run with `ENGINES=quail-mlx,omlx MODELS=qwen3-8b task bench:speed`. Engines: `quail-gguf`,
`llama-server`, `ollama-gguf` (the GGUF lane) and `quail-mlx`, `omlx`, `rapid-mlx`, `ollama-mlx` (the MLX lane).

A timed run (`speed`, `native`) refuses a Mac that isn't quiet: another LLM server running, on battery, Low Power
Mode, a Time Machine backup. `ALLOW_OTHERS=1` runs anyway, for a dry run, and the run records why its numbers
don't count (`conditions.json`).

## The speed benchmark

Per model, per round, per engine: start the server, warm it up, then run each level with GuideLLM's concurrent
profile: 512 prompt tokens → 256 generated at 1, 2, 4 and 8 requests at once, and 4096 → 128 at one. Rounds
alternate the engine order. Before each level the Mac waits until powermetrics reads Nominal; a level that ends
hotter than Moderate is run again on fresh prompts (both kept, the first marked `discarded`).

- **The same work everywhere:** each level sends exactly `concurrency × requests_per_stream` requests; the time
  limit is only a cap.
- **Prompts** are exact lengths in the model's own tokenizer, each opening differently, and a new set for every
  level, so no engine gets a prefix-cache hit another doesn't. They ask for a long continuation, so every reply
  runs to `max_tokens` without `ignore_eos` (which only some engines honour); `short_requests` counts any that
  didn't.
- **Recorded per level** (`speed.jsonl`, and GuideLLM's full report beside each): TTFT, ITL and TPOT (median and
  p95), output tokens per second, peak memory footprint of the server's processes (Metal's buffers included),
  mean power, and the thermal state before and after.

## What it needs

- A **Release** build of Quail: `/Applications/Quail.app`, `~/Apps/Quail.app` (`task install`), or
  `QUAIL_BENCH_APP=…`. It runs that app's `quail-server` and `llama-server` directly, not the app.
- The models in Quail's store (`config/models.toml`); `bench:doctor` says which `quail pull` fetches a missing one.
- `uv`, and Rapid-MLX installed (`brew install rapid-mlx`).
- For timed runs: passwordless `sudo` for `/usr/bin/powermetrics` (the thermal gate and power) and
  `/usr/bin/mdutil` (pausing Spotlight). Without them the run still goes, and records that it couldn't.
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
harness/      the driver (standard library only): engines, machine control, smoke, speed, native, monitor, tests
              (make_prompts.py runs in GuideLLM's environment, for its tokenizer)
tools/<tool>/ one uv-locked environment per tool: omlx, guidellm, mlxlm (lm-eval and BFCL next)
runs/         results (git-ignored); the report goes to docs/benchmarks/<date>/
```
