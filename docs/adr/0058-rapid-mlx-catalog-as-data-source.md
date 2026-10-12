# ADR-0058: Rapid-MLX's catalog as a data source for MLX models (Phase 3 step 9)

**Date:** 2026-09-28 · **Status:** Accepted

**Situation:** MLX is the default format on Quail server (ADR-0004 amendment), but the curated catalog (ADR-0019) offers one hand-picked MLX repo for each of 15 families. Rapid-MLX (Apache-2.0, 0.14.3, installed here with Homebrew) ships three data files with its Python package:
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
