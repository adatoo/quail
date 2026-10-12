# ADR-0063: Comparing Quail with Ollama, oMLX and Rapid-MLX: method and harness

**Date:** 2026-09-28 · **Status:** Accepted

**Situation:** the owner wants to know how Quail compares with Ollama, oMLX and Rapid-MLX, measured with standard benchmarks. The results go in the repo and on the website, including where Quail loses. Until now only `quail bench` existed. It depends on llama-server's `/tokenize` and server-side `timings`, so it can't measure the others.

**Decision:** a harness in `bench/` drives standard tools against every engine on the same weights, under one set of fairness rules.

**What it compares**
- **Two lanes, never mixed:**
  - GGUF lane: Quail, the bundled llama-server and Ollama, all on the same `.gguf` file.
  - MLX lane: Quail, oMLX, Rapid-MLX and Ollama's MLX runner, all on the same MLX folder.
  - Results across lanes are labelled as different quantisations.
- **Models:** Qwen3 8B, Qwen3.6 35B-A3B and Gemma 4 26B-A4B (`bench/config/models.toml`).
- **Standard tools:**
  - speed: GuideLLM
  - quality: EleutherAI's lm-evaluation-harness (GSM8K, MMLU-Pro)
  - tool calling: BFCL
  - engine-native baselines: `llama-bench`, `mlx_lm.benchmark`
- **Tool environments:** each tool has its own uv-locked environment under `bench/tools/`. The driver uses the standard library only, so CI tests it without installing anything (`task bench:test`).
- **Nothing in `bench/` ships in the app.** AGENTS.md's "don't bundle Python" still holds.

**Fairness** (`bench/config/fairness.toml`; the report prints it):
- **Capacity:** 8 slots of 8K context.
- **KV cache:** full precision everywhere; flash attention on for GGUF.
- **Sampling:** sent on every request (temperature 0, seed 42, penalties 0), and pinned server-side where an engine has its own defaults.
- **Thinking:** off everywhere, checked per engine and model.
- **Warm-up:** the same untimed requests before timing.
- **Settings that need explicit flags:**
  - Rapid-MLX's model profiles can switch on a quantized or compressed KV cache (TurboQuant) and prompt compression (PFlash) by themselves, so it gets explicit flags.
  - Ollama and oMLX ignore `ignore_eos`, so output length is held by the prompts and every request's token count is recorded.

**Engine sources**
- **Ollama:** its official build (`task vendor:ollama`, pinned by sha256). Homebrew's builds the MLX runner against Homebrew's mlx-c.
- **oMLX:** its release wheel.
- **Rapid-MLX:** as installed.
- **Quail:** a Release build; a Debug build is refused.

**Isolation**
- Every engine runs with a scratch `HOME` and scratch model and cache folders.
- The user's Quail, Ollama and oMLX are never touched, and never stopped: the harness asks.
- Random API keys, redacted from the recorded launch commands.

**Accuracy**
- **Order:** engines are interleaved with alternating order, and results are the median with the range across rounds.
- **Before every timed level:** a thermal gate (powermetrics must read "Nominal").
- **During the run:**
  - `caffeinate` keeps the Mac awake.
  - Spotlight and the photo and media analysis daemons are paused.
  - One server runs at a time.
  - Anything paused is recorded first and always restored, including by `task bench:restore` after a killed run.
- **What counts as a difference:** a speed claim needs more than 5% and more than the spread between rounds. Quality claims use confidence intervals on the same items.
- **Hosts:**
  - Published numbers come from a dedicated Mac (an M1 Max MacBook Pro, 64 GB) driven over SSH.
  - A speed-only confirmation run on the M4 Pro Mac mini checks the ranking holds on newer hardware.

**The smoke test** (`task bench:smoke`) comes before any timing and writes `capabilities.json`. It records:
- whether `ignore_eos` and streamed usage work
- whether thinking really is off
- whether tool calls come back parsed on the OpenAI and Anthropic routes
- how many tokens the same prompt counts as
- whether a repeated prompt hits a prefix cache

The report's caveats come from it.

