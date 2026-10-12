# ADR-0052: What each model is good for: curated strengths, vision derived

**Date:** 2026-09-26 · **Status:** Accepted

**Decision:** Catalog families carry `strengths`, raw strings from a fixed vocabulary (`ModelStrength`): chat, coding, agentic, reasoning, long-context, vision, multilingual, embedding, audio.
- **Where they show:**
  - the Add Model sheet: chips under each family, and a "Good for" list with explanations in the detail pane;
  - a "Good for" filter next to the format filter;
  - the Models list: installed rows show their family's chips, matched as `InstalledLookup` matches them.
- **How each is decided:**
  - Each curated tag is checked against the model card; long-context comes from the config's trained context (≥128K). Revision 4 of `catalog.json` records the sources.
  - `vision` is never curated. It shows when the family's GGUF download has an `mmproj`, because that's the only way Quail passes images (ADR-0047; the MLX engine is text-only), and not for an installed MLX copy.
  - `audio` is recorded when the model has it (Gemma 4 12B), but Quail can't pass audio, so it isn't a chip. The detail pane says "the model also understands audio; Quail can't pass that to it yet".
  - "Deep research" isn't a tag. It's reasoning plus long context plus tools, and the reasoning explanation says so.
- **What it replaces:** the single `role` word in the subtitle, which now appears only when it says something the chips don't ("smoke-test").
- **Recommendations:** unchanged. Strengths inform the choice; they don't rerank.

**Why:** requested ("highlight what the model is good for … allows users to make a more informed choice"). A single role string couldn't say that Qwen3.8 codes, reasons, uses tools and reads images.

**Alternatives:** Deriving everything from Hugging Face tags (inconsistent between uploaders, and a network call per family). Benchmark scores per task (no comparable source across families yet).

**Revisit if:** an engine gains audio or MLX vision (flip `isUsableInQuail`, or derive vision for MLX too), or a remote catalog needs a new strength. Older apps skip strings they don't know.
