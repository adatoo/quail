# ADR-0056: Batched MLX decoding (Phase 3c step 8)

**Date:** 2026-09-28 · **Status:** Accepted

**Situation:** MLX serves one request at a time. `ModelContainer.perform` serialises them, and the router's lease lets one in. Four requests at once total about one request's speed: 51 against 52 tokens/s on Qwen3-8B, and 80 against 85 on Qwen3.6 35B-A3B (ADR-0004 amendment of 2026-09-28). GGUF decodes up to four together (ADR-0048). Agents make concurrent requests (Claude Code's permission check beside its turn, opencode's sub-agents), and so does the chat page next to an agent. Decode is bandwidth-bound, so a step over four sequences costs little more than a step over one. mlx-swift-lm's closed PR #263 measured 2.3× total at four on Gemma 4 26B-A4B.

**What mlx-swift-lm 3.31.4 already has** (checked in its source):
- Models take the attention mask and RoPE positions from the cache: `createAttentionMask(h:cache:)` delegates to `cache.makeMask`, and attention uses `cache.ropeOffset`, whose `RoPEOffset.batch(MLXArray)` case carries a position per sequence. Checked for Qwen3, Qwen3.5 (full-attention layers) and Gemma 4.
- The recurrent (GatedDeltaNet) layers' `ArraysCache` has `leftPadding`, `lengths`, `filter(batchIndices:)` and `extend(other:)`.
- The attention caches have no batched form: `KVCacheSimple` has one offset for the whole batch.

**Proposed design:**
1. **`BatchKVCache`** (in Quail, a `BaseKVCache` subclass) for attention layers.
   - Keys and values are `[B, heads, T, dim]`, left-padded so every sequence's latest token is in the same column.
   - It keeps a per-sequence left padding, and a `ropeOffset` of `.batch(offsets)`.
   - `makeMask` returns causal plus left padding for prefill, and the padding mask for one-token steps.
   - `filter(indices)` drops finished sequences. `extend(other)` adds a newly prefilled one, re-padding to the longer length.
   - `slice(index)` hands one sequence back as a `KVCacheSimple` for the prompt caches.
   - Sliding-window layers get the same treatment over `RotatingKVCache`'s ring, or batching stays off for them in the first cut.
2. **`MLXBatchScheduler`,** shaped like `LlamaScheduler` (ADR-0048), on the engine's own serial queue.
   - A request prefills alone, with today's code: cache reuse, checkpoints, the disk tier, slices and cancellation.
   - Then it joins the batch with `extend`.
   - Each step decodes one token for every active sequence (`[B, 1]`). Each row is sampled with its own `SeededSampler`, and its penalty processors see its own tokens.
   - A finished or cancelled sequence leaves with `filter`, and its cache goes back to `PromptCaches` through `slice`.
   - With one sequence active it runs today's single-sequence loop unchanged, speculation included; speculation is off while two or more are batched.
3. **Capability and gates.**
   - `EngineCapabilities.concurrentRequests = true` for MLX. The router then lets several requests in, as it does for GGUF.
   - Limit: `--parallel`, default 4, shared with GGUF.
   - Vision turns and grammar-constrained requests stay single, and queue as today.
   - Per-family enablement: on only for families verified to give batched output equal to single output (Qwen3, then Qwen3.5 and Gemma 4).
4. **Memory.** Left padding wastes cells up to the length difference between sequences. A sequence much longer than the rest (over 2× and over 8,000 tokens) runs alone rather than padding the others.

**How it will be checked:**
- At temperature 0, each batched reply equals the same request run alone, apart from rounding, with differences counted and read.
- The benchmark's four-at-once total at least 1.8× single on Qwen3-8B and Qwen3.6, and single-request speed unchanged within noise.
- A hang-up of one sequence leaves the others' text unchanged.
- A returning conversation still finds its cache after being batched.
- A stress run of 200 mixed requests with random hang-ups leaves nothing held.

**Size and order:** the largest item in Phase 3c, about 1,000–1,500 lines, in three PRs:
1. `BatchKVCache`, with tests on a small model comparing batched and single forward passes.
2. The scheduler and capability, behind a flag.
3. Enabled by default per verified family.

**Alternatives:**
- Several engine instances, each loading the model: memory times N.
- mlx-swift-lm's own batching: not in 3.31.4, and PR #263 was closed unmerged.
- Waiting for upstream.

**Revisit if:** a model family computes attention without `cache.makeMask` or `cache.ropeOffset` (it would need its own path), or upstream lands batched generation first (adopt it instead).

