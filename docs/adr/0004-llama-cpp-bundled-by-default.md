# ADR-0004: llama.cpp is bundled and is the default runtime

**Date:** 2026-09-21 · **Status:** Accepted

> **Amended by ADR-0027 (2026-09-24).** llama.cpp stays bundled, but as `libllama` inside `quail-server`; the vendored `llama-server` remains the default until `quail-server` passes its parity gate, then goes.
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
