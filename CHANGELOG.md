# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Every PR adds its entries under [Unreleased] and cuts them into its own
version's section with `task version:bump` (ADR D-024); every merge to
`main` is released as that version.

## [Unreleased]

### Fixed

- **Quail's server starts again on macOS 14, 15 and 26.0–26.3.** Since 0.61.8, it was built against mlx-swift 0.32.2, which uses a system call that only exists from macOS 26.4. On earlier macOS the server stopped at launch, before serving anything. It now builds against mlx-swift 0.32.3, through mlx-swift-lm 3.32.3, its first release to take it. That puts the pin back on a release (#149, ADR D-044 amendment). Speeds are unchanged.

## [0.72.3] - 2026-10-03

### Changed

- The website's picture of the Quail window is now a screenshot of the real app, serving a model, in light and dark mode. It used to be rendered offscreen.

## [0.72.2] - 2026-10-03

### Added

- The benchmark harness can run llama-server with a full-size sliding-window cache, as Quail's server keeps it (`ENGINES=llama-server-swa-full`). This tells that setting apart from Quail's own differences on Gemma 4 (#152). It's never part of a default run.

## [0.72.1] - 2026-10-02

### Fixed

- **Llama 3.1 8B's Tools score is 70, not 35.** It was re-tested after Quail began converting its tool-call values to the tool's types (0.68.1). Its Maths and Knowledge scores came out the same. Catalog revision 11.

## [0.72.0] - 2026-10-02

### Added

- **`quail eval tools`** checks that tool calling works for a model, end to end (ADR D-065). It sends 16 requests, each checked against the call it should make:
  - one call, choosing a tool, two calls and two tools;
  - no tool that fits, and answering from a tool's result.

  Works on Quail's server, or any other with `--url`.

## [0.71.0] - 2026-10-02

### Added

- **`quail bench --url`** times any server that speaks OpenAI's chat completions (Ollama, LM Studio, llama-server, oMLX, or Quail on another Mac) from the terminal, without the app (ADR D-064):
  - the same tests as Quail's benchmark, except loading the model;
  - prompts sized from the server's own token counts;
  - timed from the client, as a suite of its own, `quail-bench-url-1`;
  - `--api-key` for a server that needs one, and `--json` for the full result.

  Quail's benchmark reads the same passage as before, so earlier results stay comparable.

## [0.70.1] - 2026-10-02

### Fixed

- **A development build with its own data folder (`QUAIL_DATA_ROOT`) keeps its own Keychain items.** It used the real app's, so its first launch could replace the real API key, and reading a secret raised a Keychain prompt. Shipped builds are unchanged.

## [0.70.0] - 2026-10-02

### Added

- **Alternatives on a model's card.** In Add Model, a scored model's card now suggests up to three other catalog models that fit this Mac (ADR D-070 amendment):
  - one about the same size that scores higher in Quail's tests;
  - one that needs much less memory and is about as good;
  - one that's much faster here and is about as good.

  Each has a **Show** button. The ⓘ card in the Models list shows them too.

## [0.69.0] - 2026-10-02

### Changed

- **Fit verdicts and Automatic context are sharper for models that mix layer types.** Quail now counts the memory for past tokens layer by layer (ADR D-071). It used to treat every layer as a full one. Measured on real models, this made Gemma 4's estimate 2.2 times too high on GGUF and up to 24 times on MLX. The Qwen3.5 family (Qwen3.5, 3.6 and 3.8, MiMo, Ornith and the 27B Bonsais) was 4 times too high. So these models now get longer contexts and Comfortable verdicts where they fit. Nemotron 3.5's GGUF estimate also counts its attention layers again; before, they counted as nothing.

## [0.68.1] - 2026-10-02

### Fixed

- **Llama 3.1's tool calls now carry numbers as numbers.** It often writes a number as a string (`"base": "10"`), which a client checking the tool's schema rejects. Quail now reads such a value as the type the tool's schema asks for, as it already did for Qwen's calls (ADR D-040 amendment).

## [0.68.0] - 2026-10-02

### Added

- **Quail's own scores on 28 catalog models.** Each model card in Add Model now shows Maths, Knowledge and Tools percentages from Quail's tests of the download it offers, answering without thinking, on an M1 Max (ADR D-070). Gemma 4 31B and 26B-A4B lead on knowledge (90). Qwen3.6 35B-A3B, Qwen3.5 9B and Ternary Bonsai 27B lead on tools (92–94). Each figure is good to about ±5 points (maths, tools) or ±9 (knowledge). Full results and method are in `docs/benchmarks/2026-10-02-catalog-scores/`.

## [0.67.3] - 2026-10-02

### Fixed

- **Tool calls from gpt-oss, Llama 3.1 and MiMo V2.6 now come back as tool calls** on the GGUF server, rather than as text (ADR D-040 amendment). Quail's own benchmark found them:
  - **gpt-oss:** every call came back as plain text, because the token ending a call never reached Quail's parser.
  - **Llama 3.1:** a call begins with `<|python_tag|>`, and several are joined by `;`.
  - **MiMo V2.6:** its arguments are JSON inside the function tag.
  - Models that put several calls in one `<tool_call>` block now get them all.

## [0.67.2] - 2026-10-01

### Changed

- Muse Glimmer isn't in Quail's own tests: it thinks before every answer and can't be told not to, and the tests score answers given without thinking. Its model card says so. gpt-oss is tested at its lowest reasoning effort, and its card notes that beside its scores.
- `task bench:scores` runs Gemma 4 31B two requests at a time rather than eight, as four or eight ran a 64 GB Mac's GPU out of memory. A model's `slots` in the models file sets this.

## [0.67.1] - 2026-10-01

### Fixed

- **Model downloads are much faster.** Quail read each download a byte at a time, which capped it at a few MB/s on some Macs, well below the connection (about 5 MB/s on an M1 Max where curl got 20). It now takes the data in the chunks the network delivers. Resuming, checksums and cancelling work as before.

## [0.67.0] - 2026-10-01

### Added

- **Quail's own scores for catalog models** (ADR D-070 amendment): Maths (GSM8K), Knowledge (MMLU-Pro) and Tools (BFCL), answering without thinking, on each model's default download. The model card shows them once a model has been tested. The website explains the method.
- `task bench:scores` runs those tests for every chat model in the catalog, model by model, resumably. `scripts/update-quail-scores` writes the results into the catalog.

## [0.66.0] - 2026-10-01

### Added

- **More to help you choose a model** (ADR D-070). In Add Model, each curated model now has:
  - a line on what it's for;
  - the day it was released, and a **New** badge for its first 30 days;
  - links to its maker's model card and to the files Quail downloads;
  - its **Arena rating** where Arena's text leaderboard lists it: 11 models so far, credited, dated, and with the caveat that Arena rates the full-precision model. Others say they aren't publicly ranked.
  - Each row also shows the estimated speed on this Mac.
- **In the Models list,** an ⓘ button on a row shows the same, and a **Newer** badge marks a model with a newer version from the same line (Qwen3 8B → Qwen3.5 9B, Qwen3 32B → Qwen3.8 27B), which it opens in Add Model.
- `task catalog:arena` refreshes the ratings from Arena's CC BY 4.0 dataset.

## [0.65.3] - 2026-10-01

### Fixed

- **Deleting a model while another downloads works.** It used to do nothing in the Models pane, without saying why. Deleting the model that's downloading again now says to cancel the download first.

## [0.65.2] - 2026-10-01

### Changed

- Quail won't send its Nemotron-H fixes to mlx-swift-lm, so the upstream watch (#158) no longer waits for that pull request. Quail keeps its own fixed copy of the model code until mlx-swift-lm fixes the same problems.

## [0.65.1] - 2026-10-01

### Fixed

- **Bonsai 2 27B now downloads.** An MLX download no longer fetches the files in a repo's subfolders. Bonsai 2 has a second `LICENSE` in one, which failed the download with a checksum error. Other models stop downloading images and unused side weights.

## [0.65.0] - 2026-10-01

### Added

- **Muse Glimmer: constrained output and forced tool calls,** on its GGUF download.
  - A `json_schema` or `json_object` reply comes as its answer message, after any reasoning.
  - `tool_choice` set to required or to a named tool makes it write an ATEM call. Each parameter is held to its own type, and strings are written as they are.
  - With `parallel_tool_calls` it can make several calls.
  - On MLX, constrained output and forced calls aren't available yet, for this or any other model.
- A weekly check on the upstream pull requests Quail is waiting for: the 1-bit and Bonsai 2 runtimes, and the changes that would let Quail drop its own copies of model code. When one merges or closes, it comments on #158.

## [0.64.0] - 2026-10-01

### Added

- **PrismML's Bonsai models,** Qwen3 and Qwen3.6 models trained to very low-bit weights (ADR D-069):
  - **1-bit Bonsai** 1.7B, 4B, 8B and 27B, GGUF only (MLX has no 1-bit support yet). The 8B is 1.2 GB and writes about 125 tokens a second on an M4 Pro.
  - **Ternary Bonsai** 1.7B, 4B, 8B and 27B, in GGUF and MLX.
  - **Bonsai 2 27B,** a ternary Qwen3.6 27B in 8.6 GB, on MLX. It writes about 23 tokens a second, against 15 for Qwen3.8 27B at 4 bits. Its weights are stored rotated, which mlx-swift-lm doesn't handle yet, so Quail carries its own copy of the pending mlx-swift-lm change. It handles text only, and several requests at once are decoded together.
  - The 27B models think. The 1-bit and Ternary 27B models also read images. The smaller models don't think, and the 4B models can't reliably call tools.
  - The Ternary Bonsai MLX downloads that Add Model already listed now appear once, as catalog rows.
- **Granite 4.2** 3B, 8B and 30B, IBM's Apache-licensed models, in GGUF and MLX from IBM's own repositories. They think by default.
- **Ornith 1.5** 9B and 35B-A3B, coding fine-tunes of Qwen3.5, in GGUF (which reads images) and MLX.
- **Nemotron 3.5 Lightning 30B-A3B,** NVIDIA's mixture of experts with 3B active, in GGUF and MLX. On MLX it writes about 76 tokens a second on an M4 Pro, against 65 for the GGUF.
- **Muse Glimmer 30B**, Meta's Apache-licensed model that reads images, in GGUF and MLX.
  - Its replies are messages to a recipient: its reasoning (`to=self`), the answer, or a tool. Tool calls are ATEM blocks, which Quail's server now reads on both engines.
  - A request's `reasoning_effort` sets its reasoning strength (low, medium, high or xhigh). `chat_template_kwargs` can set `reasoning_strength` directly.
- A request's `reasoning_effort` also reaches gpt-oss's template, as `reasoning_effort`.

### Changed

- **llama.cpp b11306** (from b11081), bundled for the llama.cpp runtime and used by quail-server's GGUF engine. It has llama.cpp's fixes for Muse Glimmer's tool calls and `json_schema` output on llama-server (#29242, #29615).

### Fixed

- Running the unit tests no longer puts a second Quail in the menu bar. Quitting it during a run crashed the run, since the tests had a model loaded.
- **MLX: Nemotron-H models ran in float32 after their first Mamba layer.** mlx-swift-lm's gated norm used a float32 weight, which made every later layer float32. That was slower, and greedy replies differed from mlx-lm's. Quail's own copy of the model fixes it (D-066 amendment), taking Nemotron 3.5 from 56 to 76 tokens a second.
  - Nemotron 3.5's MLX download, which Add Model already listed, also didn't load before: the pinned mlx-swift-lm couldn't read how its config names its layers.
- Adding a GGUF model no longer downloads the multi-token-prediction (`mtp-`) or draft (`dflash-`) files some repositories keep beside each quant, such as bartowski's Nemotron 3.5.

## [0.63.3] - 2026-10-01

### Changed

- **The 2026-09-30 comparison, corrected** (#152). Quail (MLX)'s accuracy and tool calling were run again with 0.63.1, which fixes the MLX prompt-cache bug the comparison found. Gemma 4's GSM8K on MLX is now 91.3%, where it was 84.7%, level with oMLX's 89.3% and Rapid-MLX's 90.0%. Qwen3.6's MMLU-Pro on MLX went from 79.5% to 84.8%. The report's summary now gives the cause, not the chat-template guess; so do quail-ai.app's comparison and How it works pages.

## [0.63.2] - 2026-09-30

### Fixed

- **Loading a model while another was busy looked stuck** (D-068). With one model loaded at a time, a model loaded while the chat page was still writing a reply stayed at "Loading…" until the reply ended, with nothing saying why. Unloading the busy model waited too.
  - **Load and Unload now stop the busy model's requests,** in Quail and in its chat page. Each stopped reply ends with a message saying why: "Stopped: *A* was unloaded to load *B*."
  - **A load that a request needs still waits,** so one client's request never cuts off another's reply. While it waits, the Models page, the Activity window, the menu and the chat page say which model it's waiting on. `GET /models` and `GET /slots` give it as `waiting_for`.
  - **The chat page follows a model loaded elsewhere.** It refreshes its list when you come back to it. Before sending to a model that isn't loaded, if loading it would unload another, it offers the loaded one: "Use *B*" or "Load *A*". Before, its next message quietly reloaded its own model and pushed the new one out.

## [0.63.1] - 2026-09-30

### Fixed

- **MLX: a prompt that went back to an earlier point in a cached prompt could read another request's text** (#152). Models with sliding-window layers (Gemma 3 and 4) or recurrent layers (Qwen3.5 and 3.6) keep checkpoints on the way through a prompt, since those layers can't be cut back. Going back to one put the checkpoint itself in service, so the tokens that followed were written into it. The next prompt that went back to the same point then read the previous request's text in those layers.
  - In the 2026-09-30 comparison, this made 8 of Gemma 4's 150 GSM8K replies make up a new question instead of answering. That was almost all of the gap on the MLX lane.
  - It also hit agents whose sub-tasks share a long system prompt with the main conversation.
  - The checkpoint is now copied when it's used, so it stays as it was taken.
- **The benchmark's smoke test now checks that a reply doesn't depend on the request before it** (`cache_replay`). It asks one prompt twice, each time after a different request sharing a long opening, and expects the same reply. Quail before this fix fails it on Gemma 4 and Qwen3.6 (MLX). A failure is listed among the report's caveats.

## [0.63.0] - 2026-09-30

### Added

- **The website has a comparison page,** [quail-ai.app/compare.html](https://quail-ai.app/compare.html). It compares Quail, Ollama, oMLX and Rapid-MLX feature by feature: installing, model formats, APIs, the key, browser access, several requests at once, prompt caching, speculative decoding, embeddings, coding tools, usage data, platforms and licence.
  - Every claim links to its project's own docs, source or release notes at the version named.
  - The measured results of the 2026-09-30 comparison sit beside it, with a link to the full report.
  - The table and results are written from `bench/config/features.toml` and the report by `task bench:site`.
- **A "How it works" page,** [quail-ai.app/how-it-works.html](https://quail-ai.app/how-it-works.html), briefly covers:
  - what Quail is for and how it's built;
  - how its speed is measured against the other engines and improved;
  - what the first comparison changed.

  A short page for each change gives the detail: several requests at once on MLX, Qwen3.5 and 3.6 on MLX, MLX memory, long prompts on GGUF, and how the comparison works.
- The site's header links to the comparison page and the "How it works" page.

## [0.62.1] - 2026-09-30

### Added

- **The second comparison with llama-server, Ollama, oMLX and Rapid-MLX:** `docs/benchmarks/2026-09-30/`, after this week's fixes, on the same M1 Max. With 8 requests at once on MLX, Gemma 4's first token now takes 1.6 s instead of 41 s. Qwen3.6 writes a token every 13.1 ms instead of 15.8 ms. On GGUF, long prompts are level with llama-server.
  - Rapid-MLX still makes 10–20% more tokens a second with several MLX requests at once (#139, #141).
  - Gemma 4 scores a few points lower on Quail than on the other engines (#152). The report says both.

## [0.62.0] - 2026-09-30

### Added

- **The Activity window shows who is using the server.** Each request says which app sent it and from where, such as "Claude Code · this Mac" or "python-httpx · 192.168.1.20". The app comes from the request's `User-Agent`, and the Connect list names the tools it knows.
- **A Clients section shows each client's load.** For each app and machine, it shows what's running now, and its requests, tokens read and tokens written in the last 1, 5 or 15 minutes. A bar shows how much of that time it kept the server busy: green under 25%, orange up to 75%, red above.
  - The server keeps these figures in memory only, behind the API key. They're never logged, and they go when it stops (ADR D-067).

## [0.61.8] - 2026-09-30

### Changed

- **Several requests at once on an MLX model make up to a fifth more tokens a second.** (#139) Quail now uses MLX 0.32.2. On the Mac mini (M4 Pro), each step of eight requests decoding together takes 61–63 ms instead of about 80 ms on Qwen3 8B.
  - Eight streams of requests made 78.6 tokens/s instead of 65.1 on Qwen3 8B, 97.9 instead of 88.5 on Gemma 4 26B-A4B, and 128.1 instead of 118.6 on Qwen3.6 35B-A3B. A request on its own runs at the same speed.
  - MLX 0.32 comes with mlx-swift 0.32.2. No mlx-swift-lm release takes it yet, so Quail pins a commit on mlx-swift-lm's main branch until one does (ADR D-044 amendment). #149 tracks moving to that release, and a weekly check (`mlx-release-watch`) flags it as soon as there is one.
  - Replies at temperature 0 can differ slightly from before on some prompts, because MLX 0.32 rounds some sums differently.
- **Gemma 4 (MLX) sees images in their own shape.** Each image is sized to fit the model's budget without being squashed, so a small or wide image takes fewer tokens than before.

## [0.61.7] - 2026-09-30

### Changed

- **Qwen3.5 and Qwen3.6 (MLX) generate about 4% faster with one request.** (#141) On the Mac mini (M4 Pro), Qwen3.6 35B-A3B now takes 10.8 ms per token instead of 11.2 ms.
  - Each of the model's GatedDeltaNet layers now runs as one GPU kernel for the next token, instead of a dozen. The kernel is adapted from Rapid-MLX (Apache-2.0).
  - Replies are unchanged. On each Mac, Quail first checks that the kernel gives exactly the same numbers as before, and keeps the old way if it doesn't. `QUAIL_MLX_FUSED_GDN=0` turns it off.

## [0.61.6] - 2026-09-29

### Changed

- **Qwen3.5 and Qwen3.6 (MLX) generate about 8% faster.** (#141) On the M1 Max, Qwen3.6 35B-A3B now takes 14.2–14.5 ms per token instead of 15.5–15.9 ms, level with mlx-lm itself.
  - Quail now has its own copy of these models' code, adapted from mlx-swift-lm (ADR D-066). The small element-wise functions that mlx-lm compiles into single GPU kernels are compiled here too.
  - Replies are unchanged.

## [0.61.5] - 2026-09-29

### Changed

- **A long prompt on an MLX model reaches its first token sooner when nothing else is running.** (#139) It's now read 2,048 tokens at a time, as mlx-lm reads it, instead of 512, up to 8,192 tokens. On the M1 Max, a 4,096-token prompt took 7.0 s instead of 8.3 s on Qwen3.6 35B-A3B, and 8.4–8.6 s instead of 9.1–9.9 s on Gemma 4 26B-A4B.
- `QUAIL_MLX_TRACE=<file>` writes where the MLX serving loop spends its time, for tuning.

## [0.61.4] - 2026-09-29

### Changed

- **Gemma 4 26B-A4B (MLX) now serves several requests at once.** (#140) Before, they waited in line: on a Mac mini, eight at once took 38.9 s to the first token and 45.5 tokens/s in total. Now it's 2.2 s and 88.7 tokens/s.
  - Quail now has its own copy of Gemma 4's language model, adapted from mlx-swift-lm (ADR D-066). mlx-swift-lm's text-only Gemma 4 lacks this model's mixture-of-experts layers, so it could only load through the vision model, which can't batch.
  - A text turn gives exactly the same reply as before, a little faster. An image turn still loads the vision model.
- A new batched cache for sliding-window layers lets Gemma 4's decoding run in a batch.

## [0.61.3] - 2026-09-29

### Changed

- **Long prompts on GGUF models are no longer slowed by other, idle conversations.** (#138)
  - When a request starts, each other idle slot's conversation now moves out of the shared KV cache into memory, as llama-server does. A later prompt that continues one of them copies it back.
  - On a Mac mini, a 4,096-token prompt after eight requests at once took 10.2–10.9 s on Qwen3 8B instead of 11.5–12.0 s, level with llama-server. Gemma 4 26B-A4B took 5.8–6.2 s instead of 6.8–6.9 s.
  - Parked conversations use up to 8 GB of memory, or an eighth of a smaller Mac's.
  - `QUAIL_LLAMA_PARK=0` turns this off.
- **Sliding-window GGUF models (Gemma 4) no longer save checkpoints of long prompts.** Their cache can be cut back without them, so the copies of up to 800 MB each were wasted work.
- Hybrid models (Qwen3.5, 3.6) no longer save two checkpoints within 64 tokens of each other.

## [0.61.2] - 2026-09-29

### Fixed

- **MLX models no longer make Quail's memory grow with every conversation.** (#137) MLX keeps the GPU buffers it frees for reuse, and by default it could keep almost all of memory. Serving several requests at once frees large buffers of ever-changing sizes, so Qwen3 8B reached 30 GB and stayed there.
  - The cache is now capped at 2 GB, or less on a smaller Mac.
  - It's cleared as requests run, and when nothing is running.
  - On a 64 GB Mac mini, Qwen3 8B serving eight requests at once peaked at 11 GB instead of 21 GB.
  - `QUAIL_MLX_CLEAR_CACHE=0` turns this off.
- The memory shown for a loaded MLX model now includes that cache, since macOS counts it against Quail.

## [0.61.1] - 2026-09-29

### Documentation

- **The first comparison with llama-server, Ollama, oMLX and Rapid-MLX:** [docs/benchmarks/2026-09-29/](docs/benchmarks/2026-09-29/README.md).
  - It ran on an M1 Max with Quail 0.58.1, on the same weights in every engine.
  - **GGUF:** Quail is level with llama-server and Ollama, except on 4,096-token prompts.
  - **MLX:** Quail is behind oMLX and Rapid-MLX on Gemma 4 concurrency, on Qwen3.6 speed, on throughput with several requests at once, and on memory.
  - **Quality and tool calling:** no significant difference.
  - The fixes are tracked in #137–#141.
- The benchmark report opens with a hand-written summary. It shows where Quail is slower as a table per model and lane, and says how to reproduce it.

## [0.61.0] - 2026-09-29

### Added

- **The Models page shows loaded models at the top, in their own Loaded section, while the server runs.** (#134) Each row has the model's format, context and memory, and what it's doing: loading, idle, or its requests and speed. Each has an **Unload** button (which waits for requests in progress to finish) and the default star. The Installed list below still shows every model.

## [0.60.0] - 2026-09-29

### Added

- **The Activity window shows the Mac's CPU, GPU and memory while the server is stopped.** It samples them for as long as the window is open. The server's own figures appear once it's running. (#133)
- **Memory is a chart,** like CPU and GPU, instead of a single bar:
  - It's drawn against the Mac's total memory, and turns orange, then red, as memory runs short.
  - While the server runs, its share is shown inside.
- **The charts cover the last 1, 5 or 15 minutes,** chosen in the window. They're drawn by time, and a pause in sampling shows as a break in the line.

## [0.59.1] - 2026-09-29

### Fixed

- The benchmark report's memory column is the memory footprint again, as Activity Monitor shows it. The resident figure that replaced it in 0.59.0 counted a mapped model file twice, giving 29 GB for llama-server with an 8B model. The report now says that memory-mapped model files aren't in the footprint.

## [0.59.0] - 2026-09-29

### Added

- **The comparison harness now covers quality and tool calling** (ADR D-063):
  - `task bench:quality` runs GSM8K and MMLU-Pro with EleutherAI's lm-evaluation-harness.
  - `task bench:tools` runs five function-calling categories from the Berkeley Function-Calling Leaderboard.
  - Both go through a small request shim, which holds every engine to the same settings: neutral sampling, thinking off, the same model id. It sends a request again when the engine asks it to wait and retry, as a real client would.
  - Every engine answers the same items, and each item's result is kept, so two engines can be compared item by item.
- `task bench:compare` runs speed, the native baselines, quality and tool calling in one run folder, for a night. `RESUME=<run>` carries on a run that stopped.
- `task bench:report` turns a run into `docs/benchmarks/<date>/`:
  - tables and light and dark charts, and the versions tested
  - caveats from the smoke test, and every request an engine refused
  - a generated section on where Quail is slower or worse, counting only differences the method allows

### Changed

- Speed runs record memory as resident memory, which includes the model file pages an engine maps. Before, llama.cpp's mapped weights weren't counted, which flattered it by up to 20 GB.
- Each engine's scratch caches are deleted when it stops. A trial run had left 45 GB behind.

## [0.58.1] - 2026-09-29

### Fixed

- Qwen3.6's tool calls with a true/false argument work. When Qwen writes Python's `True` or `False` for such an argument, Quail used to pass it on as the text "True"; it now reads it as a real true or false, as llama-server does. Found by the Berkeley Function-Calling Leaderboard run in the comparison harness.

## [0.58.0] - 2026-09-28

### Added

- **The comparison harness can time the engines** (ADR D-063):
  - `task bench:speed` runs GuideLLM against each engine with the same prompts. It covers 512 → 256 tokens at 1, 2, 4 and 8 requests at once, and 4096 → 128 tokens.
  - Each level records time to first token, time between tokens, throughput, peak memory (GPU buffers included) and power.
  - Every engine gets exactly the same number of requests. The prompts are exact lengths in the model's own tokenizer, and none repeats, so no engine gets a cache hit another doesn't. The Mac cools down before each level, and a level that ends hot is run again.
  - `task bench:native` gives each lane's own ceiling on the same weights: `llama-bench` and `llama-batched-bench` from the llama.cpp release Quail bundles, and `mlx_lm.benchmark`.
  - A timed run won't start on a Mac that isn't quiet. `ALLOW_OTHERS=1` runs it anyway as a dry run, and marks it as one.
- Rapid-MLX is loaded text-only, so Gemma 4 starts without mlx-vlm.

## [0.57.1] - 2026-09-28

### Fixed

- **Gemma 4's tool calls work.** Quail returned Gemma 4's calls as text, on both engines and on both the OpenAI and Anthropic routes, so agents couldn't use it. Now:
  - Its calls come back as `tool_calls` / `tool_use`, with the same arguments llama-server gives.
  - Its thinking (`<|channel>thought…`) comes back as reasoning, not as part of the answer. This includes the empty thought block it writes after every tool result.
  - The tools it's offered reach it in the form it was trained on. The template renderer used to put a stray space after each `{` in Gemma 4's tool declarations.

## [0.57.0] - 2026-09-28

### Added

- **A comparison harness in `bench/`**, for measuring Quail against llama-server, Ollama, oMLX and Rapid-MLX on the same Mac and the same weights with standard benchmarks (ADR D-063). This first part:
  - `task bench:setup` fetches Ollama's official build and oMLX's release into scratch folders.
  - `task bench:doctor` says what's installed, what's missing, and how quiet the Mac is.
  - `task bench:smoke` starts every engine with every model and records what each really does: whether a request's length can be held, whether thinking is off, whether tool calls parse on the OpenAI and Anthropic routes, and whether a repeated prompt hits a cache.
  - Nothing in `bench/` ships in the app, and it never touches your own Quail, Ollama or oMLX setup.

## [0.56.1] - 2026-09-28

### Changed

- The plan records that `quail-ai.app` and `quail-ai.com` are verified on the project's GitHub account, and the fresh-Mac checklist says Test… where it said Ping.

## [0.56.0] - 2026-09-28

### Added

- **Quail links to its website, [quail-ai.app](https://quail-ai.app):**
  - Quail Help in the menu opens the docs.
  - "Learn more" beside the Server, General, Benchmark and model settings captions goes to the matching docs page.
  - About has Website and Documentation links.
  - The Homebrew cask's homepage is the website too.

## [0.55.2] - 2026-09-28

### Added

- **A website:** a landing page, and docs covering getting started, models, connecting tools, the network and API key, power, benchmarks, the `quail` command, troubleshooting and privacy. It lives in `website/` and is published with GitHub Pages; `task site:serve` shows it locally.

## [0.55.1] - 2026-09-28

### Changed

- The README describes Quail as it is now, calls it a beta heading for 1.0, and points at the notices file for licences.

## [0.55.0] - 2026-09-28

### Added

- **Quail Help** in the menu opens the documentation.
- **About** has links to the release notes, to report an issue, and to the source code. It also shows the MLX engine's versions, and Copy Details includes them.
- **"Learn more" links** go from the Server, General, Benchmark and model settings pages to the documentation. They appear once the website is published.

### Changed

- **Shorter explanations:** the power, updates and benchmark captions are one line each now, with the details in the documentation.

## [0.54.0] - 2026-09-28

### Changed

- **Each model's settings are in plain sight.** A sliders button on every row of the Models page, or a click on its "8K context" text, opens its settings:
  - the model id to copy
  - context size and KV cache, each option saying whether it fits on this Mac
  - whether it loads when the server starts
  - Benchmark… and Delete…

  They used to hide in a small "ctx" menu and a star. Right-click a row for Model Settings… and Delete… too.
- The Models page starts with what this Mac can run, "This Mac: Apple M4 Pro · 64 GB · comfortable up to ~55B", and Details goes to the About page. The Storage section is now "Storage and downloads".
- Add model… in the menu, and Add Model… on the Server, Connect and Benchmark pages, open the Add Model sheet directly.

## [0.53.0] - 2026-09-28

### Added

- **The Server page says what the server is doing and lets you act on it.** It shows running, stopped or failed, and what's loaded. It has Start, Stop and Test…, and when the server failed, the reason and Show Logs. When a change needs a restart, a line says so with a Restart button; the menu shows the same line.

### Changed

- **The address you copy works.** The Server page shows "On this Mac" and, when other devices can connect, "From other devices", with this Mac's network address. It no longer shows `http://0.0.0.0:8080`.
- **Choose who can reach the server instead of typing an IP address:** This Mac only, Local network, or Custom (any address, saved when you press Return). An address set before now shows as Custom, unchanged. Starting from the page asks once before the server listens on the network, as the menu does.
- **The API key is hidden until you click Show.** A new key needs a confirmation, since tools set up with the old one stop working.
- Changing the address, port, key or number of models loaded at once while the server runs now says to restart. The menu said so only for changed models.

## [0.52.0] - 2026-09-28

### Changed

- **Settings is now the Quail window**, with a sidebar instead of six tabs. Its pages are Server, Models, Connect and Benchmark, then General and About.
  - **Server** holds everything about the server that used to be split between General and Endpoint: runtime, host, port, API key, how many models stay loaded, starting with Quail, and keeping the Mac awake.
  - **General** is Quail itself: open at login, the menu bar, the `quail` command and updates.
  - **About** has the versions and licences, and the This Mac facts that had a tab of their own. One Copy Details copies both, for a bug report.
  - The window can be resized, and each page scrolls within it.
  - The menu's **Open Quail** (⌘,) opens it where you left it. Add model…, Benchmark… and Connect a Tool… open it at their page.
- Messages that pointed at "Settings → Endpoint" or "Settings → Models" now say "Quail → Server" or "Quail → Models". The `quail` command suggests `quail pull` and `quail ctx` first.

## [0.51.0] - 2026-09-28

### Added

- **Qwen3.5 9B** in the catalog: Apache-licensed, the current small Qwen (MiMo V2.6 9B is tuned from it), with a thinking mode, tool calling, a 262K context and image reading on both GGUF and MLX. It sits above Qwen3 8B, the generation before it. Checked before listing: in GGUF Q4_K_M it chats, thinks, calls a tool and uses the result, and names the colours in a test image on both runtimes; the MLX download does the same on Quail server and reads text in images. On llama.cpp the GGUF reads small text in images poorly at the default image size, a known llama.cpp problem. Its MLX download is the Qwen3.5 9B 4-bit that Add Model already listed, so it still appears once.

## [0.50.1] - 2026-09-28

### Fixed

- Settings → Models no longer shows "No models installed yet" for a moment while it reads your models. It shows placeholder rows until it knows. The rows appear as soon as the store's index is read, with "Checking…" where each fit verdict is still being worked out. Reopening the tab starts from the last list.

## [0.50.0] - 2026-09-27

### Added

- **See what the server is doing.** While it works, a few words appear beside the menu bar bird: "Loading…" while a model loads, "Reading 41%" while a prompt is read, "52 tok/s" while writing. They disappear when it's idle, and Settings → General can turn them off. The menu shows the same line, and its new **Activity…** item opens a small window that can stay on top. It shows GPU and CPU with a minute of history, memory in use (and the server's share), each loaded model with its memory, and each request: waiting, queued, reading its prompt (with a progress bar and tokens a second), or writing (tokens a second and count). With llama.cpp as the runtime, the window shows the Mac's figures and model loading only.

## [0.49.0] - 2026-09-27

### Added

- Quail server answers `GET /slots` with what it's doing right now: each model loading (and for how long) or loaded (with its memory on MLX), and each request in progress. For a request it gives the phase (waiting for its model, queued, reading its prompt, generating), how much of the prompt has been read, and tokens a second. The app's live activity display is built on it.

## [0.48.1] - 2026-09-27

### Removed

- The leftover Mac App Store build: its scheme and configurations, sandbox entitlements, compile guards and CI build. The App Store plans were cancelled earlier (D-053). The app itself is unchanged.

## [0.48.0] - 2026-09-27

### Added

- **Bring in models other apps already downloaded.** Quail looks in llama.cpp's download cache, LM Studio's models folder, the Hugging Face cache and oMLX's models folder. If it finds models it doesn't have, the Models list offers once to move them in. Review… lists each one (format, size and where it is) with a checkbox. Models are moved, not copied, so nothing takes up space twice, and a move that fails part-way leaves the model where it was. Unfinished downloads aren't offered. Settings → Models → Storage → ⋯ → Import Models from Other Apps… opens the list again at any time.

## [0.47.0] - 2026-09-27

### Added

- **A warning before the server listens on your network.** When Settings → Endpoint's Host is anything but this Mac (0.0.0.0, a LAN address), a note under it says other devices can reach the server. With the API key off, the note is red and has a Require API Key button, since anyone on the network could then use your models. The first time you start the server that way from the menu, Quail asks once. You can start anyway or switch to listening on this Mac only.

## [0.46.1] - 2026-09-27

### Changed

- Docs: the release loose ends are closed. CI now signs, notarizes and publishes each release's DMG and update feed, and Dependabot's release-action bump was merged. The remaining install check on a second Mac is written out step by step in the plan.

## [0.46.0] - 2026-09-27

### Added

- **Many more MLX models to choose from.** Add Model now also lists the MLX models from Rapid-MLX's catalog that Quail server can run: 134 models, from 0.4 GB to 60 GB, across Qwen, Gemma, Llama, Granite, LFM, Phi, Mistral, GLM, Nemotron and more. They appear below the hand-picked families, with each one's size, and their fit on your Mac is checked as they scroll into view. Rapid-MLX's own picks for your Mac's memory (the most capable, and the fastest) have their own section. The list refreshes weekly with the catalog.

### Fixed

- MLX models whose files don't list their end-of-turn token as an end-of-sequence token (Gemma 3 1B's conversion, for one) no longer write past the end of their reply.
- Recommended for This Mac now includes MLX-only models when the runtime can serve them.

## [0.45.0] - 2026-09-27

### Added

- **A per-model KV cache setting, for a longer context in the same memory.** In the Models list, a model's context menu now also offers an 8-bit or 4-bit KV cache (the memory a conversation takes). On Qwen3-8B with a 24,000-token prompt, the cache took 1.8 GB at 8 bits and 1.0 GB at 4 bits, against 3.4 GB at full precision. Fit verdicts and Automatic context follow the choice. Add Model says when a model that only fits a reduced context would fit more with a 4-bit cache. It's off by default and trades a little accuracy: at 4 bits one of three recall checks missed on MLX. On GGUF models it costs no speed. On MLX models, prompts are read 35–55% more slowly, and the repeated-text speed-up is roughly halved; replies to long prompts are generated 13–26% faster. Quail server and llama.cpp both read it, as llama-server's `cache-type-k`/`cache-type-v` preset keys.

## [0.44.0] - 2026-09-27

### Changed

- **MLX models answer several requests at once.** Quail server now decodes up to four text requests together on Qwen3, Qwen3.5 and Qwen3.6 MLX models, as it already did for GGUF, instead of making each wait for the one before. Four at once totalled 95–99 tokens a second on Qwen3-8B, against 52 before, and 132 against 81 on Qwen3.6 35B-A3B. A single request is exactly as fast as before, and repeated-text speed-ups still apply while it runs alone. A long prompt arriving mid-reply is read between the others' tokens rather than stopping them. Gemma 4, image turns and other model families still take one request at a time. `--parallel` (default 4) sets the limit; set `QUAIL_MLX_BATCH=0` in the server's environment to turn it off.

## [0.43.2] - 2026-09-27

### Changed

- Docs: the design for decoding several MLX requests together (D-056), for review before it's built. Also a record that draft-model speculation was tried and not shipped (D-055): a small draft model's guesses were kept only a third of the time, too rarely to pay.

## [0.43.1] - 2026-09-27

### Changed

- **MLX models write repeated text up to three times as fast.** When a model repeats text it has already seen (rewriting a file, quoting a document, echoing a tool's output), Quail server now guesses the next tokens from that earlier text and checks them all in one step. Rewriting a file ran at 149 instead of 49 tokens a second on Qwen3-8B, and at 237 instead of 84 on Qwen3.6 35B-A3B. Ordinary prose is unchanged, within 1–3%. A request can limit or turn this off with llama-server's `speculative.n_max`, and the benchmark turns it off.
- **Conversations survive a model swap or a restart on MLX models.** Prompt caches leaving memory are saved in `~/Library/Caches/com.datoos.quail/PromptCache` and loaded back when the conversation returns: a 14,000-token conversation's next turn after a restart took 1 s instead of 39 s on Qwen3-8B. The cache folder is capped at 20 GB and a tenth of free disk space, and macOS may clear it. Use `--no-prompt-cache-disk` to turn it off.

## [0.43.0] - 2026-09-27

### Added

- The benchmark also measures a returning conversation's next turn (first token after a cached 2,048-token prompt) and four requests at once (their total speed). They show in Settings → Benchmark, `quail bench` and the Markdown summary. Earlier results stay comparable and show a dash.

### Changed

- With Quail server as the runtime, Add Model picks a family's MLX variant by default. Measured on the same models, MLX generates 18–54% faster, while GGUF reads short prompts 8–15% faster and can serve several requests at once. You can still choose GGUF.

## [0.42.0] - 2026-09-27

### Changed

- **Quail server is now the default runtime**, for new installs and existing ones. It passed the comparison with llama.cpp on speed, every Connect Test, Claude Code and the chat page, and it runs MLX models as well as GGUF. If you'd rather keep llama.cpp, stop the server and choose it in Settings → Endpoint → Runtime. It stays bundled as a fallback for GGUF models, and Quail remembers the choice.
- With llama.cpp chosen, Quail now says that MLX models won't run on it: in Settings → Endpoint, above the Models list when you have MLX models, and in Add Model when you browse or pick an MLX model. Each place has a button to switch to Quail server.

## [0.41.7] - 2026-09-27

### Fixed

- Quail server showed the size of a model linked into the store (kept elsewhere) as the link's few bytes. It now measures the model itself.

### Changed

- Internal: the parity gate between Quail server and llama.cpp passes on speed, all 15 Connect Tests, Claude Code's tool task and the chat page (D-027 amendment). Quail server doesn't become the default runtime yet; that waits for a decision.

## [0.41.6] - 2026-09-27

### Changed

- **Qwen3.5-family GGUF models (Qwen3.6, Qwen3.8) reuse their prompt cache on Quail server.** Before, every turn re-read the whole prompt, because llama.cpp can't rewind their recurrent layers. Quail now saves restore points as it reads a prompt, as llama-server does. Claude Code's turns on Qwen3.6 35B-A3B started replying in about 1 s instead of 27 s.
- Quail server now decodes up to four GGUF requests at once by default (`--parallel 4`, llama-server's default). It used to be one. An agent's side requests, such as Claude Code's permission check, no longer take the conversation's slot and throw its cache away. The slots share one context, so this costs no extra memory, and single-request speed is unchanged.

## [0.41.5] - 2026-09-27

### Changed

- **Gemma 4 26B-A4B (MLX) reuses its prompt cache**, as the other MLX models now do. On two interleaved conversations, a returning turn's prompt took 0.4 s instead of 4.1 s. This model always loads its vision half, and that path used to read the whole prompt every turn.

## [0.41.4] - 2026-09-27

### Fixed

- **Claude Code's turns reuse the prompt cache on Quail server**, with GGUF and MLX models alike. Before, every turn re-read the whole prompt (about 15,000 tokens). Claude Code adds a system note after each tool result ("N tokens left") whose number changes every turn, and Quail moved it to the start of the prompt, so no two turns ever began the same way. It now stays where Claude Code put it. In a replayed session, turns started replying in 3.5 s instead of 49 s on Qwen3-8B (GGUF), and in 1.7 s instead of 26 s on Qwen3.6 35B-A3B (MLX).

## [0.41.3] - 2026-09-27

### Changed

- **Returning to a conversation no longer re-reads the whole prompt on MLX models.** Quail server now keeps up to four conversations' prompt caches, within an eighth of the Mac's memory. An agent and the chat page, or an agent's sub-tasks, stop evicting each other's. On two interleaved conversations of about 2,800 tokens, a returning turn's prompt took 0.2 s instead of 7.1 s on Qwen3-8B.
- **Qwen3.5-family MLX models (Qwen3.6, Qwen3.8) reuse their prompt cache.** Before, every turn re-read the whole prompt, because their recurrent layers can't be rewound. Quail now keeps restore points as it reads. A returning turn took 0.3 s instead of 3.7 s on Qwen3.6 35B-A3B.
- Sampling at the usual settings (top-k on) is 2–3% faster on MLX models. A given seed now gives different text than in earlier versions, though still the same text every time.
- MLX weights stay wired in memory while a request runs, as mlx-lm does, so a large model isn't paged out between tokens under memory pressure.

## [0.41.2] - 2026-09-27

### Changed

- MLX models on Quail server now use mlx-swift-lm 3.31.4.
  - **Gemma 4 26B-A4B** reads prompts 23–31% faster (774 against 630 tokens a second at 512 tokens, 718 against 547 at 4,096).
  - **Qwen3.5-family models** (Qwen3.6, Qwen3.8) now keep their recurrent state at full precision, as Python's mlx-lm does. This costs about 4% of generation speed: 84–88 against 90–92 tokens a second on Qwen3.6 35B-A3B.
  - **Qwen3-8B** is unchanged.

## [0.41.1] - 2026-09-27

### Changed

- Internal: the parity-gate benchmark (Phase 3 step 7) now waits for the Mac to cool back to nominal before each server's turn and alternates which server goes first. On a warm Mac mini, the same server measured up to 20% slower late in a round than early, which had read as a gap between the servers. It also runs every Connect Test on each server.
- Docs: the keep-awake decision is renumbered D-054 (D-053 was already the distribution decision), and the MLX engine performance plan is added (D-055, Phase 3c).

## [0.41.0] - 2026-09-27

### Added

- **Keep this Mac awake while the server runs** (Settings → General → Power, and in the menu), so a long download, benchmark or agent session isn't cut off by sleep. It uses the same kind of power assertion as `caffeinate`, with nothing to install; the display can still turn off.
- In the direct download, **also with the lid closed, when plugged in**: macOS always sleeps a laptop on lid close, so this turns sleep off system-wide, after one password prompt when the server first starts. It applies only while the server runs on AC power. Sleep comes back when you unplug, stop the server or quit Quail (or crash; after a reboot, Quail offers to restore it).

## [0.40.1] - 2026-09-26

### Fixed

- `quail chat` has line editing. ↑/↓ recall earlier messages, kept across chats as `ollama run` does. ←/→ and Ctrl-A/E move along the line, and Ctrl-R searches. Previously the arrow keys typed escape codes. The history file is readable only by you, and conversations themselves are still not saved.

## [0.40.0] - 2026-09-26

### Added

- MLX models read images on Quail server: the Qwen3.5 family (Qwen3.5, 3.6, 3.8) and Gemma 4 26B-A4B and 31B. Previously every MLX model was text-only, so Qwen3.8 27B MLX refused an image even though it has a vision half. Quail now loads that half, from the same folder with no download, when an image arrives. Text-only chats keep the faster text-only load, which generates about twice as fast. The chat page shows "vision" for these models and lets you attach images, and the Add Model list shows the Vision chip for the MLX variants checked to work (Qwen3.8 27B, Qwen3.6 35B-A3B, Gemma 4 26B-A4B).

### Fixed

- Gemma 4 26B-A4B MLX loads. It used to fail ("Unhandled keys [experts, router…]") because mlx-swift-lm's text-only Gemma 4 lacks its mixture-of-experts layers; Quail now loads it through its vision model, which has them.

### Changed

- When a model can't read images, the message says why for both formats: GGUF needs its vision projector, and of MLX models only the Qwen3.5 family and Gemma 4 26B-A4B and 31B read images so far.

## [0.39.0] - 2026-09-26

### Changed

- Quail server's chat page has a richer model picker. Each model shows a GGUF/MLX badge, its size, the context it loads with, whether it reads images, whether it's the default that loads at start, and whether it's loaded. MLX names drop the `mlx-community--` prefix into the details. The loaded-state dot no longer overlaps the model's name. It works from the keyboard too.

## [0.38.2] - 2026-09-26

### Fixed

- An MLX model set as the default was forgotten every time the server started, so nothing loaded. The check for "the default model was deleted outside Quail" only looked at GGUF files. It now looks at every installed model, and a default that's really gone is still cleared.

## [0.38.1] - 2026-09-26

### Fixed

- The "Good for" chips no longer squeeze the rest of a row: in the Models list they had pushed the model's name, format, size and fit badge into ellipses, and in Add Model they pushed the fit badge off the edge. The chips now take only the room the row has, showing as many labels as fit, then icons. The "Good for" list in Add Model moved below the download choices and fit.
- `QUAIL_SNAPSHOT_DIR` (as `TEST_RUNNER_QUAIL_SNAPSHOT_DIR`) renders the Add Model sheet and the Models list to PNGs, so their layout can be checked without clicking through the app.

## [0.38.0] - 2026-09-26

### Added

- Xiaomi's **MiMo V2.6 9B** in the catalog: an MIT-licensed fine-tune of Qwen3.5-9B for coding and agents, which can also read images (GGUF). Checked before listing: in GGUF Q4_K_M it chats, reads an image and calls tools on both runtimes, and finished an opencode task by itself; the MLX download (mlx-community's mixed 4/8-bit) loads and calls tools on Quail server. Claude Code completed a file-writing task with a 64K context; at 32K its prompt left too little room and it gave up compacting.

## [0.37.0] - 2026-09-26

### Added

- The Add Model sheet and the Models list show what each model is good for (chat, coding, agents and tools, reasoning, long context, vision, multilingual, embeddings) as chips, each with an explanation, plus a "Good for" filter. Vision appears only where Quail can pass images: GGUF downloads with a vision projector. Audio-capable models say Quail can't pass audio yet.

## [0.36.1] - 2026-09-26

### Fixed

- Offline, the Add Model sheet says "You're offline" and shows a model straight away, instead of waiting minutes for fit checks and printing raw network errors. Models looked up before still show their fit. Downloads, listings and `quail pull` say "no internet connection" in plain words and give up within seconds (15 s for model details, 30 s of silence for a download, which resumes later).

### Added

- `task check:offline` proves Quail works with no internet connection. It runs both servers, the app and opencode, Codex and Claude Code in a sandbox that blocks everything beyond this Mac. All of them pass: once models are downloaded, only browsing and downloading need a connection.

## [0.36.0] - 2026-09-26

### Added

- `quail launch opencode` starts opencode 2 on a Quail model, with nothing to set up: the settings are passed in for that run only, and your own opencode config and background service are left alone. `quail launch opencode -- run "…"` works for one-off prompts.
- Qwen Code in Connect and `quail launch qwen`.

### Changed

- Every tool `quail launch` starts, and the Connect tab's snippets, now know the model's context size, so Claude Code, Codex, Goose, opencode and Zed compact before the model runs out of room (Claude Code previously assumed 200K).
- The Connect tab's model picker lists MLX models too.
- `quail launch` warns when the model is MLX and the runtime can't serve it, and lists the tools when you don't name one.
- The opencode snippet explains opencode 2's background service (run `opencode service restart` after editing its config), in place of the old "Cannot connect to API" note.

## [0.35.1] - 2026-09-26

### Fixed

- Fit verdicts for MLX models of newer architectures (Qwen3.6, Qwen3.8, Gemma 4), which said "Fit unknown": their settings sit in a nested part of `config.json` the app didn't read. MLX models now also cap their context at what they were trained for, and mixture-of-experts MLX models get a proper speed estimate.
- The Add Model list's fit badges no longer download each model's details every time the sheet opens: what's been looked up is kept for 30 days, so the badges appear straight away.

## [0.35.0] - 2026-09-26

### Added

- Add Model queues downloads: while one downloads you can pick other models and choose **Add to Queue**; they start in order. The sheet always shows what is downloading (name, quantization, progress, Cancel) and what's waiting (with Remove) above the selected model, and the list marks models that are downloading or queued. Previously the progress replaced the model details without saying which model it was.

## [0.34.0] - 2026-09-26

### Changed

- Quail server's chat page is tidier: one top bar with the model picker (a dot shows whether the model is loaded, and one Load/Unload button), the API key and system prompt tucked behind buttons, a single message box that grows as you type with attach and send inside it, and cleaner messages. The picker now starts on the model that's loaded. The settings are grouped, each with an ⓘ that explains it with a good and a bad value, and focus rings are no longer cut off at the dialog's edges.

## [0.33.0] - 2026-09-26

### Added

- MLX models can be benchmarked with the Quail server runtime, and the Benchmark pane says which format each model and result is (GGUF or MLX), and which server ran it.

## [0.32.2] - 2026-09-26

### Fixed

- Settings → General → About → **Third-party licences** opens at once with a spinner, then shows the component list as a proper table, each project's licence as its own block and its link as a link, instead of the raw Markdown file, which took seconds to appear.

## [0.32.1] - 2026-09-26

### Fixed

- After switching to the Quail server runtime, **Open Chat** kept showing llama.cpp's page: that page leaves a service worker in the browser that serves its cached copy for the same address. `quail-server` now answers `/sw.js` with a worker that removes itself and its cache and reloads the page, and its own page clears any leftover worker. Selecting an MLX model in that stale page is what failed.
- Starting the Quail server right after llama-server on the same port failed four times with "address already in use" before a later start worked: connections the browser and the app still held to the old server kept the port from being reused for up to a minute. `quail-server` now waits for such a port (logging that it is) instead of exiting; a port another program really listens on still fails at once.

## [0.32.0] - 2026-09-26

### Added

- Quail server's chat page takes attachments: images for vision models (paste, drop or pick; shown as thumbnails) and text files, saved with the chat (ADR D-042).

## [0.31.4] - 2026-09-26

### Fixed

- `quail-server`'s `/v1/messages` refused Claude Code's current requests ("each message needs a role of user or assistant"): Claude Code now puts part of its instructions in a `system` message among the others. That text now joins the system prompt, in order. With the fix, Claude Code completed a tool-using task (writing a file with its Write tool) against Qwen3.6-35B-A3B on `quail-server`.

## [0.31.3] - 2026-09-26

### Fixed

- Internal: `quail-server`'s engine handed its queue back after every generated token, which cost a thread wake-up per token on a busy Mac (a streamed Qwen3-8B reply ran several percent slower than llama-server's); it now runs several steps per turn and still lets other work in every 50 ms. Streamed Qwen3-8B: 44.5 vs llama-server's 42.7 tokens/s.

## [0.31.2] - 2026-09-26

### Fixed

- Internal: `quail-server` generated about 10 % slower than llama-server on the same model, because ggml made a new CPU thread pool for every token; it now keeps one for the model's lifetime, as llama-server does, and matches it (Qwen3-0.6B 244 vs 242 tokens/s, Qwen3-8B 39.0 vs 36.4). A request that asks for no prompt cache now still goes to the slot that last served the same prompt, instead of spreading over every slot.

## [0.31.1] - 2026-09-25

### Fixed

- Internal, affects the Quail server runtime: a connection that had carried more than 64 KB of requests (a long agent session, a benchmark run) had every later request refused with "request headers too large". Found by running the benchmark suite against `quail-server` for the parity gate.
- Internal: `quail-server` timed a prompt only until its work was queued on the GPU, so short prompts reported impossible speeds (200,000 tokens/s); it now times until the result is ready, as llama-server does. It also uses one thread per performance core, as llama-server does, instead of libllama's default of four.

## [0.31.0] - 2026-09-25

### Added

- Quail server's chat page keeps your chats (in the browser, with a searchable list), renders replies as Markdown with copyable code blocks, has a settings panel for temperature, top-p, penalties, seed, stop strings, thinking and JSON replies, and lets you edit, regenerate, copy or delete any message, and export or import chats (ADR D-042).

## [0.30.0] - 2026-09-25

### Added

- With the Quail server runtime, **Open Chat in Browser** opens the chat page already signed in: the app hands the page a one-time, 30-second ticket that it trades for the API key, so the key never appears in a URL and doesn't need pasting (ADR D-042).

## [0.29.0] - 2026-09-25

### Added

- MLX models can be run from the app: choose **Quail server** in Settings → Endpoint → Runtime (with the server stopped). It runs GGUF and MLX models from the same store, and its Open Chat page is Quail's own. llama.cpp stays the default for now (ADR D-027).

### Fixed

- An MLX model folder that is a symlink now loads in `quail-server` (it failed with "Key lm_head.weight not found").

## [0.28.1] - 2026-09-25

### Fixed

- The licence list is easier to find and opens reliably: Settings → General → About → **Third-party licences** (it was labelled "Open-source licences", and its sheet was attached in a way that doesn't always present in the Settings window).

## [0.28.0] - 2026-09-25

### Added

- Internal, no visible change yet: `quail-server --parallel N` (and a preset's `parallel`) lets a GGUF model decode several requests together in slots that share one context, sharing prompt starts between them. Four small-model requests together were 2.4 times faster than one after another, with identical text; the default stays 1 (ADR D-048).

## [0.27.1] - 2026-09-25

### Changed

- Docs only: the design for serving several requests at once from one loaded GGUF model (slots on a shared context), with measurements of how much batching gains on three models (ADR D-048).

## [0.27.0] - 2026-09-25

### Added

- Internal, no visible change yet: `quail-server` now reads images with GGUF vision models (a model with an `mmproj` projector next to it), in chat completions, `/v1/messages` and `/v1/responses`. On SmolVLM2 and Qwen2.5-VL the answers and prompt sizes matched llama-server's exactly, and a multi-turn conversation with a template that reads only typed parts now renders as llama-server's does (ADR D-047).

## [0.26.0] - 2026-09-25

### Added

- Internal, no visible change yet: `quail-server` reads images in chat completions, `/v1/messages` and `/v1/responses` requests (base64 `data:` URLs only; it never fetches an image URL) and hands them to an engine that can read them, with clear 400s where none can (ADR D-047). The engine that reads them comes next.

## [0.25.1] - 2026-09-25

### Fixed

- The Auto-merge workflow also runs when a pull request's branch is pushed to, so a PR opened before auto-merge worked (or whose auto-merge was turned off) gets it back on its next push.

## [0.25.0] - 2026-09-25

### Added

- Internal, no visible change yet: `quail-server` honours `tool_choice` `required` and a named function (and Anthropic's `any` and `tool`) for GGUF models with Hermes-style (Qwen) or bare-JSON (Llama 3) tool calls, by making the reply a call whose arguments follow the tool's own schema. On Qwen3-8B that was 20 of 20 correct calls where llama-server managed 4 of 20 (ADR D-045). Other call formats answer with a clear 400.

## [0.24.1] - 2026-09-25

### Changed

- Pull requests merge themselves again once their checks pass: the Auto-merge and Dependabot-bump workflows now act as a GitHub App (`quail-release`) instead of a personal access token that was never set up (ADR D-046). Needs the App's two secrets before it takes effect.

## [0.24.0] - 2026-09-25

### Added

- Internal, no visible change yet: `quail-server` supports JSON mode, `response_format` (`json_object`, `json_schema`), llama-server's `grammar` and `json_schema` fields, and `/v1/responses` `text.format` for GGUF models, by sampling under a grammar built from the schema. MLX models answer these with a clear 400. On Qwen3-8B, 26 of 27 test schemas gave valid JSON on five seeds each, the same as llama-server (ADR D-045).

## [0.23.0] - 2026-09-25

### Changed

- Internal, no visible change yet: `quail-server` supports llama-server's DRY, XTC, typical-p, top-n-sigma and mirostat
  sampler options for GGUF models, and the repetition penalties now take the prompt into account as llama-server's do
  (ADR D-043). Text matched llama-server's in 36 of 36 seeded runs.

## [0.22.1] - 2026-09-25

### Fixed

- Internal, no visible change yet: `quail-server` stops an MLX model's work on a long prompt when the client hangs up,
  instead of finishing the whole prompt first (a 20,000-token prompt took 71 s to let go; now about 1 s). A cancelled
  prompt's progress is kept for a retry. `task check:mlx-offline` proves the MLX path makes no network connection (ADR D-044).

## [0.22.0] - 2026-09-25

### Added

- Settings → General → About → Open-source licences now shows the licence and notice text of everything Quail
  bundles (MLX, the tokenizer and their dependencies, Sparkle, llama.cpp), not just llama.cpp's. The file is generated
  and checked in CI, so a new dependency can't ship without an entry (ADR D-044).

## [0.21.1] - 2026-09-25

### Fixed

- The release build of 0.21.0 failed before producing a DMG (the MLX shader bundle was linked, not copied, in an
  archive build), so 0.21.0 was never published for download or update; this version carries its changes (ADR D-044).

## [0.21.0] - 2026-09-25

### Changed

- Internal, no visible change yet: `quail-server` runs MLX models itself, next to GGUF ones (ADR D-044): streaming and
  whole replies, prompt caching, seeds, stop strings and hang-up handling. The app still starts llama-server until the
  runtime switch. The app bundle grows from 47 MB to 82 MB (MLX and its Metal shaders).

## [0.20.0] - 2026-09-25

### Changed

- Internal, no visible change yet: `quail-server` runs GGUF models itself, through llama.cpp's library: streaming and
  whole replies, prompt caching, stop strings and hang-up handling all work, and its output matched llama-server's
  token for token on the checks run (ADR D-043). The app still starts llama-server until the runtime switch. The app
  bundle gains llama.framework (8 MB).

## [0.19.1] - 2026-09-25

### Fixed

- Checking for updates in the minutes after a release no longer fails with "An error occurred in retrieving update
  information": a release now becomes the latest one only once its update feed is attached (ADR D-032).

## [0.19.0] - 2026-09-25

### Added

- `quail-server` serves a small chat page at `/`: pick a model, load or unload it, chat with streamed replies and a
  Stop button, with light and dark themes. Model text is only ever shown as text, and a strict
  Content-Security-Policy backs that up. `--no-webui` turns it off (ADR D-042). Not reachable from the app yet;
  the runtime switch comes with step 6.

## [0.18.0] - 2026-09-25

### Changed

- Internal, no visible change yet: `quail-server` answers Anthropic's `/v1/messages` (the API Claude Code uses, with
  `count_tokens`) and OpenAI's `/v1/responses`, on the same chat pipeline as `/v1/chat/completions`, in the shapes
  llama-server sends (ADR D-041).

## [0.17.0] - 2026-09-25

### Changed

- Internal, no visible change yet: `quail-server` reads tool calls out of a model's reply (Qwen 2.5/3, Qwen3-Coder
  and 3.5/3.6, Llama 3, gpt-oss) and returns them in llama-server's `tool_calls` shape (ADR D-040); checked against
  real Qwen3 and Qwen3.6 output.

## [0.16.0] - 2026-09-25

### Changed

- Internal, no visible change yet: `quail-server` stops work for a client that hangs up before its first token
  (a long prompt, a model still loading), instead of finishing it for nobody (ADR D-037).

## [0.15.0] - 2026-09-25

### Security

- **The API key is now on by default** (ADR D-039). The runtime Quail uses today (llama-server) answers requests
  from any web page, so with no key any site you visited could use your models. Quail generates a key at launch and
  passes it to the runtime; the app, `quail chat`, the benchmark and Connect a Tool already use it. Other clients
  (a script, Open WebUI, llama.cpp's own web UI in the browser) need the key: Settings → Endpoint → Copy.
  If you had turned the key off before, it's switched on once; turning it off again sticks.

## [0.14.0] - 2026-09-25

### Changed

- Internal, no visible change yet: `quail-server` serves `/v1/chat/completions` (streamed and not), building the
  prompt from the model's own chat template and splitting `<think>` reasoning into `reasoning_content`, in
  llama-server's shapes; `quail chat`'s stream parser reads it unchanged (ADR D-038).

## [0.13.0] - 2026-09-25

### Changed

- Internal, no visible change yet: `quail-server` serves `/v1/completions` (streamed and not, with stop strings),
  `/tokenize`, `/detokenize` and `/props` in llama-server's shapes; the benchmark's own client runs against it
  unchanged (ADR D-037).

## [0.12.0] - 2026-09-24

### Security

- `quail-server` refuses requests from web pages (cross-origin) and DNS-rebinding hosts unless allowed with
  `--allow-origin` (ADR D-036). Not yet in use: the default runtime is still `llama-server`, which answers
  every origin (see D-036).

## [0.11.0] - 2026-09-24

### Changed

- Internal, no visible change yet: `quail-server` can render a model's chat template (checked against
  llama.cpp on four model families) and parse request JSON without reordering it (ADR D-035).

## [0.10.0] - 2026-09-24

### Added

- **An app icon.** Quail now has one, in the Finder, Settings and the update prompts (ADR D-034).

## [0.9.1] - 2026-09-24

### Fixed

- The Homebrew cask is now `quail-ai` (`brew install --cask adatoo/tap/quail-ai`). `quail` is an unrelated app's
  cask in homebrew-cask, so `brew info quail` and `brew outdated` mixed the two up. If you installed 0.9.0 with
  Homebrew: `brew uninstall --cask adatoo/tap/quail`, then install `quail-ai` (settings and models are kept).

## [0.9.0] - 2026-09-24

### Added

- **Homebrew.** `brew install --cask adatoo/tap/quail` installs Quail and the `quail` command; every release
  updates the cask automatically (ADR D-033).

### Fixed

- `task install` built an app that macOS refused to launch ("Library not loaded: Sparkle.framework"), since
  0.8.0. Ad-hoc local installs now drop the hardened runtime that caused it; released builds were unaffected.

## [0.8.0] - 2026-09-24

### Added

- **In-app updates.** Quail checks for a new version and can install it (ADR D-032). Settings → General →
  Updates chooses how often (Daily, Weekly, Monthly or Never), whether updates install without asking, and has
  **Check for Updates…**, which is also in the menu-bar menu. By default Quail asks before installing;
  installing quits Quail (stopping the server first) and relaunches it. Every update is signed and verified.
- Each release now carries an `appcast.xml`, the feed installed copies read.
- Debug builds can move all of Quail's data with `QUAIL_DATA_ROOT`, so a test copy never touches the real
  config or models (see CONTRIBUTING.md).

### Changed

- Release builds are Apple silicon only (`arm64`): the bundled `llama-server` never ran on Intel.

## [0.7.2] - 2026-09-24

### Fixed

- `task verify:bundle APP=…` failed on a machine with no `./DerivedData` (the release job's fresh VM),
  which stopped the first CI-signed release before its DMG was built.

## [0.7.1] - 2026-09-24

### Changed

- The self-hosted runners and the `MAC_RUNNER` variable are gone; CI is GitHub-hosted only (ADR D-031).

## [0.7.0] - 2026-09-24

### Added

- Signed, notarized releases: `task release:all` and `task release:dmg` now build a Developer ID
  signed app **and DMG**, both notarized and stapled. Notarization uses the account's App Store
  Connect API key (`APPLE_API_KEY_*`), with an Apple ID password as a fallback. The release
  workflow attaches the DMG once `SIGNING_ENABLED` is set.

### Changed

- Releases are published as full releases, not pre-releases, so `releases/latest` finds them
  (for the updater and Homebrew to come; ADR D-031).
- A failed archive or export now fails the release build with xcodebuild's own error, instead of
  a later "app missing" message.

## [0.6.3] - 2026-09-24

### Changed

- CI runs entirely on GitHub-hosted runners (macOS for builds, Ubuntu for the rest), ahead of making
  the repository public (ADR D-031). The self-hosted runner is no longer used.

## [0.6.2] - 2026-09-24

### Changed

- CI: `softprops/action-gh-release` 2 → 3 (Node 24 runtime; the inputs Quail uses are unchanged).

## [0.6.1] - 2026-09-24

### Changed

- Building, testing, vendoring, versioning and releasing now go through [Task](https://taskfile.dev)
  (`task`, `task ci`, `task build`, `task test`, `task install`, …) instead of 13 shell scripts,
  and CI runs the same tasks, so a local `task ci` is what CI runs (ADR D-030). Xcode's build
  phases call `task embed:*`, so **go-task (`brew install go-task`) is now required to build Quail**.
  Task builds go in `./DerivedData`, so they never overwrite a running app. `task install`
  builds a signed Release into `~/Apps`; `task install:notarized` is the old `install.sh`.
  The version pins moved to `Vendor/` and `Config/`. CI also builds the App Store scheme now.

### Fixed

- The bundle check no longer rejects universal (arm64 + x86_64) Release builds, and can no longer
  pass when it examined no binaries at all.

## [0.6.0] - 2026-09-24

### Added

- Settings → General has an **About** section: the app version and build, whether
  it's the direct download or the Mac App Store build, the bundled llama.cpp
  release, the model catalog revision and your macOS version. **Copy Details**
  puts them on the clipboard for a bug report, and **Open-source licences**
  shows the llama.cpp MIT licence that ships with the app (ADR D-029).

## [0.5.0] - 2026-09-24

### Added

- `quail-server`, the first piece of Phase 3's single server for GGUF and MLX
  models (ADR D-027), shipped inside `Quail.app` in both builds. It has an
  HTTP layer, a model router (`--models-max`, least-recently-used eviction, a
  model is never unloaded under a request in flight) and the engine seam the
  GGUF and MLX engines plug into, and answers `/health`, `/models`,
  `/v1/models`, `/models/load` and `/models/unload` in the shapes
  `llama-server` uses, so the existing adapter drives it unchanged. **Nothing
  in the app starts it yet:** it has no inference engine until Phase 3 steps 4
  and 5, and Quail still runs `llama-server`.

### Changed

- Phase 3 is replanned around one `quail-server` with a `libllama` engine and
  an `mlx-swift-lm` engine instead of four MLX adapters: ADRs D-027 and D-028,
  the dependency rule in `AGENTS.md`, and the plan and architecture docs. The
  oMLX and Rapid-MLX runtimes are deferred.

## [0.4.1] - 2026-09-24

## [0.4.0] - 2026-09-24

### Changed

- `quail run` is now `quail chat` (it only ever chatted; `run` reads as
  starting a model). `run` is gone, with no alias. "Copy Terminal Chat
  Command" copies `quail chat -m <model>`.

### Fixed

- `quail chat` takes a prompt without a model: `quail chat why is the sky
  blue` asks the default model. The first word is the model only if it names
  an installed model; `-m <model>` names it outright.

## [0.3.2] - 2026-09-24

## [0.3.1] - 2026-09-24

### Added

- Benchmark window: a Cancel button (a cancelled run saves nothing and puts the
  loaded models back), a spinner and elapsed time while a run is going.
- Menu: on a runtime without a web UI, "Open Chat in Browser" becomes "Copy
  Terminal Chat Command" (`quail run <model>`).

### Changed

- Benchmark is a tab in Settings, like every other page, instead of its own
  window; Settings is one wider width on every tab.
- Comparing two benchmark runs now names a baseline (the older run, tagged in
  the table; swap it or set it from the row menu) and words each result as
  "1.23× faster" or "19% slower".

### Fixed

- Models pane: each row is two lines, so a model's name is no longer cut off
  ("Qwen3…4_K_M"); the Add Model list shows a tick for installed families and
  keeps their full names.
- Run Benchmark reacts at once ("Preparing…") instead of sitting idle while the
  machine's facts are gathered.
- The Models pane's empty MLX filter no longer recommends a GGUF quant.

## [0.3.0] - 2026-09-23

### Added

- `quail` CLI v2: `pull <name|owner/repo>[:quant]` downloads a catalog model
  (`quail pull qwen3-8b:Q8_0`) or any Hugging Face GGUF repo with a progress
  bar — Ctrl-C cancels, running it again resumes — and `pull --list` shows the
  catalog with this Mac's recommendations and what's installed; `rm`,
  `default [model|--clear]`, `ctx <model> [size|auto]` (with each size's fit),
  and `config` (endpoint, API key, store, logs, settings). Model names accept a
  unique prefix.

## [0.2.0] - 2026-09-23

### Added

- SemVer releases (ADR D-024): every PR carries a version bump derived from
  its Conventional Commits title (`scripts/bump-version.sh`, checked by the
  new required `version` workflow); PRs auto-merge with a merge commit once
  CI passes; every merge to `main` is tagged `vX.Y.Z` and published as a
  GitHub Release with its CHANGELOG section (the signed DMG attaches once
  signing is configured). `quail --version` reports the app's version.

- `ModelStore`: the unified store folder layout, `catalog.json` index, and
  `presets.ini` generated from whatever `.gguf` files are actually on disk.
- `GGUFMetadata` / `MLXMetadata`: header/config parsers supplying the
  device-fit inputs for both model formats.
- `DeviceInfo` + `FitEstimator`: ARCHITECTURE.md §7's RAM/context verdicts
  and bandwidth-based speed estimates, plus the chip bandwidth table loader.
- `HFDownloader`: resumable, checksum-verified Hugging Face downloads
  (single-file GGUFs and whole MLX directories), with cancel and
  resume-across-restart under `Models/.partial/`.
- `Catalog`: the curated download list, a weekly remote refresh
  (`QuailCatalogURL`, unset until an update host exists), and user-added
  uncurated repo entries.
- Hot swap: a Load button on installed GGUF rows while the server runs
  (`POST /models/load`), with live loading→loaded status polling, and a
  1–8 "Max loaded models" stepper in the Endpoint pane (applies next
  Start; launch flag).
- Models pane in Settings: installed models with format/size/fit-verdict/
  loaded-state badges, an All/GGUF/MLX filter, delete-with-confirm, store
  relocation (`Relocate…` + security-scoped bookmark), and a Hugging Face
  token field for gated repos.
- "Add model…" sheet: curated catalog (or a pasted repo id), quant picker,
  and a fit verdict computed from the Hub's file listing *before* download.
- Settings: the endpoint API key is now editable, copyable, regenerable
  (and visibly so — fixing a stored-vs-computed observation bug), generated
  shorter, and there's a slot for a Hugging Face token in Keychain.
- `Recommender` + `Catalog.tier(forMemoryBytes:)`: the Add-model sheet now
  shows a "Recommended for this Mac" section (curated, in-tier, Comfortable
  families, sorted by rank) ahead of the full list, with a fit verdict and
  ~tok/s per row fetched via `AppState.loadCatalogVerdicts()`. The Models
  pane's empty state names the top pick instead of a bare "Add model…"
  button.
- A "This Mac" Settings tab: chip, core counts, unified memory, GPU
  working-set ceiling, free memory, memory bandwidth, RAM tier, marketing
  name, model identifier, GPU core count, and macOS version — new
  `DeviceInfo` fields read via IOKit, with a "Copy Details" button.
- Start now refuses to run with no installed GGUF (`AppState.canStart`/
  `hasServableModel`); the menu shows "No model installed" and an "Add
  model…" shortcut into Settings instead of starting an empty router.
- Default model: a star toggle on a Models-pane row sets `Config.
  defaultModelID`, which `presets.ini` gets a `load-on-startup = true`
  key for (ADR D-017) — that model now loads automatically on Start, with
  no manual Load click or inbound request required.
- "Copy Model ID" on each Models-pane row, plus a hint: the `"model"`
  field a client sends to pick among several loaded models is the
  installed model's own id — previously undiscoverable from the app.
- Refreshed the curated catalog against the live Hub (Gemma 4, Qwen3.6/
  Qwen3.8, DeepSeek-R1-Distill) and made the weekly remote-refresh
  mechanism live for the first time — `QuailCatalogURL` now points at
  this repo's own `catalog.json`, so future catalog updates ship with a
  `git push`, not an app release.
- Developer ID signing (ADR D-018): `scripts/sign-and-notarize.sh`,
  `scripts/make-dmg.sh`, and a local entry point `scripts/install.sh`
  (archive → sign → notarize → staple → `~/Apps/Quail.app`), plus
  `.github/workflows/release.yml` reusing the same scripts on a `v*` tag
  push. Completes Phase 1 step 11.

- Connect (Phase 2b step 1): a Settings tab with copy-ready configs for 14
  tools — Claude Code, Codex CLI, Continue, Cline, Roo Code, Zed, aider,
  opencode, Goose, Open WebUI, LibreChat, curl, Python and JS — filled with
  this endpoint's address, key and a chosen model ("This Mac" or "Another
  device", using the LAN address when listening on 0.0.0.0), plus a Test
  that sends one request over the API the tool uses (chat completions,
  Responses, or Anthropic `/v1/messages`). Defined as data
  (`Resources/integrations.json`), verified against each tool's docs;
  Claude Code, Codex, opencode and curl were run end-to-end against a real
  llama-server with their snippets. Copy-only — Quail never edits other
  apps' config files. Also "Connect a Tool…" and "Open Chat in Browser"
  (the runtime's built-in web UI) in the menu.

- Per-model context size (ADR D-020): each model's row has a "ctx" menu —
  Automatic (the largest of 32K/16K/8K that's Comfortable on this Mac,
  capped at the model's trained context) or 4K–128K, each option labelled
  with its fit. The old fixed 8K overflowed coding agents on their first
  request (Claude Code's measured 15,114 tokens). Fit badges are computed
  at the context the model will actually run at; Connect warns when a
  tool needs more context than the chosen model has.
- Store audit trail: in-app deletes and models appearing/disappearing on
  disk are written to the Logs window and the persistent unified log.

- `quail` command-line tool (ADRs D-021, D-022), "like ollama": `start`,
  `stop`, `restart`, `status [--json]`, `list`, `ps`, `run <model> [prompt]`
  (terminal chat with streaming and tok/s; one-shot or piped), `launch
  claude|codex|aider|goose` (starts the tool pointed at Quail — env vars,
  args and temp files, never the tool's own config), `logs [-f]`, and
  `service enable|disable` (open at login + start the server
  automatically). A thin client of the app over a user-only Unix socket;
  launches Quail if it isn't running. Shipped inside the app (direct build
  only); Settings → General installs it to ~/.local/bin. "Start the server
  when Quail opens" is now a real setting.

- Benchmark (ADR D-023): a fixed suite, `quail-bench-1` — prompt processing at
  512 and 4096 tokens, generation over 256, time to first token and load
  time, 3 runs after a warm-up — run from a new Benchmark window (menu, or a
  Models row's context menu) or `quail bench [model]`. Results record the
  Mac, model file, llama.cpp build and conditions, are saved, and can be
  compared, copied as Markdown or exported as JSON. The Models tab shows each
  model's measured generation speed. Whatever was loaded before a run is
  loaded again after it.

### Fixed

- Leaving the Models tab left its 2-second poll running flat out — the
  cancelled sleep returned instantly — hammering `GET /models` until the Mac
  ran out of local ports, so other connections (a second `quail run` turn,
  even `git fetch`) failed with "Could not connect". Every poll loop now
  exits on cancel.
- `quail run` survives a server restart or a new API key mid-chat (it asks
  Quail for the endpoint again and retries once), a failed turn no longer
  leaves an unanswered message in the conversation, and connection errors
  read as one line instead of an NSError dump.
- Settings → General no longer jumps in size as the quail command is
  installed or removed.
- Quail's windows no longer get lost behind other apps after switching
  desktops and back: a Quail window on the Space you return to is brought
  back to the front.
- The llama-server smoke test wrote into the user's real server log.
- Start could go green for a server that wasn't Quail's: a `llama-server`
  orphaned by an earlier run (Xcode Stop, crash, `kill -9`) kept port 8080,
  Quail's new process failed to bind, but the orphan answered `/health`.
  Test then failed (older API key) and the icon went red once restarts ran
  out. Now: orphans carrying this store's `presets.ini` are stopped at
  launch and before every Start; Start refuses with a named reason if the
  port is held by anything else; and `/health` only counts while Quail's
  own process is alive. The Ping window shows the start failure reason and
  which model it tested, and prefers an already-loaded model over the
  alphabetically-first one (which, with `modelsMax` 1, evicted the default).
  `llamaCpp.log` now keeps the previous run as `llamaCpp.previous.log`.
- `project.yml`'s resources wiring never actually put `catalog.json` (or
  the app icon) into a built `Quail.app` — every build shipped an empty
  curated catalog and no recommendations. Added a CI check so this can't
  silently regress again.
- The Add-model sheet had no visible way to close it besides Esc in most
  states; added a Cancel button.
- `ServerController` kept claiming `.ready` through a supervisor
  auto-restart instead of re-verifying `/health` — the menu said "Running"
  and Ping's "server up" step failed while the process was actually down.
  It now re-checks health on every restart, same as the initial Start.
- `PingSheet` reused a stale `PingRunner` (old host/port/API key) across
  `Run Again` and reopening the window; it now always builds a fresh one
  from what the server was actually launched with.
- The generated API key was a 32-character hex string that overflowed
  the Endpoint settings field; it's now 16-character base64url.
- Settings, Logs and Test opened out of sight when another app was
  full-screen: a menu-bar-only app can't force activation on macOS 14+, and
  the window landed on the desktop Space. Windows opened from the menu now
  join the current (full-screen) Space and are ordered front — set as each
  window is created (`WindowFrontier`), after a first attempt that adjusted
  them afterwards only worked some of the time. The Models
  pane's footer is redesigned (labelled "Models folder" and "Hugging Face
  token" rows; Clean Up / Move Folder / Reload in a ⋯ menu; Add Model…
  moved to the top) — five buttons in one row had truncated.
- Models changed outside Quail (deleted or copied in Finder) are now
  picked up live: a folder watcher waits for copies to finish, then
  reconciles — `catalog.json` follows the disk, `presets.ini` is
  regenerated, and a default model whose file is gone is cleared with a Logs
  line (it used to stay in `config.json`, named in the menu but never
  loading). The router never rescans (confirmed live: a model added later
  404s on load, a deleted one stays listed), so while running the menu
  shows "Models changed — restart to apply" with a Restart button, and new
  models show "Restart to load" instead of a Load button that would 404.
  Models pane: "Show in Finder" opens the GGUF folder; "Clean Up…" lists
  unlinked projectors and abandoned partial downloads with sizes and moves
  the chosen ones to the Trash — nothing is removed automatically.
- Vision models ran text-only: their projector (`mmproj`) was downloaded
  but never passed to the server, and every repo names it `mmproj-F16.gguf`,
  so a second vision model overwrote the first's. Projectors are now saved
  as `mmproj-<model id>.gguf` and written into that model's preset as
  `mmproj =`; delete matches them exactly (a prefix match could remove
  another model's). Verified live: an image request that failed with "image
  input is not supported" now answers correctly.
- Add-model sheet: rows now say "Installed" (per quant in the picker), and
  an installed pick offers Delete instead of a second download. A failed
  download is shown in the sheet (it used to reset silently), and a
  finished download no longer leaves the sheet stuck on "Installed · Done"
  the next time it opens. Deleting a model only stops the server if that
  model is loaded (it used to stop it unconditionally); the Models list
  refreshes after a delete from either place.
- "Recommended for this Mac" was limited to the Mac's RAM tier — on a
  64 GB Mac that's 35B+, which hid comfortable 27–31B models. It now lists
  the top 5 models that run comfortably here, any size (D-019), ordered by
  catalog rank then estimated speed on this Mac. Catalog revision 3
  re-ranks by generation (Qwen3.8, Qwen3.6, Gemma 4 first) — size used to
  break ties, which put Qwen3 32B above its successor Qwen3.8 27B.
- Add-model sheet: most rows showed no fit badge. Only in-tier
  recommendation candidates were ever looked up, and 6 of 15 catalog
  models (Gemma 4, Qwen3.6/3.8, gpt-oss) have GGUF headers larger than the
  8 MiB preview fetch — their tokenizer data comes after the shape keys the
  estimate needs, so the parser now stops once it has those. Every row now
  shows a verdict, "Checking…", or "Fit unknown" with the reason on hover;
  a manual live-Hub smoke test (`CatalogFitSmokeTest`) checks the whole
  catalog. The sheet is redesigned: two columns with search/paste, a
  details pane naming the model with a spelled-out fit card (needs X of Y
  GB, ~tok/s), quant sizes in the picker, a note that MLX can't be served
  yet, and a standard Cancel / Download footer.
- This Mac: GPU cores always showed "—" (the IOKit lookup passed the
  main port where a registry entry was expected), and the RAM tier line
  printed the catalog's open-ended sentinel as "~35–999B models". Model
  size is now estimated from the measured GPU ceiling (comfortable /
  largest at 4-bit), and the pane uses grouped sections.
- The menu's status came from config, not the server: "no default model"
  showed yellow even though requests worked, and a default model that
  failed to load still showed green. It now polls the router's `/models`
  while running — green when serving, yellow while a model loads, red if
  the default model failed — and the menu shows what's actually loaded.
- `xcodebuild test` was popping a macOS Keychain-authorization prompt on
  every run — it genuinely launches Quail.app to host the test bundle,
  and that real app was reading the real stored API key from Keychain.
  `AppDelegate` now detects test-hosting and uses a no-op secret store.

### Changed

- CI can run on a self-hosted Mac: set the `MAC_RUNNER` repo variable
  (e.g. `mac-mini`) to move `build-and-test` onto it, and
  `MAC_SIGNING_RUNNER` to move the release job onto a runner that runs as
  its own macOS user (the release job replaces its default keychain).
  Unset, both stay on GitHub-hosted `macos-26`. On a self-hosted Mac the
  jobs use `/Applications/Xcode.app` and skip the `sudo xcode-select`
  switch, and `build-and-test` now builds into a per-workspace
  DerivedData so its Quail.app checks can't pick up a local build.
- The bundled server now starts with `--models-preset`, so each model gets
  its `ctx-size`/`n-gpu-layers` from the store rather than llama.cpp's
  defaults (ADR D-012).

## [0.1.0-alpha] - 2026-09-22

Phase 1 (see docs/IMPLEMENTATION_PLAN.md): a menu bar app that runs the bundled
`llama-server` against a folder and tells you it's alive. Not yet a signed,
notarized release build — that's PR 11.

### Added

- Repository scaffold: MIT licence, contribution guidelines, CI workflow.
- Xcode project (`Quail`, `Quail-AppStore` schemes) generated by XcodeGen.
- Vendored, signed llama.cpp (`llama-server` + its dependency closure),
  embedded into the app bundle on every build.
- `Runtime` protocol and `LlamaCppRuntime` adapter (router mode: health,
  list models, hot-swap select).
- `ProcessSupervisor` (spawn, log piping, restart with back-off) and
  `ServerController` (`stopped`/`starting`/`ready`/`stopping`/`failed`
  state machine).
- Menu bar UI: status icon and label, Start/Stop, Test…, Logs…,
  Settings…, Quit — the last of which, along with Cmd+Q, Dock quit, a
  macOS logout, and a direct `SIGTERM`, now actually stops the bundled
  server rather than leaving it running as an orphan.
- Settings: General (open at login, via `SMAppService`) and Endpoint
  (runtime picker, host, port, API key toggle backed by Keychain, copy
  base URL).
- Ping sheet: server-up, model-loaded, and first-token timings against a
  real running server.
- Logs window: live tail, level filter, Reveal in Finder, copy last 200
  lines.
- Persisted `config.json` (`Config.swift`), with the API key itself only
  ever in Keychain.
