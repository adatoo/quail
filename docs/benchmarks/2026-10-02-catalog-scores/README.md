# Quail's own scores for the catalog, 2 October 2026

These are the numbers behind the "Maths · Knowledge · Tools" line on each model's card in Add Model (ADR D-070). They are Quail's own tests of the download each model offers by default, so any two catalog models can be compared, including the ones Arena's leaderboard doesn't list.

## Method

- **Mac:** M1 Max 16-inch MacBook Pro, 64 GB, on mains power. The run was `task bench:scores BUDGET=night` with `QUAIL_BENCH_MODELS=catalog-models`, in run folder `20261001-174235-scores`.
- **Server:** Quail's own `quail-server`, Release builds. The GGUF lane was used for every model except Bonsai 2 27B, which is MLX only.
- **Each request:** answers without thinking (`enable_thinking: false`), at temperature 0 and seed 42, with 8 requests at once (2 for Gemma 4 31B, whose cache for more didn't fit the GPU).
- **The three tests:**

  | Test | What it is | Size |
  |---|---|---|
  | **Maths** | GSM8K, 8-shot chain of thought, strict match (lm-eval `gsm8k_cot_llama`), up to 512 tokens | first 150 questions |
  | **Knowledge** | MMLU-Pro, 5-shot chain of thought (lm-eval `mmlu_pro`) | first 8 of each of 14 subjects: 112 questions |
  | **Tools** | BFCL v4 function calling: `simple_python`, `multiple`, `parallel`, `parallel_multiple` and `irrelevance` (where no tool fits and the right answer is not to call one), scored by BFCL's own checker | first 40 of each: 200 cases |

- **Margins:** the ± figures below are 95% intervals. At these sample sizes, maths and tools are good to about ±5 points and knowledge to about ±9, so smaller differences are a tie.
- **Not scored:**
  - the DeepSeek R1 distills and Muse Glimmer, which always think before answering, so these tests don't apply;
  - Qwen3 0.6B (a smoke test);
  - Nomic Embed (embeddings).
- **gpt-oss:** its reasoning can't be switched off, so it ran at `reasoning_effort: low`, a sentence or so of reasoning per answer.

## Results

| Model | Maths (GSM8K) | Knowledge (MMLU-Pro) | Tools (BFCL) | simple | multiple | parallel | parallel-multiple | irrelevance | Tools on |
|---|---|---|---|---|---|---|---|---|---|
| Qwen3 4B | 89 ± 5 | 61 ± 9 | 90 | 39/40 | 37/40 | 35/40 | 32/40 | 36/40 | 0.66.0 |
| Qwen3 8B | 91 ± 5 | 62 ± 9 | 88 | 38/40 | 37/40 | 32/40 | 34/40 | 36/40 | 0.66.0 |
| Qwen3.5 9B (vision) | 91 ± 5 | 75 ± 8 | 92 | 37/40 | 38/40 | 36/40 | 36/40 | 37/40 | 0.67.3 |
| Qwen3.6 35B-A3B (MoE) | 97 ± 3 | 83 ± 7 | 92 | 36/40 | 34/40 | 37/40 | 38/40 | 38/40 | 0.67.3 |
| Qwen3-Coder 30B-A3B (MoE) | 92 ± 4 | 62 ± 9 | 90 | 38/40 | 37/40 | 36/40 | 34/40 | 34/40 | 0.67.3 |
| MiMo V2.6 9B (Xiaomi, vision) | 87 ± 5 | 62 ± 9 | 78 | 23/40 | 36/40 | 31/40 | 33/40 | 34/40 | 0.67.3 |
| Qwen3 32B | 95 ± 4 | 70 ± 8 | 88 | 39/40 | 36/40 | 31/40 | 36/40 | 34/40 | 0.66.0 |
| Qwen3.8 27B (vision) | 97 ± 3 | 83 ± 7 | 84 | 39/40 | 39/40 | 32/40 | 37/40 | 22/40 | 0.67.3 |
| Gemma 4 12B (vision) | 94 ± 4 | 81 ± 7 | 88 | 39/40 | 36/40 | 35/40 | 34/40 | 32/40 | 0.66.0 |
| Gemma 4 26B-A4B (MoE, vision) | 95 ± 4 | 90 ± 6 | 90 | 39/40 | 37/40 | 34/40 | 34/40 | 36/40 | 0.66.0 |
| Gemma 4 31B (vision) | 97 ± 3 | 90 ± 6 | 90 | 39/40 | 37/40 | 35/40 | 36/40 | 34/40 | 0.66.0 |
| Llama 3.1 8B Instruct | 85 ± 6 | 46 ± 9 | 35 | 18/40 | 10/40 | 16/40 | 12/40 | 14/40 | 0.67.3 |
| gpt-oss 20B (MoE) | 94 ± 4 | 46 ± 8 | 51 | 37/40 | 34/40 | 0/40 | 0/40 | 31/40 | 0.67.3 |
| Nemotron 3.5 Lightning 30B-A3B | 85 ± 6 | 62 ± 9 | 56 | 32/40 | 30/40 | 4/40 | 11/40 | 36/40 | 0.67.3 |
| Granite 4.2 30B | 95 ± 4 | 62 ± 9 | 80 | 39/40 | 38/40 | 30/40 | 32/40 | 20/40 | 0.67.3 |
| Granite 4.2 8B | 82 ± 6 | 61 ± 9 | 55 | 39/40 | 38/40 | 0/40 | 0/40 | 33/40 | 0.67.3 |
| Granite 4.2 3B | 61 ± 8 | 47 ± 9 | 76 | 37/40 | 33/40 | 22/40 | 24/40 | 37/40 | 0.67.3 |
| Ornith 1.5 35B-A3B (vision) | 93 ± 4 | 77 ± 8 | 90 | 38/40 | 36/40 | 38/40 | 38/40 | 30/40 | 0.67.3 |
| Ornith 1.5 9B (vision) | 89 ± 5 | 69 ± 8 | 85 | 39/40 | 39/40 | 33/40 | 35/40 | 24/40 | 0.67.3 |
| Ternary Bonsai 27B (vision) | 96 ± 3 | 68 ± 9 | 94 | 39/40 | 38/40 | 38/40 | 37/40 | 35/40 | 0.67.3 |
| Ternary Bonsai 8B | 85 ± 6 | 52 ± 9 | 90 | 38/40 | 37/40 | 32/40 | 33/40 | 39/40 | 0.66.0 |
| Ternary Bonsai 4B | 89 ± 5 | 45 ± 9 | 16 | 0/40 | 1/40 | 0/40 | 0/40 | 31/40 | 0.66.0 |
| Ternary Bonsai 1.7B | 55 ± 8 | 24 ± 8 | 86 | 38/40 | 35/40 | 31/40 | 32/40 | 36/40 | 0.66.0 |
| Bonsai 2 27B | 97 ± 3 | 73 ± 8 | 90 | 39/40 | 38/40 | 37/40 | 36/40 | 30/40 | 0.67.3 |
| Bonsai 27B, 1-bit (vision) | 95 ± 4 | 61 ± 9 | 87 | 39/40 | 37/40 | 33/40 | 35/40 | 30/40 | 0.67.3 |
| Bonsai 8B, 1-bit | 82 ± 6 | 38 ± 9 | 88 | 38/40 | 36/40 | 30/40 | 33/40 | 39/40 | 0.66.0 |
| Bonsai 4B, 1-bit | 79 ± 7 | 31 ± 8 | 16 | 0/40 | 0/40 | 0/40 | 0/40 | 31/40 | 0.66.0 |
| Bonsai 1.7B, 1-bit | 44 ± 8 | 22 ± 8 | 85 | 38/40 | 35/40 | 33/40 | 28/40 | 36/40 | 0.66.0 |

The maths and knowledge tests ran on Quail 0.66.0 for every model. Tool calling for the 16 models whose call formats #167 changed was re-run on 0.67.3; the rest are from 0.66.0, whose parser is the same for their formats.

## What the run found in Quail

On 0.66.0 four models' tool calls came back wrong. In each case, the raw reply was compared with what the llama-server bundled with Quail made of the same output.

- **gpt-oss 20B** scored 0 on every call category. The engine ends generation at `<|call|>` and doesn't pass the token on, so the Harmony parser returned each call's arguments as text. It's fixed in #167 (0.67.3), and gpt-oss now matches llama-server case for case: 37, 34, 0, 0 and 31 of 40.
- **Llama 3.1 8B** also scored 0 on every call category. It writes `<|python_tag|>{…}; {…}`, which Quail's parser didn't accept. After #167 it scores 18, 10, 16, 12 and 14 of 40, against llama-server's 24, 14, 0, 0 and 15. llama-server rejects its two-call replies with a 500. Most remaining failures on both servers are numbers written as strings (`"base": "10"`). Quail doesn't yet convert those to the tool's types for Llama-style calls; that's a planned fix.
- **MiMo V2.6 9B** writes JSON inside `<function=…>`, which parsed as an empty call. After #167 it scores 23, 36, 31, 33 and 34 of 40, against llama-server's 25, 36, 30, 33 and 34.
- **Granite 4.2, Nemotron 3.5 and the 4B Bonsais** score the same through llama-server, give or take a case. Their low parallel and multi-call scores are the models' own. For example, asked for two calls, Granite 4.2 8B makes one on both servers.

gpt-oss's knowledge score is the model's own too: llama-server gives 94 on maths and 49 on knowledge, against Quail's 94 and 46.

## Caveats

- These are small samples: rankings within a few points mean nothing.
- They answer without thinking. Models that think by default (Qwen3.5 and later, Granite 4.2, Ornith) may do better with thinking on, and the tests don't show that.
- They test the 4-bit (or 1-bit, or ternary) download, not the full-precision model that public leaderboards rate.
