# ADR-0026: The Ollama registry is not a download source; ModelFit only feeds catalog discovery

**Date:** 2026-09-24 · **Status:** Accepted

**Decision:** Quail keeps downloading only from Hugging Face (ADR-0002 unchanged). The ModelFit dataset (`modelfit.io/api/dataset/`, CC BY 4.0) is used at most as an input to a maintainer script that proposes catalog candidates; nothing in the app fetches it or the Ollama registry at runtime, and `catalog.json` stays curated by a person.
**Alternatives:** Add an Ollama registry downloader (manifest → GGUF and projector layers by digest) and a catalog variant keyed by Ollama tag, fed by ModelFit. Import ModelFit's `minRamGb`/`estimatedLoadGb` for fit verdicts.
**Why:** A spike against the pinned llama.cpp b11081 loaded only 2 of 5 Ollama files (`llama3.2:1b`, `qwen3.6:35b-a3b` with its projector); `gemma3:4b`, `gemma4:e4b` and `gpt-oss:20b` are Ollama-engine builds it rejects, and the manifest doesn't say which are affected. The registry API is also undocumented, and Ollama publishes only its own quants. ModelFit has no HF repo ids, and its RAM figures are a flat ~0.6 GB per billion parameters, which `FitEstimator` (real file sizes and GGUF headers) already beats. What it does have is a current, broad list of models people run locally, which is the part that's costly to notice by hand. Details in IMPLEMENTATION_PLAN Phase 2b step 7.
**Revisit if:** llama.cpp gains the missing architectures and Ollama's GGUFs become plain llama.cpp files, Ollama documents its registry, or a maintained mapping from Ollama tags to HF GGUF repos appears.
