# ADR-0002: Quail owns the model store and does all downloads itself

**Date:** 2026-09-21 · **Status:** Accepted

**Decision:** One folder with `gguf/` and `mlx/` subtrees, an app-maintained `catalog.json`, and an in-app Hugging Face downloader. Runtimes are always pointed at the store explicitly; `HF_HOME` is redirected into it.
**Alternatives:** Let each runtime download into its own default location and try to reconcile; symlink farms.
**Why:** Uniform progress/resume/checksum, one place to compute fit verdicts, no cross-runtime symlink quirks.
**Revisit if:** a runtime starts refusing models outside its own cache layout.
