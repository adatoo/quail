# ADR-0066: Quail's own copies of mlx-swift-lm model files

**Date:** 2026-09-29 · **Status:** Accepted

**Situation:** the first comparison (ADR-0063) found two MLX gaps whose cause is mlx-swift-lm's model code, not Quail's.
- **Gemma 4 26B-A4B was served one request at a time (#140).** mlx-swift-lm's text-only Gemma 4 has no mixture-of-experts layers, so the model loaded only through the vision model, whose attention takes one position for the whole batch.
- **Qwen3.5 and 3.6 decode and read prompts slower than oMLX and Rapid-MLX (#141).** Those two compile small functions and add Metal kernels for this family.

ADR-0055 had decided on mlx-swift-lm's public API only, with no custom Metal and no fork.

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

**First copy:** Gemma 4's language model, from `MLXVLM/Models/Gemma4.swift`. It's text only, and its attention takes positions from the cache's `ropeOffset`, so it batches (ADR-0056 amendment, #140).

**Alternatives:**
- **Fork mlx-swift-lm and pin to the fork.** That means the whole library to keep current, not a few files.
- **Offer the changes upstream and wait.** The timing wouldn't be ours.
- **Leave both gaps.**

**Supersedes** ADR-0055's "public API only, no custom Metal" for model code. Its other rules stand, such as no fork of MLX core.

**Revisit if:** upstream takes a change (delete that copy), or the copies grow past a handful of files.

**Amended 2026-09-29 (the second copy: Qwen3.5 and 3.6, #141):** `QuailServer/MLX/Models/Qwen35.swift` is copied from mlx-swift-lm's Qwen35.swift and Qwen35MoE.swift, with the parts of Qwen3Next.swift and GatedDelta.swift they use.
- **What it covers:** it's registered for `model_type` qwen3_5, qwen3_5_moe and qwen3_5_text. The configuration types are copied too, since their fields are internal to mlx-swift-lm.
- **Changes, following mlx-lm:**
  - The small element-wise functions mlx-lm compiles are compiled here: the decay `g`, the gated norm's float32 SwiGLU, and the MLPs' SwiGLU. The attention output gate is compiled as well.
  - `beta` stays in the activations' type, as mlx-lm keeps it.
- **Output:** replies at temperature 0 were byte-identical to mlx-swift-lm's on four prompts, including a 1,500-token one. Batched replies behave as ADR-0056 describes.
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

**Amended 2026-10-01 (the third copy: Bonsai 2 27B, ADR-0069):** `QuailServer/MLX/Models/PrismHadamard.swift` is adapted from mlx-swift-lm pull request #630 at bac826f, which is still open. That PR's code is under mlx-swift-lm's MIT licence.
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
