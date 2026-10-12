# ADR-0055: MLX engine performance: catch up to mlx-swift-lm `main`, then per-conversation caching, before batching

**Date:** 2026-09-27 · **Status:** Accepted

**Situation:** Reviewed oMLX and Rapid-MLX in depth (both deferred, ADR-0027) to see what performance work they actually do on top of stock MLX. Neither forks MLX core or `mlx-lm`; both pin stock versions and build orchestration above them, plus a handful of model-family-specific Metal kernels reached through `mx.fast.metal_kernel`, not a patched MLX. Verified in their source: continuous batching on `mlx-lm`'s own `BatchGenerator`; a block-hashed prefix cache (despite the "paged" name, this is storage and hashing around `mlx-lm`'s ordinary contiguous `KVCache`, not GPU paged attention); an SSD tier for that cache (safetensors, survives restarts); MTP and prompt-lookup speculative decoding; a wired-memory and buffer-cache limit set at startup; and narrow wins — a fused sampler (Rapid-MLX claims ~4.3ms/token removed), fused MoE gate+up (+7%), and compiled decode for specific models. `MLXEngine` (ADR-0044) today has none of the orchestration layer: it serves one request at a time (`concurrentRequests: false`), keeps exactly one prompt-prefix cache for the whole server (`ReusableCache` — a second conversation evicts the first's, so agent + chat-page use thrashes it), sets no wired-memory or MLX cache limit, and `SeededSampler` sorts the full vocabulary for top-p/min-p/top-k on every token even at request defaults (temperature 0.8, top-k 40, top-p 0.95, min-p 0.05 — all three run). `mlx-swift-lm` is pinned to 3.31.3 (`project.yml`); 3.31.4 and `main` already carry MTP speculative decoding, compiled decode for Qwen3.5/3.6, `TurboQuantKVCache`, and prompt-cache saves that include SSM/hybrid-model state.

**Decision:** Close the gap in Swift, on `mlx-swift-lm`'s public API only — no custom Metal, no MLX core fork — in the order in IMPLEMENTATION_PLAN.md's new Phase 3c: extend the benchmark first so every later step has a number to move, then the mlx-swift-lm pin bump, the sampler fast-path, a wired-memory policy, a small per-conversation cache LRU (replacing the single `ReusableCache`) with an optional disk tier, prompt-lookup speculation, opt-in `kvBits`, and continuous batching last, ported from `mlx-lm`'s `BatchGenerator` shape (or mlx-swift-lm's closed PR #263) to bring `concurrentRequests` to MLX the way ADR-0048 already brought it to GGUF. oMLX and Rapid-MLX stay deferred (ADR-0027): this is the work "a real speed gap" would be measured against before reconsidering a Python runtime, and it avoids a Python runtime's packaging and update cost (ADR-0027) while the gap is still unmeasured.

**Alternatives:** Install oMLX or Rapid-MLX now (Apache-2.0, but a Python/uv runtime to install, pin and update; rejected before our own ceiling is measured); wait for Apple to land batching in mlx-swift-lm itself (PR #263 measured 2.3× at four concurrent requests but was closed unmerged, no ETA); vendor one of oMLX's or Rapid-MLX's Metal kernels directly (each is tied to one model family — Qwen3.5/3.6 GatedDeltaNet, DeepSeek sparse attention — and one exact `mlx-lm`/`mlx-swift-lm` version, a maintenance cost both projects visibly carry themselves).

**Amended 2026-09-27 (step 2, mlx-swift-lm 3.31.4):** bumped from 3.31.3; `main` (153 commits ahead) was passed over, since its own release notes warn it needs a newer swift-tools-version. What 3.31.4 actually brings for us: Gemma 4's `prepare` now chunks its prompt (it never did), fused MoE gate+up, and Qwen3.5-family recurrent state in float32 to match Python's mlx-lm. Its MTP speculative decoding is Gemma 4 only, and it has no compiled Qwen3.5 decode or TurboQuant; those remain upstream work. It also moves swift-syntax (a build-time macro dependency, not shipped) from 600 to 603. `MLXEngine`'s own prefill loop now queues each slice with `asyncEval` and waits only for the slice before it, as 3.31.4's prefill does (one slice in flight, so a hang-up is still noticed within a slice or two). **Measured**, Release builds on a Mac mini (M4 Pro, 64 GB), one server at a time, the machine cooled to nominal and macOS's media, photo and Spotlight analysis paused, medians alternating builds A-B-A-B:
- Gemma 4 26B-A4B: prompt 774 against 630 tokens/s at 512 tokens, 718 against 547 at 4,096 (+23% and +31%); generation 78 against 77.
- Qwen3.6 35B-A3B: prompt unchanged (700–779 either way); generation **4% slower**, 84–88 against 90–92 tokens/s. This is the price of the float32 recurrent state, a correctness fix, so we take it.
- Qwen3-8B: unchanged (54 tokens/s generation, 404–412 prompt).
- The prefill pipelining showed no measurable difference on these models, because MLX already overlaps most of the work. It is kept because it matches upstream and costs nothing.

**Amended 2026-09-27 (steps 3, 4 and 5):**
- **Prompt caches per conversation (step 5, in memory; the disk tier is still to do).** `MLXEngine` keeps up to four prompt caches, within an eighth of the Mac's memory beyond the newest, least recently used out first, instead of the one `ReusableCache`. Which one a prompt reuses, and how much, is `PromptCachePlan` (in `QuailServerCore`, unit-tested, since the engine itself has no test target). A cache is passed over if the prompt would use less than half of it, as llama-server's `--slot-prompt-similarity 0.5` does, so a second conversation that shares a system prompt's first few tokens doesn't destroy the first's cache.
- **Hybrid models reuse their cache (new; the plan hadn't seen that they couldn't).** Qwen3.5-family models (Qwen3.6, Qwen3.8) have recurrent layers that can't be cut back, so before this every turn re-read the whole prompt. Two further bugs hid it: the old code read the prefix length from the first layer, which on these models is a recurrent one with no offset; and it required every layer to be trimmable.
  - Prefill now copies those layers every 4,096 tokens and 64 tokens short of the prompt's end. The copies are references, since the model replaces the arrays rather than writing into them; about 60 MB each on Qwen3.6 35B-A3B.
  - The end copy is placed before the chat template's generation header, which the next turn's history renders differently, and far enough back to cover the repetition penalty's window.
  - A later prompt resumes from the last copy before the point where it diverges.
  - Sliding-window layers are treated the same way. A vision-only load (Gemma 4 26B-A4B) reuses only a cache it can trim, as before.
- **Sampling (step 3).** With top-k on (the default), all three filters run on the top k instead of sorting the whole vocabulary. The kept set is provably the same; only the random draw's shape changes, so a seed gives different text than before (still repeatable). No `MLX.compile`.
- **Wired weights (step 4).** Each request holds a `WiredMemoryTicket` for the weights' size (`WiredSumPolicy`), as mlx-lm's `set_wired_limit` does. There's no effect to measure on an idle 64 GB Mac; it matters under memory pressure. The cache limit is left alone.

**Measured** (same machine and method as step 2):
- **Two interleaved conversations** of about 2,800 tokens, three turns each (a scratch script, not step 1's in-app benchmark, which is still to do). A returning turn's prompt took **201 ms instead of 7,081** on Qwen3-8B, and **294 ms instead of 3,750** on Qwen3.6 35B-A3B.
- **Claude Code's own requests,** replayed (15,300-token turns on Qwen3.6): **1.6–1.7 s per turn instead of 25.7**, once its late system messages stop rewriting the start of the prompt (ADR-0041 amendment of the same day). Its 28,000-token permission check reused 24,576 tokens of the previous one's.
- **Sampled generation** (top-k 40, top-p 0.95, min-p 0.05): 86.0 against 83.3 tokens/s on Qwen3.6, 51.5 against 50.6 on Qwen3-8B. Greedy is unchanged.
- **Correctness:**
  - A code word planted at three depths of a 12,500-token log was recalled correctly on every cached turn, on Qwen3.6 and Qwen3.8.
  - Cached and uncached replies at temperature 0 were identical on Qwen3-8B (6 of 6 turns).
  - On Qwen3.6 they were identical for 3 of 6 turns and then diverged mid-reply into equally sensible text. The recurrent layers' chunked scan rounds differently when the prompt is split at other points, the same kind of difference ADR-0043 records for llama.cpp's cached and uncached runs.

**Amended 2026-09-27 (Gemma 4, and a cost found on the way):**
- **Gemma 4's vision-only load now reuses its prompt caches.** mlx-swift-lm 3.31.4's text-only Gemma 4 still lacks 26B-A4B's experts, so that model only ever loads its vision half. Its vision model reads a text prompt as the text model does, positions from the cache (`gemma4PrepareTextOnly`), so its prompt is now fed in slices, and its sliding-window layers are checkpointed like a hybrid model's. Qwen3.5's vision model keeps position state that only `prepare` resets, so it stays fed whole, as before. On two interleaved 2,700-token conversations, a returning turn's prompt took **405 ms instead of 6,218** (3.31.3) or 4,098 (3.31.4). The code word was recalled on 5 of 5 cached turns, and cached replies matched uncached ones on 5 of 6 turns (the sixth changed one word, "provided" for "available").
- **Stopping short of the prompt's end costs a forward pass.** On a 512-token prompt that is 15% of Gemma 4's prompt time, so the checkpoint split happens only for a request that asks for caching (`cache_prompt`, on by default for chat). The benchmark (`cache_prompt: false`) is unaffected; Qwen3.6's 512-token prompt was within noise either way.
- **Two prefill slices in flight** instead of one. With one, Gemma 4's 4,096-token prompt ran 3–5% behind the library's own fully pipelined prefill; with two it's within noise (719–747 against 717–767 tokens/s; Qwen3-8B 410–418 against 402–415). A hang-up during a 20,000-token prompt still frees the model at once: the next request took 0.23–0.29 s on Qwen3.6 and Gemma 4.

**Amended 2026-09-28 (step 5's disk tier, and step 6):**
- **Prompt caches on disk.**
  - When a cache leaves memory (evicted from the four, or all of them when the model unloads: a swap under `--models-max 1`, or the server stopping), `quail-server` writes it with mlx-swift-lm's `savePromptCache` (recurrent state included), with a JSON file of its tokens beside it.
  - A later prompt loads one back when it holds clearly more than anything in memory (by at least `checkpointMargin` tokens). A hybrid model's cache is written as it was at its last checkpoint, where the next turn picks up.
  - Location: `~/Library/Caches/com.datoos.quail/PromptCache`, one folder per model and load kind, keyed by its path, weight size and `config.json` date, so a changed model starts afresh. The folder is macOS's to clear, which costs only speed. `--prompt-cache-dir` moves it and `--no-prompt-cache-disk` turns it off.
  - Oldest out first, within 20 GB and a tenth of the free space.
  - **Measured:** a 14,000-token conversation, the server restarted between turns. The next turn took **1.0 s instead of 39 s** on Qwen3-8B, **3.0 s instead of 21.6 s** on Qwen3.6 35B-A3B and **3.2 s instead of 24.4 s** on Gemma 4 26B-A4B (model load included), and the code word planted mid-log came back right. A cache file is 0.36 GB (Qwen3.6), 0.59 GB (Gemma 4) or 2.0 GB (Qwen3-8B, all-attention) for 14,000 tokens.
- **Prompt-lookup speculative decoding (step 6).**
  - Our own decode loop, used when the load can be fed in pieces and no penalty processor is on (they'd have to see each guess in order). When the text so far ends with 3–4 tokens seen before (`PromptLookup`, in `QuailServerCore`, unit-tested), a step feeds the last token and what followed them then, up to 16 tokens, in one forward pass.
  - Greedy keeps the guesses the model agrees with. Sampling keeps each with the model's probability for it and redraws the first rejected one from what's left (standard speculative sampling, with our seeded state).
  - Unkept tokens are cut from the cache. Layers that can't be cut back are restored from a reference copy taken before the step, and the kept tokens are fed again.
  - Between guesses the loop runs pipelined, as mlx-swift-lm's iterator does, looking up as it goes and stopping to guess only when something recurs. A wholly wrong guess pauses looking for 8 tokens, doubling to 256. The guess length grows while guesses are kept and shrinks when they aren't.
  - The first cut regressed prose by 19–26% (a synchronous step per token, and 2-token matches that were mostly wrong); the pipelined, 3-token version is within noise.
  - Timings report llama-server's `draft_n` and `draft_n_accepted`. A request can cap or turn off guessing with llama-server's `speculative.n_max`, and the benchmark sends 0, because its repetitive text would otherwise measure the guessing instead of the model: 112 against 53 tokens/s on Qwen3-8B. `QUAIL_PROMPT_LOOKUP=0` turns it off server-wide, for comparison.
  - **Measured** (700-token replies, cooled, A-B-A-B, on against off):

    | Task | Qwen3-8B | Qwen3.6 35B-A3B | Gemma 4 26B-A4B |
    |---|---|---|---|
    | Rewrite a file with a rename | **149 against 49 (3.0×)** | **237 against 84 (2.8×)** | **126 against 71 (1.8×)** |
    | Summary | 48.7–48.9 against 49.9 | 83 against 84–85 | 70.5 against 70.2 |
    | Story | 52.1–52.3 against 52.2–52.5 | 83 against 85–86 | 75.6 against 75.0 |

  - Prose is within 1–3%. The hybrid model's 2–3% comes from its occasional wrong guess costing a re-feed.
  - Greedy text with guessing matches the same loop without it. It differs from the library's iterator path from mid-reply on, because the prompt's tail is split differently (the rounding difference noted above).
  - A real `claude -p` task on Qwen3.6 took 99 s, against 129–218 s before this and the late-system-message fix.

**Amended 2026-09-28 (draft-model speculation, tried and not shipped):** a small model of the same family drafting for a large one, named by a `model-draft` preset (llama-server's key).
- It was built into the same decode loop, drafting only when prompt lookup found nothing. The draft model kept its own cache between requests and checked that its tokenizer matched the target's.
- Measured with Qwen3-0.6B (MLX 4-bit) drafting for Qwen3-8B (MLX 4-bit), on the same prompts as step 6 and on a cooled machine:
  - The draft model's guesses were kept only 34% of the time (21 of 61 on the summary, 40 of 124 on the story).
  - Prose ran 30–33 tokens/s against 33–34 without it, and file rewriting was no faster, since lookup already covers it.
  - Every guess costs a step of the small model plus a wider step of the large one, so at that rate it can't pay.
- The code stays on the unmerged branch `perf/mlx-draft-model`. Revisit with a better-matched draft, such as a distilled drafter or Gemma 4's MTP heads (mlx-swift-lm 3.31.4 has MTP for Gemma 4), or with measured acceptance above about 60%.
- The machine was also re-indexing Spotlight at the time, which slowed every run about a third alike; only the with/without comparison counts from this session.

**Amended 2026-09-29 (step 4's cache limit, #137):** MLX's buffer cache is now limited and cleared while serving.
- **The problem.** The first comparison (ADR-0063) found `quail-server`'s footprint growing with every conversation and never coming back down: Qwen3 8B reached 30 GB on the M1 Max, where oMLX peaked at 9 GB.
  - MLX keeps freed GPU buffers for reuse, by default up to about the whole of memory.
  - A batch drops large buffers of ever-different sizes: its caches as they grow by 256 columns, and as sequences join and leave.
  - The prompt caches weren't the cause: they're capped at four and an eighth of RAM.
- **What's done now** (`BufferCachePolicy` in QuailServerCore, with tests):
  - **A cache limit on load:** 2 GB, or a sixteenth of the GPU's working set on a Mac where that's less, and at least 512 MB.
  - **Clearing while serving:** every 512 decode steps, and 8 steps after a request ends. Not at once: oMLX saw kernel panics when it cleared the moment a request completed.
  - **Clearing when idle:** once the serving loop has nothing to run, after waiting for the GPU.
  - `GET /slots` reports the cache with the model's memory, since macOS charges it to the process.
  - `QUAIL_MLX_CLEAR_CACHE=0` restores MLX's defaults.
- **Measured** on the Mac mini (M4 Pro, 64 GB), Qwen3 8B, GuideLLM at the quick budget. Quail's own app was running alongside, so only memory counts from this session.

  | Buffer cache | Peak, 8 at once | Peak, 4,096-token prompt after it |
  |---|---:|---:|
  | MLX's default | 21.0 GB | 23.3 GB |
  | Rapid-MLX's rule (a quarter of the working set) | 16.0 GB | 9.4 GB |
  | 2 GB (chosen) | 11.0 GB | 9.0 GB |
  | 512 MB | 9.5 GB | 7.7 GB |

  Speed on the mini moved by more than the differences between settings from run to run, in both directions. The M1 Max run after the fixes (ADR-0063) is the speed check.
- **The harness** passes Quail's own switches (`QUAIL_*`, but not `QUAIL_BENCH_*`) through to its server, for A/B runs like these, and logs them when it starts it.

**Revisit if:** Phase 3c step 8's batching port needs more than the public `mlx-swift-lm` API exposes (paged attention on the GPU, specifically, needs a gather-SDPA kernel neither project's own comments claim to have solved cleanly), or a fresh cross-runtime benchmark (Phase 3 step 8/12) shows oMLX or Rapid-MLX still meaningfully ahead once steps 1–8 land — then ADR-0027's deferral is reopened with real numbers instead of an assumption.
