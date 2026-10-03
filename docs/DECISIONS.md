# Quail — Decision Records

Short ADRs. Newest first. Each states the decision, the alternatives, and what would make us revisit it.

## D-072 · 2026-10-03 · Models that don't chat: a task for every model, narrowing D-001

**Decision:** Quail serves models that don't chat, through standard APIs, and the app only downloads and manages them. D-001 ("no chat, agent, image or audio UI") becomes "no chat, agent, image or audio *UI* in the app"; serving those models is in scope. The first are embedding and reranking models (`/v1/embeddings`, `/v1/rerank`; #181), then speech and images (#179). AGENTS.md and ARCHITECTURE §1 say the same.

Every model now has a **task**: `chat`, `embedding` or `rerank`.
- **Where it comes from:** the catalog family a model was downloaded as (`task`, plus `pooling` when the model's header doesn't say it). Otherwise from the model itself, read at each store refresh:
  - A GGUF's `<arch>.pooling_type` gives 1 mean, 2 CLS or 3 last for an embedding model, and 4 rank for a reranker. `<arch>.classifier.output_labels` means a reranker. `<arch>.attention.causal = false` means an encoder, so an embedding model. Checked on the headers of Qwen3-Embedding 0.6B, EmbeddingGemma 300M, nomic-embed v1.5, bge-m3 and Qwen3-Reranker 0.6B. gpustack's bge-reranker-v2-m3 has neither key, so the catalog must name its task.
  - An MLX folder's sentence-transformers files (`modules.json`, `config_sentence_transformers.json`, `1_Pooling/`), an encoder-only `model_type` (BERT and its kin), or a `…ForSequenceClassification` architecture for a reranker.
- **How the server learns it:** from `presets.ini`, in **llama-server's own keys**: `embeddings = true`, `reranking = true` and `pooling = …`. llama-server b11306's router accepts them and starts that model's instance with `--embeddings --pooling mean` (checked), so llama-server serves a GGUF embedding model's `/v1/embeddings` from the same presets. `quail-server` reads the same keys, and for an MLX folder without a preset it detects the task from the files, the same rule the app uses.
- **What it changes:**
  - Only a chat model can be the default model, be pinged, be benchmarked, or be offered in Connect and the chat page.
  - A chat route (`/v1/chat/completions`, `/v1/completions`, `/v1/messages`, `/v1/responses`) refuses another task's model with a 400 that names the route serving it.
  - `/v1/models` adds `task` and gives `output_modalities` of `embedding` or `score`.
  - The Models pane badges the task, and Add Model lists these models in a section of their own.
  - Recommendations stay chat-only.

**Why:** Nativ (#179) and Ollama, oMLX and Rapid-MLX serve embeddings; Quail didn't, so RAG tools, editors' codebase indexing and memory tools couldn't use it. The catalog already had nomic-embed, but nothing could serve it: Quail would download a model it then couldn't use. Serving a model through an API keeps D-001's reason intact, that the desktop apps are bloated by trying to be everything in their UI.

**Alternatives:**
- **A `task =` preset key of Quail's own:** llama-server refuses a key it doesn't know ("option not recognized in preset"), so the presets would differ by runtime. Its own keys work for both.
- **Reading the GGUF header inside `quail-server` too:** that needs a second header parser in the server. The app writes the presets, and a model placed by hand for `quail-server` alone gets a preset line, as llama-server needs.
- **Deciding the task from `role`:** that's a display string, and the server never sees it.

**Revisit if:** a model of one task needs another (an embedding model that also chats), or speech and image models need a field the presets can't carry.

**Amended 2026-10-03 (serving them, #181):** `quail-server` serves `/v1/embeddings` and `/v1/rerank` (also at `/rerank`, `/v1/reranking` and `/reranking`) for both formats, through an `EmbeddingEngine` beside the chat engines. `main.swift` picks it by the model's task.
- **GGUF (`LlamaEmbeddingEngine`):**
  - libllama's embedding mode, as llama-server's `--embeddings` and `--reranking` use it, with the preset's pooling or the model's own.
  - Inputs are packed into as few forward passes as fit, each input its own sequence, and read back with `llama_get_embeddings_seq`.
  - One pass holds a whole input (`n_ubatch` = `n_batch` = the context, 8,192 tokens unless the preset says), because an encoder can't split one. An input longer than that is a 400.
  - A reranker joins query and document as llama-server does: the GGUF's own `rerank` template, or else `[BOS] query [EOS] [SEP] document [EOS]`. Its score is the ranking head's first output, unscaled.
- **MLX (`MLXEmbeddingEngine`):**
  - mlx-swift-lm's `MLXEmbedders` and `MLXRerankers` products, from the release already pinned, so there's no new package.
  - Inputs run one at a time, with no padding, because padding needs a mask every family reads the same way.
  - A model that pools itself (EmbeddingGemma) gives its own vector.
  - MLX downloads are flat, so `1_Pooling/config.json` isn't fetched. The catalog's `pooling` covers the families that need one.
- **Shapes and defaults are llama-server's:**
  - OpenAI's embeddings response. Vectors are L2-normalized unless `embd_normalize: -1`. `encoding_format: base64` sends float32 bytes. `dimensions` cuts the vector and normalizes it again.
  - Rerank answers in Jina's shape (`relevance_score`, best first, `top_n`), or as TEI's bare array when sent `texts`.
- **Checked:** against llama-server b11306 on the same GGUF files, the vectors were the same to a cosine of 1.0 (nomic-embed v1.5 Q4_0, Qwen3-Embedding 0.6B Q8_0), and the rerank scores agreed to 4e-4 (bge-reranker-v2-m3, Qwen3-Reranker 0.6B). On MLX, Qwen3-Embedding 0.6B at 8-bit matched the GGUF Q8_0 to a cosine of 0.9995; the `mxfp8` build only to 0.975, so the catalog offers the 8-bit one. Qwen3-Reranker 0.6B (MLX, 4-bit) ranked the same documents in the same order.
- **Catalog:** Qwen3 Embedding 0.6B and EmbeddingGemma 300M (GGUF and MLX), Qwen3 Reranker 0.6B (GGUF and MLX), and BGE Reranker v2 M3 (GGUF). Connect has Embeddings and Reranking entries with a Test button.

## D-065 · 2026-10-02 · `quail eval tools`: a quick check that tool calling works

**Decision:** `quail eval tools [model] [--url URL] [--api-key KEY] [--json]` sends 16 hand-written tool-calling requests (`ToolEval`, `Shared/ToolEval.swift`, suite `quail-tools-1`) to Quail's server, or to any OpenAI-compatible one with `--url`, and checks each reply:
- **Kinds:** five single calls (string, enum, integer, number, boolean and array arguments), three where the right tool must be chosen from six, two parallel calls of one tool, two calls of different tools, three where no tool fits (two must also answer correctly), and one answer from a tool's result.
- **Checking:** as BFCL's checker does it. The tool's name must match. Every expected argument must be present and of its schema's type: an integer as a JSON number with no fraction (`25.0` passes, `"25"` doesn't), and a boolean as `true` or `false`, not a string. Each value must be one of the accepted answers, ignoring case and surrounding spaces. A parameter the tool doesn't take fails. Expected calls are matched to returned ones in any order, each used once.
- **Requests:** non-streamed, `tool_choice` auto, temperature 0, seed 42 and 4,096 tokens, so a thinking model has room. Thinking is left as the server's default.
- **Nothing is saved;** `--json` prints every case with the calls and text that came back.

**Why:** the bugs D-070's BFCL run found are ones a user meets as "tool calls come back as text": gpt-oss's `<|call|>`, Llama 3.1's `<|python_tag|>` and `"10"` for an integer, and MiMo's JSON body. Finding those needed the bench Mac and Python. This finds the same kind of failure in about a minute, on any Mac, against any server, and says which case failed and why.

**Not a score:** 16 cases can't rank models; BFCL's 200 on the bench Mac do that (D-070). The cases are written for Quail, not taken from BFCL, so there's no dataset licence to carry and no overlap with what models may have been trained on.

**Checked** on the M4 Pro, quail-server 0.67.3:
- Qwen3.6 35B-A3B and Gemma 4 26B-A4B (GGUF) passed 16 of 16.
- Qwen3-0.6B passed 14. It answered in text where it should have started a timer, and called `get_weather` for a haiku.
- Under llama-server b11306, Qwen3.6 35B-A3B passed 15: it made one call where two different tools were asked for.

**Alternatives:** bundle BFCL's cases and checker (Python, AGENTS.md: no Python), or a subset of its JSON (its licence and notices to carry, for a check that doesn't need them).

**Revisit if:** a format family needs a case these don't exercise (a nested object argument, say), or a server needs a request field to call tools at all.

## D-064 · 2026-10-02 · `quail bench --url`: timing any server from the client