**Publication:**
- Dated and versioned.
- The losses are shown, in a generated "Where Quail is slower or worse" section.
- Every competitor feature claim links to its own docs or source.
- Stable releases only (not Ollama's release candidates).

**Alternatives:**
- **Extend `quail bench` to do it all:** that would be our method, not a standard one. `quail bench --url` still comes, so Quail can measure any server itself, cross-checked against GuideLLM.
- **Compare with each engine's own published numbers:** different Macs, settings and prompts.
- **Rent a cloud Mac:** a Scaleway Mac mini M4 Pro is about €12 a night (24-hour minimum). It isn't needed while a dedicated laptop is available.

**Revisit if:**
- a competitor adds a setting the fairness rules can't express
- the lanes converge, for example if one engine reads both formats' weights

**Amended 2026-09-28 (the speed benchmark and the native baselines):**
- **The same work for every engine.** A speed level sends exactly `concurrency × requests_per_stream` requests (2, 6 or 10 per stream for the quick, night and full budgets). A time limit is only a cap, because a fixed duration would give a faster engine more samples and cut requests off mid-reply.
- **Prompts:** built by `make_prompts.py` to an exact length in the model's own tokenizer (512 or 4096 tokens), from seeded filler text.
  - Each prompt opens with its own number and topic, and every level and warm-up in a round has its own set. So no engine can get a prefix-cache hit that another doesn't.
  - Every prompt asks for a continuation of at least 400 words. Replies then run to `max_tokens` without `ignore_eos`, which only some engines honour. A reply that stops short is counted in `short_requests`.
- **What's reported per level:**
  - from GuideLLM's own statistics: TTFT, ITL and TPOT (median and p95)
  - output tokens per second over the measured window
  - peak memory of the server's whole process group, from `footprint`, which counts Metal's GPU buffers. The report uses the footprint (Activity Monitor's Memory) and says that it leaves out model files an engine maps rather than loads, so the llama.cpp engines read low by up to the file's size. Adding footprint's clean pages to it was tried for a fairer figure, but it over-counts: a mapped file also appears inside the Metal buffer wrapped around it, which gave 29 GB for llama-server with an 8B model. It stays recorded, but only for reference.
  - mean power, from powermetrics
- **Thermal re-runs:** a level that ends hotter than "Moderate" is run once more, on prompts of its own (the server has seen the first set, and the first dry run's re-run was served from its cache). Both results are kept, the first marked `discarded`. The first dry run on the Mac mini needed this at concurrency 8.
- **Refusal:** a timed run refuses to start while another LLM server runs, on battery, in Low Power Mode, or during a Time Machine backup. `--allow-others` runs anyway for a dry run, and records why its numbers don't count.
- **Native baselines:**
  - GGUF lane: `llama-bench` and `llama-batched-bench` (1–8 sequences). They come from the same llama.cpp release tarball and sha256 as the bundled llama-server, unpacked by `task vendor:llama-tools` into `Vendor/llama-tools/`, which `embed:llama` never reads.
  - MLX lane: `mlx_lm.benchmark` at batch 1–8, from mlx-lm 0.31.3 and MLX 0.32.0, the versions oMLX and Rapid-MLX run on.
  - Both bound what a server on that engine can reach. They aren't a server comparison, and the report says so.
- **Smoke findings so far:**
  - Quail parsed none of Gemma 4's tool calls. This was fixed in 0.57.1; see ADR-0040's amendment.
  - Rapid-MLX 0.14.3 needs `--no-mllm` to load Gemma 4 without mlx-vlm. Loaded text-only, it generates Gemma 4's tool call but returns an empty reply with no `tool_calls`, on both routes.
  - Ollama 0.34.4 can't import mlx-community's MLX folders ("Invalid quantization mode ''"), so its MLX lane is empty for now.

**Amended 2026-09-28 (quality, tool calling, and the whole run):**
- **A request shim between each tool and the engine** (`harness/shim.py`). lm-eval and BFCL send ordinary chat-completions requests. The shim applies the fairness rules: the served id, neutral sampling, thinking off in each engine's own words, and the key. The tool's prompt, stop strings, length limit and tools pass through untouched. Without it, each tool would need patching per engine; lm-eval, for example, sends its own seed and knows nothing of `reasoning_effort`. The shim logs each request by a hash of its messages, never the text.
- **Quality:** lm-eval 0.4.13, `local-chat-completions`, on two tasks.
  - `gsm8k_cot_llama`: 8-shot chain of thought as chat turns, 512 tokens.
  - `mmlu_pro`: 5-shot chain of thought, 14 subjects.
  - `--limit` takes the first items, per subject for MMLU-Pro, so every engine answers the same ones. `--log_samples` keeps per-item scores for paired comparisons.
- **Tool calling:** BFCL 2026.3.23 in function-calling mode, on five categories: `simple_python`, `multiple`, `parallel`, `parallel_multiple` and `irrelevance`.
  - These don't need executable backends or several turns.
  - Each engine runs the first `bfcl_per_category` cases of each, and BFCL's AST checker scores them.
  - The served id is registered in BFCL's model table as an OpenAI-compatible function-calling model, through `OpenAICompletionsHandler`, as BFCL's own OpenAI-compatible entries are.
- **`task bench:compare`** runs speed, native, quality and tools into one run folder. `RESUME=<run>` carries on a stopped one, skipping every engine and model, or round, that's already complete.
- **`task bench:report`** writes `docs/benchmarks/<date>/` from a compare run and a smoke run:
  - `README.md` with tables and SVG charts (light and dark), `summary.json` for the website, and `raw/` with the results files and `fairness.toml`
  - speed as medians across rounds, with the native curve beside each lane
  - accuracies with 95% Wilson intervals
  - a generated "Where Quail is slower or worse" list, using ADR-0063's rules: more than 5% and more than the spread between rounds for speed, and an exact McNemar test (p < 0.05) on the same items for quality and tool calling
  - the smoke test's findings as caveats
- **Found by the first dry runs:** on both Macs, llama.cpp b11081 barely gains throughput from batching Qwen3 8B.
  - `llama-batched-bench` on the Mac mini: 46 tokens/s generated with one sequence, 59 with two, and 51 with eight.
  - Quail's GGUF engine and llama-server follow the same curve.
  - `mlx_lm.benchmark` on the same Mac scales from 53 to 126 tokens/s at four sequences.
  - The report shows the native curves beside the servers', so a server isn't blamed for its engine.

**Amended 2026-09-29 (the first run, and how it's published):**
- **The first run** is `docs/benchmarks/2026-09-29/`: night budget, M1 Max laptop, Quail 0.58.1.
  - **GGUF lane:** Quail is level with llama-server and Ollama, except on 4,096-token prompts.
  - **MLX lane:** Quail is behind oMLX and Rapid-MLX on four counts:
    - Gemma 4 isn't batched;
    - new prompts stall decoding;
    - Qwen3.6 is slower on a single request;
    - the memory footprint keeps growing.
  - **Quality and tool calling:** no significant difference.
  - **Issues:** #137–#141.
- **Published in the repo now; on the website after the fixes.** The owner chose this.
  - `website/compare.html` keeps its "results coming" note until the fixes are released and the comparison is run again.
  - The first report stays in the repo as history.
- **The report gained a hand-written part:** `bench/config/notes/<date>.toml`, read by default or given with `NOTES=`.
  - `found` is the summary at the top, in plain statements, including the losses and links to their issues.
  - `caveats` adds what the run can't see by itself. Examples: a chat-template difference between engines; the kernels an engine switches on as it loads a model; which speed-ups were off.
  - The numbers in the notes are the report's own.
- **Other report changes:**
  - **"Where Quail is slower or worse"** is now a table per model and lane: a row per level, a column per metric, and each cell naming the engines ahead and by how much. The first run's 59 findings didn't read as a list.
  - **Caveats also come from the engines' own logs.** For example, Ollama's "model architecture does not currently support parallel requests" means it served that model one request at a time.
  - **"Reproducing it"** names the run and smoke folders, the harness commit and the Quail version, the prerequisites, and what the budget does.

**Amended 2026-09-30 (the second run):** `docs/benchmarks/2026-09-30/`, on the same M1 Max, after the fixes for #137–#141.
- **How it was run:** the GGUF lane and every engine's quality and tool calling ran overnight with Quail 0.61.6. The MLX fixes (0.61.7 and 0.62.0, MLX 0.32.2) landed while it ran, so the MLX lane's speed was measured again that afternoon, for all four MLX engines in one session, and Quail MLX's quality and tool calling with it. The run folder is a copy of the night run with the MLX lane's rows replaced; the versions table gives each engine's version.
- **Found:**
  - **GGUF:** level with llama-server, long prompts included.
  - **MLX:** Quail's first token is the fastest of the three with 4 and 8 requests at once, and on 4,096-token Qwen3.6 prompts. Rapid-MLX makes 10–20% more tokens a second with 2 to 8 at once, and is 7–10% faster alone on Qwen3.6 and Gemma 4.
  - **Quality:** Gemma 4 scores a few points lower on Quail on both lanes, in both runs (#152). The other models show no significant difference.
- **The website** gets these results through PR #131, after the owner has seen the page.

**Amended 2026-10-03 (Nativ, and three more rows):** the feature table adds Nativ 0.3.11 (Blaizzy/nativ, a SwiftUI app around the Python `mlx-vlm` server).
- **Sources:** each Nativ cell links its repo at tag `v0.3.11`, or, where the behaviour is `mlx-vlm`'s, `mlx-vlm` at `v0.7.4`. Nativ asks for `mlx-vlm>=0.7.0`, and 0.7.4 reached PyPI a minute before Nativ 0.3.11's release build started.
- **New rows,** for all five projects at the pinned versions: Image generation, Speech (transcription and speech), and MCP. They are where Nativ, oMLX and Rapid-MLX are ahead of Quail. Quail's cells link the issues that plan each one (#182–#186).
- **Not measured:** Nativ isn't in either lane yet (#188), and the page says so.