**Amended 2026-09-28 (built):** approved as designed and built, with these differences.
- **Where it lives.** Requests queue for one serving task per engine (`MLXQueue`, `MLXEngine.serve`); text requests on a load that feeds prompts in slices go through `MLXEngine.serveText`, and each request's state is an `MLXSequence`. `BatchKVCache` is as designed; a hybrid model's recurrent layers use mlx-swift-lm's `MambaCache` batching (`extend`, `filter`) unchanged. `BatchedLayers` merges, extends, filters and slices a model's caches.
- **Prompts are still fed alone, but between the others' steps:** one slice (512 tokens) of the newcomer's prompt, then one token for everyone already decoding, so a 4,400-token prompt arriving mid-reply slows the others instead of stopping them. One newcomer is fed at a time. With nothing else in progress a request runs exactly the old path: pipelined slices, then decoding alone with prompt-lookup speculation. It hands over to the batch when another request can join, and a sequence left alone goes back to it.
- **Memory rule, by bytes instead of lengths:** a request waits if the padding it would add to the batch costs more than a quarter of the model's weights to read each step.
- **Scope.** Gemma 4 still serves one at a time (batched since 2026-09-29, amendment below). Its sliding-window layers have no batched cache yet. Its vision model, which is how Gemma 4 26B-A4B loads, also takes positions from `cache.offset` rather than `ropeOffset`: that is the "Revisit if" case below, so batching it needs a change upstream as well. Batching is on for `model_type` qwen3, qwen3_5 and qwen3_5_moe. `QUAIL_MLX_BATCH=0` turns it off; `=1` turns it on for any model whose caches can batch. Images and whole-prompt vision loads queue as before.
- **One decode loop.** Penalty processors run per row. mlx-swift-lm's `TokenIterator` is now used only for image turns and the text turns of vision loads other than Gemma 4's. `QUAIL_PROMPT_LOOKUP=0` now means the same loop without guessing, as `nodraft` did.

**Measured** on the M4 Pro Mac mini, Release builds, cooled A-B-A-B, four and two greedy requests of 128 tokens each (tokens a second, total):

| | Alone | Four at once, before | Four at once, now | Two at once, now |
|---|---|---|---|---|
| Qwen3-8B 4-bit | 54 | 52 | 95–99 (1.84–1.92×) | 85–90 |
| Qwen3.6 35B-A3B 4-bit | 86 | 81 | 132 (1.63×) | 105 |
| Qwen3.8 27B 4-bit | 15 | – | 27 | – |

- **The 1.8× target** was met on Qwen3-8B but not on Qwen3.6. A step's time on Qwen3.6 is 11.7 ms alone and grows by 4.8 ms for each extra sequence (profiled: all of it waiting on the GPU, not graph building). Below about ten rows, MLX's quantized matmul (`qmv`) reads the weights once per row, and a mixture-of-experts model sends each row to different experts. Getting past that needs kernel work, which ADR-0055 rules out.
- **Single requests are unchanged:** same speed and byte-identical text, including speculation, against 0.43.2 (edit, summary and story tasks, greedy and sampled). A real Claude Code task on Qwen3.6 took 102 s, against 101 s.
- **Output at temperature 0.** Each batched reply matched its solo run for a first stretch; then one to three of four replies took a different word, all still coherent. Batched steps use MLX's array-offset RoPE and masked attention, whose rounding differs slightly from the single-sequence paths, so a near-tie can flip, and expert routing makes that likelier. Rows of very different lengths (26 and 4,399 tokens) stayed correct side by side.
- **Checked on Qwen3-8B and Qwen3.6:**
  - staggered joins, including a long prompt fed between the others' steps;
  - a returning conversation after batching reused 4,395 and 4,615 of its tokens;
  - a hang-up left the others running to their full length;
  - penalties and one-token replies inside a batch;
  - 200 mixed requests, six at a time with a fifth hung up: no errors, and the server healthy afterwards;
  - an image turn among text requests kept its place in the queue;
  - Gemma 4 unchanged.
- **Not done:** reading several short prompts in one pass, batching sliding-window layers (Gemma 4), and speculation while batched.

