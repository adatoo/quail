# ADR-0020: Per-model context size, defaulting to the largest comfortable

**Date:** 2026-09-23 · **Status:** Accepted

**Decision:** Each installed model has a context setting in the Models pane: Automatic (the largest of 32K / 16K / 8K that is Comfortable on this Mac, capped at the model's trained context), or a user-chosen size from 4K–128K (options above the trained context aren't offered; options that don't fit at their own size are disabled). The choice lives in `catalog.json` (`userContextSize`) and survives store refreshes; `presets.ini` writes the effective size, and a change while running shows "restart to apply".
**Alternatives:** Keep ARCHITECTURE §7's fixed C = 8,192 (only reduced for Tight models); fully automatic sizing with no user control (considered — user chose the explicit setting).
**Why:** Measured live: Claude Code's first request is 15,114 tokens (system prompt + tool definitions), so every coding agent overflowed an 8K context before doing anything. A 64 GB Mac runs most catalog models comfortably at 32K+.
**Trade-off:** A larger context reserves more KV-cache memory up front; Automatic stays within the Comfortable threshold, and a user picking beyond it sees the verdict first. The Connect tab warns when a tool's known minimum (`minContext`) exceeds the chosen model's context.
**Revisit if:** llama.cpp gains dynamic context growth, or KV-cache quantization (q8) becomes the default — both change the memory maths.
