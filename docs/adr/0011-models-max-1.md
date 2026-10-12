# ADR-0011: `--models-max 1` by default

**Date:** 2026-09-22 · **Status:** Accepted

**Decision:** `EndpointConfig.modelsMax` (passed to router-mode `llama-server` as `--models-max`) defaults to `1`, not upstream's own default of 4. A single loaded model is the only thing Quail's UI has any concept of in Phase 1; there's no model picker, no "which models are loaded" view, and no per-model RAM accounting yet. Letting the router silently keep up to 4 GGUFs resident — each potentially several GB — with no UI surfacing that fact would be a footgun on the exact machines (16 GB, 32 GB) Quail's device-fit story (ARCHITECTURE.md §7) cares most about.
**Alternatives:** Leave it at the upstream default of 4 (rejected for the reason above); make it 2 as ARCHITECTURE.md's open question floated for "fast switching on 64 GB+ machines" (deferred, not rejected — worth revisiting once Settings has a way to show and evict multiple loaded models).
**Answers ARCHITECTURE.md's open question:** "Whether to let llama-server keep two models loaded (`--models-max 2`) for fast switching on 64 GB+ machines" — not yet; `modelsMax` is a `Config` field so this is a one-line change plus UI once Phase 2's Models pane exists to make loaded state visible.
**Revisit if:** the Models pane (Phase 2) adds a "loaded models" view — at that point `--models-max 2` on 64 GB+ machines becomes safe to default to, or at least easy to offer as a Settings toggle.
