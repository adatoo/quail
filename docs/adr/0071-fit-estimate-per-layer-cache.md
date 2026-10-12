# ADR-0071: The fit estimate counts each layer's cache

**Date:** 2026-10-02 · **Status:** Accepted

**Decision:** `FitEstimator` sums the KV cache over the layers that keep one, each at its own size, instead of `2 · L · H_kv · d · b · C` over every layer. `ModelShape.kvLayers` holds the groups of alike layers. It's `nil` for a model whose layers are all alike, which keeps the old formula and the same numbers.
- **GGUF**, from the keys libllama reads:
  - `attention.head_count_kv` per layer. Hybrids write 0 for a layer without attention; the first element was taken before, so Nemotron's cache counted as nothing.
  - `attention.sliding_window_pattern`, with `key_length_swa`/`value_length_swa` for those layers.
  - `full_attention_interval`: a Qwen3.5-family hybrid's linear-attention layers keep none.
  - `attention.shared_kv_layers`: layers that reuse an earlier one's cache keep none.
  - A sliding-window layer still holds the whole context: quail-server keeps libllama's full-size window cache (`swa_full`, ADR-0048 amendment).
- **MLX**, from `config.json`:
  - `layer_types`, `sliding_window` and Gemma 3's `sliding_window_pattern`. A sliding-window layer holds at most its window, as mlx-swift-lm's and mlx-lm's rotating cache does. It stays at full precision under a quantized setting, since MLX doesn't quantize a rotating cache (ADR-0057).
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
- Gemma 4 31B (GGUF) on the bench M1 Max (64 GB, Metal ceiling 55.7 GB), quail-server 0.67.3, every slot given a 6,000-token prompt at once: 14 GiB (15.0 GB) at 16K over two slots and 28 GiB (30.1 GB) at 32K over four, as `footprint` rounds them, against 14.8 and 29.5 GB of cache from the new formula (the old one said 32 and 64 GB). Both ran. Four slots of 8K had run this Mac's GPU out of memory on 0.66.0 during the catalog scores (ADR-0070 amendment); that no longer happens.

The MLX window cap is from mlx-swift-lm's `makeHybridAttentionKVCache` and Quail's own `Gemma4Text`, not measured.

**Not counted:** the linear-attention and Mamba layers' fixed state (about 250 MB for Qwen3.6 with four slots), and the compute buffers. Both are left to O. The 26B-A4B measurement put everything outside the cache at about 1.1 GB, under O's 1.5 GB. For Gemma 4 31B on the M1 Max, 32K is now Tight (49.4 GB of the 55.7 GB ceiling) rather than over it, and Automatic picks 16K, the largest under 70%.

**Alternatives:** count only full-attention layers (the decision records' MLX config note of 2026-09-26): simpler, but wrong for GGUF's full-size window cache and Gemma 4's different head sizes. Measure each model after loading (§7's calibration): still wanted, but the estimate has to be right before a download.

**Revisit if:** quail-server turns `swa_full` off (GGUF windowed layers would then hold their window, as MLX's do), or an architecture with another kind of layer arrives (MLA, as DeepSeek V3 writes `kv_lora_rank`).