**Amended 2026-09-29 (Gemma 4 batches, #140):** Gemma 4 26B-A4B is now decoded in a batch like the Qwen families. Before, eight requests at once waited in line: 41 s to the first token on the M1 Max in the first comparison (ADR-0063), where oMLX took 3 s.
- **Quail's own Gemma 4 language model** (`QuailServer/MLX/Models/Gemma4Text.swift`, ADR-0066):
  - It's copied from mlx-swift-lm's vision model, so it has the mixture-of-experts layers the library's text-only Gemma 4 lacks.
  - Its attention takes positions from the cache's `ropeOffset`.
  - It's registered for `model_type` gemma4. Text turns now load it instead of the vision model, and image turns still swap to the vision model.
  - A text-only load that fails still falls back to the vision model, and now says why on stderr.
  - Alone, it gives the same text as the vision model did, and is a little faster: 13.5 against 14.5 ms a token on the mini.
- **`BatchSlidingKVCache`** holds a sliding-window layer's cache for the batch:
  - Rows are left-padded and right-aligned, as in `BatchKVCache`.
  - Only the window is kept. Columns stay in order, and the oldest are dropped 256 at a time.
  - Each sequence keeps its own position.
  - A rotating cache joins in time order, and a finished row leaves as a rotating cache again.
- **The gate:**
  - `gemma4` is added to the batched families.
  - A Gemma 4 whose later layers share earlier layers' keys and values (E2B, E4B) isn't batched yet: that path hasn't been checked.
- **Checked** on Gemma 4 26B-A4B (4-bit) on the Mac mini:
  - **Four at once, staggered:** each reply matched its solo run for a first stretch, and two of four copies of one prompt matched it to the end. Some then took a different word, all still coherent, as ADR-0056 found for Qwen.
  - **A code word** at the start of a 3,000-token prompt was recalled while three other requests were decoding beside it. That prompt is well past the 1,024-token window, so it depends on the full-attention layers.
- **Measured** on the Mac mini, GuideLLM at the quick budget. The owner's own Quail was running alongside.

  | Requests at once | Before: tokens/s, first token | Now: tokens/s, first token |
  |---|---|---|
  | 1 | 54.5, 1.0 s | 59.0, 0.8 s |
  | 4 | 55.1, 13.7 s | 82.0, 1.8 s |
  | 8 | 45.5, 38.9 s | 88.7, 2.2 s |

  - **Two at once was slower in total** (48.9 against 58.8 tokens/s), though its first token came sooner (2.3 against 5.1 s). Each row sends its tokens to different experts, so two rows read about twice the expert weights: 31 ms a step against 13.5 ms alone.
  - **Peak memory at eight at once was 23.9 GB, against 16.9 GB,** for eight sequences' caches.

**Amended 2026-09-29 (where the time goes with eight at once, #139):**
- **A trace of the serving loop.** `QUAIL_MLX_TRACE=<file>` writes one JSON line per slice, first token, join, step and solo decode, each with its wall time and batch size. It's for tuning; nothing reads it otherwise.
- **Eight streams of 512-token prompts and 256-token replies**, on the M1 Max:

  | Model | Steps at eight | Their share of the time | Native mlx-lm step at eight | Reading each newcomer | Its share |
  |---|---:|---:|---:|---:|---:|
  | Qwen3 8B | 141 ms | 70% | 124 ms | 1.7 s | 30% |
  | Qwen3.6 35B-A3B | 72 ms | 63% | 61 ms | 1.1 s | 23% |
  | Gemma 4 26B-A4B | 97 ms | 66% | 79 ms | 1.2 s | 21% |

- **Reading the steps and the newcomers:**
  - **The steps take 13–24% longer than mlx-lm's own batched step.** Building a step's graph takes about 1 ms of CPU; the rest is waiting on the GPU. So the gap is in the GPU work Quail asks for, not in Swift. Two leads to profile: a cache update that can't write in place while the step before it is still pending, and sampling one row at a time.
  - **Reading prompts together wouldn't help much here.** mlx-lm reads 512-token prompts at 318–331 tokens/s on Qwen3 8B whether one or eight at a time. Mixture-of-experts models gain more (Qwen3.6: 504 → 670 tokens/s). But newcomers arrive about one at a time once a batch is running, so a wave would mean holding requests back. Rapid-MLX does hold them back: 10.6 s to first token at eight at once, against Quail's 3.6 s.
- **Changed: a prompt read with nothing else in progress goes in 2,048-token slices,** as mlx-lm reads it, instead of 512. The larger slices stop at 8,192 tokens. Past that, a slice's attention scores (Qwen3.5 and Gemma 4 heads are too wide for MLX's fused prefill kernel) would pass a gigabyte, so it's 512 again. A newcomer read between the others' steps stays at 512, so it holds them up less at a time.
- **Measured** on the M1 Max, a 4,096-token prompt, cooled before each, two runs of three:

  | Model | 512-token slices | 2,048-token slices |
  |---|---:|---:|
  | Qwen3.6 35B-A3B | 8.3 s | 7.0 s |
  | Gemma 4 26B-A4B | 9.1–9.9 s | 8.4–8.6 s |
  | Qwen3 8B | 13.6 s | 13.4 s |

  The Qwen3 8B runs varied by more than the difference between them.
