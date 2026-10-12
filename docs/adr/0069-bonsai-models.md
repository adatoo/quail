# ADR-0069: The Bonsai models: which files, and which engine

**Date:** 2026-10-01 · **Status:** Accepted

**Situation:** PrismML's Bonsai models are Qwen3 and Qwen3.6 models trained to low-bit weights. They come in three kinds, each published for GGUF and MLX:
- **1-bit Bonsai** at 1.7B, 4B, 8B and 27B;
- **Ternary Bonsai** (weights of −1, 0 or +1) at the same sizes;
- **Bonsai 2 27B**, a ternary Qwen3.6 27B whose weights are stored in a Hadamard-rotated basis.

Add Model already listed three Ternary Bonsai MLX downloads, from Rapid-MLX's catalog (ADR-0058). Several of the other files need runtime code that llama.cpp and mlx-swift-lm don't have yet.

**What runs where.** Checked on 2026-09-30 and 10-01 with llama.cpp b11081 and again with b11306, and with mlx-swift-lm 0dcfe2f8a (MLX 0.32.2):

| | GGUF | MLX |
|---|---|---|
| 1-bit | ✅ `Q1_0` | ❌ MLX refuses `bits: 1` (mlx#3161, open since February) |
| Ternary | ✅ the `Q2_0_g64` file (the 27B's is `Q2_g64`); ❌ PrismML's `Q2_0` and `PQ2_0` | ✅ affine 2-bit |
| Bonsai 2 | ❌ `PQ2_0`/`PTQ1_0` (llama.cpp #29600, open) | ❌ needs mlx-swift-lm #630 (open); ✅ with Quail's own copy of it |

**Decision:**
- **1-bit Bonsai: GGUF only.** MLX would need either a fork of MLX core, which ADR-0055 rules out, or Quail's own 1-bit quantized matmul in Metal.
- **Ternary Bonsai: both formats, with the GGUF quant llama.cpp reads.**
  - llama.cpp's own `Q2_0` stores 64 weights a block. PrismML's file named `Q2_0` stores 128, their fork's format, so llama.cpp stops with "failed to read tensor data".
  - Their `Q2_0_g64` file is the upstream format.
- **Bonsai 2: MLX only,** through a third model copy (ADR-0066 amendment): mlx-swift-lm PR #630's rotation, built on Quail's Qwen3.5 copy.
- **Strengths are what the checks showed, not what the base model can do.**
  - The 1.7B, 4B and 8B models have no thinking mode: their template closes the think block.
  - Both 4B models write a tool call without its opening `<tool_call>` tag, on llama-server as on quail-server, so they aren't marked agentic.

**Alternatives:**
- **PrismML's forks for 1-bit MLX** (`PrismML-Eng/mlx-swift`): a fork of MLX core, against ADR-0055.
- **Quail's own 1-bit matmul kernel,** which ADR-0066 would allow: a large piece of Metal for one family, while upstream has a PR open.
- **PrismML's recommended GGUF files** (`Q2_0`, `PQ2_0`): they don't load on upstream llama.cpp.

**Revisit if:**
- mlx#3161 ships in mlx-swift (1-bit on MLX);
- mlx-swift-lm takes #630 (delete the copy);
- llama.cpp takes #29600 (Bonsai 2 on GGUF);
- PrismML renames its files.

The weekly Upstream watch workflow follows the three upstream PRs and comments on #158 when one merges or closes.

**Amended 2026-10-12 (llama.cpp b11564):** llama.cpp #29600 merged on 10-11 and is in b11564, which Quail now bundles. It adds Bonsai 2's activation transform for llama.cpp's own `Q2_0` type, not PrismML's `PQ2_0` and `PTQ1_0`; those two still stop with "failed to read tensor info".
- **What works:** the `Q2_0` file is in PrismML's testing repo, `prism-ml/Ternary-Bonsai-2-27B-gguf-dev` (7.6 GB, named `…-Q2_0-prism-fork-required.gguf`). On b11564 it answered correctly with its thinking, called a tool, and read the test image with the main repo's Q8_0 projector. That held on both quail-server and the bundled llama-server.
- **Speed:** on the M4 Pro with a Release build, it wrote 18 tok/s against 15 for the MLX 2-bit build. That's one short reply each, so it's not a benchmark.
- **The catalog waits for PrismML.** Its testing repo says the file "moves to the main repo once that lands", next to the projector. A catalog row pointing at a testing repo, under a name that says a fork is required, would be wrong on both counts. #158 tracks the move.
- mlx#3161 merged on 10-09 but isn't in an mlx-swift release yet. The Upstream watch now follows mlx-swift-lm #630 alone, and #158 lists what the other two wait on.
