# ADR-0057: Opt-in KV cache quantization, per model (Phase 3c step 7)

**Date:** 2026-09-28 · **Status:** Accepted

**Situation:** A model's KV cache grows with context: 147 KB a token on Qwen3-8B, so 3.4 GB at 24,000 tokens and 4.6 GB for a 32K GGUF context. On a 16–24 GB Mac that decides whether a coding agent's 30K prompt fits at all. Both engines can store it in fewer bits:
- llama.cpp has `type_k`/`type_v`, with q8_0 and q4_0 needing flash attention for V; llama-server exposes them as `--cache-type-k/-v`.
- mlx-swift-lm 3.31.4 converts plain `KVCacheSimple` layers with `maybeQuantizeKVCache` to affine 8- or 4-bit, group 64. Every model we serve reads the result through `QuantizedKVCacheProtocol`. Recurrent and sliding-window layers aren't converted.

The fit formula had `b` fixed at 2, and nothing set anything else.

**Decision:** a per-model setting, off by default: **Full precision / 8-bit / 4-bit**, in the model row's context menu. Each option is labelled with its verdict at the model's context.
- **Stored** as `InstalledModel.userKVCache`, like the context choice (ADR-0020).
- **Written** to `presets.ini` as llama-server's own keys, `cache-type-k`/`cache-type-v` = `q8_0`/`q4_0`, plus `flash-attn = on` for GGUF. llama-server reads them unchanged; checked against the vendored b11081.
- **Read by quail-server** for both engines (`ModelEntry.cacheTypeK/V`, `flashAttention`), so one preset format serves both runtimes. This differs from the plan's new `cache-bits` key.
  - **GGUF:** the types go into the context parameters, with flash attention on for a quantized V.
  - **MLX:** a cache is quantized only when K and V both are, to the larger of the two bit counts. `MLXSequence` swaps its attention caches for quantized ones as soon as they hold anything, after each prefill slice and forward pass. mlx-swift-lm's own iterator paths get `kvBits` through `GenerateParameters`.
  - **MLX restrictions:** a model with a quantized cache doesn't batch (ADR-0056's `BatchedLayers` takes plain caches only). Its disk prompt caches live in a folder of their own, because the layout differs.
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