**Decision:** `quail bench --url URL [model] [--api-key KEY] [--json]` runs a speed benchmark against any server that speaks OpenAI's `/v1/chat/completions`, from the CLI process, with no app or control socket involved. It's a suite of its own, `quail-bench-url-1` (`URLBenchmarkSuite`, `Shared/URLBenchmark.swift`):
- **Tests:** `quail-bench-1`'s shape, so results read alike. Prompts of 512 and 4,096 tokens; 256 tokens generated; time to first token on the 512 prompt; a returning turn (2,048 tokens, then the same with 64 more, its cache allowed); four requests of 128 tokens at once. One warm-up and three measured runs each, with the median and range.
- **No load test:** only Quail and llama-server's router can be asked to load or unload a model.
- **Prompts are text,** from `quail-bench-1`'s passage (now `BenchmarkPassage`, shared, unchanged). Two calibration requests (one passage and four, at `max_tokens` 1) give the server's tokens per word and what its chat template adds, from `usage`, so each test asks for the words that come to its size. The size the server counted is reported with the result.
- **Timing is the client's:** prompt speed is the prompt's tokens over the time to the first token, which includes the request's trip and the first token, as GuideLLM measures it. Generation is the tokens after the first over the time from the first to the last. Token counts come from `usage` (`stream_options.include_usage`), or from streamed chunks with a note when a server sends none.
- **No prefix-cache hits:** every timed prompt starts with a tag of its own (`Request 7-1a2b3c4d:`). Only the returning turn shares a prefix, on purpose.
- **Requests** ask for `temperature` 0, `seed` 42 and `ignore_eos`. A server that ignores `ignore_eos` (Ollama, oMLX and Rapid-MLX, D-063's smoke test) and stops early gets a note; its speed is over what it wrote. A prompt the server refuses with a 4xx, usually longer than its context, is skipped with the server's reason.
- **Nothing is saved:** the result isn't a `BenchmarkResult` (no model file, no engine build), and isn't compared with `quail-bench-1`'s, whose prompts are token ids and whose timings are the server's own.

**Cross-checked** on the M4 Pro against GuideLLM 0.7.4 (the D-063 harness's tool) on quail-server 0.67.3 with Qwen3.6 35B-A3B (GGUF), alternating the two. The Mac was busy (load average about 25), so absolute numbers moved between runs.
- **Generation:** 51.9 and 53.1 tok/s, against GuideLLM's 54.3 and 51.4 (1000 / inter-token latency).
- **Time to first token,** 512-token prompt: 782 and 834 ms, against GuideLLM's 712 ms on its first run. Its later runs repeated the same synthetic prompts and hit the prefix cache (163–180 ms), which the tags avoid.
- The server's own `timings` for a 576-token prompt said 633 tok/s and 38.1 tok/s generation, against 655 and 38.0 from the client on a run a minute apart.

**Alternatives:**
- Run GuideLLM from the CLI: it needs Python and a tokenizer folder for the model, which Quail doesn't bundle (AGENTS.md: no Python).
- Make `quail-bench-1` itself work over any URL: its exact token-id prompts and server timings are what make it comparable across runs, and other servers offer neither.

**Revisit if:** a server streams `usage` in another shape, or a widely used one rejects `stream_options` or `ignore_eos`.

## D-071 · 2026-10-02 · The fit estimate counts each layer's cache

**Decision:** `FitEstimator` sums the KV cache over the layers that keep one, each at its own size, instead of `2 · L · H_kv · d · b · C` over every layer. `ModelShape.kvLayers` holds the groups of alike layers. It's `nil` for a model whose layers are all alike, which keeps the old formula and the same numbers.
- **GGUF**, from the keys libllama reads:
  - `attention.head_count_kv` per layer. Hybrids write 0 for a layer without attention; the first element was taken before, so Nemotron's cache counted as nothing.
  - `attention.sliding_window_pattern`, with `key_length_swa`/`value_length_swa` for those layers.
  - `full_attention_interval`: a Qwen3.5-family hybrid's linear-attention layers keep none.
  - `attention.shared_kv_layers`: layers that reuse an earlier one's cache keep none.
  - A sliding-window layer still holds the whole context: quail-server keeps libllama's full-size window cache (`swa_full`, D-048 amendment).
- **MLX**, from `config.json`:
  - `layer_types`, `sliding_window` and Gemma 3's `sliding_window_pattern`. A sliding-window layer holds at most its window, as mlx-swift-lm's and mlx-lm's rotating cache does. It stays at full precision under a quantized setting, since MLX doesn't quantize a rotating cache (D-057).
  - Gemma 4's `num_global_key_value_heads` and `global_head_dim`.
  - `full_attention_interval`, Nemotron H's `layers_block_type` or `hybrid_override_pattern`, and `num_kv_shared_layers`.
- The largest context that fits is found by halving the range, since a windowed layer's cost stops growing at its window.
- **Shapes cached from Hugging Face** carry a version (`ModelShapeCache.version`, now 2), so those cached before are read again.

**Why:** the estimate over-counted every catalog model that mixes layer types. Estimated against real KV per token:

| Models | GGUF | MLX |
|---|---|---|
| Gemma 4 (12B, 26B-A4B, 31B) | 2.2× | 12–24× |
| Qwen3.5 family (Qwen3.5, 3.6, 3.8, MiMo, Ornith, the 27B Bonsais) | 4× | 4× |
| gpt-oss, Muse Glimmer | exact | 2–4× |

Gemma 4 31B at 32K on MLX came to 32 GB of cache against about 2.7 GB. Qwen3.8 27B at 32K came to 8.6 GB against 2.1 GB, which decides the verdict on a 16–32 GB Mac. The error was always high, so nothing was let through that didn't fit. But Automatic picked smaller contexts than the Mac could hold, and verdicts said Tight where a model was Comfortable.

**Verified** from the growth of quail-server's dirty memory (`footprint`) with the context. On the M4 Pro (64 GB), with 0.67.0, between two sizes:
- Gemma 4 26B-A4B (GGUF), 8K to 32K: 225.3 KB a token, against 225,280 bytes from the new formula and 491,520 from the old.
- Qwen3.6 35B-A3B (GGUF), 32K to 128K: 20.48 KB a token, against 20,480 and 81,920.
- Gemma 4 31B (GGUF) on the bench M1 Max (64 GB, Metal ceiling 55.7 GB), quail-server 0.67.3, every slot given a 6,000-token prompt at once: 14 GiB (15.0 GB) at 16K over two slots and 28 GiB (30.1 GB) at 32K over four, as `footprint` rounds them, against 14.8 and 29.5 GB of cache from the new formula (the old one said 32 and 64 GB). Both ran. Four slots of 8K had run this Mac's GPU out of memory on 0.66.0 during the catalog scores (D-070 amendment); that no longer happens.

The MLX window cap is from mlx-swift-lm's `makeHybridAttentionKVCache` and Quail's own `Gemma4Text`, not measured.

**Not counted:** the linear-attention and Mamba layers' fixed state (about 250 MB for Qwen3.6 with four slots), and the compute buffers. Both are left to O. The 26B-A4B measurement put everything outside the cache at about 1.1 GB, under O's 1.5 GB. For Gemma 4 31B on the M1 Max, 32K is now Tight (49.4 GB of the 55.7 GB ceiling) rather than over it, and Automatic picks 16K, the largest under 70%.

**Alternatives:** count only full-attention layers (DECISIONS' MLX config note of 2026-09-26): simpler, but wrong for GGUF's full-size window cache and Gemma 4's different head sizes. Measure each model after loading (§7's calibration): still wanted, but the estimate has to be right before a download.

**Revisit if:** quail-server turns `swa_full` off (GGUF windowed layers would then hold their window, as MLX's do), or an architecture with another kind of layer arrives (MLA, as DeepSeek V3 writes `kv_lora_rank`).

## D-070 · 2026-10-01 · Helping people choose a model: release dates, model cards, and Arena's ratings

**Decision:** Each curated catalog family carries what helps someone choose it, all optional in the schema so older apps read the catalog unchanged:
- `released`, the day its maker made it public;
- `modelCard`, the maker's own Hugging Face repo, as opposed to the quantized one Quail downloads;
- `summary`, one line on what it's for and any quirk worth knowing;
- `supersededBy`, the id of a newer family from the same line;
- `arena`, its rating on Arena's text leaderboard.

The Add Model sheet shows these in a card (`ModelFactsCard`) under the model's name, a **New** badge on its row for 30 days after release, and the default pick's estimated speed on each row. The Models list shows the same card behind an ⓘ button on a row, and a **Newer: …** badge on a row whose family has a successor you haven't installed; it opens Add Model on that successor.

**Release dates are hand-entered, from the maker's announcement.** A Hugging Face repo's `createdAt` is when it was created, often weeks before it went public (Qwen3.8 27B: created 5 August, public 14 August; Granite 4.2: 7 and 25 August), and a quantized repo's dates are the quantizer's. Where a maker published no post, the date is from news coverage that agrees with the repo's own dates.

**The public ranking is Arena's text leaderboard with style control.** It was chosen on 2026-10-01 from these sources:
- **Artificial Analysis Intelligence Index:** a single 0–100 score covering 20 of the 32 chat models in the catalog, the most of any source. Its Data Platform Terms (v1.1, 2026-08-19) forbid showing the numbers in a product or reproducing them "in a structured, tabular, or machine-readable format", so it isn't used unless Artificial Analysis gives written permission.
- **Arena:** 11 of 32, a single comparable number with a confidence interval, published daily as `lmarena-ai/leaderboard-dataset` under CC BY 4.0.
- **Others:** Epoch's Capabilities Index covers 8 and LiveBench 1. Hugging Face's Open LLM Leaderboard was retired in 2025. Model cards' own eval results are self-reported and not comparable.

**How the rating is shown:**
- `rating ± interval · #rank of N`. The interval is half the 95% confidence interval, so two ratings within each other's ± are a tie (Granite 4.2 8B at 1288 and 3B at 1289).
- With the caveat that Arena rates the full-precision model (Nemotron 3.5's entry is its NVFP4 build), so a quantized download can do a little worse.
- With the credit CC BY 4.0 asks for: the source, © Arena, the date, links to the leaderboard, the dataset and the licence, and that the numbers are rounded.
- A family Arena doesn't list says "Not publicly ranked". It never borrows a base model's score: a fine-tune, a distill or a 1-bit or ternary Bonsai isn't the model it came from. Embedding and smoke-test models say nothing.

**Refreshing:** `scripts/update-arena-ratings` (`task catalog:arena`) reads the leaderboard through the Hub's dataset viewer API, so no parquet reader is needed. It rewrites only the `arena` lines, keeping the file's hand-made layout. A name the leaderboard drops is an error to fix by hand. The app picks up a refreshed `catalog.json` from `main` within a week (D-051), whether or not a release follows.

**Quail's own scores (amended 2026-10-01):** every chat model in the catalog is also tested by Quail, not only those Arena misses, so any two can be compared on one scale beside Arena's.
- **How:** `task bench:scores` runs the D-063 harness's quality and tool-calling steps on Quail's server, with `bench/config/catalog-models.toml` (every chat family at its default download; `QUAIL_BENCH_MODELS` picks the file). It uses the night budget: GSM8K 150, MMLU-Pro 8 per subject (112) and BFCL 40 per category (200).
- **Thinking off,** as in D-063: comparable across models and about a day's run, where letting each model think would take most of a week and put thinking and non-thinking answers on one scale. The user chose this. gpt-oss runs at its lowest reasoning effort, its template's nearest to off.
- **Not scored:** the DeepSeek R1 distills, which always think, so a 512-token answer limit would cut them off. They carry a note saying so instead. So do the smoke test and the embedding model.
- **Shown:** as "Maths · Knowledge · Tools" percentages, labelled as Quail's tests, with the method, the date and their margins: about ±5 points for maths and tools and ±9 for knowledge (95% intervals at these sample sizes; amended 2026-10-02 from ±4, which was one standard error). They are never blended with Arena's ratings.
- `scripts/update-quail-scores RUN` writes them into the catalog.

**Alternatives (amended 2026-10-02):** a scored family's card suggests up to three other catalog families (`ModelAlternatives`). Each has a **Show** button that opens it in Add Model. The Models list's ⓘ card shows them too, once Add Model has worked out the catalog's verdicts.
- **Candidates:** curated, scored, for the same kind of work (a coding model's alternatives have the coding strength), and Comfortable or Tight on this Mac. The family's own successor is left out, since the card shows it as Newer already.
- **Scores higher:** needs about the same memory: at most 1.25 times as much, or 2 GB more, whichever is larger, so a 1.5 GB model can step up. It must be ahead of the family on at least one test by more than that test's margin, and behind on none. The best total wins; on a tie, the one needing less memory.
- **Smaller:** needs at most three-quarters of the memory and is behind on no test by more than its margin. The smallest wins.
- **Faster:** has at least 1.5 times the estimated speed on this Mac and is behind on no test by more than its margin. The fastest wins.
- **Size is memory, not parameters:** this Mac's fit estimate at the default context. Parameters made a 1-bit 27B Bonsai, at 3.8 GB, look as big as a 4-bit 27B at 16 GB.
- Each family appears once. With parameters as size and no size limit on "scores higher", Gemma 4 31B was the "higher" pick for 24 of 28 families, down to a 1.7B, which helps no one.
- **Not used:** Arena's ratings (11 of 32 families). Mixing them in would make the comparison depend on which families Arena happens to list.

**Alternatives:**
- Artificial Analysis's index, pending permission.
- Filling gaps from other sources: their scales differ, and a mixed column reads as one.
- Hugging Face downloads and likes for curated models: they measure popularity, which would be read as quality.

**Revisit if:** Artificial Analysis grants permission; Arena changes its dataset's licence or shape; or Quail's own scores cover the catalog.

## D-069 · 2026-10-01 · The Bonsai models: which files, and which engine

**Situation:** PrismML's Bonsai models are Qwen3 and Qwen3.6 models trained to low-bit weights. They come in three kinds, each published for GGUF and MLX:
- **1-bit Bonsai** at 1.7B, 4B, 8B and 27B;
- **Ternary Bonsai** (weights of −1, 0 or +1) at the same sizes;
- **Bonsai 2 27B**, a ternary Qwen3.6 27B whose weights are stored in a Hadamard-rotated basis.

Add Model already listed three Ternary Bonsai MLX downloads, from Rapid-MLX's catalog (D-058). Several of the other files need runtime code that llama.cpp and mlx-swift-lm don't have yet.

**What runs where.** Checked on 2026-09-30 and 10-01 with llama.cpp b11081 and again with b11306, and with mlx-swift-lm 0dcfe2f8a (MLX 0.32.2):

| | GGUF | MLX |
|---|---|---|
| 1-bit | ✅ `Q1_0` | ❌ MLX refuses `bits: 1` (mlx#3161, open since February) |
| Ternary | ✅ the `Q2_0_g64` file (the 27B's is `Q2_g64`); ❌ PrismML's `Q2_0` and `PQ2_0` | ✅ affine 2-bit |
| Bonsai 2 | ❌ `PQ2_0`/`PTQ1_0` (llama.cpp #29600, open) | ❌ needs mlx-swift-lm #630 (open); ✅ with Quail's own copy of it |

**Decision:**
- **1-bit Bonsai: GGUF only.** MLX would need either a fork of MLX core, which D-055 rules out, or Quail's own 1-bit quantized matmul in Metal.
- **Ternary Bonsai: both formats, with the GGUF quant llama.cpp reads.**
  - llama.cpp's own `Q2_0` stores 64 weights a block. PrismML's file named `Q2_0` stores 128, their fork's format, so llama.cpp stops with "failed to read tensor data".
  - Their `Q2_0_g64` file is the upstream format.
- **Bonsai 2: MLX only,** through a third model copy (D-066 amendment): mlx-swift-lm PR #630's rotation, built on Quail's Qwen3.5 copy.
- **Strengths are what the checks showed, not what the base model can do.**
  - The 1.7B, 4B and 8B models have no thinking mode: their template closes the think block.
  - Both 4B models write a tool call without its opening `<tool_call>` tag, on llama-server as on quail-server, so they aren't marked agentic.

**Alternatives:**
- **PrismML's forks for 1-bit MLX** (`PrismML-Eng/mlx-swift`): a fork of MLX core, against D-055.
- **Quail's own 1-bit matmul kernel,** which D-066 would allow: a large piece of Metal for one family, while upstream has a PR open.
- **PrismML's recommended GGUF files** (`Q2_0`, `PQ2_0`): they don't load on upstream llama.cpp.

**Revisit if:**
- mlx#3161 ships in mlx-swift (1-bit on MLX);
- mlx-swift-lm takes #630 (delete the copy);
- llama.cpp takes #29600 (Bonsai 2 on GGUF);
- PrismML renames its files.

The weekly Upstream watch workflow follows the three upstream PRs and comments on #158 when one merges or closes.

## D-068 · 2026-09-30 · Load and Unload by hand stop a busy model's requests

**Situation:** with one model loaded at a time, loading another while the chat page was still streaming a reply left the new model at "Loading…" for as long as the reply ran, with nothing saying why. The router never takes a model out from under a request (D-011's router semantics), so it waited. With a slow thinking model and no length limit, that's many minutes. Unload waited the same way. And the page kept its own choice of model, so its next message could reload the old model and push the new one out.

**Decision:**
- **Loads and unloads asked for by hand don't wait.** `POST /models/load` and `POST /models/unload` are what Quail's Load and Unload buttons send, and the chat page's. They stop the requests on a model that has to go, and each of those requests ends with a 503 `unavailable_error`: "Stopped: *A* was unloaded to load *B*." A stream gets it as its last event. For a load, the busy model stopped is the least recently used one, and only if every model in the way is busy.
- **A load a request needs still waits.** A request for another model, from any client, never stops someone else's reply.
- **The wait shows.** While a load waits, `GET /models` gives the model's status a `waiting_for` list, and so does its `GET /slots` entry. The Models page and the Activity window say "Waiting for *A* to finish", the menu's model line says the load comes once *A* finishes its requests, and the chat page says so too.
- **The chat page follows a switch made elsewhere.** It refreshes its list when it comes back into view. Before it sends to a model that isn't loaded, when loading it would unload another (`max_instances` in `/props`), it offers the loaded model instead: "Use *B*" or "Load *A*". Load is a hand load, as above.

**Details:**
- Each load of a model gets a fresh interrupter. A request registers with it while it generates, and one that registers after an interruption is stopped at once.
- A model stopped for a load that another model then made room for (it finished first) gets a new interrupter, so its next requests run.
- So does a model whose unload is cancelled by loading it again.

**Alternatives:**
- **Always stop, like a llama-server router ending a child process:** a load that one client's request needs would cut off another client's reply. Rejected.
- **A grace period before stopping:** the owner already chose, and a reply can outlast any fixed wait.
- **Only show the wait:** it names the problem without fixing it; Unload still wouldn't free the model.

**Revisit if:** clients other than Quail's own call `/models/load` while others are generating, and being stopped surprises them. An opt-out field on the request would then do.

## D-067 · 2026-09-30 · Who a request is from, in the Activity window

**Situation:** the Activity window (D-060) shows a row per request in progress, but not who sent it. With Claude Code, a chat app and a script sharing one server, the owner can't tell which is keeping it busy. Every client uses the same API key (D-039), so the key says nothing.

**Decision:** quail-server notes two clues for each request, and the app names and totals them.
- **The app:** the `User-Agent` header's first product, without a numeric version: `claude-cli`, `OpenAI/Python`, `curl`. The whole header is also kept, cut to 160 characters.
- **The machine:** the connection's address. Loopback becomes "local", and a mapped IPv4 address is written plainly.
- **`GET /slots`** gives each request its `client`, and adds `clients`: one entry per app-and-machine seen since the server started, with its requests, prompt tokens read (reused ones not counted), tokens written, busy seconds (time with at least one request in progress, waiting for a model included) and requests active now. It also adds `uptime_seconds`.
- **The app** keeps each poll's totals for 15 minutes. For the window the charts show (1, 5 or 15 min), it subtracts the totals at the window's start.
  - A total that went down means the server restarted, so it counts from nothing.
  - A server younger than the window counts from its start.
- **Names:** the Connect list's new `userAgents` prefixes name the tool. Only strings seen on a real request were added: `claude-cli`, `codex_`, `curl` and `OpenAI/Python`. Anything else shows its own product name ("OpenAI/JS", "python-httpx"), or "Unknown app". The machine is "this Mac" or the address.
- **The window:**
  - Each request row gets a line, "Claude Code · this Mac".
  - A new Clients section lists each client busy now or in the window, busiest first, at most six. Each shows what it's running now, its requests and tokens in the window, and a bar of its busy share. The bar is green under 25%, orange up to 75% and red above: the memory chart's colours.

**Privacy:** the figures stay in the server's memory, behind the API key. They're never logged or written to disk, and they go when the server stops. The privacy page says so.

**Limits:**
- A tool that goes through a shared SDK shows as that SDK: one built on the OpenAI Python library reads as "Python".
- A tool can send any `User-Agent` it likes. This is a label, not authentication.
- llama-server has no `/slots`, so with it there are no clients to show.

**Alternatives:**
- **A key per tool:** it names clients reliably, but means a Keychain entry for each and new Connect flows; D-039 chose one key.
- **An `X-Quail-Client` header:** no tool would send it.
- **Reverse DNS for addresses:** slow, and often nothing on a home network.

**Revisit if:** keys per tool arrive, or a tool Quail lists can't be told apart from its SDK.

## D-066 · 2026-09-29 · Quail's own copies of mlx-swift-lm model files

**Situation:** the first comparison (D-063) found two MLX gaps whose cause is mlx-swift-lm's model code, not Quail's.
- **Gemma 4 26B-A4B was served one request at a time (#140).** mlx-swift-lm's text-only Gemma 4 has no mixture-of-experts layers, so the model loaded only through the vision model, whose attention takes one position for the whole batch.
- **Qwen3.5 and 3.6 decode and read prompts slower than oMLX and Rapid-MLX (#141).** Those two compile small functions and add Metal kernels for this family.

D-055 had decided on mlx-swift-lm's public API only, with no custom Metal and no fork.

**Decision (the owner's, 2026-09-29):** Quail may keep its own copies of mlx-swift-lm model files, changed where it needs.
- **Where:** `QuailServer/MLX/Models/`.
- **How they're used:** registered through mlx-swift-lm's public `LLMTypeRegistry.shared.registerModelType`, in place of the library's own model for the same `model_type` (`QuailModels.register()`, called before every load).
- **Custom Metal kernels** (`MLXFast.metalKernel`) are allowed in them.
- **Downloads don't change:** the copies read the same checkpoints.

**Rules:**
- **Header:** each copy starts "Adapted from mlx-swift-lm <release>, <path>", with the source's licence line, and lists what it changes.
- **Keeping up with upstream:** `MLXModelCopiesTests` fails when the mlx-swift-lm pin moves, until every copy has been compared with its source in the new release and names it.
- **Licences:**
  - `Config/third-party.json`'s mlx-swift-lm entry says Quail carries adapted copies (the MIT notice already ships).
  - A kernel adapted from another project gets its own entry and licence text.
- **Upstream:** changes worth having there are offered there.

**First copy:** Gemma 4's language model, from `MLXVLM/Models/Gemma4.swift`. It's text only, and its attention takes positions from the cache's `ropeOffset`, so it batches (D-056 amendment, #140).

**Alternatives:**
- **Fork mlx-swift-lm and pin to the fork.** That means the whole library to keep current, not a few files.
- **Offer the changes upstream and wait.** The timing wouldn't be ours.
- **Leave both gaps.**

**Supersedes** D-055's "public API only, no custom Metal" for model code. Its other rules stand, such as no fork of MLX core.

**Revisit if:** upstream takes a change (delete that copy), or the copies grow past a handful of files.

**Amended 2026-09-29 (the second copy: Qwen3.5 and 3.6, #141):** `QuailServer/MLX/Models/Qwen35.swift` is copied from mlx-swift-lm's Qwen35.swift and Qwen35MoE.swift, with the parts of Qwen3Next.swift and GatedDelta.swift they use.
- **What it covers:** it's registered for `model_type` qwen3_5, qwen3_5_moe and qwen3_5_text. The configuration types are copied too, since their fields are internal to mlx-swift-lm.
- **Changes, following mlx-lm:**
  - The small element-wise functions mlx-lm compiles are compiled here: the decay `g`, the gated norm's float32 SwiGLU, and the MLPs' SwiGLU. The attention output gate is compiled as well.
  - `beta` stays in the activations' type, as mlx-lm keeps it.
- **Output:** replies at temperature 0 were byte-identical to mlx-swift-lm's on four prompts, including a 1,500-token one. Batched replies behave as D-056 describes.
- **Measured** on the M1 Max, Qwen3.6 35B-A3B, cooled before each request, two runs of three:
  - **Time between tokens:** 15.5–15.9 ms before, 14.2–14.5 ms now. That's mlx-lm's own speed on the same Mac (70.5 tokens/s is 14.2 ms). MLX core 0.32 against 0.31.2 made about 2% difference in mlx-lm.
  - **First token on a 4,096-token prompt,** read in 512-token slices: 8.2 s before, 7.9 s now. With #139's 2,048-token slices it's 7.0 s.
- **What's still behind:**
  - Rapid-MLX (12.2 ms) replaces the whole single-request decode step with a compiled one and fuses the GatedDeltaNet decode.
  - oMLX (12.7 ms) patches the expert routing and weighted sum.
  - Both are larger ports: #141 stays open for them.
- **Tried and not kept:** Rapid-MLX's blocked GatedDeltaNet prefill kernel (adapted from oMLX's, Apache-2.0), ported through `MLXFast.metalKernel`. It saved 1–2% of a 4,096- or 7,000-token prompt's first-token time. That's too little to carry the kernel and its licences, since the recurrence is a small part of a prompt's reading at these lengths. Revisit for prompts well past 8,000 tokens, which oMLX measured at about 2× per layer at 16,000.

**Amended 2026-09-30 (a fused GatedDeltaNet decode kernel, #141):** for one request's next token, each GatedDeltaNet layer of the Qwen3.5 copy now runs as one Metal kernel between its input and output projections. It covers the causal convolution and its cache shift, the SiLU, the q and k norms, the decay and `beta`, the recurrence and the gated norm, which were a dozen kernels.
- **Source:** adapted from Rapid-MLX 0.15.2's `qwen4_fused_gdn_decode.py` (Apache-2.0), keeping its Qwen3.5 semantics only. Its reduction structure is itself from mlx-vlm pull request 2105 (MIT). Both are in `Config/third-party.json` with their licence texts.
- **Same bytes, checked on the Mac it runs on:** the first time a layer shape loads, eight steps of a random layer run both ways. The kernel is used only if its output and both states match the separate kernels' byte for byte. Otherwise the separate kernels stay, and the server log says which. `QUAIL_MLX_FUSED_GDN=0` turns it off.
- **Only where it's written for:** one sequence, one position, no mask, bfloat16 activations, a float32 state, and 128-wide heads. Prompts, batches and other shapes keep the separate kernels.
- **Measured** on the Mac mini (M4 Pro), Qwen3.6 35B-A3B, prompt lookup off, cooled before each request: 11.22 ms a token with separate kernels, 10.79 ms fused (−3.8%). Replies at temperature 0 were identical.
- **Still behind:** Rapid-MLX also compiles the whole single-request step. So does mlx-swift-lm's main branch, whose Qwen3.5 (four input projections fused into one, compiled decode segments, a fused router top-k) measured 10.99 ms against this copy's 10.79 ms on the same mini, so this copy stays.

**Amended 2026-10-01 (the third copy: Bonsai 2 27B, D-069):** `QuailServer/MLX/Models/PrismHadamard.swift` is adapted from mlx-swift-lm pull request #630 at bac826f, which is still open. That PR's code is under mlx-swift-lm's MIT licence.
- **What the copy is for:** Bonsai 2 packs Qwen3.6 27B's language-model weights as ternary values in MLX's affine 2-bit form, in a Hadamard-rotated basis. `model_type` is `prism_hadamard_qwen35`, and `config.json` names every rotated module.
  - Each rotated linear layer rotates its input before the packed matmul, with a signed, blockwise Walsh–Hadamard transform (MLX's `hadamardTransform`).
  - The rotated embedding un-rotates the rows it looks up.
  - Without both, the pack still loads and writes fluent nonsense.
- **Built on the Qwen3.5 copy** (`QPrismHadamardQwen35Model: QQwen35Model`). That copy keeps the GatedDeltaNet input projections apart, as the manifest names them.
  - The manifest, its validation and the choice of tensors to cast to float16 are in `QuailServerCore` (`PrismHadamardManifest`), where they're tested without MLX.
  - Text only: mlx-swift-lm's vision Qwen3.5 isn't `open`, so there's nothing to subclass for images.
- **Checked against a reference:** mlx-lm's Qwen3.5, with the rotated modules installed as Rapid-MLX 0.14.3's runtime installs them. On a fixed prompt at temperature 0, Quail's reply matched its token ids, 60 of 60, up to Quail's end of turn.
- **Several requests at once:** four different requests sent together gave the same greedy replies as sent one at a time, so `prism_hadamard_qwen35` is in `batchedFamilies`.
- **Speed** on the M4 Pro (release build, one request): 23.5 tokens a second, against 14.9 for Qwen3.8 27B at 4 bits on the same Mac.
  - The pack runs in float16, so the fused GatedDeltaNet decode kernel, which is bfloat16 only, isn't used.
- **Delete when** the pin takes #630.

**Amended 2026-10-01 (the fourth copy: Nemotron-H, and a config adapter):** `QuailServer/MLX/Models/NemotronH.swift` is copied from mlx-swift-lm's NemotronH.swift and registered for `model_type` nemotron_h, behind a rewrite of `config.json`.
- **The config adapter** (`MLXConfigAdapters.nemotronH`, in `QuailServerCore`, tested without MLX):
  - Nemotron 3.5 Lightning 30B-A3B writes its layer layout as `layers_block_type` (`["mamba", "moe", …]`), and the pinned `NemotronHConfiguration` refuses a config without `hybrid_override_pattern`, so its MLX download, listed from Rapid-MLX's catalog, didn't load.
  - The adapter adds the pattern with mlx-lm's own mapping (ml-explore/mlx-lm#1857).
  - It splices the keys in rather than re-serializing, because Nemotron 3 Nano's config has an `Infinity` that `JSONSerialization` reads but can't write.
  - Nemotron 3.5's layout comes out as exactly Nemotron 3 Nano's pattern.
- **The copy's one change:** the gated norm's identity weight is in the activations' type.
  - mlx-swift-lm passes `rmsNorm` a float32 array of ones, where mlx-lm passes no weight.
  - That makes the norm's output float32, and through each Mamba layer's output projection, the residual stream too.
  - The cost was twice the bytes, and greedy replies that differed from mlx-lm's from the first token.
- **Measured** on the M4 Pro (release build, mlx-community 4-bit, a 200-token reply):
  - 56 tokens a second before, 76 now, against 89 for Python mlx-lm 0.31.3 and 65 for the Q4_0 GGUF on quail-server.
  - Its greedy reply now matches mlx-lm's.
  - Mlx-lm compiles its expert selection, and compiling that and the squared ReLU here changed nothing measurable, so the copy doesn't.
- **Several requests at once** gave replies that differ from the same requests sent alone, so Nemotron-H isn't in `batchedFamilies`.
- **Upstream:** both fixes belong in mlx-swift-lm's NemotronH.swift, but Quail isn't submitting them (2026-10-01). The copy and the adapter stay until a pin brings the same fixes from upstream's own work.

## D-063 · 2026-09-28 · Comparing Quail with Ollama, oMLX and Rapid-MLX: method and harness

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
  - Quail parsed none of Gemma 4's tool calls. This was fixed in 0.57.1; see D-040's amendment.
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
  - a generated "Where Quail is slower or worse" list, using D-063's rules: more than 5% and more than the spread between rounds for speed, and an exact McNemar test (p < 0.05) on the same items for quality and tool calling
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

## D-062 · 2026-09-28 · A website: hand-written HTML in `website/`, on GitHub Pages

**Situation:** Quail had no home page, only a README. The owner wants the app to link to one before 1.0, with docs the app's long captions can point at instead of explaining everything in place. They bought `quail-ai.app` and `quail-ai.com`, both on Cloudflare DNS.

**Decision:** A landing page and ten short docs pages in `website/`, as plain HTML with one stylesheet: no build step, no framework, no JavaScript except on the 404 page.
- **Pages:** getting started, models, connect a tool, network and API key, power, benchmark, the `quail` command, troubleshooting and privacy, plus an index.
- **The docs sidebar** is repeated on each page. `scripts/check-site` (`task site:check`, run by the workflow) fails if the copies differ, and also checks titles, descriptions and every link and image inside the site, including `#fragments`.
- **Links are relative,** so the site works both at `https://adatoo.github.io/quail/` and at the root of a domain.
- **Deploy:** `.github/workflows/pages.yml` checks the site on pull requests and deploys it from `main` with `actions/deploy-pages`. Pages must be switched to "GitHub Actions" in the repository's settings once; the workflow doesn't turn it on itself.
- **Domain: `https://quail-ai.app`**, with `quail-ai.com` redirecting to it.
  - **Why `.app` is the address:** it names what Quail is (the Homebrew cask is `quail-ai` too), and every `.app` domain is HTTPS-only in browsers. Anyone who types `.com` still lands on the site.
  - **The custom domain is a repository Pages setting** (Settings → Pages, or `gh api -X PUT repos/adatoo/quail/pages -f cname=quail-ai.app`). It isn't a `website/CNAME` file: GitHub ignores that file when an Actions workflow deploys.
  - **`quail-ai.app`'s records point straight at GitHub Pages and aren't proxied** (DNS only). GitHub issues and renews its certificate; `www` is a CNAME to `adatoo.github.io`, and GitHub redirects it to the root. The domain is verified on the GitHub account (a `_github-pages-challenge-adatoo` TXT record), so no one else can claim it.
  - **`quail-ai.com` and `www.quail-ai.com` are proxied by Cloudflare.** A Redirect Rule sends each path to the same path on `https://quail-ai.app` (301), with Cloudflare's own certificate.
  - **If `quail-ai.app` is ever proxied** (for analytics or caching), use SSL/TLS "Full (strict)", never "Flexible", which loops with GitHub's enforced HTTPS.
- **Screenshots:** `task site:screenshots` renders the Quail window, light and dark, through the snapshot suite (`UISnapshotTests.websiteScreenshots`).
  - The sidebar and page are drawn side by side, because offscreen rendering leaves a real split view's sidebar blank.
  - Rendered offscreen, the window is inactive, so the sidebar's labels are grey. Real screenshots from a running app can replace these images.

**Alternatives:**
- **A static site generator** (Jekyll, Hugo, Astro Starlight): Markdown docs and a shared layout, but a toolchain to install and pin for about ten pages. The repo keeps dependencies to what the app needs (AGENTS.md), and `quail-server`'s own page is hand-written too (D-042).
- **Docs in the repo's Markdown only:** no landing page, and GitHub's rendering is the look.

**Revisit if:** the docs grow past what one person keeps consistent by hand (about 20 pages), or need search. Then a generator earns its keep.

**Amended 2026-09-30 (the comparison's results, and "How it works"):**
- `compare.html` shows the 2026-09-30 comparison's headline results (`task bench:site`), beside the sourced feature table.
- **A new `how-it-works.html`,** kept brief, covers:
  - what Quail is for;
  - how it's built, as a diagram in HTML;
  - how speed is measured and improved;
  - what the first comparison changed, as a card for each change.
- **The details go on their own pages** under `website/performance/`: the comparison's method, several requests at once on MLX, Qwen3.5 and 3.6 on MLX, MLX memory, and long prompts on GGUF. Each is found → why → changed → result, with its issue and PR, and what's still to do. The owner asked for this layout: a short page, with callouts for readers who want more.
- **Linked from:** every page's header ("How it works", hidden on narrow screens), and the footers of the top-level pages.

## D-061 · 2026-09-28 · One Quail window with a sidebar, instead of six Settings tabs

**Situation:** Settings had six tabs holding three kinds of thing:
- preferences (General, Endpoint)
- the app's work surfaces (Models, Connect, Benchmark)
- a page of facts (This Mac)

The server's settings were spread over three of them:
- auto-start and keep-awake under General
- runtime, host, port, API key and "Max loaded models" under Endpoint, in a section that was also called "Models"
- the default model and context size in Models

Settings had no server status and no Start/Stop, though Endpoint's runtime picker said to stop the server. The owner found they had to think several times to work out where anything was.

**Decision:** Settings becomes one resizable `Window("Quail", id: "main")` with a sidebar. The pages are Server, Models, Connect and Benchmark, then a gap, then General and About.
- **Server** takes everything about the server. It is today's Endpoint, plus "Start the server when Quail opens" and the Power section, which leave General; "Max loaded models" becomes "Models loaded at once" under Memory.
- **General** is Quail itself: open at login, menu bar activity, the `quail` command and updates.
- **About** is now a page of its own, amending D-029: versions, licences, and the This Mac facts. It has one Copy Details for a bug report, covering both Quail and this Mac. The This Mac tab is gone.
- **Scene:** a `Window` scene rather than `Settings`. The window now shows live state, runs tests and benchmarks, and can be resized, so pages fill it and scroll. The old window sized itself to each tab, with a minimum height per pane and a fixed height for Connect. Removing that cleared those workarounds.
- **The menu:** "Open Quail" (⌘,) opens the window on the page it last showed, the Server page the first time. The window also takes ⌘, while it's key, through `CommandGroup(replacing: .appSettings)`. Add model…, Benchmark… and Connect a Tool… open it at their page (`AppState.mainPage`, which replaced `settingsTab`).
- **Messages** from the app and the CLI say "Quail → Server" or "Quail → Models" where they said "Settings → Endpoint" or "Settings → Models". The CLI's suggest a `quail` command first.
- **Windows:** `opensInFront(id:)` registers each window under its scene id, so `bringToFront(id:)` fronts the one asked for rather than the newest visible window. Windows are no longer restorable, so they don't reappear by themselves after a relaunch; `Settings` never did.

**Alternatives:**
- **A main window plus a slimmer Settings window.** This is closer to the Mac convention, but you'd still have to know which window holds what.
- **Keeping the tabs and regrouping.** This was the least work, but it leaves preferences and tools mixed in "Settings".

**Follow-ups, in order (docs/IMPLEMENTATION_PLAN.md, Road to 1.0):**
1. The Server page proper: status and Start/Stop; usable addresses instead of `0.0.0.0`; a This Mac / Local network / Custom choice instead of a free-text host; a restart banner.
2. Per-model settings in a popover instead of a small "ctx" menu.
3. "Learn more" links to the website instead of long captions.

**Checked:**
- snapshots of every page, rendered in the window, and the sidebar alone (inside the split view, offscreen rendering leaves the sidebar blank)
- unit tests

**Revisit if:** Phase 5's multiple endpoints need a list of servers: the Server page is written over one controller and config so it can sit under one.

**Amended 2026-09-28 (the Server page):**
- **Status at the top:** the server's state and what's loaded, with Start, Stop and Test…. When it failed, the reason and Show Logs. With no model, Add Model….
  - A line with Restart appears when a restart is needed: `AppState.restartReason`, for changed models as before, or for a changed address, port, key or models-at-once. That is `endpointChangedSinceStart`, which compares `ServerController.launchedConfig` with what Start would use.
  - The menu shows the same line.
- **Address shows addresses a client can use,** never `0.0.0.0`. "On this Mac" is loopback when listening everywhere. "From other devices" is this Mac's network address, and appears only when other devices can connect.
  - Both show the launched address while the server runs, and otherwise what Start will use: `AppState.localBaseURL` no longer keeps the last run's address after a stop.
  - The API key is masked, with Show (where it can be edited, saved on Return), Copy, and New Key… behind a confirmation.
- **"Reachable from: This Mac only | Local network | Custom" replaces the free-text Host** (`EndpointAddress.Reach`).
  - The first two write `127.0.0.1` and `0.0.0.0`.
  - Custom takes an address, saved on Return or Save; the old field saved on every keystroke, so its warnings flipped as you typed.
  - A host from an older config that is neither loopback nor wildcard shows as Custom, unchanged, so there is no migration.
  - The exposure warnings (D-039) sit under it. Start from the page gives the same one-time warning as the menu (`ServerActions`).

**Amended 2026-09-28 (model settings):**
- Each Models row's context size and KV cache used to sit behind a small "8K ctx ⌄" menu, and the default model was a star explained only in a tooltip. They now open a **settings popover**, from a sliders button on the row, from the row's "8K context · 8-bit KV" text, or from Model Settings… in its right-click menu.
- **The popover holds:**
  - the id to copy (what a client sends as `"model"`)
  - Context size and KV cache, each option labelled with its fit
  - "Load when the server starts" (the star)
  - Benchmark… and Delete…

  It's a popover rather than an inspector: an inspector would take about 250 pt from every page, and Form rows have no selection.
- **A "This Mac: Apple M4 Pro · 64 GB · comfortable up to ~55B" line** heads the page, with Details for the About page. It is `DeviceInfo.summaryLine`, shared with the Add Model sheet.
- **Add Model:** every "Add Model…" outside the page (the menu, the Server page, Connect, Benchmark) opens the sheet itself, through `AppState.addModelRequested`.


**Amended 2026-09-28 (links to the website, ADR D-062):**
- **`Website`** holds every link out of the app. The website's address is `Info.plist`'s `QuailWebsiteURL` (from `project.yml`), so a new domain is a one-line change. It is empty until the site is published, and empty hides every website link.
- **"Learn more"** (`LearnMoreLink`) now sits beside captions cut to one line, pointing at the matching docs section:
  - the address and key, and the network (Server page)
  - power, and the lid-closed option
  - the `quail` command (General)
  - the benchmark suite
  - a model's settings
- **The menu** gains Quail Help: the docs, or the README without a website.
- **About** gains:
  - links: Release Notes, Report an Issue, Source Code, plus Website and Documentation when there is a website
  - an MLX row: the mlx-swift-lm and mlx-swift pins, read from the notices file. `quail-server`'s version is the app's own, so it needs no row of its own (Phase 4 step 6).

**Amended 2026-09-29 (issue #134): loaded models at the top of the Models page.** A loaded model used to show only as a small "loaded" badge among every installed row.
- **A Loaded section:** while the server is ready, it heads the page with every loaded or loading model. It comes from the same app-wide `GET /models` poll as the menu's "Loaded: …" line, and each row shows:
  - the model's format and context;
  - its memory: MLX's own figure from `/slots`, or the server's footprint for GGUF;
  - what it's doing: "Loading 6 s", "Idle", or "1 request · 43 tok/s".
- **Actions:** **Unload** (`POST /models/unload` through a new `Runtime.unload`, finishing the model's requests in flight first) and the default star.
- **With nothing loaded,** one line says what will load and when.
- **Installed still lists every model,** loaded ones included, so it doesn't reshuffle as models load and unload.
- **Layout:** the rows share one Form row. As separate rows, the grouped Form drew only the first inside the section's card.

## D-060 · 2026-09-28 · Live activity: `GET /slots`, the menu bar and an Activity window

**Situation:** a 30,000-token prompt takes a minute and a half on Qwen3-8B, and a model load takes seconds. The whole time, Quail's menu says "Running" and the client waits in silence. The app knew the server's phase and each model's load state, from a 2 s `GET /models` poll, and nothing else: no request state, no progress, no memory, CPU or GPU figures.

**Decision (server):** `ActivityRegistry` keeps a record per request in progress. `GET /slots` (behind the API key, never loading a model) returns them with the active models.
- **Request lifecycle:** a request is recorded as it asks for its model, which is the `waiting_for_model` phase. It becomes `queued` once the engine has it. `TextGenerator.stream` then moves it to `reading_prompt` at the engine's first prompt progress and to `generating` at the first token. It's removed however it ends, including when the client leaves (the record's `end()` is idempotent).
- **A new optional event,** `GenerationEvent.promptProgress(done:total:cached:)`. MLX emits it after each 512-token slice, GGUF after each chunk (2,048 tokens). `TextGenerator` consumes it, so no client ever sees it.
- **Rates:** prompt tokens a second are counted from the first progress event and exclude reused tokens. Generation tokens a second are counted from the first token.
- **Models** carry their state, `loading_seconds`, leases and `memory_bytes`. The memory comes from MLX's allocator (`Memory.activeMemory`); GGUF reports nil, and the app measures the process instead.
- **The name:** `/slots` is llama-server's route name, but the shape is Quail's own, because per-slot objects don't describe batched MLX requests or queued ones. `/props` now says `endpoint_slots: true`.

**Checked:** registry phase and rate tests; `/slots` during a scripted stream (generating, then gone after a hang-up) and while a prompt is read (half done, and the reply text unchanged); auth; and no model load. Against real models, a 13,570-token prompt on Qwen3-8B showed MLX advancing 512 tokens at a time at about 336 tokens a second, and GGUF showing loading for 15 s and then 2,048-token steps.

**Amended 2026-09-28 (the app):**
- **`ActivityMonitor`** polls `/slots` and samples the Mac: every second while something is happening, every two seconds otherwise, only while the server runs.
- **`SystemMonitor`** takes its readings without special rights:
  - CPU from Mach's per-core ticks;
  - the server's CPU and memory from `proc_pid_rusage` on its process and any children (llama-server's per-model processes); on Apple silicon the footprint includes GPU buffers;
  - GPU busy % from the `IOAccelerator` service's `PerformanceStatistics["Device Utilization %"]` (it read 99–100% while Qwen3-8B read a prompt);
  - memory used as Activity Monitor counts it (internal pages less purgeable, plus wired and compressed).
- **Menu bar:** the label is the bird plus the busiest thing happening: "Loading…", then "Reading n%" for the longest prompt being read, then the total tokens a second, with "+n" for other requests. Nothing when idle, and `Config.menuBarActivity` turns it off. The menu repeats the line.
- **Activity… window:** a minute's GPU and CPU sparklines, memory, models, and a row per request. It floats above other windows unless "Keep on top" is unchecked.
- **With llama.cpp** (no `/slots`), only loading and the Mac's figures are shown.

**Amended 2026-09-29 (issue #133):** the Activity window now shows the Mac with the server stopped, and charts memory.
- **When it samples:** the Mac is sampled while the server runs **or** the window is open. The window's appear and disappear events count watchers, and `/slots` is still polled only while the server runs.
  - Stopping the server clears only the server's figures. The Mac's history goes on while the window is open.
  - Nothing is sampled with the window closed and the server stopped.
  - The first reading after the window opens is followed half a second later by a second, so CPU (a rate between two readings) shows at once.
- **History:** kept as timestamped readings for 15 minutes, and drawn by time rather than by index. The window shows the last 1, 5 or 15 minutes, chosen in the window and remembered between launches.
  - Before, "a minute" was 60 readings taken 1 or 2 s apart.
  - A pause of more than 10 s breaks the line rather than joining across it.
- **Memory chart:** memory is a chart like CPU and GPU, replacing the single bar.
  - The y-axis runs from 0 to the Mac's total memory, so the chart shows how full the Mac is.
  - The area is green, orange above 80% and red above 90%.
  - While the server runs, its share is drawn inside in indigo, with a matching dot in its caption.
  - All three charts share one `HistoryChart`, drawn with Canvas. Swift Charts would bring axis chrome that doesn't suit a 340 pt window.
**Amended 2026-09-30 (D-067):** each request row names its client (app and machine), and a Clients section shows each client's load over the chosen window.

## D-059 · 2026-09-28 · Moving in models other apps downloaded (Phase 4 step 2)

**Situation:** people arrive with models already downloaded by llama.cpp (`-hf`), LM Studio, the Hugging Face cache (mlx-lm and others) or oMLX. Re-downloading tens of gigabytes is slow, and keeping two copies wastes disk space. ARCHITECTURE §6 said to offer to move them on first run, never symlink.

**Decision:** `ModelImporter` scans four places and names each model as the store does:
- `~/.cache/llama.cpp`: flat `owner_repo_file.gguf`, with the `owner_repo_…mmproj…` projector;
- `~/.lmstudio/models/<publisher>/<repo>/`: GGUF files, or an MLX folder named `publisher--repo`;
- `~/.cache/huggingface/hub/models--owner--name/snapshots/<refs/main>/`: an MLX folder `owner--name`, or GGUF files. Its entries are links to blobs, so the blobs move and the links go;
- `~/.omlx/models/<name>/`: MLX folders.

It skips anything whose name is already in the store, and an MLX folder missing a shard its `model.safetensors.index.json` names (an unfinished download).

**How a move works:** all or nothing.
- The files go into a staging folder in the store: renamed if they're on the same disk, copied if not.
- The staging folder then takes the model's place, and only after that are the originals removed.
- A failure part-way puts renamed files back.

**The offer** is a banner at the top of the Models pane, shown until it's answered either way (`Config.importOffered`); Review… opens the list with a checkbox per model. Storage's menu reopens the list at any time.

**Differences from the plan:**
- A banner instead of a sheet that opens by itself on first launch. A menu-bar app opening a window unasked is intrusive, and the Models pane is where the result shows.
- Moves go through a staging folder, so a failure never leaves half a model.

**Checked:** a fixture with a model in each place, including a Hugging Face snapshot of links and a llama.cpp projector. Tests cover that each is found and named, moved and removed at the source (blobs and links too), not found again afterwards, and refused when already in the store. A failure part-way puts the model back, and an unfinished download is skipped. Snapshots `import-offer` and `import-sheet`.

**Alternatives:** copy (doubles the space); symlink (llama-server and MLX treat links inconsistently, ARCHITECTURE §6); point Quail at the other folders in place (the store's single-writer rule and presets assume one folder).

## D-058 · 2026-09-28 · Rapid-MLX's catalog as a data source for MLX models (Phase 3 step 9)

**Situation:** MLX is the default format on Quail server (D-004 amendment), but the curated catalog (D-019) offers one hand-picked MLX repo for each of 15 families. Rapid-MLX (Apache-2.0, 0.14.3, installed here with Homebrew) ships three data files with its Python package:
- `aliases.json`: 215 models, with repo, parsers, MoE flag, modality and experimental flag;
- `model_sizes.json`: each repo's bytes;
- `model_recommendations.json`: schema 1, memory tiers each with a "smart" and a "fast" pick.

Rapid-MLX runs Python mlx-lm, which loads more architectures than mlx-swift-lm does.

**Decision:** import the data, never the runtime.
- **The generator:** `scripts/import-rapid-mlx` (Python, standard library) writes `Resources/mlx-models.json` with a schema version and revision.
  - **It keeps:** text models (or image-reading ones), not image/video generation, diffusion or embeddings; not experimental; one row per repo; and only those whose `config.json` `model_type`, read from Hugging Face, is in mlx-swift-lm's text registry (read from the pinned checkout) or is one Quail loads through its vision half.
  - **It excludes by hand, with the reason recorded in the script:** a diffusion architecture, and Gemma 3n, whose conversions fail to load in 3.31.4.
  - **Result:** 134 models across 22 architectures.
  - It copies Rapid-MLX's licence and notice into `Config/licences/rapid-mlx/`, and `task notices` lists it as vendored data.
- **In the app:** `RapidMLXCatalog` loads the file, or its weekly refresh from the same host as `catalog.json` (same guards: a schema this build reads, no older revision). `Catalog.current` appends its models after the curated families as MLX-only rows, leaving out any repo a curated family already offers.
  - **Parameter counts** come from the alias ("35b-a3b"), because Rapid-MLX has none.
  - **Fit:** rows are looked up as they scroll into view (`AppState.loadCatalogFit`), not all at once as the curated ones are.
  - **Picks:** Rapid-MLX's picks for the Mac's memory (the largest tier it reaches) get a section of their own, when the runtime serves MLX.
- **Recommendations** stop being GGUF-only: `Recommender.candidates` takes the formats the runtime serves, and verdicts are keyed by family.
- **The MLX engine also stops at common end-of-turn tokens** the tokenizer really has (`<end_of_turn>`, `<|im_end|>`, `<|eot_id|>`, `<|eom_id|>`), as llama.cpp does from its vocabulary. Found in this check: Gemma 3 1B's conversion lists only `<eos>` and wrote past `<end_of_turn>`.

**Checked:** 13 models outside the curated list, one or more for each architecture new to Quail, answered on quail-server: Llama, LFM2 and its MoE, Gemma 3 (1B text, 4B), Granite and Granite hybrid, Phi-3.5, SmolLM3, Qwen2 (a reasoning distill), MiniCPM, and a 2-bit ternary Qwen3. Gemma 3n failed, so it's excluded.

**Alternatives:**
- Curate more families by hand: slow, and the list goes stale.
- Query Rapid-MLX's CLI at runtime: it would have to be installed.
- Use Hugging Face search: no quality signal, and no check that a repo loads.
- Merge the data into `catalog.json`: its tests and ranks assume a curated list.

**Revisit if:** Rapid-MLX changes its schema (the script refuses anything but 1), mlx-swift-lm gains architectures (rerun the script), or the list needs pruning by quality rather than loadability.

## D-057 · 2026-09-28 · Opt-in KV cache quantization, per model (Phase 3c step 7)

**Situation:** A model's KV cache grows with context: 147 KB a token on Qwen3-8B, so 3.4 GB at 24,000 tokens and 4.6 GB for a 32K GGUF context. On a 16–24 GB Mac that decides whether a coding agent's 30K prompt fits at all. Both engines can store it in fewer bits:
- llama.cpp has `type_k`/`type_v`, with q8_0 and q4_0 needing flash attention for V; llama-server exposes them as `--cache-type-k/-v`.
- mlx-swift-lm 3.31.4 converts plain `KVCacheSimple` layers with `maybeQuantizeKVCache` to affine 8- or 4-bit, group 64. Every model we serve reads the result through `QuantizedKVCacheProtocol`. Recurrent and sliding-window layers aren't converted.

The fit formula had `b` fixed at 2, and nothing set anything else.

**Decision:** a per-model setting, off by default: **Full precision / 8-bit / 4-bit**, in the model row's context menu. Each option is labelled with its verdict at the model's context.
- **Stored** as `InstalledModel.userKVCache`, like the context choice (D-020).
- **Written** to `presets.ini` as llama-server's own keys, `cache-type-k`/`cache-type-v` = `q8_0`/`q4_0`, plus `flash-attn = on` for GGUF. llama-server reads them unchanged; checked against the vendored b11081.
- **Read by quail-server** for both engines (`ModelEntry.cacheTypeK/V`, `flashAttention`), so one preset format serves both runtimes. This differs from the plan's new `cache-bits` key.
  - **GGUF:** the types go into the context parameters, with flash attention on for a quantized V.
  - **MLX:** a cache is quantized only when K and V both are, to the larger of the two bit counts. `MLXSequence` swaps its attention caches for quantized ones as soon as they hold anything, after each prefill slice and forward pass. mlx-swift-lm's own iterator paths get `kvBits` through `GenerateParameters`.
  - **MLX restrictions:** a model with a quantized cache doesn't batch (D-056's `BatchedLayers` takes plain caches only). Its disk prompt caches live in a folder of their own, because the layout differs.
  - `/props` reports `cache_type_k`/`cache_type_v`. A type the server doesn't implement is logged as ignored.
- **Fit:** `b` comes from the setting: 2, 1.0625 or 0.5625 bytes, the quantized ones including their per-group scales. Verdicts, the context picker and Automatic context use it.
  - A `.tight` verdict at full precision also carries the context a 4-bit cache would fit (`FitEstimate.contextWith4BitKV`), which Add Model states.
  - In the context menu, a size that won't fit but would with 4 bits says so.

**Measured** on Qwen3-8B 4-bit, M4 Pro. Recall is three code words planted in a 24,127-token log.

| | Full precision | 8-bit | 4-bit |
|---|---|---|---|
| MLX KV cache kept (24K tokens) | 3,420 MB | 1,816 MB | 961 MB |
| MLX prompt reading (tok/s) | 279–305 | 129–179 | 185 |
| MLX generation at 24K (tok/s) | 25 | 25–28 | 31–32 |
| MLX recall | 3/3 | 3/3 | 2/3 |
| GGUF KV cache (32K cells) | 4,608 MiB | 2,448 MiB | 1,296 MiB |
| GGUF prompt reading (tok/s) | 208 | 217 | 187 |
| GGUF generation at 24K (tok/s) | 18.6 | 18.1 | 18.3 |
| GGUF recall | 3/3 | 3/3 | 3/3 |

- **Short prompts, MLX at 4 bits:**
  - plain generation 5–9% slower (46–48 against 49–53 tok/s);
  - rewriting a file with prompt lookup 68 against 150 tok/s, because fewer guesses are kept (383 against 637) and each check costs more.
- **Why MLX prompts are slower:** mlx-swift-lm's quantized attention computes the scores with quantized matmuls instead of the fused attention kernel.
- **Peak memory while reading a prompt barely moves on MLX** (14.3 against 11.9–14.3 GB), because that same path builds the full score matrix per slice. The saving is in what's held afterwards and between turns. llama.cpp's flash-attention kernels read the quantized cache directly, so on GGUF the saving holds at the peak too.
- **Quantized caches still work with the rest:** cut back for prompt lookup, restored from checkpoints, and saved to and reloaded from disk (a 16,779-token prompt came back from disk after a restart with 16,778 tokens reused).

**Alternatives:**
- A server-wide flag: models differ too much in how much a cache costs.
- Quantizing only after the prompt is read, with `quantizedKVStart` or at the first token: prompt speed would be kept, but the peak would stay at full precision, defeating the point.
- mlx-swift-lm's TurboQuant cache: not in 3.31.4.
- Separate K and V choices in the UI: llama.cpp can mix them, but MLX can't, and one choice is easier to understand.

**Revisit if:** mlx-swift-lm gets a fused quantized attention kernel (the prompt cost would go), rotating or recurrent layers become quantizable, or the second-Mac acceptance run shows the 4-bit accuracy cost on real agent work.

## D-056 · 2026-09-28 · Batched MLX decoding (Phase 3c step 8)

**Situation:** MLX serves one request at a time. `ModelContainer.perform` serialises them, and the router's lease lets one in. Four requests at once total about one request's speed: 51 against 52 tokens/s on Qwen3-8B, and 80 against 85 on Qwen3.6 35B-A3B (D-004 amendment of 2026-09-28). GGUF decodes up to four together (D-048). Agents make concurrent requests (Claude Code's permission check beside its turn, opencode's sub-agents), and so does the chat page next to an agent. Decode is bandwidth-bound, so a step over four sequences costs little more than a step over one. mlx-swift-lm's closed PR #263 measured 2.3× total at four on Gemma 4 26B-A4B.

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
2. **`MLXBatchScheduler`,** shaped like `LlamaScheduler` (D-048), on the engine's own serial queue.
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

- **The 1.8× target** was met on Qwen3-8B but not on Qwen3.6. A step's time on Qwen3.6 is 11.7 ms alone and grows by 4.8 ms for each extra sequence (profiled: all of it waiting on the GPU, not graph building). Below about ten rows, MLX's quantized matmul (`qmv`) reads the weights once per row, and a mixture-of-experts model sends each row to different experts. Getting past that needs kernel work, which D-055 rules out.
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

**Amended 2026-09-29 (Gemma 4 batches, #140):** Gemma 4 26B-A4B is now decoded in a batch like the Qwen families. Before, eight requests at once waited in line: 41 s to the first token on the M1 Max in the first comparison (D-063), where oMLX took 3 s.
- **Quail's own Gemma 4 language model** (`QuailServer/MLX/Models/Gemma4Text.swift`, D-066):
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
  - **Four at once, staggered:** each reply matched its solo run for a first stretch, and two of four copies of one prompt matched it to the end. Some then took a different word, all still coherent, as D-056 found for Qwen.
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

## D-055 · 2026-09-27 · MLX engine performance: catch up to mlx-swift-lm `main`, then per-conversation caching, before batching

**Situation:** Reviewed oMLX and Rapid-MLX in depth (both deferred, D-027) to see what performance work they actually do on top of stock MLX. Neither forks MLX core or `mlx-lm`; both pin stock versions and build orchestration above them, plus a handful of model-family-specific Metal kernels reached through `mx.fast.metal_kernel`, not a patched MLX. Verified in their source: continuous batching on `mlx-lm`'s own `BatchGenerator`; a block-hashed prefix cache (despite the "paged" name, this is storage and hashing around `mlx-lm`'s ordinary contiguous `KVCache`, not GPU paged attention); an SSD tier for that cache (safetensors, survives restarts); MTP and prompt-lookup speculative decoding; a wired-memory and buffer-cache limit set at startup; and narrow wins — a fused sampler (Rapid-MLX claims ~4.3ms/token removed), fused MoE gate+up (+7%), and compiled decode for specific models. `MLXEngine` (D-044) today has none of the orchestration layer: it serves one request at a time (`concurrentRequests: false`), keeps exactly one prompt-prefix cache for the whole server (`ReusableCache` — a second conversation evicts the first's, so agent + chat-page use thrashes it), sets no wired-memory or MLX cache limit, and `SeededSampler` sorts the full vocabulary for top-p/min-p/top-k on every token even at request defaults (temperature 0.8, top-k 40, top-p 0.95, min-p 0.05 — all three run). `mlx-swift-lm` is pinned to 3.31.3 (`project.yml`); 3.31.4 and `main` already carry MTP speculative decoding, compiled decode for Qwen3.5/3.6, `TurboQuantKVCache`, and prompt-cache saves that include SSM/hybrid-model state.

**Decision:** Close the gap in Swift, on `mlx-swift-lm`'s public API only — no custom Metal, no MLX core fork — in the order in IMPLEMENTATION_PLAN.md's new Phase 3c: extend the benchmark first so every later step has a number to move, then the mlx-swift-lm pin bump, the sampler fast-path, a wired-memory policy, a small per-conversation cache LRU (replacing the single `ReusableCache`) with an optional disk tier, prompt-lookup speculation, opt-in `kvBits`, and continuous batching last, ported from `mlx-lm`'s `BatchGenerator` shape (or mlx-swift-lm's closed PR #263) to bring `concurrentRequests` to MLX the way D-048 already brought it to GGUF. oMLX and Rapid-MLX stay deferred (D-027): this is the work "a real speed gap" would be measured against before reconsidering a Python runtime, and it avoids a Python runtime's packaging and update cost (D-027) while the gap is still unmeasured.

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
- **Claude Code's own requests,** replayed (15,300-token turns on Qwen3.6): **1.6–1.7 s per turn instead of 25.7**, once its late system messages stop rewriting the start of the prompt (D-041 amendment of the same day). Its 28,000-token permission check reused 24,576 tokens of the previous one's.
- **Sampled generation** (top-k 40, top-p 0.95, min-p 0.05): 86.0 against 83.3 tokens/s on Qwen3.6, 51.5 against 50.6 on Qwen3-8B. Greedy is unchanged.
- **Correctness:**
  - A code word planted at three depths of a 12,500-token log was recalled correctly on every cached turn, on Qwen3.6 and Qwen3.8.
  - Cached and uncached replies at temperature 0 were identical on Qwen3-8B (6 of 6 turns).
  - On Qwen3.6 they were identical for 3 of 6 turns and then diverged mid-reply into equally sensible text. The recurrent layers' chunked scan rounds differently when the prompt is split at other points, the same kind of difference D-043 records for llama.cpp's cached and uncached runs.

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
- **The problem.** The first comparison (D-063) found `quail-server`'s footprint growing with every conversation and never coming back down: Qwen3 8B reached 30 GB on the M1 Max, where oMLX peaked at 9 GB.
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

  Speed on the mini moved by more than the differences between settings from run to run, in both directions. The M1 Max run after the fixes (D-063) is the speed check.
- **The harness** passes Quail's own switches (`QUAIL_*`, but not `QUAIL_BENCH_*`) through to its server, for A/B runs like these, and logs them when it starts it.

**Revisit if:** Phase 3c step 8's batching port needs more than the public `mlx-swift-lm` API exposes (paged attention on the GPU, specifically, needs a gather-SDPA kernel neither project's own comments claim to have solved cleanly), or a fresh cross-runtime benchmark (Phase 3 step 8/12) shows oMLX or Rapid-MLX still meaningfully ahead once steps 1–8 land — then D-027's deferral is reopened with real numbers instead of an assumption.

## D-053 · 2026-09-26 · Developer distribution through Homebrew and a signed DMG

**Decision:** Quail is a free, open-source tool for developers on Apple Silicon Macs. Homebrew (`brew install --cask adatoo/tap/quail-ai`) is the primary installation path; the same Developer ID-signed, notarized app remains available as a DMG on GitHub Releases. Sparkle continues to provide in-app updates (D-032), with the cask's existing update behavior (D-033).

Mac App Store publication is dropped. This supersedes D-006's two-channel distribution plan and cancels the Store submission work in Phase 4, including Store-specific helper signing and removing Sparkle from a Store product. Existing App Store configurations, compile guards and CI checks remain unchanged for now; removing that legacy machinery, and updating AGENTS.md's corresponding conventions, is a separate cleanup task.

**Why:** the intended audience is the developer community, for whom Homebrew is an acceptable distribution channel. Maintaining a second distribution variant would take time from offline reliability, coding-tool compatibility, model curation and reproducible benchmarks.

**Release requirements:** retain Developer ID signing, notarization, signed updates, dependency notices and model licence review. Validate installation on a fresh Mac through Homebrew and the DMG, plus CLI availability and an update from an existing release. Dropping Store publication does not remove these requirements or expand the deferred runtime scope.

**Alternatives:** Maintain a reduced App Store edition as a discovery channel (rejected because it adds packaging and validation work for a secondary audience). Homebrew only (keep the DMG too, so installation does not require Homebrew).

**Revisit if:** demonstrated demand from users who require App Store distribution justifies maintaining and testing another product variant.

**Amended 2026-09-28 (Phase 4 step 5a):** the legacy machinery is gone:
- the `Quail-AppStore` scheme, and the `Debug-AppStore`/`Release-AppStore` configurations of every target;
- `Quail/Quail-AppStore.entitlements`;
- all 18 `APPSTORE` compile guards, each resolved to the direct build's branch;
- `task build:appstore` and its CI step, and `embed:cli`'s App Store skip;
- `AppInfo.isAppStoreBuild`.

AGENTS.md's rule to keep runtime installs behind `#if !APPSTORE`, and its two-scheme definition of done, went with them. Unchanged: notarization's App Store Connect API key (that's Apple's name for the notary credential), the Developer ID signing, Sparkle and the Homebrew cask. The fallback to llama.cpp for a runtime that can't start remains, for the deferred oMLX and Rapid-MLX.
## D-054 · 2026-09-27 · Keeping the Mac awake while the server runs, and with a laptop's lid closed

**Decision:** Settings → General → Power, plus a menu toggle, "Keep this Mac awake while the server runs". It's off by default.
- **The assertion:** while the server is starting or ready, Quail holds one `kIOPMAssertPreventUserIdleSystemSleep` power assertion (`KeepAwake`), the kind `caffeinate -i` takes, named "Quail is serving a local model…" in `pmset -g assertions`. It's released when the server stops, the setting goes off, or Quail quits. The display can still turn off. It needs no password or install, and it's allowed in the App Store build.
- **The lid-closed option (direct build only), "Also with the lid closed, when plugged in":** macOS sleeps a laptop when its lid closes whatever assertions an app holds; the header says so for this assertion type, and the old `PreventSystemSleep` type is unsupported. The only general switch is `pmset disablesleep`, which needs root. So `LidSleepGuard` asks once per launch, when the server first starts, through `do shell script … with administrator privileges` (the system's own password prompt), and starts a small root shell loop:
  - The loop sets `disablesleep 1` only while a "serving" flag file exists and `pmset -g ps` says AC Power, and `disablesleep 0` otherwise, every 3 seconds. Unplugging brings sleep back.
  - It ends when Quail's process is gone (quit or crash) or its "enabled" flag file is removed (the option turned off, or Quail quitting cleanly), and restores `disablesleep 0` on the way out.
  - Nothing is installed. The flag files live in `Application Support/Quail`, and paths that could break the loop's quoting are refused.
  - A reboot while it's on leaves `SleepDisabled 1` and the flag behind. The next launch sees both (`recoverIfLeftOn`) and asks for the password to restore sleep.

**Why:** requested. Utilities that do this have to be installed; built in, it's one switch, and it can follow the server's state. The user chose "while the server runs" over "while a model is busy" (pauses between an agent's requests would let the Mac sleep) and over a manual toggle, and chose the guarded lid-closed option.

**Safety:** a closed laptop running a model gets warm in a bag. That's why the lid-closed option runs only on AC power, only while the server runs, ends with Quail, and says so beside the switch.

**Alternatives:**
- A privileged helper daemon (`SMAppService.daemon`): a persistent root component to install, sign and update, for one command.
- Asking for the password at every server start and stop, which is tiresome.
- Clamshell mode: it needs an external display and keyboard, so it isn't general.

**Revisit if:** macOS offers a public lid-close assertion. (The legacy App Store configuration leaves the lid-closed option out, since the sandbox can't run `do shell script` as root; Store publication is cancelled by D-053.)

## D-052 · 2026-09-26 · What each model is good for: curated strengths, vision derived

**Decision:** Catalog families carry `strengths`, raw strings from a fixed vocabulary (`ModelStrength`): chat, coding, agentic, reasoning, long-context, vision, multilingual, embedding, audio.
- **Where they show:**
  - the Add Model sheet: chips under each family, and a "Good for" list with explanations in the detail pane;
  - a "Good for" filter next to the format filter;
  - the Models list: installed rows show their family's chips, matched as `InstalledLookup` matches them.
- **How each is decided:**
  - Each curated tag is checked against the model card; long-context comes from the config's trained context (≥128K). Revision 4 of `catalog.json` records the sources.
  - `vision` is never curated. It shows when the family's GGUF download has an `mmproj`, because that's the only way Quail passes images (D-047; the MLX engine is text-only), and not for an installed MLX copy.
  - `audio` is recorded when the model has it (Gemma 4 12B), but Quail can't pass audio, so it isn't a chip. The detail pane says "the model also understands audio; Quail can't pass that to it yet".
  - "Deep research" isn't a tag. It's reasoning plus long context plus tools, and the reasoning explanation says so.
- **What it replaces:** the single `role` word in the subtitle, which now appears only when it says something the chips don't ("smoke-test").
- **Recommendations:** unchanged. Strengths inform the choice; they don't rerank.

**Why:** requested ("highlight what the model is good for … allows users to make a more informed choice"). A single role string couldn't say that Qwen3.8 codes, reasons, uses tools and reads images.

**Alternatives:** Deriving everything from Hugging Face tags (inconsistent between uploaders, and a network call per family). Benchmark scores per task (no comparable source across families yet).

**Revisit if:** an engine gains audio or MLX vision (flip `isUsableInQuail`, or derive vision for MLX too), or a remote catalog needs a new strength. Older apps skip strings they don't know.

## D-051 · 2026-09-26 · Quail works offline, and a check proves it

**Decision:** Once models are downloaded, Quail needs no internet connection. `task check:offline` (`Config/check-offline.sh`) enforces this with `sandbox-exec`:
- quail-server (GGUF and MLX) and llama-server run with every connection beyond loopback fatal: load, chat, stream, `/v1/messages`, the web page.
- The Debug app runs on a scratch `QUAIL_DATA_ROOT` with those connections denied. The check drives it over its control socket (status, list, ps, config, default, ctx, bench, chat through its endpoint) and expects `pull` to fail at once with an offline message.
- opencode, Codex and Claude Code run from the app's own launch recipes in the same sandbox and must answer.

Only three things want the network, and each fails quickly and in plain words:
- The weekly catalog refresh and the Sparkle check run in the background and fail quietly.
- Hugging Face lookups (listing, fit headers, downloads) now carry request timeouts: 15 s for metadata, 30 s idle for downloads (URLSession's default is 60 s).
- Hugging Face lookups also map connection failures to `HFDownloadError.offline`: URL errors for no network, DNS or timeouts, and POSIX `EPERM`/unreachable from a firewall. The error reads "no internet connection — adding models needs one; installed models work as normal, and a download resumes where it stopped".

The Add Model list stops asking after its first offline answer. It fills the rest from `ModelShapeCache` where it can, or "Offline" otherwise, says "You're offline" at the top, and preselects the best candidate for the Mac's size instead of waiting for verdicts.

**Why:** requested ("we need to be able to work offline"). Tracing every network call showed the serving path was already local (D-044 had checked MLX). The Add Model sheet was the weak spot: it waited for every family's fit check before selecting anything, showed raw `URLError` dumps, and on a network that looks connected but goes nowhere took minutes. The first run of the new check also found that llama-server's router talks to its model processes over loopback, which is why loopback stays open in the strict profile.

**Alternatives:** `NWPathMonitor` to detect offline up front. It reports "satisfied" on a captive portal or behind a firewall, the cases that were slowest, so a failed request is the better signal. A real Wi-Fi-off test in CI isn't possible, since the runner needs its network.

**Revisit if:** a feature needs the network on the serving path (for example remote tokenizers), or opencode, Codex or Claude Code start requiring a connection at start-up.

## D-050 · 2026-09-26 · `quail launch opencode`: config in the environment, a private server, and every recipe sized to the model

**Decision:** `quail launch opencode` passes a whole opencode config in `OPENCODE_CONFIG_CONTENT`: a `quail` provider (`@ai-sdk/openai-compatible`, the key read from `QUAIL_API_KEY` with `{env:…}` so it isn't in the config text), the model with `limit.context` set to its context, and `model`, `small_model`, `agents.build` and `agents.plan` all pointing at it. It adds `--standalone` *after* the user's own arguments (a new `trailingArgs` in launch recipes and `ToolLaunch`), so `quail launch opencode -- run "…"` becomes `opencode run "…" --standalone`. Snippets and recipes gain `{{contextSize}}` (the model's context, 32768 when unknown) and `{{maxOutput}}` (min(8192, context/4)); Claude Code gets `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, Codex `model_context_window`, Goose `GOOSE_CONTEXT_LIMIT`, Zed and opencode their limits. Qwen Code joins Connect and `quail launch` (`qwen --auth-type openai --openai-base-url … --model …`, the key in `OPENAI_API_KEY`). The Connect tab lists MLX models as well as GGUF.
**Why:** opencode 2 runs a background service that clients share, and that service reads config when it starts, so config set in a client's environment never reaches it (checked with opencode 2.0.18: "Model unavailable: quail/…"). `--standalone` gives the run its own server, which does read it. opencode 2 only accepts `--standalone` after a subcommand, hence after the user's arguments. The user's global config often gives `build` and `plan` models of their own, which beat the top-level `model`, so those two are overridden; agents they define themselves are not. Without the context size, Claude Code assumes 200K and Goose 128K, so neither compacts before a local model's window overflows.
**Alternatives:** A temp `opencode.json` via `OPENCODE_CONFIG` (works too, but leaves a file behind, since the CLI `exec`s the tool). Editing the user's opencode config or restarting their background service (Quail never changes other tools' config, Phase 2b).
**Revisit if:** opencode's service learns to take per-client config, or opencode changes the `agents` key again (it was `agent` in 1.x).

## D-049 · 2026-09-26 · Model downloads queue, one at a time

**Decision:** `ModelInstallController` runs one download and queues the rest, starting each in order when the running one finishes, fails or is cancelled. The Add Model sheet shows the running download (which model and quantization, progress, Cancel) and the queue (with Remove) above whatever model is selected, and its button reads **Add to Queue** while something downloads; list rows mark a model that is downloading or queued. `recent` keeps how the last few ended, so `quail pull` reads its own result even when a queued download has already started, and `installedCount` tells views to reload.
**Why:** reported: while a download ran, the sheet replaced the model details with a progress bar that didn't say what was downloading, yet the list still let you pick other models. Freezing the list would make you wait for a large download before choosing the next.
**Alternatives:** Simultaneous downloads (they share one connection's bandwidth, so each finishes later; `HFDownloader` fetches one file at a time by design, D-015). Locking the sheet while downloading.
**Revisit if:** people want to reorder the queue or pause, or a download source where parallel transfers are faster.

## D-048 · 2026-09-25 · Concurrent requests for GGUF: slots on one unified context

**Situation:** `quail-server` decodes one request at a time. Leases are counted, not exclusive, so several requests reach the engine together and queue on `LlamaRuntime`'s dispatch queue; each waits for the ones before it. llama-server (the runtime being replaced) serves four requests at once (`-np` auto is 4, with a unified KV cache), so Claude Code sub-agents, an editor's autocomplete beside a chat, and the app's own chat page beside an agent all overlap there and don't here. D-043 listed this as the largest deferred piece.
**Measured 2026-09-25, llama-server b11081 on this machine (Apple M4 Pro, 64 GB), four simultaneous 128-token requests, temperature 0, tokens per second across all four:**

| Model | serial (`-np 1`) | batched (`-np 4`) | gain | last request finishes after |
|---|---|---|---|---|
| Qwen3-0.6B Q8_0 | 226 | 507 | 2.2x | 2.3 s vs 1.0 s |
| Qwen3.6-35B-A3B Q4_K_M (mixture of experts) | 51.5 | 82.3 | 1.6x | 9.9 s vs 6.2 s |
| Qwen3-8B Q4_K_M (dense) | 41.5 | 40.8 | none | 12.3 s vs 12.6 s |

One request alone, `-np 1` vs `-np 4`: 44.7 vs 40.8 tok/s (8B), 157.6 vs 228.7 (0.6B), 50.0 vs 52.0 (35B-A3B): a single stream isn't slowed beyond noise (the 8B's 9 % is the one to re-check). So batching pays where decoding is not already compute-bound (small models, few active experts) and costs nothing in aggregate where it is; the last request never finishes later, but for a dense model the *first* of four finishes later than it would in a queue (12.6 s for all four against 3.1 s for the first), which is the price of fairness. The gain is larger when requests share a prompt prefix; the loss is nil when only one request is active.
**Decision (to build):** N slots (sequences) on **one context with a unified KV cache** (`n_seq_max = N`, `kv_unified = true`), so memory is what one context costs today (the slots share the pool; a lone long request can still use all of it), a `--parallel N` option on `quail-server` (a per-model setting later), **default 4 as in llama-server if the single-stream check passes (within 3 % of `--parallel 1` on Qwen3-8B, Qwen3-0.6B and Qwen3.6-35B-A3B), else 1**.
**Design:** the engine's dispatch queue runs a scheduler instead of one request's loop. `generate` becomes "enqueue a request and its continuation"; the scheduler, while any request is waiting or active, (1) gives each waiting request a free slot, the one whose cached prefix matches best (so a returning conversation finds its own slot), (2) builds one batch: a token per decoding slot, then prefill tokens from prefilling slots up to `n_batch`, round-robin, (3) `llama_decode`, (4) for each slot that wants a token, samples from the batch row's logits (`llama_get_logits_ith(i)`) with **that slot's own** sampler chain, grammar and UTF-8 assembler, emits it, and checks stop, length and cancellation. State per slot: sampler, grammar, cached tokens (the prefix reuse D-043 has, per sequence), position, the request's cancel flag and continuation. A request that can't get KV cells (the unified pool is full) evicts the least recently used *idle* slot's sequence and retries, and fails with the existing "exceeds the context" 400 only if none is left to evict. Cancellation is per slot at each step and leaves the slot's cached prefix as far as it got, as now. A prompt with images (D-047) is evaluated by libmtmd's own decode calls, so the scheduler runs it as an exclusive step and clears just that sequence afterwards (`llama_memory_seq_rm`). Each slot has its own seeded sampler chain, so a request's text doesn't depend on its neighbours except through numerical noise in batched kernels; the checks below are on text at temperature 0 and count any difference.
**Built (amended 2026-09-25), with these differences and findings:** `LlamaRuntime` runs the scheduler as one block per step on its queue (`LlamaScheduler.swift`), so `tokenize` and the like run between steps; `n_seq_max = N` and `kv_unified` come on for N above 1, `--parallel N` (or `-np`) sets N for every GGUF model and a preset's `parallel`/`np` per model, and `/props` reports `total_slots`. **The default stays 1, not 4:** the single-stream check could not be settled on this machine, which was too loaded (OrbStack near 700 % CPU, load average above 18, repeat runs of the same setting varying by 20 %); the runs that were quiet enough on Qwen3-8B gave 36.0, 43.3 and 44.1 tok/s at `--parallel 1` against 42.1, 41.1 and 39.5 at 4, which is within the noise but not proof of the 3 % bound. The app can pass `--parallel 4` (or a preset) once step 7 measures a quiet machine. **Slot choice was reworked after tests:** taking "the slot with the longest shared start" evicted other conversations' caches for the sake of a shared system prompt, so a request takes the free slot that *loses the least* (an empty slot, or one whose cache the prompt carries on from, loses nothing; otherwise the one whose cache the prompt diverges from soonest, then the one holding more of the prompt, then the least recently used), and then copies the start it shares with whichever slot holds most of it (`llama_memory_seq_cp`, a change of owner in a unified cache; only for models whose memory can shift, so not recurrent ones, and only for 32 or more tokens). **Measured, Debug build, Qwen3-0.6B Q8_0, four requests of 128 tokens at temperature 0:** 197 tok/s one after another against 474 together (2.4x), text identical to serial for 4 of 4; Qwen3-8B Q4_K_M 41.7 against 43.6 (1.05x), identical for 2 of 4, the other two differing after 230 and 520 of 540 characters (batched kernels round differently, as in llama-server). **Tests (model-gated, Qwen3-0.6B):** four requests together equal four alone; a client leaving among three doesn't change the others' text and its slot serves the next; a returning conversation gets its own cache (`cache_n` at least prompt minus one) and a prompt sharing a start gets that start from the other slot with the same answer as decoding it all; constrained and plain requests side by side; a hundred mixed requests with clients leaving at random leave no slot held. An image prompt is evaluated as an exclusive step and leaves its sequence empty. Not measured: the benchmark suite itself against `--parallel N` (the suite drives one stream, which the tests above and the single-stream numbers cover).
**Not in this design:** MLX (mlx-swift-lm 3.31.3 has no batched generation we have verified; it stays serial and says so in `EngineCapabilities`), speculative decoding, `/slots` save and restore, per-slot context sizes, priorities between requests.
**How it will be verified:** 2 and 4 parallel requests each equal their serial output at temperature 0 (differences counted and looked at); aggregate tokens per second beats serial on the small and mixture-of-experts models and matches it on the dense one; one client hanging up doesn't disturb the others (the survivors' text is unchanged); a returning conversation reuses its slot's prefix (`cache_n`); grammar-constrained, tool-call and image requests run beside plain ones; the benchmark suite still measures a single stream; a stress run of 200 mixed requests with random hang-ups leaves no slot or sequence held.
**Alternatives:** One context per slot (memory times N, and a lone long prompt limited to 1/N of it). Continuing to queue and shipping the parity gate as it is (agents that fire parallel calls see each wait for the last). Running several `quail-server` processes (each loads the model).
**Amended 2026-09-27 (the parity gate settles the default, and hybrid models get checkpoints):**
- **`--parallel` now defaults to 4,** as llama-server's does. Running Claude Code for the gate showed why one slot isn't enough. Its permission check (a 28,000-token prompt with another system prompt) took the only slot between two turns of the conversation, so the next turn re-read its whole 15,000-token prompt. The slots share one context, so four cost no memory beyond a hybrid model's recurrent state per sequence (tens of MB). Single-request speed measured the same, alternating one and four slots A-B-A-B: Qwen3-8B generation 47.0 against 46.9 tokens/s, prompt 404–417 against 403–405 at 512 tokens and 372–375 at 4,096; Qwen3.6 35B-A3B 56.1–56.2 against 56.1, and 770–791 against 769–773.
- **Slot choice for a model whose memory can't share a start** (recurrent, hybrid, sliding-window: no `seq_cp` donor copy) now carries on from a slot only if the prompt follows at least half of its cache, as llama-server's `--slot-prompt-similarity 0.5` does. Otherwise it takes an empty slot, then the least recently used. Before, the permission check shared its first ~20 tokens with the conversation and took its slot for them.
- **Checkpoints for those models.** libllama can't drop the tail of a recurrent or sliding-window sequence, so `keepPrefix` used to reset the slot. Every Qwen3.5-family GGUF turn (Qwen3.6, Qwen3.8) re-read its whole prompt. Now, for a request with `cache_prompt`, the scheduler stops a prompt's chunks at every 4,096 tokens and 64 short of its end. It saves the sequence's partial state there (`llama_state_seq_get_data_ext` with `LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY`), at most eight per slot, as llama-server's context checkpoints do. A later prompt that parts from the cache restores the last checkpoint before the parting point and cuts the attention cache to match.
- **Measured** on Qwen3.6 35B-A3B Q4_K_M:
  - Claude Code's replayed turns started replying in 3.2 s and 1.3 s instead of 27 s.
  - A live `claude -p` task took 116 s against llama-server's 110 s. Its second and later turns started in 0.6–1.2 s, and its second permission check reused the first's instructions.
  - A code word planted in a 12,500-token log was recalled on every cached turn.
  - Checkpointing a 15,000-token prompt cost nothing measurable (23.2 s against 22.6–23.1).
  - A model-gated test (`QUAIL_TEST_HYBRID_MODEL`) checks the next turn resumes near the end, and a prompt that parts at 5,000 tokens resumes from the checkpoint at 4,096.

**Amended 2026-09-29 (long prompts after a busy spell, #138):** idle conversations now leave the shared cache, and sliding-window models no longer take checkpoints.
- **The problem.** The first comparison (D-063) had Quail slower to first token than llama-server on 4,096-token prompts: 7.8 s against 6.1 s on Gemma 4, and about 10% on Qwen3 8B and Qwen3.6. That level runs right after eight requests at once.
- **Measured on the Mac mini:**
  - Timing a 4,096-token prompt on a fresh server and again after a round of eight requests, cooled before each, showed where the time went. Quail matched llama-server fresh but not afterwards: 11.5–12.0 s against 10.3–10.6 s on Qwen3 8B.
  - Emptying the idle slots closed the gap. Their conversations, left in the pool for their next turn, sit in the cells every chunk of the new prompt attends over. llama-server moves idle slots out on every new request (`--cache-idle-slots`, on by default, into its `--cache-ram` prompt cache).
  - `swa_full = false`, llama-server's setting, made Gemma 4 slower here: 7.3 s against 6.9 s after the round.
  - Quail's own thread pool made no measurable difference.
- **Idle sequences are parked (`ParkedSequences` in QuailServerCore, tested):**
  - **When:** a text request starts on a model with several slots.
  - **What:** every other idle slot's sequence is copied out with `llama_state_seq_get_data_ext`, with its checkpoints, into ordinary memory, and the slot is emptied.
  - **Restoring:** a prompt that shares more of its start with a parked sequence than with any slot (at least 32 tokens) gets it copied back into its slot first. What that slot held is parked in turn.
  - **Budget:** llama-server's 8 GB, or an eighth of a smaller Mac's memory. The least recently parked go first.
  - `QUAIL_LLAMA_PARK=0` turns it off.
  - This costs memory for parked conversations, where before they sat in the preallocated pool. In exchange, one conversation's prompt no longer pays for every other one's history.
- **No checkpoints for sliding-window models.** libllama's default full-size window cache (`swa_full`, which Quail keeps) cuts back like a plain one.
  - Checked on Gemma 4: a prompt sharing half of an earlier 4,109-token prompt reused 2,051 tokens without checkpoints. The reply was identical to one with no cache.
  - The two state copies of up to 800 MB per long prompt are gone.
  - Recurrent and hybrid models (Qwen3.5 and 3.6) still checkpoint. No interval checkpoint is taken within 64 tokens of the last one: a 4,109-token prompt had stopped at 4,045 and again at 4,096. A checkpoint's buffer is no longer zeroed before libllama fills it.
- **Result** on the Mac mini, a 4,096-token prompt after eight requests at once, cooled before each, two runs each:

  | | Before | Now | llama-server |
  |---|---:|---:|---:|
  | Qwen3 8B | 11.5–12.0 s | 10.2–10.9 s | 10.3–10.6 s |
  | Gemma 4 26B-A4B | 6.8–6.9 s | 5.8–6.2 s | 6.0–6.3 s |

  The M1 Max's gap was larger than the mini's. Its re-run after the fixes (D-063) is the check that it's closed there too.

**Revisit if:** the benchmark shows a single-stream regression, libllama's unified-cache behaviour under memory pressure is worse than described, or MLX gets batched generation.

## D-047 · 2026-09-25 · Images: `data:` URLs only, a marker in the prompt, the bytes beside it

**Decision:** A request's images are accepted as base64 `data:` URLs (chat completions `image_url`, Anthropic `image` blocks with a `base64` source, Responses `input_image`) and **never fetched**: an `http(s)`, `file:` or bare-path image is a 400 that says to send a data: URL. **Why:** fetching whatever address a request names is a network and privacy decision (server-side request forgery from a page's script to the local network, or a leak of the user's address to a third party) that the server shouldn't make for a client; llama-server does it, and the app's chat page and every local tool can send bytes. Each image is capped at 32 MB decoded.
**Design:** in `ChatMessages.normalize` an image part becomes a text part holding `<__media__>` (libmtmd's default marker, as in llama-server), so the chat template renders it wherever that model wants an image, and the decoded bytes go in `GenerationRequest.media` in marker order beside `promptText` (the rendered prompt). An engine that reads images tokenizes `promptText` itself, turning each marker into the image's embeddings; `promptTokens` stays the text's own tokenization, for the context check. A request with images to an engine without `EngineCapabilities.vision` is a 400 ("can't read images yet"), and to a model whose projector isn't loaded (`EngineInfo.supportsImages`) a 400 saying it has no mmproj.
**The engine (amended 2026-09-25):** `LlamaEngine` loads a model's `mmproj` file with libmtmd (`mtmd_init_from_file`, from the xcframework already linked) and sets `capabilities.vision` and `info.supportsImages`; **a projector that is missing, doesn't fit the model or can't read images fails the model's load**, as in llama-server. A request with images decodes them (`mtmd_helper_bitmap_init_from_buf`: JPEG, PNG, BMP, GIF; video files refused), has libmtmd tokenize `promptText` into text and image chunks, and evaluates the chunks into an emptied context one at a time, so a client that leaves stops it between chunks (a long text chunk or one image's encode is not interruptible). The reply's `max_tokens` is capped to what the context has left after the image tokens, and a prompt that doesn't fit is a 400 with llama-server's message. **No prefix reuse for a prompt with images:** the memory is cleared before and after such a request, so the next text request starts clean (the cache keys are token ids, and an image has none). The marker is checked against `mtmd_get_marker` at load. The projector's log lines go through the same warn-and-error filter as llama.cpp's.
**Checked against llama-server b11081 on SmolVLM2-500M-Video (Q8_0, with its Q8_0 projector), a generated 224x224 test image (two colour halves and a green square), temperature 0:** three questions (colours, a one-sentence description, a count) gave **identical text and identical prompt token counts (149 to 151) to llama-server**; two images in one message, `/v1/messages` `image` blocks and `/v1/responses` `input_image` parts work; text requests after an image request are unchanged (no `cache_n` on the first, reuse on the second); undecodable bytes are a 400. A model-gated test (`QUAIL_TEST_VISION_MODEL`, passed to the tests as `TEST_RUNNER_QUAIL_TEST_VISION_MODEL`) covers these on any vision model; the fixture image is `TestFixtures/Images/blocks.png`.
**Rules matched to llama-server (found by comparing, not reading):** a message with images is joined into one text, newlines between parts but none next to a marker, whatever the template's style (llama.cpp's `concat_content_parts`; for a template that only reads typed parts that text is then one typed part), and a template that only reads typed parts gets *every* message's string content as a typed part (before, a multi-turn conversation with such a template had its plain strings left as strings, and its prompt differed by seven tokens). The reply's tokens are placed by where the prompt ended, not by the memory's own count, because an M-RoPE model gives an image's tokens a smaller span than their number. **Qwen2.5-VL-3B (Q4_K_M, its Q8_0 projector, an M-RoPE model): ten questions about the test image gave text identical to llama-server's in ten of ten** (five of ten before the joining rule was matched), and SmolVLM2 ten of ten, plus image-first, image-between-texts and image-then-text-turn conversations, all with equal prompt token counts.
**Not yet:** prefix reuse across images; MLX vision (`MLXVLM`) isn't scheduled; audio input stays a 400.
**MLX models read images too (amended 2026-09-26):** reported: Qwen3.8 27B MLX refused an image, because the MLX engine loaded every model text-only (`LLMModelFactory`). Gemma 4 was asked for next and added in the same change.

**Which models:** an MLX folder whose `config.json` has a `vision_config`, whose `model_type` names an `MLXVision.Family`, and that has its processor config. The families are:
- `qwen3_5` and `qwen3_5_moe`: the Qwen3.5, 3.6 and 3.8 family;
- `gemma4`: Gemma 4 26B-A4B and 31B. Gemma 4 12B is `gemma4_unified`, which mlx-swift-lm doesn't load with its vision half.

`ModelEntry.supportsImages` reports such a model, and `/v1/models` `input_modalities`, `/props` and the chat page follow from that.

**When the vision half loads:** only when an image arrives. mlx-swift-lm's vision models generate text at about half the speed of its text models: Qwen3.6-35B-A3B measured 11 against 20 tokens a second on the same machine. So a model loads text-only, as before. A request with images reloads it through `VLMModelFactory`, from the same local folder with no download, and the next request without images reloads it text-only. Each switch takes a few seconds from the page cache. A chat with an image in its history resends it every turn, so it stays on the vision load.

**Gemma 4 26B-A4B:** it only loads that way. mlx-swift-lm's text-only Gemma 4 lacks the mixture-of-experts layers, so it failed with "Unhandled keys [experts, router…]", while the vision model has them. When the text-only load fails for a model that has a vision half, the engine loads the vision half and keeps it. That also fixes Gemma 4 26B-A4B MLX, which never loaded in Quail before: 25 tokens a second.

**How an image turn runs:**
1. The engine puts the template's own placeholder where each marker is: `<|vision_start|><|image_pad|><|vision_end|>` for Qwen, `<|image|>` for Gemma 4.
2. It runs each image through the model's processor (`Qwen3VLProcessor` or `Gemma4Processor`).
3. It widens each image token (`MLXVision.expand`; the library's own versions are internal):
   - Qwen: t·h·w/merge² pad tokens;
   - Gemma 4: begin-of-image, its `image_seq_length` soft tokens (280), then end-of-image.
4. It generates from a fresh cache and keeps nothing for the next request. Positions after an image aren't a plain token count, so the prefix can't be reused.

**Other changes:**
- Text turns on a vision load (Gemma 4 26B-A4B) skip the sliced prefill, because only the iterator's `prepare` resets the model's position state. They pass the prompt as a batch of one (`[1, n]`), which is what the vision half's language model reads: a flat prompt crashed it.
- **Colour fix:** Qwen's image path in the library renders pixels without colour matching, which leaves them in Core Image's linear working space. Mid-tones came out too dark, and the model read orange as red. The engine applies the sRGB tone curve first; Gemma 4's processor already does. After that, a four-colour test came back exact on all three models, and a text-reading test on Qwen3.8 and Gemma 4.
- Refusals now name both ways Quail reads images (`ImageInput.unsupportedMessage`).
- The catalog marks an MLX variant `vision` once checked: Qwen3.8-27B, Qwen3.6-35B-A3B and Gemma 4 26B-A4B.

**Why GGUF is simpler:** libmtmd does the processing and token accounting for every architecture it supports behind one call, given the `mmproj`. For MLX, each architecture's processor, placeholder and token layout is written into Quail, family by family.

**Revisit if:** a client genuinely needs remote images (a flag that allows named hosts, off by default), or the marker differs across libmtmd versions (the engine checks it at load).

**Amended 2026-10-01 (Muse Glimmer 30B):** a third MLX image family, `.museGlimmer`.
- mlx-swift-lm registers Muse Glimmer only as a vision model, so it always loads through the existing fallback, and text turns run on the vision load too, one request at a time.
- **The placeholder is `<|patch|>`.** Each widens to `<|image_start|>`, one `<|patch|>` per merged patch (t·h·w/merge²), then `<|image_end|>`, as the library's `MuseGlimmerProcessor` does.
- Its processor applies the sRGB curve itself.
- **Checked:** it named the three colours of the test image and where each is.

## D-046 · 2026-09-25 · Automation acts as a GitHub App, not a personal access token

**Decision:** The Auto-merge and Dependabot-bump workflows authenticate as a GitHub App, `quail-release` (Contents and Pull requests: read and write, installed on this repo only), minting a one-hour installation token per run with `actions/create-github-app-token` from the secrets `RELEASE_APP_CLIENT_ID` and `RELEASE_APP_PRIVATE_KEY` (Actions and Dependabot stores). This replaces D-024's `BOT_TOKEN` fine-grained PAT, which was never added: auto-merge never switched on, and every PR since needed a hand merge.
**Why an App:** actions taken with `GITHUB_TOKEN` start no workflows, so a merge or a bump push made with it would neither release nor re-run the checks. A PAT works but belongs to a person, expires, and is broad; an App's token is short-lived, scoped to one repo and attributed to the App. OIDC isn't an option: GitHub's OIDC tokens are for cloud providers, not for its own API.
**Without the secrets** both workflows say so in a notice and skip, as they did without `BOT_TOKEN`; a PR is then merged by hand.
**Revisit if:** a merge queue replaces auto-merge, or the App's key needs rotating (regenerate it, replace the secret in both stores).

## D-045 · 2026-09-25 · Constrained output: JSON mode, `response_format`, `json_schema` and `grammar` for GGUF

**Decision:** `LlamaEngine` samples under a GBNF grammar (`GenerationRequest.grammar`, `EngineCapabilities.grammar`), and the shared layer builds the grammar from the request: llama-server's own `grammar` (GBNF, passed through) and `json_schema` fields, and OpenAI's `response_format` (`json_object`, which llama-server reads as "an object" and which may carry a `schema`, and `json_schema`; `text` is no constraint). `/v1/responses` maps `text.format` onto the same (its schema sits beside the type, chat completions nests it). Anthropic's API has no such field. **MLX refuses with an accurate 400** ("the engine serving this model can't constrain its output yet") because mlx-swift-lm has no grammar sampler and a logit processor would need a grammar engine of our own; not scheduled.
**Schema to grammar:** `JSONSchemaGrammar` (`QuailServerCore`) is a Swift port of llama.cpp's `json-schema-to-grammar.cpp` at b11081 (libllama doesn't include it): primitives and their rule names, objects (required properties in order, then optional ones), `additionalProperties` (false, a schema, or any), arrays (`minItems`/`maxItems`, `items`, `prefixItems`), strings (`minLength`/`maxLength`, `format` date, time, date-time, uuid), integers with `minimum`/`maximum`/exclusive bounds, `enum`, `const`, `oneOf`/`anyOf`, `allOf`, type lists, and `$ref`/`$defs` into the same document. **Any other keyword that constrains a value (`pattern`, `not`, `if`, `patternProperties`, `multipleOf`, `minProperties`, `uniqueItems`, and so on) is a 400 naming it**, not a silent loosening. A schema is converted when the request is parsed, so a bad one is refused before a model loads.
**Sampling, as llama-server does it:** the token is drawn from the normal sampler chain first and kept if the grammar allows it (checked by applying the grammar to that one token); only if not, the logits are masked by the grammar and drawn again through the chain. The prompt's tokens are fed to the chain (as before, for penalties and DRY) but never to the grammar. A grammar libllama can't parse is a 400 from the engine (`EngineError.invalidRequest`), and the engine stays usable.
**Reasoning models (the difference that mattered):** Qwen3-style templates make the model write `<think>…</think>` first. A grammar that starts at the first token forces JSON where the model's preferences are meaningless, and it answered `-7777777777777777` to "days in a week" where llama-server says `7`; llama-server lets the thinking block come first. So for a template that supports thinking, the schema's grammar is `("<think>" text-without-"</think>" "</think>" up to two newlines)? json-root` (and without the `<think>` opener when the template already opened it). The whitespace after `</think>` is capped at two newlines: unbounded, the model preferred whitespace forever over `{` until the token limit. A client's own `grammar` is used as written. Harmony (gpt-oss) is a 400 for constrained output until its channels get a grammar.
**Checked against llama-server b11081 on Qwen3-8B Q4_K_M:** 27 schemas (objects, optional properties, nesting, enums, unions, integer and length bounds, arrays and tuples, `$ref`, additional properties, formats, allOf, JSON mode, JSON mode with a schema) times five seeds, every reply parsed and validated with `jsonschema`: **26 of 27 schemas valid on both servers**, and the same one fails on both (`optional`: the model never stops adding tags before the 500-token limit). The exact text is not identical (47 of 81 seeded runs match; most differences are whitespace, because llama-server's newer chat parser builds its own grammar with different layout rules); validity is the contract, byte parity for constrained output isn't attainable. Unit tests cover the converter's rules, request parsing, capability refusal, Harmony and the thinking wrapper; a model-gated test loads Qwen3-0.6B and checks a grammar bounds the reply and a bad grammar leaves the engine usable.
**Forced `tool_choice` (amended 2026-09-25):** `tool_choice: "required"` and a named function (chat completions' nested form, Responses' flat form, Anthropic's `any` and `tool` with its name) make the reply a call, by a grammar built from the tools' own parameter schemas: `{"name": <const>, "arguments": <the tool's schema>}` for each tool (any tool for `required`, one for a named choice), in the model's call format. **Hermes JSON** (Qwen 2.5/3): `<tool_call>` `\n`? the JSON `</tool_call>`, after the thinking block when the template has one; `parallel_tool_calls: true` (Anthropic's `disable_parallel_tool_use` false is the default) allows one or more, the default being one as in llama-server. **Bare JSON** (Llama 3.x): the whole reply is `{"name": …, "parameters": …}`. **Qwen XML and Harmony, and templates with no known call format, are a 400 naming the format**, per format until each gets a grammar. A named tool that isn't in `tools`, forcing with no tools, and combining it with `response_format`/`grammar` are 400s; MLX is the capability 400. The tools' parameter schemas go through the same converter, so an unsupported keyword in one is a 400 that says so. `tool_choice: "auto"` stays unconstrained: a lazy grammar that starts at `<tool_call>` is not done. **Checked on Qwen3-8B Q4_K_M, four prompts the model would answer in prose ("Say hello", "What is 2+2?", "Tell me a joke", "Thanks!"), required and named, five seeds each: 20 of 20 replies were a single call of the right tool whose arguments validate against its schema. llama-server b11081 on the same requests: 4 of 20** (it ignores a named choice and lets a reasoning model run on to the token limit). Not compared for Llama 3's bare JSON (no such model on disk); the grammar's shape is unit-tested.
**Not yet:** vision and concurrent requests (see D-043's list).
**Alternatives:** Refuse `response_format` and keep only the `grammar` field (clients like the OpenAI SDK's structured outputs would still fail). Start every grammar at the first token (worse than llama-server, above). Loosen unsupported keywords quietly (a reply that looks valid but isn't).
**Revisit if:** llama.cpp's converter gains keywords we get asked for (`pattern` is the likely one), or a template's thinking format differs from `<think>…</think>`.

## D-044 · 2026-09-25 · The MLX engine: `mlx-swift-lm` in the `quail-server` tool

**Decision:** `quail-server` loads MLX models (a folder with `config.json`, safetensors and a tokenizer, as `HFDownloader` installs them) with `MLXEngine` (`QuailServer/MLX`, part of the tool target), on `mlx-swift-lm` **3.31.3** (exact; the version the D-027 spike ran; 3.31.4 exists) and `swift-transformers` **1.3.4** (exact) for the tokenizer. **Why in the tool and not a library like `QuailServerLlama`:** a static-library target can't be handed a package's C modules (`Cmlx`, `_NumericsShims`, `yyjson`): Xcode fails the compile with "Unable to resolve module dependency", with or without explicit modules. The tool target links them fine. The cost is that the engine can't be imported by the unit tests, so **it has no automated test**, only the live checks below; a test bundle also couldn't find the Metal shaders (they are found next to the executable or in the app's Resources), and MLX aborts the whole process when it can't. The engine keeps its logic small for that reason.
**Design:** generation goes through `ModelContainer.perform`, so requests are served one at a time; token ids come from `generateTokenTask` (text and tool-call parsing stay in the shared chat layer, D-038/D-040), and a `NaiveStreamingDetokenizer` turns them into text without splitting a character. Sampling is mlx-lm's own order (top-p, min-p, top-k, temperature) in a small `SeededSampler` of ours, because the library's samplers draw from a random state they create themselves and so cannot honour a request's `seed` (checked: the same seed gives the same text, another seed another text); penalties are the library's (repetition, presence, frequency over the last 64 tokens); `ignore_eos` bans the end-of-sequence tokens in a logit processor. **Prompt-prefix reuse** keeps the KV cache between requests and, for the next prompt, trims it to the common prefix (`cache_n` 1,510 of 1,517 in the check); a model whose cache can't be trimmed starts over. What the cache holds afterwards is reconciled with what was actually fed (the library's iterator feeds each token as it returns it, and its `.cancelled` stop reason also stands for "hit the token limit", which the engine maps to `length`). The chat template, BOS and EOS strings and `max_position_embeddings` are read from the model folder (`chat_template.jinja` or `tokenizer_config.json`, `config.json`), so the same shared renderer builds the prompt for both formats: the Qwen3 prompt is 18 tokens under GGUF and MLX alike, `/tokenize` and `/detokenize` are identical to llama.cpp's on five inputs including emoji and special tokens. `parse_special: false` in `/tokenize` can't be honoured (the tokenizer always recognises special-token text).
**Build and shipping facts (D-028's, now real):** `xcodebuild` needs `-skipPackagePluginValidation -skipMacroValidation` (added to every call, `XCODEBUILD_TRUST` in the Taskfile); Xcode 26 needs the Metal Toolchain to compile mlx-swift's shaders (the CI and release workflows install it when `xcrun --find metal` fails: about 840 MB per job on a runner without it, **untried on GitHub's images until this PR's CI runs**); `swift-collections` stays pinned at 1.3.0. mlx-swift's shaders are a resource bundle, `mlx-swift_Cmlx.bundle`; `embed:server` copies it into `Quail.app/Contents/Resources` (where the library looks for it when the server sits in an app's `Contents/MacOS`) and signs it, and fails the build if it is missing. **Two things that did not work and are recorded so they aren't retried:** the bundle in `Contents/MacOS` next to the server isn't found (the main bundle is then the app, so the library looks in its Resources), and a bare `mlx.metallib` in `Contents/MacOS` loads fine but `codesign` refuses the app ("code object is not signed at all" for that file). `verify:bundle` checks the bundle is there; a missing one would abort the server on the first MLX load. The server binary grows from 3.5 MB to 35 MB and the app from 47 to 82 MB (Release). `ARCHS` were already arm64-only for shipped builds.
**Dependencies that came with it (all pinned by Package.resolved):** mlx-swift 0.31.6, swift-numerics, swift-syntax 600.0.1 (macro support, not linked into the server), swift-huggingface 0.11.0, swift-crypto 4.5.2, swift-asn1, yyjson 0.12.0, EventSource. This is more than D-028 expected (*checked 2026-09-25: `task check:mlx-offline` runs the server under `sandbox-exec` with every outbound IP connection fatal, loads Qwen3-8B 4-bit and generates; it succeeds, so none of the extra packages' network code runs on the MLX path. It needs a built app and a model, so it is a manual check; a unit test and `task notices:check` stop a package joining unrecorded*): `swift-transformers` 1.3 puts its tokenizer behind `Hub`, which needs `swift-huggingface`, crypto and yyjson, though Quail uses none of their download code (D-002 keeps downloads in `HFDownloader`). **Open:** the repository has no third-party notices file, and several of these (Apache-2.0, MIT) require their licence text and notices to ship with the binary; the same is true today of Sparkle and llama.cpp beyond `LICENSE-llama.cpp`. That needs a NOTICES mechanism before the App Store submission (Phase 4). *(Closed 2026-09-25: `Config/third-party.json` records every resolved package and whether it ships, `Config/generate-notices.py` (`task notices`) builds `Quail/Resources/THIRD_PARTY_NOTICES.md` from it and the packages' own licence files, `task notices:check` is in `task ci`, a unit test fails when a resolved package isn't in the record, and Settings → General → About → Third-party licences shows the file (renamed from "Open-source licences" in 0.28.1, which people looking for licences or attribution didn't find); it also lists the code mlx-swift vendors inside itself (mlx, mlx-c, metal-cpp, fmt, nlohmann/json). Still to check with a lawyer before the App Store submission; llama.cpp's own release carries no notices for what it vendors beyond its MIT file.)*
**Verified on this machine with Qwen3-8B 4-bit (`mlx-community`), against llama-server b11081 on Qwen3-8B Q4_K_M:** chat, `/v1/messages` (with a tool call), streaming, `cache_prompt` on and off, `ignore_eos`, seeds, hang-up mid-generation (the next request took 0.27 s), and answers that agree ("Paris", "391"). A Developer-ID-signed Release build (hardened runtime, one Team ID) passes `codesign --verify --deep --strict`, runs MLX and GGUF models from the app bundle, and `task ci` (both schemes) passes. **Decode speed**, 128 tokens, five runs after a warm-up, Release build from the signed app: MLX 4-bit **53.5 tok/s** (52.9 to 53.7) against llama-server's **46.3** (45.1 to 46.8); the two models are not the same weights or quantization (4-bit MLX against Q4_K_M), so this compares the stacks, not the maths, and the D-023 gate must still measure on an idle machine. **Not verified:** *(notarization of the new bundle: verified by the 0.21.1 release run, 2026-09-25), a model whose cache can't be trimmed (the fallback is written), vision models, several sizes and families (Llama, Gemma, gpt-oss), memory behaviour with a large model loaded next to another. *(Amended 2026-09-25: a hang-up during a long prompt. The library processes the whole prompt inside `TokenIterator`'s initialiser, so a client that left during a 20,000-token prompt was noticed only when it finished: the next request took **71.5 s**. `MLXEngine` now prefills in slices of the library's step size (512 tokens, the same call `LLMModel.prepare` makes) and checks for cancellation between them, leaving the last one to two slices to the iterator so the penalty processors still see the prompt's tail; the next request after a hang-up at 0.3 s took **1.9 s**, at 5 s **1.0 s**. Two findings: `ModelContainer.perform` runs its closure in a task of its own, so `Task.isCancelled` never became true there and the request's cancellation also travels by a flag of ours; and a cancelled prefill leaves what it processed in the cache for a retry (a retry after a cancelled 6,000-token prompt reused 1,539 tokens). Output is unchanged: four prompts of 15 to 3,220 tokens give the same text as 0.21.1's engine at temperature 0, and prompt speed is within noise.)*
**Not in v1 (as for D-043):** grammar output (`response_format`, forced `tool_choice`), vision, DRY/XTC/typical-p/mirostat, and decoding several requests at once.
**Alternatives:** `MLXHuggingFace` for tokenizers (pulls `swift-huggingface` and macros for a downloader Quail doesn't use). Writing our own BPE tokenizer to avoid `swift-transformers` (a large, bug-prone job for byte-level BPE, SentencePiece and their pre-tokenizers). A separate `mlx-server` process (D-014, superseded by D-027).
**Revisit if:** the notices work or the dependency footprint becomes a problem, mlx-swift-lm's generation API changes (3.x moved things before), or the static-library limitation is fixed and the engine can be tested.

**Amended 2026-09-30 (a commit pin for MLX 0.32.2, #139):** mlx-swift-lm is pinned to commit `0dcfe2f8a` on its main branch (2026-09-29) instead of a release, which brings mlx-swift 0.32.2 and MLX core 0.32.2.
- **Why:** with eight requests decoding at once, a step on MLX 0.31.1 (what mlx-swift 0.31.6 bundles) took about a third longer than on 0.32. The same held for mlx-lm itself, so it's MLX core, not Quail. The Mac mini (M4 Pro), Qwen3 8B 4-bit, eight rows, median step:

  | | MLX 0.31.1 | MLX 0.32 |
  |---|---:|---:|
  | mlx-lm's `BatchGenerator` | 75.4–84.9 ms | 56.5–58.4 ms |
  | Quail | 78.0–81.6 ms | 60.7–62.0 ms |
- **Why a commit:** mlx-swift 0.32.2 came out on 2026-09-28. mlx-swift-lm 3.31.4, the latest release, caps mlx-swift below 0.32, and its main branch took 0.32.2 the same day, unreleased. Swift packages can't override a dependency's version range.
- **What changed for Quail:**
  - `newCache` now throws, and the prompt step size moved to `GenerateParameters.prefill`. The library's own iterator (image turns) keeps its old prompt chunking (`.remainder`).
  - **Gemma 4 images keep their aspect ratio.** The library's processor now sizes each image to fit Gemma 4's 280-token budget without distorting it, so an image's token count is its own (a 96-pixel icon is 256, not 280). Quail now counts each image's tokens from its frame, `(height / patch) × (width / patch) / pooling²`, and pads the images onto the largest one's canvas, as the library's own `Gemma4Processor.prepare` does. Checked with one image and with two of different shapes, on Gemma 4 and Qwen3.6.
- **Replies at temperature 0 change** slightly on some prompts, because MLX 0.32's kernels round differently: the same request gives the same text every time, but not always the text 0.61 gave. Batched replies still match their solo runs for a first stretch, then may take a different word, as D-056 describes.
- **Model copies (D-066):** both were compared with this commit and stay. The copy test now accepts a commit pin.
- **Moving back to a release:** as soon as mlx-swift-lm releases a version that takes mlx-swift 0.32 or later, the pin moves to it (#149, with the steps). `.github/workflows/mlx-release-watch.yml` checks every Monday while the pin is a commit: it reads the latest release's `Package.swift`, and once that release takes mlx-swift ≥ 0.32 it comments on #149 and fails, so GitHub emails the owner. It stops when the pin is an `exactVersion` again.

**Amended 2026-10-03 (back to a release, #149):** mlx-swift-lm is pinned to **3.32.3** (2026-09-30), which brings mlx-swift **0.32.3**.
- **The release changes no library code:** its only changes since `0dcfe2f8a` are its Package.swift, which now requires mlx-swift 0.32.3, its README and its tests. Quail's model copies were checked against it, and their headers say so.
- **mlx-swift 0.32.3 fixes a crash at launch on macOS before 26.4** (ml-explore/mlx-swift#491 and #493). 0.32.2's logger calls `os.Logger.isEnabled(type:)`, which libswiftos only has from macOS 26.4. Every quail-server built against 0.32.2, which is Quail 0.61.8 to 0.72.x, imports the symbol strongly with a deployment target of macOS 14 (`nm -m`: `(undefined) external …isEnabled4type…`). dyld refuses to start such a binary on macOS 14 and 15, and on 26.0 to 26.3, so the default runtime couldn't start there. Neither the M4 Pro (26.6) nor the bench M1 Max (27.0) could show it. The new quail-server has no reference to the symbol.
- **Checked** on the M4 Pro with a Release build:
  - Qwen3.6 35B-A3B, Gemma 4 26B-A4B and Bonsai 2 27B (MLX) each answered a text question.
  - Qwen3.6 and Gemma 4 each named the three colours of `TestFixtures/Images/blocks.png` and where they are.
  - With eight requests at once on Qwen3.6, alternating with 0.67.3 (mlx-swift 0.32.2), the new build made 142–155 tok/s and the old one 124–156, on a busy Mac. One run of each fell outside that range at a moment of high load (100 and 124).
- **The weekly watch** (`mlx-release-watch.yml`) now does nothing, as the pin is a release.

## D-043 · 2026-09-25 · The GGUF engine: `libllama` through llama.cpp's xcframework, in its own module

**Decision:** `quail-server` loads GGUF models with `LlamaEngine` (`QuailServer/Llama`), a separate static library (`QuailServerLlama`) linked into the `quail-server` tool and the tests but not into `QuailServerCore`, so the seam types in `Engine.swift` and `ModelEntry.swift` became `public` and the tool hands its engines to `QuailServerApp.run(arguments:engines:)`. A format with no engine in a build still says so. **The library** is llama.cpp's own `llama-<tag>-xcframework.zip` at the same tag as the bundled `llama-server` (b11081), fetched by `task vendor:llama` with its own line in `Vendor/llama.sha256`, staged whole in the git-ignored `Vendor/llama.xcframework`, linked by Xcode, and embedded by `embed:llama` into `Quail.app/Contents/Frameworks/llama.framework`, thinned to arm64 (8 MB) and signed like everything else there. `quail-server` finds it through the rpath `@executable_path/../Frameworks` (Debug builds run from the products folder also find the copy beside them). `verify:bundle` checks the framework is present and **starts** `quail-server`, since a bad rpath, architecture or Team ID only shows at launch.
**Design:** one engine instance, one model, one request at a time (the router's lease already guarantees it). Every C call runs on one dedicated dispatch queue, never on Swift's cooperative pool, because `llama_decode` blocks. Prompts decode in `n_batch` chunks and the loop checks for cancellation between chunks and between tokens, so a client that leaves during a 20,000-token prompt frees the model in well under a second (measured). **Sampling** is llama-server's default order: penalties, top-k, top-p, min-p, temperature, then the seeded draw; temperature 0 is greedy; `ignore_eos` bans every end-of-generation token, as llama-server does. **Prompt-prefix reuse** (`cache_prompt`): the engine remembers the tokens whose keys and values are in the context, keeps the common prefix with the next prompt, drops the tail with `llama_memory_seq_rm` (clearing everything for a model whose memory can't drop a tail), and always re-decodes the last prompt token because sampling needs its logits; `cache_n` matches llama-server's exactly. **Text:** token bytes are assembled into UTF-8 so a character split across tokens is never sent in halves; special tokens are rendered (what Harmony needs, and what llama-server's `/detokenize` returns). **Context:** the model's `ctx-size` if the preset sets one, else the smaller of its training context and 32,768 (llama-server defaults to the full training context and then shrinks it to fit memory; this one has no fit step yet, so it caps). llama.cpp's own logging is reduced to warnings and errors in the server's stderr (`QUAIL_LLAMA_VERBOSE=1` for all of it).
**Not in v1:** *(DRY, XTC, typical-p, top-n-sigma and mirostat: done 2026-09-25, see below; grammar output, `response_format` and `json_schema`: done 2026-09-25, D-045)*; forced `tool_choice` and image parts (`libmtmd` vision): done 2026-09-25, D-045 and D-047; a memory-fit step for the context. Each is a follow-up, none is needed for the parity gate's task (Claude Code doing a tool-using job, step 7).
**Verified against llama-server b11081 on this machine (Qwen3-0.6B Q8_0 and Qwen3-8B Q4_K_M):** six chat prompts at temperature 0, including a Japanese one and a reasoning one, give identical text and reasoning as llama-server, with equal `cache_n`; `/tokenize` and `/detokenize` are identical for ten inputs (multi-byte, emoji, special tokens parsed and not); the chat template, BOS and EOS in `/props` are identical; a 1,517-token prompt with a different last question is served with 1,510 tokens from the cache, as llama-server does; hanging up mid-generation and mid-prompt frees the model at once; a prompt over the context is a 400; the same seed gives the same text, except that llama-server and this engine both differ slightly between a cached and an uncached run of the same request (a batch of one token and a batch of many round differently); tool calls come back through `/v1/chat/completions`, `/v1/messages` and `/v1/responses` from Qwen3-8B. A build signed with the Developer ID identity (hardened runtime, one Team ID for the app, `quail-server` and `llama.framework`) passes `codesign --verify --deep --strict`, launches and generates. **Speed**, Qwen3-8B Q4_K_M, 128 tokens, five runs after a warm-up: 32.7 tok/s (median; 31.8 to 33.0) against llama-server's 33.3 (32.9 to 33.5), about 2% apart, measured while the app held a 35B model on the same GPU, so the parity gate must measure again on an idle machine (D-023, D-027). **Not verified:** notarization of the framework (the release run will), the App Store build's sandbox running it, Llama 3 and gpt-oss models, and models whose memory can't drop a tail (the fallback is written, not exercised).
**Amended 2026-09-25, the sampler options:** `EngineCapabilities` joined the `Engine` seam (`extraSamplers` now; grammar, vision and concurrency will join it), and `GenerationSettings` parses llama-server's `dry_multiplier`, `dry_base`, `dry_allowed_length`, `dry_penalty_last_n`, `dry_sequence_breakers`, `xtc_probability`, `xtc_threshold`, `typical_p` (and the older `typ_p`), `top_n_sigma`, `mirostat`, `mirostat_tau` and `mirostat_eta` for every engine. `LlamaEngine` builds llama-server's chain (penalties, DRY, top-n-sigma, top-k, typical-p, top-p, min-p, XTC, temperature, draw; mirostat replaces the truncation samplers and the draw) and reports the capability; the MLX engine has none of them, so a request that sets one is served without it and the server log says so. Two differences found by comparing with llama-server and fixed: the samplers that look back now **see the prompt** (llama-server feeds it in, so the repetition penalty and DRY act on the prompt's tail; before, only the reply was counted), and DRY's `-1` window (the whole context) is passed as the context size, since the C API reads a negative window as none. **Checked:** three prompts by twelve settings (each option alone, a combination, the older penalties, temperature 0) with a fixed seed give text identical to llama-server's in **36 of 36** runs of 100 tokens on Qwen3-0.6B; the engine test checks each option changes the output and that a seed repeats it.
**Alternatives:** Compile llama.cpp from source into the server (a submodule and a CMake build inside an Xcode project for what the release asset already gives). Keep spawning `llama-server` (the thing this replaces). Put the engine in `QuailServerCore` (every test and the app's model tests would then link and load libllama).
**Revisit if:** the gate's speed measurement shows a real gap, or a llama.cpp bump changes the C API (the tag pins both the server and this library, so they move together).

## D-042 · 2026-09-25 · `quail-server` serves one small chat page of its own at `/`

**Decision:** `GET /` (and `/index.html`) returns a single self-contained page (`WebUI.swift`, about 300 lines of HTML, CSS and JavaScript; no framework, no build step, no request to another host): the build label, the model list with Load / Unload, and a chat with an optional system prompt, streaming replies with a Stop button, the model's reasoning in a collapsed "Thinking" block, and a tok/s line. Conversation lives in the page only (Clear or reload drops it); no attachments, no markdown rendering, plain pre-wrapped text. It talks to the same API as every other client (`/v1/models`, `/models/load|unload`, `/v1/chat/completions`, `/props`), so it works for GGUF and MLX models alike. `--no-webui` turns it off (404; `/props` reports `"ui": false`), as llama-server's flag does. `/favicon.ico` answers 204.
**Why not llama.cpp's UI:** D-027 planned to vendor `llama-<tag>-ui.tar.gz` (3.1 MB, 75 files, pinned by sha256 like the binaries). Rejected: it is a blob to pin, verify and bump with every llama.cpp release; it is built around llama-server's own endpoints and settings (`/props` fields, `/slots`) that an MLX engine has to imitate to keep it working; and it is one more thing Quail ships but doesn't own. A page that only needs the shared API is ours to keep small. This supersedes the "serve llama.cpp's UI" line of D-027 and its "we'd lose the web UI" answer. It narrows D-001 and D-021 further: the *app* still has no chat window, but the server it ships now has one page.
**API key:** the page itself is served without a key (it contains nothing secret) and every call behind it needs one, as D-039 has it. The user pastes the key into the page once; it is kept in `localStorage` for that origin and sent as a Bearer token. Not done, on purpose: putting the key in the URL to save typing it, because URLs end up in synced browser history. The one-time ticket that replaces it is below.
**Hardening, because it renders text a model wrote:** model output only ever enters the page as `textContent` (checked live: `<b>` and `<img onerror>` in a prompt come back as literal text, no element is created). The Content-Security-Policy allows exactly this script and this style by sha256 (computed at startup from the embedded strings, so an edit can't leave it stale), `connect-src 'self'`, `default-src 'none'`, `base-uri 'none'`, `form-action 'none'`, `frame-ancestors 'none'`; plus `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `Cache-Control: no-store`. A test fails if the source contains `innerHTML`, `eval`, `document.write`, `new Function`, any `http(s)://` URL, an inline handler or style attribute, or a `fetch` to anything but a path on this server; another asserts the script is valid JavaScript (JavaScriptCore). The Origin/Host guard (D-036) already lets a page served by the server call it and refuses every other page or host name.
**Verified live:** headless Chrome driving `quail-server --engine echo --api-key …`: without a key the page says so and focuses the field; with it the models and build label load, a message streams back, Load and Unload change the listed state, Stop ends a stream and keeps its partial text, the wrong key is reported, light and dark themes render (`docs/images/`), and the console shows no CSP violation. **Not verified:** a real model (the engines are steps 4 and 5), Safari and Firefox.
**Alternatives:** Vendor llama.cpp's UI (above). No page at all: `quail chat` and the runtimes' UIs (a user of `quail-server` with MLX would have nothing to open in a browser). Render markdown (needs a parser we'd have to trust with model output; plain text first).
**Signing in from the app (amended 2026-09-25, step 6):** the ticket hand-over mentioned above is built. The app's "Open Chat in Browser", with Quail server as the runtime and a key set, asks `POST /auth/ticket` (behind the key) for a one-time ticket: 32 random bytes, valid 30 seconds, used once, held in memory only (`KeyTickets`, at most 16 outstanding). It opens `/#ticket=…`. The page removes the fragment with `history.replaceState` before any request, then trades the ticket at `POST /auth/exchange` (open, but only from the page's own origin through `RequestGuard`, and the ticket is the secret) for `{"key": …}` (`null` when the server has no key) and keeps the key in `localStorage` as before. A fragment never reaches the server or a `Referer`, and it is gone from the address bar and history before the exchange. The key is never in a URL. A used or expired ticket leaves the page asking for the key. **Checked in headless Chrome against a real `quail-server`:** the page opened signed in and listed a GGUF and an MLX model, the address bar showed no fragment, and reopening the same link asked for the key. llama.cpp's page can't take a key this way, so with llama.cpp chosen the menu opens it as before.
**A fuller page (amended 2026-09-25):** you chose to extend this page rather than serve llama.cpp's richer one, so it now has most of what people used that one for. **Conversations** kept in the browser's IndexedDB (in memory if it gives none), listed in a sidebar with new, search, rename and delete, titled from the first message, each remembering its model and system prompt, and restored on reload. **Settings** in a dialog, kept in `localStorage` for every chat, blank meaning the server's default: temperature, max tokens, top-k, top-p, min-p, seed, the three penalties, DRY, XTC, typical-p, top-n-sigma, mirostat, stop strings, thinking on or off (`chat_template_kwargs.enable_thinking`) and a JSON reply (`response_format`); the GGUF-only ones say so and aren't sent for an MLX model (`/v1/models` now reports each model's `format`). **Markdown** replies through our own parser (`WebUIMarkdown`): headings, emphasis, strikethrough, inline and fenced code with a copy button and the language, block quotes, nested lists, tables with alignment, rules, links (http(s) and mailto only, `noopener`), and maths shown as code; no syntax highlighting. It builds a plain tree and then DOM nodes, never HTML, and is tested in JavaScriptCore on normal and hostile input. **Per message:** copy, edit and resend (a user message), regenerate (a reply), delete, and the speed and token count. **Export and import** as JSON; a file shaped like llama.cpp's export (`conv` plus `messages`) is read too, text only, from what we know of that format rather than a real export. Deliberately not copied: llama.cpp's tool/MCP panel, a prompt-template editor, and per-chat settings (settings are per browser). **Attachments (second slice):** images for vision models, pasted, dropped or picked, sent as `data:` URLs (D-047) and shown as thumbnails, which is why the policy gained `img-src data:` (nothing is fetched); an image for a model without a projector is refused on the page before anything is sent. Text files (up to 256 KB, by type or extension) go after the message's text in a fenced block, named. Both are saved with the chat and kept when a message is edited. The model picker shows each model's format, state and vision. **Checked in headless Chrome against a real `quail-server`:** signed in by ticket, both formats listed, settings saved, a Markdown reply rendered as a list and a code block, regenerate at temperature 0 gave the same text, edit and delete worked, the chat survived a reload, search and import worked, the GGUF-only settings were marked for the MLX model, and the chat list folds away on a narrow window. Attachments, on SmolVLM2 and Qwen3-0.6B: an image to the text model was refused before sending, the same image to the vision model got "The image contains red and blue colors.", a CSV reached the text model, and the image chat reloaded with its thumbnail. The page is about 1,250 lines of Swift string constants (markup, style, parser and script), still one response with no other request.
**llama.cpp's service worker (amended 2026-09-26):** llama.cpp's page registers a Workbox service worker at `/sw.js` that serves its precached copy of `/` for the origin, so once the app ran `quail-server` on the same port the browser went on showing llama.cpp's page (and a model chosen there never reached our server). `quail-server` answers `/sw.js` and `/service-worker.js`, without a key and only while the page is on, with a worker that skips waiting, deletes every cache, unregisters itself and reloads the open pages; our page also unregisters any worker and clears Cache Storage when it loads. **Checked in headless Chrome:** llama.cpp's page opened with its worker controlling it; after the switch the next visit showed ours, with no registration left.
**Refined after use (amended 2026-09-26):** the model picker follows what the server has loaded (this chat's model if loaded, else the loaded one) until you pick one yourself; one Load/Unload button reflects the picked model's state, with a status dot; the API key and the system prompt moved behind top-bar buttons (the key panel opens by itself on a 401); the composer is one box that grows with the text; settings are grouped (basics, word choice, repetition, advanced), each with an ⓘ panel saying what it does with a good and a bad value; the dialog's scrolling area has room for focus rings. Icons are inline SVG in the markup, still no request to anywhere.
**A picker with details (amended 2026-09-26):** the model picker is a button over a listbox instead of a native `<select>`. Each model shows:
- its name, with an MLX folder's `owner--` prefix moved into the details;
- a GGUF/MLX badge, the owner, the size on disk and the context it loads with;
- "vision", and "loads at start" for the app's default;
- its state (loaded, loading, failed).

The status dot sits inside the button, where Safari's native select had drawn its text over it. To support this, `/v1/models` gains three Quail-only fields beside `format`:
- `size_bytes`, measured once at discovery;
- `context_size`, from the preset;
- `load_on_startup`.

The hidden `<select>` stays the source of truth, so nothing else in the script changed. The listbox is operable from the keyboard: arrows, Home and End, Enter, and Escape.
**Revisit if:** the page keeps growing towards a full chat app (D-001's reasons apply again), or keeping it inline in the binary gets in the way (a build step would then be worth it).

## D-041 · 2026-09-25 · `/v1/messages` and `/v1/responses` are translations onto the chat pipeline

**Decision:** Anthropic's Messages API (`/v1/messages`, `/v1/messages/count_tokens`; what Claude Code speaks) and OpenAI's Responses API (`/v1/responses`) are served by rewriting the request into the chat-completions body the pipeline already takes (`AnthropicRequest.chatBody`, `ResponsesRequest.chatBody`), running `startChat` (template, tokenizer, `ChatOutputParser`; the same code as D-038 and D-040), and writing the reply back in each API's own shape. So reasoning, tool calls, stop strings, the reasoning-open template case and the client-hang-up handling behave identically on all three routes, and a fix to one is a fix to all. **Mapping:** `system` (a string or text blocks) becomes a system message; `tool_use` and `tool_result` blocks become `tool_calls` and `tool` messages (Responses: `function_call` and `function_call_output` items); `thinking` blocks travel back as `reasoning_content`; `input_schema` / flat function tools become the nested OpenAI form. Replies: text, `thinking` (empty `signature`) and `tool_use` blocks with `stop_reason` `end_turn` / `max_tokens` / `tool_use`; Responses `message`, `reasoning` and `function_call` items, `incomplete` when the token limit cut it off. `usage.input_tokens` is the prompt the model processed and `cache_read_input_tokens` the cached part, as llama-server reports them. **Streams:** Anthropic's `message_start` → `content_block_start/delta/stop` → `message_delta` → `message_stop`, closing each block (a thinking block with its `signature_delta`) before the next opens; Responses' `response.created` … `response.completed` with `sequence_number`, `output_index` and `content_index` on every event. A tool call goes out whole (one `input_json_delta`, one `function_call_arguments.delta`), as in D-040. Neither stream ends with `[DONE]`; errors are that API's (`{"type":"error",…}` on `/v1/messages`, an `error` event mid-stream). `x-api-key` and `Authorization: Bearer` already both work; `anthropic-version` is accepted and ignored.
**Verified:** shapes recorded from the vendored llama-server b11081 running Qwen3-8B (`TestFixtures/Messages`); a test replays the same scenarios through `quail-server` and fails if any field llama-server sends is missing (mutation-checked), plus 27 behaviour tests over the scripted engine (block order, every stop reason, tool round trips, errors, `count_tokens`). **Not verified:** a real Claude Code or Codex session against `quail-server`; the engines don't exist yet (steps 4 and 5), so that check is part of step 7's parity gate.
**Deliberately different from llama-server:** stream blocks close in order (its `signature_delta` and every `content_block_stop` arrive at the end); Responses events carry the sequence and index fields OpenAI's do and reasoning is an output item (its Responses route drops it); `/v1/messages` errors are Anthropic-shaped; an empty `messages` is a 400 (it answers with an unrelated reply).
**Refused or ignored, and why:** `tool_choice` `any` / a named tool, `text.format` other than text, images and documents: a 400 (grammar sampler and vision engine, steps 4 and 5). `previous_response_id`: a 400, since quail-server keeps no conversations. Tools the provider runs itself (`web_search_…`, `file_search`) are dropped from the tool list without an error: a local model has nothing to call them with, and failing would break a Claude Code session that sends them. `stop_reason: "stop_sequence"` and the matched `stop_sequence` aren't reported (like llama-server, a stop string ends the reply as `end_turn`); a client that needs which one matched is out of luck until the shared layer reports it. Fields with no local meaning (`metadata`, `service_tier`, `thinking.budget_tokens`, `store`, `parallel_tool_calls`) are accepted and ignored.
**Alternatives:** Native handlers per API over the engine (three copies of template, reasoning and tool logic to keep equal). Only the Anthropic route (Codex and other OpenAI clients speak Responses now; llama-server has both).
**Amended 2026-09-26:** Claude Code 2.1 sends some instructions (its environment block) as a message with role `system` among the others, which the translation refused. A `system` message's text now joins the top-level `system` text in order, as one system message first, since most chat templates allow only that. Found by running Claude Code against `quail-server` for the parity gate.
**Amended 2026-09-27:** only a `system` message that comes before the first assistant message still joins the system prompt (Claude Code's environment block). A later one stays where it is, as user text: appended to the user message before it, or as a user message of its own after a tool result. Claude Code 2.1.283 adds a `<total_tokens>N tokens left</total_tokens>` system message after each tool result, and N changes every turn. Hoisted to the top, it changed the prompt's first tokens every turn, so no prompt cache could ever be reused, on either engine: every Claude Code turn re-read its whole 15,000-token prompt. Kept in place, those messages stay put in the history, and a replayed Claude Code session went from 25.7 s to 1.6–1.7 s per turn on Qwen3.6 35B-A3B (MLX, with D-055's caches), and from 49 s to 3.1–3.5 s on Qwen3-8B Q4_K_M (GGUF), where only the first 3,144 tokens had been reused before. Found by timing Claude Code's requests through a logging proxy while measuring D-055's caches.
**Revisit if:** a client needs `stop_sequence` reported or fragment-by-fragment tool arguments; when the grammar sampler lands (step 5), `tool_choice` and `text.format` can be honoured on all three routes at once.

## D-040 · 2026-09-25 · Tool calls: read from the model's text by family, sent whole

**Decision:** A chat reply's tool calls are parsed out of the generated text by `ChatOutputParser`, for the format the model's template says it speaks (`ToolCallFormat.detect`, from what the template renders for a call): **Hermes JSON** (`<tool_call>{"name","arguments"}</tool_call>`, Qwen 2.5/3), **Qwen XML** (`<tool_call><function=NAME><parameter=KEY>VALUE…`, Qwen3-Coder and Qwen 3.5/3.6), **bare JSON** (Llama 3.x: a reply that is exactly `{"name","parameters"}`), and **Harmony** (gpt-oss channels). A family with no known format (Gemma) keeps calls as content, as llama-server does; so does a request with no tools. The reasoning splitter runs first, then only the answer text is searched for calls. **Wire shape** as llama-server's (captured from real Qwen3-8B and Qwen3.6-35B runs): `message.tool_calls[]` with a 32-character `id`, `type: "function"`, `function{name, arguments}` (a JSON string), `content: ""`, `finish_reason: "tool_calls"`; streamed as `delta.tool_calls[]` with `index`. **Deliberately different:** a streamed call goes out whole in one delta instead of argument fragments — a partial-JSON parser for a fragment's worth of latency — which every client that concatenates `arguments` handles. A block that isn't a valid call (bad JSON, a tool the request didn't offer, cut off by `max_tokens`) is given back as content rather than dropped. Qwen XML values are typed by the tool's own JSON schema (a `string` parameter stays `"007"`; a `number` becomes `2.5`). Text before a call loses the layout newline the model put there.
**Verified:** against real model output, not invented samples: Qwen3-8B (Hermes) and Qwen3.6-35B-A3B (XML) on five conversations each (two parallel calls, a call after thinking, typed arguments, no call, a call with a system prompt) — the parsed calls, their `arguments` strings byte for byte, the content and the reasoning equal llama-server's, at four chunk sizes (`TestFixtures/ToolCalls`). The same fixtures also confirm the shared template renderer (D-035) on a fifth family: our Qwen3.6 prompts equal llama-server's exactly.
**Not verified against a real model:** Llama 3 (bare JSON) and gpt-oss (Harmony) are written from each format's specification and chat template, and tested on constructed examples only; no such model was available here. Harmony also assumes the engine decodes its special tokens (`<|channel|>` …) into the text, as llama.cpp does for that model — the engines of steps 4 and 5 must, or its calls can't be seen. Mistral's `[TOOL_CALLS]` and DeepSeek's formats are not implemented. Treat these as unproven until a real model runs through them (step 7's parity gate has Claude Code do a tool-using task, which is the check).
**Refused, not ignored:** `tool_choice` other than `auto`/`none` (forcing a call needs the grammar sampler, step 5).
**Alternatives:** Stream arguments fragment by fragment (needs a resumable JSON parser; nothing needs it). Parse in each engine (D-038's argument). Ask the model to emit JSON with a grammar (step 5, and only for forced calls).
*(Amended 2026-10-02, from Quail's own BFCL scores (D-070 amendment): four models' calls were coming back as text.* **gpt-oss:** the engine ends generation at `<|call|>` and keeps the token, so a call's arguments end with the output rather than at the tag. The Harmony parser now takes whole-JSON arguments at the end as the call. Before, every gpt-oss call was text: BFCL scored it 0 on every category but irrelevance (20% overall). **Llama 3.1:** it writes `<|python_tag|>` before a call and joins several with `;`. The bare-JSON parser now reads both. llama-server b11306 answers that reply with a 500. **Qwen XML:** a `<function=…>` block whose body is a JSON object (MiMo V2.6) is that object, not an empty call. Several functions in one `<tool_call>` are several calls. Each fix has a test made from the model's real reply.)*
*(Amended 2026-10-02, Llama values: most of Llama 3.1 8B's remaining BFCL failures, on Quail and llama-server alike, were numbers written as strings, `"base": "10"` for an integer. A bare-JSON call's string value is now read as its parameter's schema type, as Qwen XML values are: `"10"` becomes `10` for an integer, `"true"` a boolean, `"[1, 2]"` an array. A string parameter, one the schema doesn't name, and a value that doesn't parse stay as written. Hermes JSON is unchanged: it hasn't been seen to do this.)*
**Revisit if:** a client turns out to need fragment streaming, or a family's format is added — add its template and a captured run to the fixtures first.

**Amended 2026-09-28 (Gemma 4):** a fifth format, found when the benchmark harness's smoke test (D-063) saw Quail return Gemma 4 26B-A4B's calls as text on both engines, on `/v1/chat/completions` and `/v1/messages`, while llama-server, Ollama and oMLX parsed them.
- **The format:** `<|tool_call>call:NAME{key:<|"|>text<|"|>,n:2.5,flag:true,list:[…],obj:{…}}<tool_call|>`. Keys are bare, strings sit raw between `<|"|>` marks with nothing escaped, and numbers, booleans and `null` are JSON's. It's detected as llama.cpp detects it, by the template containing `'<|tool_call>call:'`. The arguments come out as compact JSON in the order written, as llama-server writes them. Also accepted, since it costs nothing: keys and strings quoted either way. A closing tag inside a string doesn't end the call.
- **Reasoning:** Gemma 4 thinks in `<|channel>thought…<channel|>`, not `<think>`. `ReasoningTags` now gives the family's tags to the splitter, to the check for a prompt that leaves reasoning open (Gemma 4's newer template does, after a tool result with thinking on), and to the grammar that lets constrained output follow a thinking block. Gemma 4 writes an empty thought channel after a tool result even with thinking off, and can end a reply with another or with a stray `<channel|>`. So for this family a thought block counts wherever it comes, and a lone closing tag is dropped, as in llama.cpp's own parser.
- **Differences from the other formats:** text before a Gemma 4 call keeps its newline, because llama-server keeps it. Forcing a call (`tool_choice` `required` or named) is refused with a 400 naming the format, as for Qwen XML: its arguments aren't JSON, so the JSON-schema grammar can't express them yet.
- **The template renderer was wrong for Gemma 4 too (D-035):** swift-jinja 2.5.1 keeps one space where jinja2 strips all whitespace before `{%-`/`{{-`/`{#-`, whenever that whitespace follows a literal `{`. It does this on purpose, so the brace can't merge into `{{`. Gemma 4's tool declarations came out as `parameters:{ properties:{ city:{ type…` instead of `{properties:{city:{type…`, which is a different prompt from the one the model was trained on. `ChatTemplate` now prints such a brace with `{{ '{' }}` before handing the source over.
- **Verified against real output:** Gemma 4 26B-A4B (unsloth Q4_K_M under llama-server b11081) on seven conversations: the five of the other captures (with thinking on for `call-thinking`, since Gemma's template defaults it off), nested arguments (an array, an object, a number, a boolean and a string with quotes), and a reply after a tool result. The parsed calls byte for byte, the content and the reasoning equal llama-server's at four chunk sizes (`TestFixtures/ToolCalls/gemma-4-26b.json`). Our prompts equal llama-server's for all seven. Both Gemma 4 templates, the GGUF's and mlx-community's (they differ), render the five template cases byte for byte as llama.cpp does (`TestFixtures/ChatTemplates`).
- **Python literals in Qwen XML (2026-09-29):** the first BFCL run on the benchmark laptop found Qwen3.6 writing `True` for a boolean parameter. Quail kept it as the string `"True"`, so the call failed BFCL's type check, while llama-server's parse was right, because its grammar holds typed parameters to JSON. A parameter whose schema says boolean now reads `True`/`False` as booleans, and `None` is read as null for any type except string. It cost Qwen3.6 two of eight `parallel` cases and one of eight `multiple` cases on both Quail engines.
- **Left as it is:** llama-server passes `enable_thinking: true` to any template that can think. Quail passes only what the request sends, so Gemma 4 on Quail doesn't think unless asked, while on llama-server it does (Qwen3's template reads a missing value as on, so it isn't affected). Changing Quail's default is a separate decision.

**Amended 2026-10-01 (Muse Glimmer):** a sixth format, `ToolCallFormat.museGlimmer`, read by its own parser (`MuseGlimmerParser`), as Harmony is, since it carries the reasoning too.
- **The format:** Meta's template writes each turn as `<|start|>ROLE to=RECIPIENT<|message|>BODY` ended by `<|eom|>` (more to come) or `<|eot|>`. The generation prompt already wrote `<|start|>assistant`, so a reply starts in its first header.
  - `to=self` is reasoning.
  - `to=user`, or no recipient, is the answer.
  - `to=NAME` is a tool call whose body is an ATEM block: `<atem:function_calls><atem:invoke name="NAME"><atem:parameter name="KEY">VALUE</atem:parameter>…`.
  - Detected by the template containing `<atem:function_calls>` and `to=self`.
- **Values:** written raw and possibly over several lines. A string parameter is kept exactly, spaces included, as the template promises. A parameter the tool's schema types otherwise is read as JSON, as mlx-swift-lm's `ATEMToolCallParser` does. Several invokes in one block are several calls. A block that doesn't parse, or names a tool the request didn't offer, is given back as content.
- **Reasoning strength:** OpenAI's `reasoning_effort` is passed to the template as `reasoning_strength`, which Muse Glimmer's reads (low, medium, high, xhigh; its default is high), and as `reasoning_effort`, which gpt-oss's reads. A value in `chat_template_kwargs` wins.
- **Constrained output and forced calls, on the GGUF engine (2026-10-01):** the grammar writes the headers too, since a reply starts inside its first one.
  - **Constrained output:** an optional reasoning message (` to=self<|message|>…<|eom|><|start|>assistant`), then ` to=user<|message|>` and the JSON (`ReasoningTags.museGlimmer`).
  - **Forced calls:** each call is ` to=NAME<|message|>` and its ATEM block, with the schema's parameters in order, required ones always present. A string, a string-or-null or an untyped parameter is any text without `</atem:parameter>`; a string enum is one of its values; any other type is JSON from the schema, which the parser reads as JSON. Parallel calls are joined by `<|eom|><|start|>assistant`, as the template writes them.
  - llama.cpp's grammar sampler matches the special tokens (`<|message|>`, `<|eom|>`, `<|start|>`) by their text, as Gemma 4's `<channel|>` grammar already relies on.
  - **Verified** with bartowski's Q4_K_M under quail-server: a `json_schema` request came back schema-valid after its reasoning; `tool_choice` required and named each gave one call with typed arguments; a request for two calls at once gave both. Asked less directly, the model makes one call and waits for its result, forced or not.
  - **Still refused:** Harmony, and the MLX engine, which has no grammar for any model.
- **Verified against real output:** bartowski's Q4_K_M under quail-server, and mlx-community's 4-bit on the MLX engine. Each thought, called the tool, answered from its result and read a test image.
  - The template renders the five template cases byte for byte as llama-server b11081 does (`TestFixtures/ChatTemplates/golden/muse-glimmer`, dates aside; see its README).
  - The parser's tests use constructed replies in the shape the real ones took.
  - The same GGUF under llama-server b11081 gave the same answer and call, and reasoning of the same length, on the three text requests.
- **llama-server** has its own Muse Glimmer parser. Two fixes to it came after b11081: #29242 for a call's first parse, and #29615 for `json_schema`. So the bundled llama.cpp moves to b11306. On it the same GGUF gave the same replies, and a `json_schema` request came back valid after its reasoning.

## D-039 · 2026-09-25 · The API key is on by default while llama-server is the runtime

**Decision:** `Config.apiKeyEnabled` now defaults to `true`. A fresh install generates a key at launch (32 random bytes, Keychain only, as before) and passes it as `--api-key`. A `config.json` from before this change says `false` only because that was the default, so a new `apiKeyDefaultApplied` field (absent in old files) makes `AppState` switch it on once and save that; after it the toggle is the user's, and turning it off sticks. An enabled key whose Keychain entry has gone is generated again at launch instead of starting the runtime open. Settings → Endpoint keeps the toggle, Copy and Regenerate; Connect a Tool already fills the key into every snippet.
**Why:** D-036 measured the vendored `llama-server` answering `Origin: http://evil.example` with `Access-Control-Allow-Origin: http://evil.example` and `Access-Control-Allow-Credentials: true`. D-010 ("anything on the same machine that can reach loopback can read the key out of Keychain or `ps`") is right about other *processes* and silent about the browser, where a page you merely visit can send requests to `127.0.0.1` but cannot know a key. llama-server has no switch for its CORS, and it stays the default runtime until the parity gate (Phase 3 step 7), so the key is the only lock available today. `quail-server` doesn't need it for this reason (D-036's guard) and could go back to off by default when it becomes the default runtime; the user decides then.
**Cost, stated plainly:** every client now needs the key. The Quail app, `quail chat`, the benchmark, Ping and Connect's Test already send it; a browser tab at llama.cpp's own web UI (`http://127.0.0.1:8080/`, served without a key) loads but must have the key pasted into its settings before it can chat (Settings → Endpoint → Copy); anything else the user has pointed at Quail (Open WebUI, scripts) needs it added. One-time, and a re-enabled key for anyone who had deliberately turned it off before this version (the old file can't say which it was).
**Alternatives:** Only for new installs (leaves every existing user exposed). Generate a key but keep the toggle off (no effect). Put a small reverse proxy with the guard in front of llama-server (a second process to run and supervise for a runtime that's leaving). Open the web UI with the key injected (llama.cpp's UI takes no key from the URL).
**Revisit if:** `quail-server` becomes the default (the guard makes the key optional again), or a llama.cpp release adds a CORS switch.

**Amended 2026-09-28 (Phase 4 step 3):** a host other than loopback is now said out loud.
- **Under Endpoint's Host field:** orange text says other devices can reach the server and need the key. With the key off, the text is red ("anyone on your network can use this server") and has a Require API Key button.
- **At the first Start from the menu with such a host:** a one-time alert (`Config.lanWarningShown`) offers Start, Listen on This Mac Only (switches the host to 127.0.0.1) or Cancel.
- **Loopback** is `127.*`, `::1` or `localhost` (`EndpointAddress.isLoopback`).
- **The key stays on by default,** since llama-server is still selectable (see the Quail-server-default note above).

## D-038 · 2026-09-25 · Chat completions: the template builds the prompt, reasoning is split by a streaming state machine

**Decision:** `/v1/chat/completions` (also `/chat/completions`) renders the request with the model's own template (D-035), tokenizes the text, and streams through the same generation path as completions (D-037), with a `ReasoningSplitter` between the text and the response. **Prompt:** the template comes from the engine, falling back to ChatML like llama.cpp; text parts of `content` are joined with a newline for templates that want a string, or kept as typed parts for the few that only handle those (found by rendering a probe, as llama.cpp does, not by reading the template); `developer` becomes `system` unless the template names the role (gpt-oss); `tool_choice: "none"` hides the tools; `chat_template_kwargs` reach the template (`enable_thinking`). A prompt that already begins with the model's BOS text is tokenized without a second one. Compiled templates are cached by source. **Reasoning:** `<think>…</think>` becomes `reasoning_content`, the tags and the whitespace after each are dropped, the whitespace before `</think>` is kept, and only text that could still be half a tag is held back; a template that left `<think>` open at the end of its prompt starts generation inside the reasoning. Checked against real Qwen3-0.6B output and what llama-server made of it (three cases × four chunk sizes, `TestFixtures/Reasoning`) and independent of how the tokens are cut. **Stream shape** as llama-server's: an opening chunk with the role and `content: null`, deltas, a finish chunk carrying `timings`, and with `stream_options.include_usage` one more with `choices: []` and the usage. `quail chat`'s own parser reads it unchanged (tested).
**Deliberately not done yet:** tool-call *output* parsing (done in D-040), `response_format` (needs the engine's sampler, step 5; refused with a 400 rather than ignored), image parts (no vision engine; a 400 — llama-server returns a 500 for the same case), and family-specific reasoning formats other than `<think>` (gpt-oss's Harmony channels come with 3c). An empty `messages` is a 400 here; llama-server tries to generate from nothing.
**Alternatives:** Split reasoning in the engine (each engine would do it, differently). Post-process only at the end for non-streamed replies (a streamed reply would then leak the tags to every client).
**Revisit if:** a model family's reasoning delimiter isn't `<think>` and isn't handled in 3c.
*(2026-09-28: Gemma 4's `<|channel>thought…<channel|>` is the first such family; see D-040's amendment.)*

## D-037 · 2026-09-25 · Generation routes: completions, tokenize and props over the engine seam

**Decision:** `/v1/completions`, `/tokenize`, `/detokenize` and `/props` are served by `InferenceRoutes`, written once over `Engine`, in llama-server's router-mode shapes (captured from a real b11081 router this session, not remembered): a request must name its model (`model` in the body, `?model=` for `/props`) — no name is a 400 "model name is missing from the request", an unknown one "model 'x' not found" — and naming an unloaded model loads it and waits. `usage.prompt_tokens` counts what the model read including the cached part, `timings.prompt_n` only what it processed, and `timings` carries `prompt_per_second` and `predicted_per_second`, which is all `BenchmarkClient` reads. A test runs the real `LlamaCppBenchmarkClient` against a real `HTTPServer` on these routes.
**Behaviour worth knowing:** (1) A streamed response waits for the first event before the status line is sent, so a model that can't load or start is a real 500, not a 200 with an error inside; an error after the first chunk travels as an `error` event. (2) Stop strings (`stop`, one or several) are applied once, over the text, by `StopMatcher`: the stop isn't emitted, only text that could still become a stop is held back, and generation is cancelled at the match. When that happens the engine can't report its own timings, so they're measured at the shared layer. (3) A model with a request in flight holds a router lease, released when the stream ends however it ends; ending consumption of the response stream (the client going away) cancels the engine. Tested, including the subtle part: the `AsyncStream` only terminates when every reference to it is gone, so the HTTP write loop must not keep the response alive after a failed send (it doesn't). (4) `n` other than 1 and batched prompts are refused rather than half-served; v1 runs one request at a time per model. (5) The engine seam gained `info()` (context size, BOS/EOS strings), `SamplingParameters.minP` and the penalties, and `GenerationTimings.cachedTokens`.
**Still open:** `logprobs`, and llama.cpp's native `/completion` and `/slots`, which no Quail client uses. *(Closed 2026-09-25: a client that leaves before the first token. While a request is handled, `HTTPConnection` keeps one read of the socket outstanding; a close or error cancels the handler, which cancels the engine, and a pipelined request that arrives instead is kept for the next read, not mistaken for a departure. Tested at the socket level and end to end on both generation routes; mutation-checked.)*
**Alternatives:** Default to the only loaded model when none is named (friendlier, but not what a router does, and the clients here always send one). Serve `n > 1` and batched prompts sequentially (more surface for no client that needs it).

## D-036 · 2026-09-24 · quail-server refuses cross-origin browser requests by default

**Decision:** `quail-server` answers no cross-origin browser request unless told to. `RequestGuard` sits in front of every route: (1) a request carrying an `Origin` header is refused with 403 unless the origin is the server's own (an `http://` origin whose authority equals `Host`) or was allowed with `--allow-origin <origin>` (repeatable; `*` allows any, an explicit opt-in); (2) while the server is bound to a loopback address, a `Host` header that isn't `localhost`, `127.x.y.z` or `::1` is refused with 421. An allowed origin gets `Access-Control-Allow-Origin` for exactly that origin (never `*`, never `Allow-Credentials`), `Vary: Origin`, and its preflight is answered (including Chrome's Private Network Access header). No `Origin` header (curl, SDKs, the Quail app, `quail chat`) means no change.
**Why:** measured on the vendored `llama-server` b11081, this session: it answers `Origin: http://evil.example` with `Access-Control-Allow-Origin: http://evil.example` and `Access-Control-Allow-Credentials: true`, on `/health` and on the preflight. With the API key off by default (D-010), any web page you open can read and drive your local models, load and unload them, and use their tools. Refusing *the request*, not only omitting the response header, matters: a POST with `Content-Type: text/plain` is a "simple" request that needs no preflight, so the server would still run it. The `Host` rule covers DNS rebinding, where a hostile page's own domain resolves to 127.0.0.1 and so looks same-origin to an Origin check alone; its `Host` is still the hostile name.
**Consequence to know now:** until the parity gate (Phase 3 step 7) the default runtime is still `llama-server`, and it has no way to turn this off. **The permissive behaviour above is what Quail serves today.** Setting an API key closes it (a web page doesn't know the key, so every request it makes is a 401); the guard makes that unnecessary for `quail-server`.
**Not covered:** another process on the same Mac (it can send any headers), and a page on an origin you allowed. A non-loopback bind (`--host 0.0.0.0`) skips the Host rule, since any name may reach it, but keeps the Origin rule.
**Alternatives:** Mirror llama-server (a ready-made hole). Deny all CORS with no opt-in (breaks a browser UI on another port, e.g. Open WebUI running in the browser against Quail). Require `Content-Type: application/json` on POSTs (blocks the simple-request case but breaks `curl -d` and clients that omit it, and the Origin rule already covers browsers).
**Revisit if:** the Quail app needs to offer an "allowed origins" setting (the flag is what it would set), or the served web UI (step 3e) runs on another origin.

## D-035 · 2026-09-24 · The shared chat layer's foundation: swift-jinja pinned directly, an order-preserving JSON parser, goldens from llama.cpp

**Decision:** Step 3 of Phase 3 is built in slices, each its own PR: (3a) template rendering and the JSON parser; (3b) `/v1/chat/completions` (SSE and not), `/tokenize`, `/detokenize`, `/props`, the benchmark contract and the CORS policy; (3c) reasoning and tool-call parsing per family; (3d) `/v1/messages` and `/v1/responses`; (3e) the served web UI. 3a is `OrderedJSON` (a strict RFC 8259 parser into swift-jinja's own `Value`, so a request body goes into a template with no conversion that could reorder keys) and `ChatTemplate` (swift-jinja with `trim_blocks`/`lstrip_blocks`, the model's `bos_token`/`eos_token`, `tools`, `add_generation_prompt`, and `chat_template_kwargs` such as `enable_thinking`, which can't replace the server's own variables).
**Dependencies:** `swift-jinja` is now a direct package, pinned `exactVersion` 2.5.1, and `swift-collections` is pinned to 1.3.0 per D-028; both are linked into `quail-server` and the test bundle only. (D-028 named `swift-transformers` as the source of swift-jinja; step 4 still adds that, whose own requirement is a range that includes 2.5.1. The direct pin means the renderer doesn't move when swift-transformers does.) A static library doesn't carry its package products to what links it, so the tool and the tests declare them too.
**Verified against llama.cpp, not against itself:** `TestFixtures/ChatTemplates` holds the real templates of Qwen3, Gemma 3, Llama 3.2 and gpt-oss and what the vendored `llama-server` b11081 returns from `/apply-template` for each on five conversations (plain, multi-turn, tools with a schema whose keys aren't alphabetical, a full tool-call round trip, Unicode and escapes): 20 cases, byte-identical, including Gemma's "roles must alternate" rejection. The oracle is `llama-server --chat-template-file <family>.jinja`, which renders any template with a loaded model's token strings, so the fixtures regenerate from one small model (README in that folder).
**Found while doing it:** (1) swift-jinja copies a render's variables and *then* adds its own built-ins, so a context can't replace `raise_exception` or `strftime_now`; the stock `raise_exception` keeps its message private (`TemplateException.message` is internal), so a client would never learn why a template refused its conversation, and `strftime_now` reads the real clock, so a test couldn't pin the date. `ChatTemplate` therefore points calls to those two names at its own functions by rewriting the template source (a call only; bare mentions are left alone). Worth an upstream issue. (2) llama.cpp gives the template `content: ""`, not null, for an assistant turn that only calls tools; Gemma's template rejects null, so the same is done here. (3) Tool-call `arguments` arrive as a JSON string but templates read an object; they're parsed, in the order sent, before rendering.
**Not yet done (3b onward):** content given as a list of typed parts (text/image) for templates that want plain strings, the `developer` role, reasoning-content handling (`reasoning_content` → the template's own field), and per-family tool-call output parsing.
**Alternatives:** Depend on swift-transformers now (drags in the tokenizer stack before an engine can use it). Fork swift-jinja to fix the built-in override (a maintained fork for two functions; the source rewrite is 4 lines and the upstream fix is the better home). Compare only against Python's transformers (a different engine than the one we're replacing).
**Revisit if:** swift-jinja lets a context override its built-ins, or a target model family renders differently from llama.cpp in a way the goldens don't cover — add its template and case to the fixtures first.
*(2026-09-28: Gemma 4 did. swift-jinja keeps a space after a literal `{` where jinja2's whitespace control strips it. The source is rewritten around that, and both Gemma 4 templates are in the goldens; see D-040's amendment.)*

## D-034 · 2026-09-24 · The app icon: an AI-generated quail, rendered to the macOS icon shape by a script

**Decision:** The icon is a flying California quail on a yellow field, generated with ChatGPT's image tool from the maintainer's prompt and kept as `Design/AppIcon-source.png` (1254 px, flat colour). `Design/make-icon.py` (Python + Pillow) turns it into the ten `AppIcon.appiconset` sizes: a 824 px superellipse ("squircle") on the 1024 px canvas with the standard soft shadow, because a plain `.appiconset` isn't masked by the system. Re-run it after changing the source; the PNGs are committed so a build needs neither Python nor Pillow.
**Provenance:** the image is AI-generated. Its copyright status is uncertain in most jurisdictions (purely machine-generated images may not be protected at all), and the generator's terms, not this repo's, decide what can be done with it. It sits under `Design/` and the asset catalog, apart from the MIT-licensed code, so it can be swapped for commissioned artwork without touching anything else.
**Not done:** the menu-bar glyph is still an SF Symbol per state (stopped/starting/running/failed); a quail silhouette template image would need to read at 18 pt in both appearances and is separate work. No dark or tinted icon variants (macOS 26's Icon Composer `.icon` format would give layered artwork; the flat raster is the portable baseline).
**Alternatives:** A hand-drawn vector quail (more control, more time); a lettermark.
**Revisit if:** Quail gets commissioned artwork, or the Store submission wants an `.icon` file.

## D-033 · 2026-09-24 · Homebrew: a cask in `adatoo/homebrew-tap`, rendered and pushed by every release

**Decision:** `brew install --cask adatoo/tap/quail-ai` installs the release DMG's `Quail.app` and links the bundled `quail` command-line tool (`Contents/Helpers/quail`) onto the PATH. The cask's source is `Config/quail-ai.rb.in` in this repo; `task release:cask` fills in the version and the sha256 of the DMG, and `task release:cask:publish` commits it to the tap's `Casks/quail-ai.rb`. The Release workflow's `homebrew` job (after `dmg`) downloads the DMG *as published*, so the hash brew checks is of what people download, and pushes with the `TAP_TOKEN` secret (a fine-grained token with contents:write on the tap only, passed to git through the environment so it never reaches argv, a URL or `.git/config`). A rejected push (two releases close together) is refetched and retried. The tap holds any number of casks and formulae, so future projects can share it.
**The token is `quail-ai`, not `quail`:** homebrew-cask already has a `quail` cask, an unrelated (and now disabled) app, so the short name `quail` resolves to *it*. With 0.9.0 published as `quail`, `brew info quail` described the other app and `brew outdated --greedy` offered to "upgrade" Quail to its 3.0.0. A tap can't shadow a homebrew-cask name, and both would share one Caskroom folder, so the cask was renamed in 0.9.1 (`brew search` finds no `quail-ai`). The publish task removes the old `Casks/quail.rb` from the tap.
**Upgrades:** the cask declares `auto_updates true`, because Quail updates itself (D-032). `brew upgrade` leaves it alone unless `--greedy`, and the two paths never fight: brew only tracks the version it installed. `livecheck` follows GitHub's latest release. `zap` removes Application Support, Caches, Logs and the preferences plist, but not the model folder, which is yours.
**Requirements it states:** Apple silicon (`depends_on arch: :arm64`) and macOS 14 (`:sonoma`).
**`brew audit --new` says "not notable enough":** that rule gates the official homebrew-cask repo only, not a personal tap, so it's expected and ignored. `brew style` is clean.
**Found while testing:** `task install` (ad-hoc signed) built an app that died at launch on `Library not loaded: Sparkle.framework … different Team IDs`. The hardened runtime's library validation only loads frameworks from the app's own team, and an ad-hoc app has no team. Ad-hoc installs now drop the hardened runtime, and the task fails if the built app still has it; Developer ID builds keep it, and the released 0.8.0 has the app and Sparkle on one team.
**Alternatives:** Submit to the official homebrew-cask (needs the notability threshold, and its review cadence). A formula that builds from source (needs Xcode on the user's machine). Both rejected for now.
**Revisit if:** Quail passes homebrew-cask's notability rule, or the tap gets a second project with its own release cadence.

## D-032 · 2026-09-24 · In-app updates with Sparkle: appcast on GitHub Releases, prompt by default, key custody

**Decision:** The direct build updates itself with Sparkle 2 (SwiftPM, pinned `exactVersion` 2.10.0, linked into the Quail target only). Every release attaches an `appcast.xml` next to its DMG; the app's `SUFeedURL` is `https://github.com/adatoo/quail/releases/latest/download/appcast.xml`, which GitHub redirects to the newest full release (so releases are not marked pre-release, D-031). Settings → General → Updates offers **Check for updates: Daily / Weekly / Monthly / Never**, "Download and install updates automatically", the last check time, and **Check for Updates…** (also in the menu-bar menu). Defaults: checks on (daily) with no first-launch prompt (`SUEnableAutomaticChecks`), and Quail **asks before installing** until the automatic-install toggle is turned on, which installs silently when Quail next quits. Sparkle keeps these settings in `UserDefaults` itself, so nothing goes in `config.json`; `UpdateSettings` only translates its separate on/off and interval settings into the single choice a person sees. Hidden in the App Store build. Installing quits Quail through the ordinary `applicationShouldTerminate`, so the server stops first.
**Keys:** every update is EdDSA-signed. The private key lives in the maintainer's login keychain (`generate_keys`) and the `SPARKLE_ED_PRIVATE_KEY` Actions secret (fed to `generate_appcast` on stdin, never written to disk); its public half is `SPARKLE_PUBLIC_ED_KEY` in `project.yml`, baked into `SUPublicEDKey`. **If the private key is lost, installed copies can never verify another update** and people must reinstall by hand, so keep a backup. A build with an empty public key can't ship: the release job runs `verify:bundle REQUIRE_UPDATE_KEY=1`, and `release:appcast` fails if the feed comes out unsigned (which is what Sparkle does when the signing key doesn't match the app's public key).
**Tested end to end (2026-09-24, local, throwaway key, real Sparkle):** an old build found the feed, downloaded and verified the update, installed it with its model server running, stopped that server first (no orphan), and relaunched as the new version; a tampered archive (bytes changed after signing) was fetched and **refused**, with the untampered control installed. Not tested: clicking through the prompt window (nothing here can drive the UI), and the first real update from a shipped release to the next.
**Found while testing, worth knowing:** `NSApplication.terminate` waits in a nested run loop for `applicationShouldTerminate`'s deferred reply, which is a main-actor `Task`; calling `terminate` from inside a `Task` or a main-queue block therefore deadlocks (the reply can't run while the caller holds the main queue). The menu's Quit is a synchronous button action, and Sparkle's own quit path was tested and is fine; but don't call `terminate` from a `Task`. Sparkle's relaunch also drops the environment, so Debug builds can read the test data-root from a preference too.
**Test aids (Debug builds only, never shipped):** `QUAIL_DATA_ROOT` (or the `QuailDataRoot` preference) moves everything Quail writes, including the control socket, under a scratch directory, because `HOME` is ignored; `-QuailUpdateFeed <url>`, `-QuailCheckForUpdatesOnLaunch YES`, `-QuailInstallUpdateAfterSeconds N`, `-QuailQuitAfterSeconds N`. Run any test copy with a different bundle ID (`PRODUCT_BUNDLE_IDENTIFIER=…`) so its preferences, login item and Keychain state stay separate. (My first test copy skipped the data-root safeguard on relaunch and briefly ran against the real data directory: it rewrote the catalog cache and `presets.ini` and rotated the log, nothing else.)
**App Store:** Sparkle is linked into every configuration (XcodeGen can't link per configuration), so the Store build must have it removed before submission — recorded under Phase 4 step 5.
**Alternatives:** A custom updater on the GitHub API (re-implements signature checking, atomic replacement and relaunch — the hard parts). Homebrew only (`auto_updates` false): no in-app update; rejected because you asked for it. A beta channel (D-031 chose every release).
**Revisit if:** Sparkle 3 or a sandboxed Store build changes the packaging, or the appcast needs delta updates.
**Amended 2026-09-25:** the release used to be marked latest as soon as the tag job created it, about six minutes before the DMG job attached the appcast, so a check in that window got a 404 and Sparkle showed "An error occurred in retrieving update information" (seen on 0.19.0). With signing on, the release is now created not-latest and made latest by the last step of the DMG job, after the appcast is attached; until then the previous release, with its working feed, stays latest. If the DMG job fails, the release stays not-latest, which is the safe way round.


## D-031 · 2026-09-24 · The repo is public; every workflow runs on GitHub-hosted runners

**Decision:** `adatoo/quail` becomes public, so Sparkle and Homebrew can download releases without a token (and the app's remote catalog URL on raw.githubusercontent.com, which 404s for everyone else while the repo is private, starts working). Every workflow runs on GitHub-hosted runners: `macos-26` with Xcode 26.6 for anything that builds, `ubuntu-latest` for the rest (versioning, auto-merge, Dependabot bumps, tagging a release). The `MAC_RUNNER` / `MAC_SIGNING_RUNNER` variables and the self-hosted runners (a Mac and a Linux one on the mac-mini) were removed from the repo on 2026-09-24.
**Why hosted only:** in a public repo anyone can open a PR, and a `pull_request` workflow runs the PR's code on whatever runner the job names; on a self-hosted runner that is our own Mac, with whatever the runner's user can reach. Hosted runners are fresh VMs per job, which also makes `release:import-cert` (it replaces the default keychain) harmless. Standard hosted runners are free for public repos, macOS included. Also turn on Settings → Actions → "Require approval for all outside collaborators".
**Before going public:** `gitleaks git` over the full history (48 commits) found no secrets.
**Alternatives:** A separate public releases repo, with the code private (more tokens and moving parts). Keep the self-hosted runner for maintainers' PRs only (an expression on `head.repo.fork`) — rejected: one misjudged condition runs a stranger's code on the Mac, and hosted runners cost nothing here.
**Releases are full releases, even while 0.x** (amending D-024): Sparkle's feed and Homebrew both find the newest build through GitHub's `releases/latest`, which ignores pre-releases. The version number still says it's pre-1.0.
**Revisit if:** hosted macOS runners stop being free for public repos, or a job needs hardware they don't have (e.g. benchmarking on a specific chip).

## D-030 · 2026-09-24 · Task is the single entry point for local and CI commands; the shell scripts are gone

**Decision:** A `Taskfile.yml` (with `taskfiles/vendor.yml`, `embed.yml`, `version.yml`, `release.yml`) replaces all 13 scripts in `scripts/` and the hand-written command lists in the workflows. `task ci` is CI's step list, and every workflow step is one task, so "passes locally" and "passes in CI" are the same claim. Xcode's three embed build phases call `task embed:*`. The release job runs `release:*` tasks configured only through environment variables (`APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_SIGNING_IDENTITY`), so a developer's shell and CI secrets drive the same commands, and moving notarization to an App Store Connect API key is a change inside `release:notarize` alone. Builds go in a repo-local `./DerivedData` (what CI uses), so a task build never overwrites the app Xcode last ran. The pins moved out of `scripts/` to `Vendor/` (`llama.version`, `llama.sha256`, `uv.version`) and `Config/` (`ExportOptions-DeveloperID.plist`). `task install` is a quick local install (Release, ad-hoc unless `QUAIL_SIGN_IDENTITY`); `task install:notarized` is the old `install.sh`.
**Where each script went** (older ADRs and the CHANGELOG still name the scripts): `vendor-llama.sh`, `vendor-uv.sh`, `verify-macho.sh` → `vendor:llama`, `vendor:uv`, `vendor:verify`; `embed-llama.sh`, `embed-cli.sh`, `embed-quail-server.sh` → `embed:llama`, `embed:cli`, `embed:server`; `version.sh`, `check-version.sh`, `bump-version.sh`, `test-versioning.sh` → `version:*`; `sign-and-notarize.sh`, `make-dmg.sh`, `install.sh` → `release:*`, `install:notarized`.
**Found while porting, and why it matters for anyone editing a task:**
- Task runs commands in its own Go shell interpreter, not bash. It handles nearly everything the scripts used (`[[ =~ ]]` with `BASH_REMATCH`, arrays, functions, process substitution, `trap`, `pipefail`), but `read -d ''` is unsupported, `${VAR:-$(cmd)}` runs `cmd` even when `VAR` is set, and `{{ … }}` is template syntax even inside a quoted heredoc.
- **`read -d ''` failed silently:** my first port of `verify-macho` reported OK for everything, including a deliberately broken binary, because the loop body never ran. Comparing every port with the old script's real output before deleting it caught this. `vendor:verify` now fails if it examined zero Mach-O files, so that class of breakage can't approve anything again.
- **Untrusted input must not be templated into a command.** Task pastes `{{.VAR}}` and `{{.CLI_ARGS}}` into the shell text, so a PR title of `$(…)` executes (confirmed). The version tasks read `PR_TITLE` / `PR_BODY` from environment variables, which are inert, and `version:test` proves a hostile title runs nothing.
- `verify-macho`'s "skip the first line of `otool -L`" wrongly rejected universal binaries (one header per architecture, so the second header read as a dependency). It now reads only the indented dependency lines.
- **`task build` isn't launchable, on purpose.** It builds unsigned like CI (`CODE_SIGNING_ALLOWED=NO`), and an unsigned bundle has only the linker's stub signature, so macOS reports it as "damaged" (`codesign --verify` says: code has no resources but signature indicates they must be present). I told you to open exactly such a build and it failed. `task install` signs (ad-hoc unless `QUAIL_SIGN_IDENTITY`) and is the way to get an app that opens.
**Trade-offs accepted:** shell now lives in YAML, so no shellcheck and weaker editor support; `go-task` must be installed anywhere Xcode builds Quail (a missing one fails the build with `brew install go-task`, rather than shipping an app with no runtime); CI installs it with `go-task/setup-task`. CI also builds the App Store scheme now, so it equals `task ci`.
**Alternatives:** Keep the scripts behind a thin Taskfile (two sources of truth); make or just (Task was already installed and its YAML is the least surprising for CI).
**Revisit if:** another interpreter difference causes a silent failure, or requiring go-task to build proves a real burden on contributors — the embed steps could then return to one small script.

## D-029 · 2026-09-24 · About lives in Settings → General; no About menu item, tab or window *(superseded in part by D-061: About is a page of the Quail window)*

**Decision:** Version, distribution channel, the bundled llama.cpp tag, the catalog revision, the macOS version, a "Copy Details" button for bug reports and the open-source licences all sit in one **About** section at the bottom of Settings → General, in both builds. Quail has no separate About window, tab or menu item. The llama.cpp tag reaches the app because `scripts/embed-llama.sh` copies `scripts/llama.version` (the pin `vendor-llama.sh` downloads) into `Contents/Resources`; CI fails the build if that file or `LICENSE-llama.cpp` is missing from the app.
**Alternatives:** A dedicated About tab, or an "About Quail" item in the menu-bar menu (what Phase 4 step 6 planned). Rejected: Quail is an `LSUIElement` menu-bar agent, so it has no app menu with a conventional About item to be missing, and one place beats three for a person filing a bug.
**App Store:** I know of no App Store rule that requires an in-app About screen, but I did not check Apple's current review guidelines, so treat that as unverified. What both builds do need is llama.cpp's MIT licence text to travel with the app; it's bundled and now readable in-app (General → Open-source licences).
**Revisit if:** App Review asks for an About item, or Sparkle's update UI (Phase 4 step 1) wants a natural home of its own. Rows for things that don't exist yet (the `quail-server` version, runtime pins) join this section when they do.

## D-028 · 2026-09-24 · Dependencies for `quail-server`: mlx-swift-lm, swift-transformers, swift-jinja

**Decision:** AGENTS.md's dependency rule gains a third exception beside Sparkle and swift-argument-parser (D-022): the `quail-server` target (D-027), and only that target, links `mlx-swift` and `mlx-swift-lm` (`MLXLLM`, `MLXLMCommon`), `swift-transformers` (`Tokenizers`, which brings `swift-jinja`) and `OrderedCollections`. The HTTP layer is hand-written on `Network.framework`, not swift-nio. None of them is linked into the app or the `quail` CLI. Three build facts, all found in the D-027 spike, are part of the decision:
- `mlx-swift` compiles its Metal shaders at build time, so the server is built with `xcodebuild`, never plain `swift build`, on a machine with Xcode's Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`, ~840 MB) and with `-skipPackagePluginValidation` (a build-tool plugin in `mlx-swift`). CI needs both.
- `swift-collections` is pinned to 1.3.x. 1.7.0 compiled with Xcode 27's Swift 6.4 emits a runtime symbol (`_swift_initBorrow`) that macOS 26 doesn't have, so the binary dies in `dyld` at launch. CI's Xcode 26.6 may not hit it; a local Xcode 27 does. Lift the pin only after a launch test on the oldest supported macOS.
- `mlx-swift`'s `default.metallib` ships in a SwiftPM resource bundle (`mlx-swift_Cmlx.bundle`) that has to be embedded next to the server binary.
**Alternatives:** swift-nio for HTTP (more transitive dependencies and an Apache-2.0 NOTICE; nothing Quail needs that `Network.framework` lacks). The `MLXHuggingFace` macros (pull in `swift-huggingface`, a downloader Quail doesn't use — D-002 keeps downloads in `HFDownloader`); a small `TokenizerLoader` over `Tokenizers.AutoTokenizer.from(modelFolder:)` is about 25 lines instead.
**Revisit if:** an `mlx-swift-lm` release needs a newer macOS than 14, or the `quail-server` binary's size becomes a problem for the App Store build.

## D-027 · 2026-09-24 · One `quail-server` with a GGUF engine and an MLX engine; `llama-server` retires after a parity gate

**Decision:** Phase 3 builds a single server we own, `quail-server`, run as a child process like every other runtime (D-003). It serves one HTTP API (the llama-server shapes Quail, the benchmark and every Connect tool already use) over two engines behind an `Engine` protocol: `libllama` (from llama.cpp's own `llama-<tag>-xcframework.zip` release asset) for GGUF and `mlx-swift-lm` for MLX. The router (load, unload, `modelsMax`, per-model status), chat-template rendering, tool-call and reasoning parsing, `/v1/chat/completions`, `/v1/messages`, `/v1/responses`, `/tokenize`, `timings` and the web UI are written once and shared by both formats. The vendored `llama-server` stays the default until `quail-server`'s GGUF path passes the parity gate in the plan (Phase 3 step 7); then it and `libllama-server-impl` leave the bundle. If the gate fails, `llama-server` stays as a selectable runtime and the gap is recorded here. oMLX and Rapid-MLX (D-005) are deferred, not dropped: they come back only if the benchmark shows a real speed gap over the native MLX engine.
**Supersedes:** D-014's separate `mlx-server` and its "why not wrap libllama" paragraph. **Amends:** D-004 (llama.cpp stays bundled, but as a library, and `llama-server` goes after the gate) and D-009 (the closure it vendors changes at the gate).
**Why D-014's reasoning changed:**
- It counted the router, Jinja templates, the `/v1/*` routes, `/tokenize` and `timings` against the GGUF path. An MLX server that works with Claude Code, Connect and the benchmark needs every one of them anyway, so they are a fixed cost of Phase 3. Adding GGUF adds only the decode loop, the sampler chain, prompt-prefix KV reuse and `libmtmd` vision.
- "No headers": the release ships an xcframework, with headers including `mtmd.h`, Metal built in, depending only on system frameworks.
- "We'd lose the web UI": releases also ship `llama-<tag>-ui.tar.gz`, the UI as static files.
- One template renderer for both formats means the same model gets the same prompt in GGUF and in MLX — the uniformity that motivates this.
**Spike evidence (2026-09-24, throwaway package outside the repo, llama.cpp b11157, mlx-swift-lm 3.31.3, macOS 26.6, M-series):**
- Both engines loaded and generated coherent output: Qwen3-0.6B-Q8_0 through the xcframework, and mlx-community/Qwen3-0.6B-4bit through `mlx-swift-lm` with a local-directory tokenizer.
- GGUF decode, bare greedy sampling, 128 tokens: 188–204 tok/s in the spike, and 188.7 tok/s from the vendored b11081 `llama-server` once warm. Its first two runs read 60–80 tok/s and its third 188.7. The cause is not established: GPU clock ramp-up is the likely reading, but a 35B model held by the running Quail app and a second `llama-server` were resident on the same GPU throughout, so contention isn't ruled out. Either way **a single short run cannot decide the gate**; the gate uses the benchmark suite's warm-up plus median (D-023), on an otherwise idle machine. No MLX speed figure was taken (Debug build).
- Chat templates: swift-jinja 2.5.1 rendered Qwen3's 4,100-character embedded template, with `tools`, an assistant `tool_calls` turn and a `tool` message, byte-identical to `llama-server`'s `/apply-template` (its own Jinja engine). Qwen3.6-35B-A3B's 8,057-character template rendered without error; it was not diffed. **Only with an order-preserving JSON parse:** `JSONSerialization`, `JSONDecoder` and swift-jinja's own `Value` decoding all sort object keys, which reorders a tool schema inside the prompt — the kind of silent, model-looks-worse bug D-014 feared. The server therefore parses request bodies with its own order-preserving parser into `Value.object(OrderedDictionary)`.
- The framework signs with the hardened runtime and passes `codesign --verify --deep --strict`. An ad-hoc-signed hardened process refuses to load an ad-hoc framework (different Team IDs, i.e. none), which says nothing about Developer ID; verify with the project's identity in step 2.
**Not verified yet:** Release-build performance (either engine), MLX decode speed, `libmtmd` vision, several concurrent requests (`llama-server` batches four slots; v1 of `quail-server` serves one request at a time), template families beyond Qwen3, and linking `mlx-swift` in the App Store build.
**Alternatives:** Keep two server codebases with one API shape (D-014 as written) — the least work, but two implementations of everything above to keep in step. Build MLX first behind an `Engine` seam and add `libllama` later — the same end state in two stages, and the option if the spike had gone the other way.
**Amended 2026-09-25 (step 6, the app side):** the app can now run `quail-server`: Settings → Endpoint → Runtime offers **llama.cpp (GGUF)**, still the default, and **Quail server (GGUF and MLX, preview)**, changeable only while the server is stopped and remembered in `Config.runtimeID` (a config naming oMLX or Rapid-MLX, still deferred, falls back to llama.cpp). This is what makes MLX models usable from the app: under llama.cpp they stay listed but say they need the Quail server runtime. The orphan reaper and log rotation cover both servers. Found while testing it end to end: an MLX model folder that is a symlink loaded no weights ("Key lm_head.weight not found"); `MLXEngine` now loads the resolved folder. Not in this step: the key hand-over to the chat page (next), MLX benchmarking in the app (the benchmark reads GGUF headers), and a GGUF and an MLX model sharing an id (the MLX one wins in `quail-server`; the store's naming, `owner--repo` for MLX, makes it unlikely).
**Amended 2026-09-27 (the parity gate, run):** `quail-server` passes on GGUF, measured against the vendored llama-server b11081 on a Mac mini (M4 Pro, 64 GB), both Release. The benchmark suite ran four rounds per model, the server order alternating, each turn waiting for the Mac to cool back to nominal, with macOS's media, photo and Spotlight analysis paused. Medians, as quail ÷ llama:

| Model | prompt 512 | prompt 4,096 | generation | time to first token |
|---|---|---|---|---|
| Qwen3-0.6B Q8_0 | 1.004 | 0.998 | 1.019 | 0.971 |
| Qwen3-8B Q4_K_M | 0.987 | 0.999 | 1.003 | 1.009 |
| Qwen3.6 35B-A3B Q4_K_M | 1.044 | 0.982 | 1.006 | 0.954 |

Every ratio is inside the tolerances (5% for speed, 10% for time to first token).
- **The first run's "22% gap"** on Qwen3-8B's 512-token prompt was the harness. llama-server always went first, on a cooler machine; the Mac mini was at "heavy" thermal pressure, and the same server measured up to 20% slower late in a round. `ParityGateBench` now waits for nominal and alternates the order.
- **Every Connect Test** (15 tools: Anthropic, Responses and chat-completions shapes) passes on both servers.
- **Claude Code** completes the tool-using task (write fizz.py, run it, report the last lines) through `/v1/messages` on Qwen3.6 35B-A3B: 116 s against llama-server's 110 s. That took two fixes the gate found:
  - Claude Code's late system messages had rewritten the prompt's start every turn (D-041 amendment).
  - Hybrid models had no prompt reuse, and one slot lost the conversation to Claude Code's permission check (D-048 amendment).
- **The chat page chats** on a GGUF model.

**Not yet done, by decision:** making `quail` the default runtime and taking `llama-server` out of the bundle. That changes what every user runs, so it waits for the user's go-ahead.

**Amended 2026-09-28 (the default):** Quail server is the default runtime (`Config.runtimeID`, and first in the picker). A config written before this names llama.cpp only because it was the default, so it moves to Quail server once. A one-off flag (`quailDefaultApplied`) does it, the way D-039 switched the key on; it can't tell a deliberate llama.cpp choice from the old default, so the CHANGELOG says how to switch back. By the owner's decision, `llama-server` stays in the bundle and in the picker ("llama.cpp (GGUF only)") as a fallback, instead of leaving as step 7 planned; the Settings picker, the Models list and Add Model say that it can't run MLX models. The API key stays on by default (D-039), since llama-server is still selectable.

**Revisit if:** the parity gate fails by more than the plan's tolerances, or upstream `llama-server` gains something (speculative decoding, batching) that users need and `quail-server` can't match soon.

## D-026 · 2026-09-24 · The Ollama registry is not a download source; ModelFit only feeds catalog discovery

**Decision:** Quail keeps downloading only from Hugging Face (D-002 unchanged). The ModelFit dataset (`modelfit.io/api/dataset/`, CC BY 4.0) is used at most as an input to a maintainer script that proposes catalog candidates; nothing in the app fetches it or the Ollama registry at runtime, and `catalog.json` stays curated by a person.
**Alternatives:** Add an Ollama registry downloader (manifest → GGUF and projector layers by digest) and a catalog variant keyed by Ollama tag, fed by ModelFit. Import ModelFit's `minRamGb`/`estimatedLoadGb` for fit verdicts.
**Why:** A spike against the pinned llama.cpp b11081 loaded only 2 of 5 Ollama files (`llama3.2:1b`, `qwen3.6:35b-a3b` with its projector); `gemma3:4b`, `gemma4:e4b` and `gpt-oss:20b` are Ollama-engine builds it rejects, and the manifest doesn't say which are affected. The registry API is also undocumented, and Ollama publishes only its own quants. ModelFit has no HF repo ids, and its RAM figures are a flat ~0.6 GB per billion parameters, which `FitEstimator` (real file sizes and GGUF headers) already beats. What it does have is a current, broad list of models people run locally, which is the part that's costly to notice by hand. Details in IMPLEMENTATION_PLAN Phase 2b step 7.
**Revisit if:** llama.cpp gains the missing architectures and Ollama's GGUFs become plain llama.cpp files, Ollama documents its registry, or a maintained mapping from Ollama tags to HF GGUF repos appears.

## D-025 · 2026-09-24 · `quail run` becomes `quail chat`; a prompt doesn't need a model

**Decision:** The terminal-chat command is `quail chat [model] [prompt…]`; `quail run` is removed, with no alias. The first word is the model only if it names exactly one installed model (exact id, then case-insensitive, then a unique prefix — the same matching as `rm`, `ctx` and `default`, now one function, `ModelNameMatch`); otherwise every word is the prompt and the default model answers. `-m/--model` names the model outright (strictly: unknown or ambiguous is an error, and every word is the prompt). An ambiguous first word is an error rather than a guess. A quoted prompt is one argument containing spaces, so it is never read as a model. "Copy Terminal Chat Command" emits `quail chat -m <model>` so a model id with a space in it can't read as a prompt.
**Alternatives:** `-m` only (predictable, but loses ollama-style `quail chat <model>`); keep `run` as a hidden alias (ollama muscle memory, but the user chose a clean break).
**Why:** `run` suggests starting or loading a model, and the command only chats. With the model as a required first positional, `quail run why is the sky blue` took "why" as the model and failed; a one-shot prompt to the default model was impossible.
**Trade-off:** A prompt whose first word is a prefix of exactly one installed model's id (e.g. `quail chat gemma is …` with a Gemma installed) is read as a model choice; `-m` or quoting the prompt avoids it. Anyone with `quail run` in scripts or muscle memory gets an unknown-command error.
**Revisit if:** the auto-detection bites people in practice — then `-m` only.

## D-024 · 2026-09-23 · SemVer from PR titles, bumped in every PR, released on every merge

> **Amended by D-031 (2026-09-24):** releases are no longer marked pre-release while 0.x — GitHub's `releases/latest`, which Sparkle and Homebrew rely on, skips pre-releases.

**Decision:** Quail's version is SemVer, kept in `project.yml` (`MARKETING_VERSION`, plus `CURRENT_PROJECT_VERSION` as a build number that rises with every release). Every PR carries its own bump, derived from its Conventional Commits title — `feat` → minor, other types → patch, `!`/`BREAKING CHANGE` → major (minor while 0.x) — made with `scripts/bump-version.sh` and enforced by the required `version` check. PRs merge only with merge commits (no squash, rebase, force-push or direct push; admins included) and auto-merge once `build-and-test` and `version` pass. Every merge to `main` tags `vX.Y.Z` and publishes a GitHub Release from that version's CHANGELOG section (pre-release while 0.x); the signed DMG is attached once signing is configured (`vars.SIGNING_ENABLED`).
**Alternatives:** Bumping at release time on `main` (release-please style) — needs a bot to push to `main`, which "PRs only" forbids. A label per PR — one more thing to forget; the title is already required to be Conventional. Squash merges — the user chose merge commits.
**Why:** User request: SemVer releases, a bump in every PR, auto-merge on green CI, and a `main` that only changes through merged PRs. Computing the bump from `main`'s version inside the PR keeps `main` untouched by bots and makes every merge commit a releasable version.
**Trade-off:** Two open PRs conflict on the version lines once one merges; the second re-runs the bump script (the check says so). Anything automated that pushes or merges needs a token that isn't `GITHUB_TOKEN` (*D-046: a GitHub App's, no longer a PAT*) because actions taken with `GITHUB_TOKEN` start no workflows — without it, Dependabot PRs need a manual bump and auto-merge must be enabled by hand.
**Revisit if:** PR volume makes version conflicts routine (a merge queue would serialize them), or Sparkle needs a different build-number scheme.

## D-023 · 2026-09-23 · A fixed, versioned benchmark suite; its result is the sharing format

**Decision:** Benchmarks run one fixed suite, `quail-bench-1` (`BenchmarkSuite.swift`): exact-length prompts sent as token ids, the server's own `timings`, deterministic settings, no prompt cache, 1 warm-up + 3 runs. Any change to what it measures or how is a new suite id, never an edit. `BenchmarkResult` (schema v1, in `Shared/`) carries the hardware, model file (incl. sha256), engine build and conditions with the numbers, and is the format later sharing will upload.
**Alternatives:** llama.cpp's own `llama-bench` (measures the engine, not the endpoint users actually hit, and would mean shipping a second binary); a configurable suite (results stop being comparable).
**Why:** The point is comparing across machines, models and later runtimes — which only works if every result was produced the same way and says exactly what it ran on. Measuring through the running endpoint means the numbers are the ones a client will see, and the same suite can run against the MLX runtimes in Phase 3.
**Trade-off:** llama.cpp-specific today (`/tokenize`, `/models/unload`, `timings`); Phase 3's adapters need their own `BenchmarkClient`.
**Revisit if:** the suite proves too slow for large models, or a runtime can't report its own timings.

## D-022 · 2026-09-23 · swift-argument-parser for the `quail` CLI

**Decision:** The `quail` command-line tool uses Apple's `swift-argument-parser` (SPM), linked into the CLI target only — never the app.
**Alternatives:** Hand-written argument parsing (no dependency).
**Why:** A CLI with ~12 subcommands, flags and generated `--help` is exactly what the package exists for; hand-rolled parsing would be more code to get wrong for help text, errors and completions. It's Apple-maintained, source-only and has no transitive dependencies. User decision.
**Trade-off:** The first dependency beyond Sparkle — AGENTS.md's rule now reads "Sparkle and swift-argument-parser (CLI only)".
**Revisit if:** the package ever pulls in transitive dependencies.

## D-021 · 2026-09-23 · Terminal chat (`quail chat`) — narrowing D-001

**Decision:** `quail chat [model] [prompt]` (originally `quail run`, renamed by D-025) chats with a model in the terminal: streaming output, one conversation per invocation, a tok/s line after each reply. It exists to judge a model, not to be a chat app: no saved history, no attachments, no system-prompt library, no tools. The menu-bar app itself still has no chat UI ("Open Chat in Browser" links to the runtime's own).
**Alternatives:** Keep D-001 absolute (point users at the web UI or `curl`).
**Why:** A CLI "like ollama" (user request) is expected to have a way to chat; trying a model from the terminal is the fastest way to judge it, and it costs one streaming request loop, not a UI.
**Trade-off:** D-001's "never" is now "never in the app"; the list of things `quail chat` will not do is the guard against scope creep.
**Line editing (amended 2026-09-26):** reported: ↑ didn't recall earlier messages. `quail chat` read lines with `readLine()`, which has no editing at all. It now uses the system's libedit (loaded with `dlopen`, so there's no build setting, and it falls back to `readLine()`), for ↑/↓, ←/→, Ctrl-A/E and Ctrl-R. What you typed is kept across chats in `Application Support/Quail/chat-history` (mode 0600, the last 500 lines), as `ollama run` keeps its own. That's input history, like a shell's. Conversations are still not saved, which is the history this record rules out.
**Revisit if:** requests arrive for history, attachments or tools — the answer should stay no.

## D-020 · 2026-09-23 · Per-model context size, defaulting to the largest comfortable

**Decision:** Each installed model has a context setting in the Models pane: Automatic (the largest of 32K / 16K / 8K that is Comfortable on this Mac, capped at the model's trained context), or a user-chosen size from 4K–128K (options above the trained context aren't offered; options that don't fit at their own size are disabled). The choice lives in `catalog.json` (`userContextSize`) and survives store refreshes; `presets.ini` writes the effective size, and a change while running shows "restart to apply".
**Alternatives:** Keep ARCHITECTURE §7's fixed C = 8,192 (only reduced for Tight models); fully automatic sizing with no user control (considered — user chose the explicit setting).
**Why:** Measured live: Claude Code's first request is 15,114 tokens (system prompt + tool definitions), so every coding agent overflowed an 8K context before doing anything. A 64 GB Mac runs most catalog models comfortably at 32K+.
**Trade-off:** A larger context reserves more KV-cache memory up front; Automatic stays within the Comfortable threshold, and a user picking beyond it sees the verdict first. The Connect tab warns when a tool's known minimum (`minContext`) exceeds the chosen model's context.
**Revisit if:** llama.cpp gains dynamic context growth, or KV-cache quantization (q8) becomes the default — both change the memory maths.

## D-019 · 2026-09-23 · Recommend what runs comfortably, not what's in the RAM tier

**Decision:** "Recommended for this Mac" is every curated, GGUF-capable, non-smoke-test/embedding family whose real fit verdict is Comfortable — any size — sorted by `rank` then larger-first, capped at 5. The cheap pre-filter is `FitEstimator.approxMaxParamsB` on the measured GPU ceiling, not the catalog's `ramTiersGB`.
**Alternatives:** Keep ARCHITECTURE §7's three tiers (16 GB → 4–8B, 32–48 GB → 14–32B, 64 GB+ → 70B-class).
**Why:** Live testing on a 64 GB M4 Pro: the "large" tier (35B+) recommended only one model and hid Gemma 4 31B and Qwen3.8 27B, both Comfortable. The per-model verdict already answers "does it run well here"; a second, coarser size band on top only removed good answers. User decision.
**Follow-up (same day):** ranks had been set per tier, and size broke ties — an older Qwen3 32B landed above its successor Qwen3.8 27B. Catalog revision 3 re-ranks by generation (rank = best of its kind today, regardless of size; a model never outranks its successor), and ties now break by estimated tok/s on this Mac, then size.
**Trade-off:** rank is a hand judgement, re-checked with each catalog refresh; speed is an estimate from memory bandwidth.
**Revisit if:** the catalog grows enough that "top 5 comfortable" stops being a useful shortlist.

## D-018 · 2026-09-23 · Developer ID signing (Phase 1 step 11), reusing the existing Apple Developer identity

> **Updated 2026-09-24:** the scripts named below are now `release:*` tasks (D-030). Notarization prefers the account's App Store Connect API key (`notarytool --key`, the same `.p8` `lookout` uses) and falls back to an Apple ID password; CI's secrets are `APPLE_API_KEY_P8` / `APPLE_API_KEY_ID` / `APPLE_API_ISSUER_ID`, not `APPLE_ID` / `APPLE_APP_SPECIFIC_PASSWORD`. The DMG is now notarized and stapled as well as the app. First real run 2026-09-24, locally: both submissions **Accepted**, and a quarantined copy of the DMG and the app inside it both assess as `source=Notarized Developer ID`.

**Decision:** Quail signs Developer ID (direct-distribution) builds with the certificate already issued to this Apple Developer account — `"Developer ID Application: Arif Datoo (QKAYS6D525)"`, the same identity the `lookout` project already uses (same account; `lookout`'s own `com.datoos.lookout` bundle id prefix matches Quail's `com.datoos.quail`). No new certificate, no new Apple Developer enrollment. Two new scripts do the work, reused identically by both a local developer and CI:
- `scripts/sign-and-notarize.sh`: `xcodebuild archive` with `CODE_SIGN_STYLE=Manual`/the real identity, `-exportArchive` with `scripts/ExportOptions-DeveloperID.plist` (`method: developer-id`), `notarytool submit --wait`, `stapler staple`.
- `scripts/make-dmg.sh`: `create-dmg`, then `codesign` the DMG itself — the notarization ticket lives on the `.app` inside, which is what Gatekeeper actually checks on launch, so the DMG isn't re-submitted for its own notarization round.
- `scripts/install.sh`: the local entry point — vendors llama.cpp, runs both scripts above, `ditto`s the result into `~/Apps/Quail.app`. Directly modeled on `lookout/install.sh`, adapted from electron-builder's config-driven signing to Xcode's archive/export flow.
- `.github/workflows/release.yml`: tag-push CI, reusing the same two scripts (not a separate, drifting CI-only implementation). The one CI-specific step — importing the `.p12` into a dedicated build keychain and running `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k` — is copied verbatim from the `documail` project's own `.github/workflows/build.yml`; that one line is what grants `codesign`/`notarytool` non-interactive access to the imported key, which is what makes this work at all in a headless runner (the same class of problem as the Keychain-authorization-prompt issue this session hit locally, just in CI instead of a dev machine — see the "no Keychain prompts under test" fix earlier this session).
**Why now:** raised directly by the user, first pointing at `lookout` (for which certificate to reuse), then at `documail` (for the actual CI plumbing — `documail`'s own ADR-0019 documents the identical Apple-side setup, notarization command, and CI keychain-import pattern for its own, unrelated Tauri app).
**Secrets required in the GitHub repo for `release.yml`** (names match `documail`'s convention, for consistency across the account's projects): `APPLE_DEVELOPER_ID_APPLICATION_CERT_P12` (base64-encoded `.p12` export of the certificate + private key), `APPLE_DEVELOPER_ID_APPLICATION_CERT_PASSWORD`, `APPLE_TEAM_ID` (`QKAYS6D525`), `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD` (an app-specific password from appleid.apple.com, not the account password). None of these were set by this change — the user adds them via GitHub's own UI, never through this session.
**Not done in this pass:** Sparkle auto-update wiring (needs the appcast host question from ARCHITECTURE §10's open questions resolved first) and the App Store scheme's separate submission path (`Quail-AppStore`, a different signing story entirely — App Store Connect, not Developer ID).
**Revisit if:** the certificate expires or is revoked (Developer ID certs are long-lived but not permanent), or Quail moves to a different Apple Developer account than `lookout`'s (would need a new identity end to end, not a reuse).

## D-017 · 2026-09-23 · Default model loads via the router's own `load-on-startup` preset key, not a post-start RPC

**Decision:** A user-designated "default model" (`Config.defaultModelID`, set via a star toggle on its row in the Models pane) is applied by writing `load-on-startup = true` into that one section of `presets.ini` (`ModelStore.regeneratePresets`). Confirmed against the real vendored `llama-server` binary (found via `strings` on `libllama-common.dylib`, then verified live: router mode against a real GGUF, with the key set and no client request made at all — the model was already `"loaded"` on the very first `/models` poll after startup): this key is real, documented in the binary itself as *"in server router mode, autoload this model on startup"*, and does exactly that.
**Alternative considered:** issuing `AppState.selectModel(id:)` (`POST /models/load`) right after `ServerController.start(...)` settles to `.ready`. Rejected: it would need re-issuing after every `ProcessSupervisor` auto-restart too (the preset file doesn't need that — the router re-reads it fresh on every launch, including a restart's), and it puts runtime-specific load semantics in `AppState` rather than in the one place (`presets.ini`) that already describes everything about how the router should start.
**Why now:** raised directly by the user after live testing ("When we start, what model is loaded?") — `ARCHITECTURE.md` already described a "selected model" config field and restoring "the last runtime and model" at launch, but nothing had built it; today's router starts with every preset `unloaded` until a manual Load click or a client request names one.
**Scope not covered:** MLX runtimes (Phase 3) will need their own mechanism — the star toggle is GGUF-only for now, matching the Load button's own Phase-3 gating. `autoStartServer` (`docs/IMPLEMENTATION_PLAN.md` Phase 1 step 10's still-unwired setting) is a separate, still-open piece — this ADR only covers *which model* loads once the server *does* start, not starting it automatically at app launch.
**Revisit if:** a future llama.cpp release changes or drops `load-on-startup`'s behavior (re-run the same live verification before trusting a version bump), or Phase 3 needs a genuinely different mechanism for MLX that makes a runtime-agnostic approach worth revisiting.

## D-016 · 2026-09-23 · Multiple concurrent endpoints deferred to Phase 5, after MLX runtimes

**Decision:** Quail serves one endpoint (one `ServerController`, one host:port) at a time, same as today, through Phase 3 and 4. Running several endpoints at once — e.g. llama.cpp on one port and an MLX runtime on another, or a loopback endpoint alongside a LAN one with its own API key — is deferred to a new Phase 5, added to docs/IMPLEMENTATION_PLAN.md.
**Why now, not folded into an existing phase:** raised as a question during the Phase 2 follow-up review (recommendations, Start gating, This Mac tab). Phase 2's router mode already serves *several models* concurrently (`modelsMax`) through one endpoint, which covers the common case; a second concurrent *endpoint* is a distinct feature — separate `ServerController`/`Config` plurality, port-collision validation, per-endpoint logs, a menu row per endpoint, and `FitEstimator` needing to account for RAM every other running endpoint's loaded models already hold.
**Why after Phase 3, not before:** multiple endpoints are only useful once there's more than one runtime to spread across them — running two llama.cpp endpoints against the same model store has little value over router mode's own multi-model support. Ordering it after Phase 3 means the design starts from two real runtimes, not a guess at what a second one will need.
**Revisit if:** a user need for concurrent endpoints (e.g. one trusted LAN endpoint plus one loopback-only) shows up before Phase 3 ships, in which case it should move earlier rather than wait on MLX runtimes that don't gate it.

## D-015 · 2026-09-22 · In-process streaming downloads with `.partial/` + sidecar resume, not a background `URLSession`

**Decision:** `HFDownloader` streams via `URLSession.bytes(for:)` inside Quail's own process, buffering 1 MiB before each write + progress event, hashing incrementally as bytes land (existing prefix re-hashed on resume). Resume state is plain files: partial bytes plus a JSON sidecar (`repo`, `remotePath`, expected size/sha, destination) under `ModelStore.partialDirectory/<owner--repo>/`. The signed CDN URL from `resolve/main/...`'s 302 is never persisted — confirmed short-lived/expiring — resume re-requests `resolve` fresh and re-sends `Range`. A custom task delegate re-attaches `Range` across the cross-host redirect (URLSession doesn't reliably carry it) while deliberately *not* forwarding `Authorization` to the CDN host.
**Alternatives:** True background `URLSession` (`background(withIdentifier:)`, transfers in `nsurlsessiond`, survive app quit) — rejected. Background sessions are delegate-only (no `bytes(for:)`, so sha256 needs a second full read of a 20 GB file), resume via Apple's own opaque and sometimes-unreliable `resumeData` rather than an HTTP `Range` we control, and critically `URLProtocol` stubbing does not work with them at all — the hermetic download test suite (listing, resume, checksum mismatch, 401, cancel) would have to go, leaving only a manual smoke test. For an `LSUIElement` menu-bar agent designed to always be running — with an `AppDelegate` that already blocks quit to shut the server down cleanly — "resumes instantly on next launch from a plain file" beats "survives quit" at far lower cost.
*(Amended 2026-10-01: the stream is a data task's own chunks (`ChunkedBody`, fed by its delegate), not `URLSession.bytes(for:)`, which hands the body over a byte at a time. Inside `HFDownloader`'s actor that loop was the bottleneck. Against a local server, a 1 GB file took 68 s at 14 MB/s (Debug, M4 Pro), and 0.6 s at about 1,700 MB/s with chunks. On the M1 Max, `quail pull` managed about 5 MB/s on a line where curl got 20. Resume, `Range` across the redirect, the sha256 and cancellation are unchanged, and the stubbed tests still cover them.)*
**Revisit if:** downloads routinely exceed what an always-running agent tolerates (e.g. users quit mid-100 GB download often enough that relaunch-resume feels broken), or Apple fixes `URLProtocol` stubbing for background sessions so the test suite could survive the switch.

## D-014 · 2026-09-22 · A native Swift MLX server (Phase 3), not a `libllama` wrapper or a vendored third-party binary

> **Partly superseded by D-027 (2026-09-24).** The separate `mlx-server` and the "why not wrap `libllama`" reasoning below no longer stand: Phase 3 builds one `quail-server` with both engines. The rejections of `swama` and of linking `mlx-swift-lm` into the app process still hold, and so does the MLX-benchmark question.

**Decision:** Phase 3's fourth `Runtime` adapter will be a small server Quail builds and ships itself — a second executable target linking Apple's `mlx-swift-lm` (MIT, `.macOS("14.0")`, matching Quail's own deployment target) plus a thin HTTP layer, exposing `/v1/models` and `/v1/chat/completions` (with SSE streaming). It mimics llama-server's router-mode shape where practical (`status.value` on `/models`, `POST /models/load`) so its `Runtime` adapter is close to a copy of `LlamaCppRuntime` rather than a third, differently-shaped one. `--api-key` and a loopback-by-default `--host` are ours to add from the start, matching ADR D-010's requirement uniformly across every runtime. oMLX and Rapid-MLX (D-005) are retained as additional adapters, not replaced — which one is fastest is an empirical question (all three ultimately run the same MLX Metal kernels; Python overhead, if any, likely lands on orchestration/TTFT rather than raw decode throughput) to be settled by extending `Ping`'s existing per-step timing into a real cross-runtime benchmark once more than one MLX adapter exists, not assumed up front.
**Why not wrap `libllama` and write our own REST layer for GGUF too (for uniformity):** looked at seriously and rejected. `Vendor/llama.cpp` ships no headers, only dylibs — `llama-server` itself is 67 KB; the real server logic (router mode, `/models`, `/models/load`, auto load/unload, `--models-preset`) lives in the separate 8.9 MB `libllama-server-impl.dylib`, on top of `libllama`, not inside it. Reimplementing that server would also mean reimplementing Jinja chat-template rendering — GGUF files embed arbitrary Jinja2 (confirmed on Qwen3's real metadata: a hundred-line template), and `libllama`'s public `llama_chat_apply_template` only covers a hardcoded set of known templates, not arbitrary embedded ones. Getting this wrong produces subtly malformed prompts on every model — the worst kind of bug, since it looks like the model is bad, not the server. It would also mean losing the built-in web UI, which AGENTS.md explicitly relies on ("Don't add a chat window... Link to the runtime's web UI instead") and `launchSpec` deliberately keeps enabled by omitting `--no-webui`. llama-server is excellent, actively maintained, and already fully integrated (Ping passes against it, D-004's whole rationale). There is no uniformity win large enough to justify discarding all of that for the one runtime that already works best.
**Why not vendor a third-party MLX binary instead of building one (`swama` was evaluated):** MIT-licensed, pure Swift, would map onto `Runtime` almost exactly — but its `Package.swift` targets `.macOS("15.4")` against Quail's 14.0 floor, its `serve` command has no `--api-key` at all (breaks D-010 outright), it defaults to binding `0.0.0.0` rather than loopback, model recognition needs a proprietary `.swama-meta.json` sidecar per directory, and it ships no standalone CLI binary in its releases — only a full competing menu-bar `.app`, from which a CLI would have to be extracted. A single-maintainer, ~600-star project is also a real supply-chain question for something Quail would sign and distribute. `mlx-swift`/`mlx-swift-lm` (Apple's own packages, and swama's actual MLX dependency) have none of these problems and already meet the 14.0 floor.
**Why not link `mlx-swift-lm` directly into Quail (no child process at all):** rejected because it breaks process isolation, the one property every other runtime in this document relies on — a bad inference run would crash Quail itself rather than moving `ServerController` to `.failed` with a restart available, and there would be no `launchSpec`/port to health-probe at all, discarding `ProcessSupervisor` and `HealthProbe` for this path specifically.
**New dependency, pending its own ADR when Phase 3 starts:** `mlx-swift-lm` (and likely `swift-transformers` for tokenizers) via SwiftPM — the first exception to AGENTS.md's "Sparkle is the only permitted dependency" rule. Attribution for any code taken from `swama` as prior art, and an Apache-2.0 `NOTICE` if `swift-nio` is used for the HTTP layer rather than a hand-rolled one on `Network.framework`, follow the precedent already set by `Vendor/llama.cpp/LICENSE-llama.cpp`.
**Revisit if:** `mlx-swift-lm` drops the macOS 14.0 floor before Phase 3 ships (would force choosing between it and Quail's own deployment target); a cross-runtime benchmark shows one Python runtime meaningfully outperforms both our server and the other Python runtime, changing which adapter should be the MLX default; or a maintained, signed, App-Store-legal MLX server binary appears that meets D-010's `--api-key` requirement, making "build our own" unnecessary.

## D-013 · 2026-09-22 · `FitEstimator`'s `.wontFit` boundary, and GGUF fields beyond ARCHITECTURE §7's literal list

**Decision (verdict boundary):** `FitEstimator.estimate` returns `.wontFit` exactly when `model.weightBytes > ceiling` — weights alone against the full GPU working-set ceiling, per ARCHITECTURE.md §7's literal wording ("Won't fit (weights alone exceed the ceiling)"). This is *not* the same as "doesn't fit at any context": a model whose weights are just under the ceiling but whose weights-plus-runtime-overhead exceed it instead produces `.tight(reducedContextSize: 0)` — still unusable in practice, but a distinct, much rarer edge case from weights themselves not fitting. `Comfortable` is a separate, tighter threshold (70% of ceiling) than the fits/doesn't-fit boundary (100% of ceiling) that separates `.tight` from `.wontFit`.
**Alternatives:** Define `.wontFit` as `weightBytes + overheadBytes > ceiling` (rejected — contradicts ARCHITECTURE.md's own wording, and conflates two different failure modes: "this model is fundamentally too big" vs. "this model plus a fixed per-runtime tax doesn't quite fit").
**MLX configs (amended 2026-09-26):** multimodal MLX architectures (Qwen3.5 and later, Gemma 4) keep the language model's settings under `text_config`; `MLXMetadata` now reads each field at the top level first and from `text_config` otherwise, accepts the other names for expert counts (`num_experts`, `top_k_experts`, `experts_per_token`), and reads `max_position_embeddings` as the trained context. All 14 MLX repos in the catalog now give a shape (5 gave none). The KV estimate still counts every layer, although these models give only some layers a full cache (linear attention in three of four layers for Qwen3.6, sliding-window layers for Gemma 4); that overestimates their memory, and does so the same way for GGUF, so the two formats stay comparable. Counting only the full-attention layers, for both, would sharpen it. *(Done per layer in D-071, 2026-10-02.)* **Shapes read from Hugging Face are cached** in `Application Support/Quail/Cache/model-shapes.json` for 30 days (`ModelShapeCache`), keyed by repo and file, so the Add Model list's badges come from disk after the first lookup; verdicts are still computed fresh from the cached shape for this Mac.
**Revisit if:** a `reducedContextSize` of 0 (or some other clearly-unusable-but-technically-`.tight` value) turns out to need surfacing differently in the UI than a normal Tight verdict — at that point `.tight` may need a sub-case, or the UI layer (not `FitEstimator`) may just special-case a reduced context under some floor (e.g. 512 tokens) as effectively `.wontFit` for display purposes.

**Decision (GGUF fields beyond the literal ARCHITECTURE §7 list):** `GGUFMetadata` also reads `<arch>.attention.key_length`/`value_length` and `<arch>.expert_count`/`expert_used_count`, none of which ARCHITECTURE.md §7's table names explicitly (it only lists `block_count`, `head_count_kv`, `embedding_length`, file size). Confirmed these keys are real, present in llama.cpp's own build (`strings Vendor/llama.cpp/libllama-common.0.4.1.dylib | grep '^%s\.attention\.\|^%s\.expert'`) before adding them.
**Why:** without `key_length`, GGUF's per-head attention dimension `d` in the RAM formula has to be computed as `embedding_length / head_count` — which has exactly the failure mode `MLXMetadata.swift` already documents for MLX's `head_dim` (confirmed against a real repo, mlx-community's Gemma 2 9B, that the computed and actual values disagree). GGUF has the identical escape hatch for architectures where that division doesn't hold; not reading it would silently ship a wrong `d` for those architectures. Without `expert_count`/`expert_used_count`, GGUF MoE models get no `activeWeightBytes`, meaning `FitEstimator.speedEstimate` would badly underestimate their tok/s (using full weight bytes instead of active-expert bytes) — while MLX MoE models (which do have `num_local_experts`/`num_experts_per_tok`) would not have this problem, an inconsistency between formats.
**Alternatives:** Only read what ARCHITECTURE.md's table names literally, treat GGUF MoE speed estimates as "unavailable" and computed `d` as always correct enough (rejected — a formula that's known-wrong for a real, common case like Gemma-family GGUFs isn't better than not shipping the fields at all).
**Revisit if:** never expected to — these are just filling in fields ARCHITECTURE.md's table description was shorthand for, not a scope change.

## D-012 · 2026-09-22 · `presets.ini` regenerated from disk, not from the catalog; keyed like the CLI flags

**Decision:** `ModelStore.regeneratePresets(catalog:)` builds `presets.ini` by scanning `gguf/` for `.gguf` files actually present on disk right now, not by iterating `catalog.json`'s entries. `AppState.start()` calls it on every Start, not just once on first run. Each file gets one `[alias]` section with `model`, `n-gpu-layers = 99`, and `ctx-size` (from a matching catalog entry's `contextSize` if one exists, else a fixed 8,192 default).
**Why scan disk, not the catalog:** Phase 1's "Done when" is "placing a GGUF in `.../Models/gguf/` and clicking Start yields a passing ping test" — a model dropped in by hand has no catalog entry and never will unless something explicitly imports it. If `presets.ini` only covered catalog entries, hand-placed models would keep working (llama-server's own directory scan doesn't need a preset) but would silently never get one — fine today since nothing in the preset is essential yet, but a footgun for the day `ctx-size`/`n-gpu-layers` actually need to vary per model (Phase 2 step 4's `FitEstimator`).
**Found only by testing against a real b11081 build:** `--models-preset`'s INI keys have to be the CLI flag's own name, dashes and all — `n-gpu-layers`, not `n_gpu_layers`. The underscore form isn't silently ignored; it fails the router at startup with `option 'n_gpu_layers' not recognized in preset '<alias>'`, taking every model down with it. Confirmed the dash form works and actually reaches the spawned model instance's own arg list (`ps`/`GET /models` both show `--n-gpu-layers 99 --ctx-size 8192` on the child process once fixed).
**Sampling defaults deliberately omitted:** docs/IMPLEMENTATION_PLAN.md's original Phase 2 step 1 line item said `presets.ini` generation should include "sampling defaults" alongside context size and `n_gpu_layers`. Not implemented: llama-server already ships its own (temperature, top-p, ...), and Quail has no Settings surface yet for anyone to choose different ones. Writing specific numbers into every model's preset with nothing in the UI explaining or controlling them would be guessing, not a decision — this line item is revisited once there's an actual place to set them.
**Alternatives:** Only regenerate on `ModelStore.saveCatalog` (rejected — misses hand-placed models, the exact case Phase 1 was built to support); keep the catalog and disk-scan approaches both, unioned (unnecessary complexity while `ctx-size` is a single fixed default for everything either way).
**Revisit if:** Phase 2 step 4 lands and most models get a real, catalog-derived `contextSize` — at that point it may be worth warning (not silently defaulting to 8,192) when a disk-scanned file has no matching catalog entry at all.

## D-011 · 2026-09-22 · `--models-max 1` by default

**Decision:** `EndpointConfig.modelsMax` (passed to router-mode `llama-server` as `--models-max`) defaults to `1`, not upstream's own default of 4. A single loaded model is the only thing Quail's UI has any concept of in Phase 1; there's no model picker, no "which models are loaded" view, and no per-model RAM accounting yet. Letting the router silently keep up to 4 GGUFs resident — each potentially several GB — with no UI surfacing that fact would be a footgun on the exact machines (16 GB, 32 GB) Quail's device-fit story (ARCHITECTURE.md §7) cares most about.
**Alternatives:** Leave it at the upstream default of 4 (rejected for the reason above); make it 2 as ARCHITECTURE.md's open question floated for "fast switching on 64 GB+ machines" (deferred, not rejected — worth revisiting once Settings has a way to show and evict multiple loaded models).
**Answers ARCHITECTURE.md's open question:** "Whether to let llama-server keep two models loaded (`--models-max 2`) for fast switching on 64 GB+ machines" — not yet; `modelsMax` is a `Config` field so this is a one-line change plus UI once Phase 2's Models pane exists to make loaded state visible.
**Revisit if:** the Models pane (Phase 2) adds a "loaded models" view — at that point `--models-max 2` on 64 GB+ machines becomes safe to default to, or at least easy to offer as a Settings toggle.

## D-010 · 2026-09-22 · API key off by default, regardless of host

> **Reversed by D-039 (2026-09-25):** the key is now on by default, because the threat this decision didn't consider is a web page in the user's own browser.

**Decision:** `Config.apiKeyEnabled` defaults to `false`. A freshly-launched Quail runs `llama-server` with no `--api-key` at all, on `127.0.0.1`, same as it always has. The Settings → Endpoint toggle is the only way to turn one on; enabling it generates a random 32-byte key (Keychain-only, never in `config.json`) and passes it as `--api-key`.
**Why:** Matches Postgres.app's "trust" default on loopback (cited in ARCHITECTURE.md's own open question) — a local dev tool serving `127.0.0.1` isn't meaningfully more secure with an API key, since anything on the same machine that can reach loopback can also read the key out of Keychain or `ps`. The real risk is binding to `0.0.0.0` (LAN) with no key; Phase 4's one-time LAN-binding warning (ARCHITECTURE.md's UI table) is the point where Quail should actively steer users towards enabling one, not Phase 1 forcing it on unconditionally for everyone including the common loopback-only case.
**Alternatives:** Default on everywhere (rejected — friction for the common case, and a key sitting in Keychain that every loopback process can already read isn't protecting much); default on only when host isn't loopback (deferred to Phase 4 alongside the LAN warning this PR doesn't implement, rather than half-building host-dependent defaulting now).
**Answers ARCHITECTURE.md's open question:** "Should the API key default to on (random, shown once) or off for loopback?" — off, matching Postgres.app.
**Revisit if:** Phase 4's LAN-binding warning ships and it turns out users routinely miss it — at that point, forcing the toggle on when `host != "127.0.0.1"` (rather than just warning) is worth reconsidering.

## D-009 · 2026-09-22 · llama.cpp vendoring: computed dependency closure, no `install_name_tool` rewriting

**Decision:** `scripts/vendor-llama.sh` copies `llama-server` and its full `@rpath` dependency closure — computed by recursively walking `otool -L`, not a hardcoded library list — into `Vendor/llama.cpp/`, and does **not** run `install_name_tool -id`/`-change`. `scripts/verify-macho.sh` asserts every dependency is `@rpath/`, `@loader_path/`, `@executable_path/`, or a system path, failing loudly otherwise. A separate Xcode run-script build phase, `scripts/embed-llama.sh`, copies that same closure into `Contents/MacOS` on every build and signs each file with whatever identity Xcode resolved for that build (ad-hoc for `CODE_SIGNING_ALLOWED=NO`, the real Developer ID identity for a signed Release build) — this is where the "sign inside-out … `--timestamp --options runtime`" step from §9 actually happens, not in the vendor script.
**Why:** Inspecting the real `b11081` release (2026-09-21) showed every Mach-O already carries an `@loader_path` `LC_RPATH` and an `@rpath/<name>` install name/ID — the rewriting ARCHITECTURE.md originally called for is unnecessary today. The closure is 10 dylib names, not the 3 the docs guessed (`libllama`, `libggml*`, `libmtmd`) — it also needs `libllama-common` and `libllama-server-impl`. Computing the closure at vendor time instead of hardcoding names means a future llama.cpp release can add/rename a dylib without an immediate script update; `verify-macho.sh` is the safety net if a future release stops being `@rpath`-relative.
**Alternatives:** Keep the original hardcoded-list + `install_name_tool` approach (matches what the docs assumed, but is both unnecessary for the current release layout and silently wrong if the library list ever changes); sign once at vendor time only (rejected — a Developer ID Release build needs the *project's* resolved identity and a notarization timestamp, which only exist at Xcode build time, not when a contributor runs the vendor script).
**Finding carried into PR 4:** the very first launch of a freshly (re-)signed `llama-server` took ~16 s to start listening in local testing (subsequent launches of the same signature were ~1 s), consistent with one-time AMFI/Gatekeeper validation of a new code signature. `ProcessSupervisor`'s 90 s bind timeout (per the existing plan) already covers this.
**Correction (PR 4):** the note below about needing a process-group kill for router mode was written from reading the docs, before it was actually tested. It was wrong. Tested against a real model load: sending a plain `SIGTERM` to only the router's PID triggers the router's own graceful shutdown, which stops its child model-instance process itself (`llama_server: cleaning up before exit... unload_all: stopping model instance... exit command received, exiting...`, child exits with status 0, confirmed via `ps` that both processes are gone). `ProcessSupervisor` therefore just calls `Process.terminate()` (`SIGTERM`) on the single `Process` it owns — no `setpgid`/`killpg` machinery. ~~router-mode `llama-server` forks a child process per loaded model — the supervisor must kill the whole process group, not just the router PID.~~
**Revisit if:** a future llama.cpp release ships a dependency that isn't `@rpath`-relative (verify-macho.sh will fail the vendor step, forcing a conscious fix rather than a silent break).

## D-008 · 2026-09-22 · Xcode project generated by XcodeGen, committed as `Quail.xcodeproj`

**Decision:** `project.yml` is the source of truth; `xcodegen generate` produces `Quail.xcodeproj`, which is committed (not git-ignored) so `xcodebuild` works with no extra tooling for anyone who clones the repo. Two schemes (`Quail`, `Quail-AppStore`) are backed by four build configurations — `Debug`/`Release` and `Debug-AppStore`/`Release-AppStore` — because the App Store variant needs both a distinct `SWIFT_ACTIVE_COMPILATION_CONDITIONS` (`APPSTORE`) and a distinct `CODE_SIGN_ENTITLEMENTS` file, and Xcode ties both to the build configuration, not the scheme.
**Alternatives:** Hand-write the `.pbxproj` (more control, much more error-prone to hand-edit and review in diffs); Xcode 16's synchronized root groups without a generator (avoids the extra tool, but doesn't solve the two-schemes/four-configs problem and still means hand-editing the pbxproj for every new file group). Tuist was considered and rejected — more powerful than needed here and another Ruby/Swift toolchain dependency for a single-target app.
**Why it doesn't conflict with AGENTS.md's "no third-party UI" rule:** XcodeGen is a project-generation tool, not a runtime or UI dependency — it never ships in the app bundle.
**Revisit if:** the project grows enough targets/schemes that `project.yml` becomes hard to read, or XcodeGen stops tracking new Xcode project-format features we need.

## D-007 · 2026-09-21 · Name: Quail

**Decision:** The product is Quail ("quick AI, local"). Bundle id `com.datoos.quail`, CLI/paths `quail`.
**Alternatives:** Infer.app, Bellows, Llamp, Corral, Applai. Applai rejected on Apple trademark and App Store guideline 5.2.5 grounds; Llamp rejected as tying the brand to one runtime.
**Revisit if:** a trademark search turns up a conflicting software product.

## D-006 · 2026-09-21 · Two builds: Developer ID direct + Mac App Store

**Superseded by D-053 (2026-09-26):** publication now targets Homebrew and the signed DMG; the Store configuration remains only until a separate cleanup.

**Decision:** One codebase, two schemes. Direct build has everything; App Store build is llama.cpp-only with `#if !APPSTORE` compiling out runtime installs.
**Why:** The sandbox forbids downloading executable code and spawning unsandboxed processes, which rules out oMLX/Rapid-MLX on the Store. The Store is still useful for discovery.
**Revisit if:** Store review rejects even the bundled `llama-server` helper, or the Store channel brings no users.

## D-005 · 2026-09-21 · Python runtimes installed by app-managed uv, not bundled or Homebrew

**Decision:** Ship the `uv` binary; install oMLX and Rapid-MLX into `Application Support/Quail/Runtimes` with pinned versions, tested ranges, smoke-tested updates and cached rollback.
**Alternatives:** Bundle a Python + wheels (multi-GB, brittle notarization, forces an app release for every runtime release); depend on Homebrew (PATH/version detection, no control over updates).
**Revisit if:** either runtime ships a self-contained native binary, or uv changes its tool layout incompatibly.

## D-004 · 2026-09-21 · llama.cpp is bundled and is the default runtime

> **Amended by D-027 (2026-09-24).** llama.cpp stays bundled, but as `libllama` inside `quail-server`; the vendored `llama-server` remains the default until `quail-server` passes its parity gate, then goes.
>
> **Amended 2026-09-28.** The gate passed and `quail-server` is the default. By the owner's decision `llama-server` stays bundled and selectable (GGUF only) as a fallback, rather than leaving; it remains the only runtime in the legacy App Store build.

**Decision:** Vendor a pinned `llama-server` release into the bundle. It is the only runtime in the App Store build and the default everywhere.
**Why:** Zero dependencies, router-mode hot swap (`/models/load`), `/health`, `--log-file`, widest model catalogue. Postgres.app-faithful.
**Trade-off:** MLX decodes 1.4–1.8× faster on large dense/MoE models; that is what the optional runtimes are for.
**Revisit if:** mlx-serve or similar offers a signed native binary with an equivalent management API — then it could become a second bundled runtime.

**Amended 2026-09-28 (MLX against GGUF, measured; Phase 3 step 8):** the same families in both formats on Quail server, on a Mac mini (M4 Pro, 64 GB), Release. The app's own benchmark ran, extended the same day with a returning turn and four requests at once; each model ran twice, the formats alternating, each run on a cooled machine with macOS's analysis daemons paused. Medians of the two runs:

| | Qwen3-8B GGUF Q4_K_M | Qwen3-8B MLX 4-bit | Qwen3.6 35B-A3B GGUF UD-Q4_K_M | Qwen3.6 35B-A3B MLX 4-bit |
|---|---|---|---|---|
| Prompt, 512 tokens (tok/s) | **454** | 420 | **824** | 718 |
| Prompt, 4,096 tokens | 368–381 | **417–425** | 785–798 | 788–798 |
| Generation | 44 | **52** | 55 | **85** |
| First token, 512-token prompt (ms) | **1,130** | 1,221 | **624** | 717 |
| Returning turn, first token (ms) | 195–203 | 203–206 | 185–189 | **172** |
| Four requests at once, total (tok/s) | 49 | 51 | 82 | 80 |

- **Generation:** MLX writes 18% faster on the dense 8B and 54% faster on the mixture-of-experts 35B.
- **Short prompts:** GGUF reads 8–15% faster, so its first token comes sooner.
- **Returning turns:** equal on both; both reuse their caches now.
- **Several callers:** four requests at once total about the same on either format. GGUF decodes them together, while MLX takes them one at a time and makes up for it with speed. Per request, GGUF's four each ran at about a quarter of that total, and MLX's queued behind one another.
- **Not compared:** peak memory, and Gemma 4 (no GGUF of it is installed).
- **Decision:** with Quail server as the runtime, Add Model now picks the MLX variant by default where a family has one; its format picker says GGUF serves several requests at once. Under llama.cpp it stays on GGUF. The catalog's per-family recommendations are unchanged; the difference is by format, not by family.

## D-003 · 2026-09-21 · Child-process supervision, not a LaunchAgent

**Decision:** The app spawns the runtime as a child `Process`; quitting the app stops the server. Open-at-login gives "always on while logged in".
**Alternatives:** `SMAppService.agent` LaunchAgent so the server outlives the app; Rapid-MLX's system LaunchDaemon.
**Why:** Simplest correct behaviour, no `launchctl` state to reconcile, matches Postgres.app. A LaunchAgent can be added later behind the same `Runtime` protocol.
**Revisit if:** users routinely want the server up without the menu bar icon.

## D-002 · 2026-09-21 · Quail owns the model store and does all downloads itself

**Decision:** One folder with `gguf/` and `mlx/` subtrees, an app-maintained `catalog.json`, and an in-app Hugging Face downloader. Runtimes are always pointed at the store explicitly; `HF_HOME` is redirected into it.
**Alternatives:** Let each runtime download into its own default location and try to reconcile; symlink farms.
**Why:** Uniform progress/resume/checksum, one place to compute fit verdicts, no cross-runtime symlink quirks.
**Revisit if:** a runtime starts refusing models outside its own cache layout.

## D-001 · 2026-09-21 · Scope: serving only, no chat

**Decision:** No chat, agent, image or audio UI. The ping test is a streamed one-token completion with timings, not a conversation.
**Why:** The existing desktop apps are bloated precisely because they try to be everything. Runtimes already ship web UIs; link to them.
**Revisit if:** never, for v1. *(Narrowed by D-021: `quail chat` chats in the terminal; the app itself still has no chat UI. Narrowed again by D-042: the `quail-server` it ships serves one small chat page at `/`. And by D-072: serving models that don't chat, through APIs, is in scope; a UI for them is not.)*
