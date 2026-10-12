# ADR-0070: Helping people choose a model: release dates, model cards, and Arena's ratings

**Date:** 2026-10-01 · **Status:** Accepted

**Decision:** Each curated catalog family carries what helps someone choose it, all optional in the schema so older apps read the catalog unchanged:
- `released`, the day its maker made it public;
- `modelCard`, the maker's own Hugging Face repo, as opposed to the quantized one Quail downloads;
- `summary`, one line on what it's for and any quirk worth knowing;
- `supersededBy`, the id of a newer family from the same line;
- `arena`, its rating on Arena's text leaderboard.

The Add Model sheet shows these in a card (`ModelFactsCard`) under the model's name, a **New** badge on its row for 30 days after release, and the default pick's estimated speed on each row. The Models list shows the same card behind an ⓘ button on a row, and a **Newer: …** badge on a row whose family has a successor you haven't installed; it opens Add Model on that successor.

**Release dates are hand-entered, from the maker's announcement.** A Hugging Face repo's `createdAt` is when it was created, often weeks before it went public (Qwen3.8 27B: created 5 August, public 14 August; Granite 4.2: 7 and 25 August), and a quantized repo's dates are the quantizer's. Where a maker published no post, the date is from news coverage that agrees with the repo's own dates.

**The public ranking is Arena's text leaderboard with style control.** It was chosen on 2026-10-01 from these sources:
- **Artificial Analysis Intelligence Index:** a single 0–100 score covering 20 of the 32 chat models in the catalog, the most of any source. Its Data Platform Terms (v1.1, 2026-08-19) forbid showing the numbers in a product or reproducing them "in a structured, tabular, or machine-readable format", so it isn't used unless Artificial Analysis gives written permission.
- **Arena:** 11 of 32, a single comparable number with a confidence interval, published daily as `lmarena-ai/leaderboard-dataset` under CC BY 4.0.
- **Others:** Epoch's Capabilities Index covers 8 and LiveBench 1. Hugging Face's Open LLM Leaderboard was retired in 2025. Model cards' own eval results are self-reported and not comparable.

**How the rating is shown:**
- `rating ± interval · #rank of N`. The interval is half the 95% confidence interval, so two ratings within each other's ± are a tie (Granite 4.2 8B at 1288 and 3B at 1289).
- With the caveat that Arena rates the full-precision model (Nemotron 3.5's entry is its NVFP4 build), so a quantized download can do a little worse.
- With the credit CC BY 4.0 asks for: the source, © Arena, the date, links to the leaderboard, the dataset and the licence, and that the numbers are rounded.
- A family Arena doesn't list says "Not publicly ranked". It never borrows a base model's score: a fine-tune, a distill or a 1-bit or ternary Bonsai isn't the model it came from. Embedding and smoke-test models say nothing.

**Refreshing:** `scripts/update-arena-ratings` (`task catalog:arena`) reads the leaderboard through the Hub's dataset viewer API, so no parquet reader is needed. It rewrites only the `arena` lines, keeping the file's hand-made layout. A name the leaderboard drops is an error to fix by hand. The app picks up a refreshed `catalog.json` from `main` within a week (ADR-0051), whether or not a release follows.

**Quail's own scores (amended 2026-10-01):** every chat model in the catalog is also tested by Quail, not only those Arena misses, so any two can be compared on one scale beside Arena's.
- **How:** `task bench:scores` runs the ADR-0063 harness's quality and tool-calling steps on Quail's server, with `bench/config/catalog-models.toml` (every chat family at its default download; `QUAIL_BENCH_MODELS` picks the file). It uses the night budget: GSM8K 150, MMLU-Pro 8 per subject (112) and BFCL 40 per category (200).
- **Thinking off,** as in ADR-0063: comparable across models and about a day's run, where letting each model think would take most of a week and put thinking and non-thinking answers on one scale. The user chose this. gpt-oss runs at its lowest reasoning effort, its template's nearest to off.
- **Not scored:** the DeepSeek R1 distills, which always think, so a 512-token answer limit would cut them off. They carry a note saying so instead. So do the smoke test and the embedding model.
- **Shown:** as "Maths · Knowledge · Tools" percentages, labelled as Quail's tests, with the method, the date and their margins: about ±5 points for maths and tools and ±9 for knowledge (95% intervals at these sample sizes; amended 2026-10-02 from ±4, which was one standard error). They are never blended with Arena's ratings.
- `scripts/update-quail-scores RUN` writes them into the catalog.

**Alternatives (amended 2026-10-02):** a scored family's card suggests up to three other catalog families (`ModelAlternatives`). Each has a **Show** button that opens it in Add Model. The Models list's ⓘ card shows them too, once Add Model has worked out the catalog's verdicts.
- **Candidates:** curated, scored, for the same kind of work (a coding model's alternatives have the coding strength), and Comfortable or Tight on this Mac. The family's own successor is left out, since the card shows it as Newer already.
- **Scores higher:** needs about the same memory: at most 1.25 times as much, or 2 GB more, whichever is larger, so a 1.5 GB model can step up. It must be ahead of the family on at least one test by more than that test's margin, and behind on none. The best total wins; on a tie, the one needing less memory.
- **Smaller:** needs at most three-quarters of the memory and is behind on no test by more than its margin. The smallest wins.
- **Faster:** has at least 1.5 times the estimated speed on this Mac and is behind on no test by more than its margin. The fastest wins.
- **Size is memory, not parameters:** this Mac's fit estimate at the default context. Parameters made a 1-bit 27B Bonsai, at 3.8 GB, look as big as a 4-bit 27B at 16 GB.
- Each family appears once. With parameters as size and no size limit on "scores higher", Gemma 4 31B was the "higher" pick for 24 of 28 families, down to a 1.7B, which helps no one.
- **Not used:** Arena's ratings (11 of 32 families). Mixing them in would make the comparison depend on which families Arena happens to list.

**Alternatives:**
- Artificial Analysis's index, pending permission.
- Filling gaps from other sources: their scales differ, and a mixed column reads as one.
- Hugging Face downloads and likes for curated models: they measure popularity, which would be read as quality.

**Revisit if:** Artificial Analysis grants permission; Arena changes its dataset's licence or shape; or Quail's own scores cover the catalog.
