# ADR-0060: Live activity: `GET /slots`, the menu bar and an Activity window

**Date:** 2026-09-28 · **Status:** Accepted

**Situation:** a 30,000-token prompt takes a minute and a half on Qwen3-8B, and a model load takes seconds. The whole time, Quail's menu says "Running" and the client waits in silence. The app knew the server's phase and each model's load state, from a 2 s `GET /models` poll, and nothing else: no request state, no progress, no memory, CPU or GPU figures.

**Decision (server):** `ActivityRegistry` keeps a record per request in progress. `GET /slots` (behind the API key, never loading a model) returns them with the active models.
- **Request lifecycle:** a request is recorded as it asks for its model, which is the `waiting_for_model` phase. It becomes `queued` once the engine has it. `TextGenerator.stream` then moves it to `reading_prompt` at the engine's first prompt progress and to `generating` at the first token. It's removed however it ends, including when the client leaves (the record's `end()` is idempotent).
- **A new optional event,** `GenerationEvent.promptProgress(done:total:cached:)`. MLX emits it after each 512-token slice, GGUF after each chunk (2,048 tokens). `TextGenerator` consumes it, so no client ever sees it.
- **Rates:** prompt tokens a second are counted from the first progress event and exclude reused tokens. Generation tokens a second are counted from the first token.
- **Models** carry their state, `loading_seconds`, leases and `memory_bytes`. The memory comes from MLX's allocator (`Memory.activeMemory`); GGUF reports nil, and the app measures the process instead.
- **The name:** `/slots` is llama-server's route name, but the shape is Quail's own, because per-slot objects don't describe batched MLX requests or queued ones. `/props` now says `endpoint_slots: true`.

**Checked:** registry phase and rate tests; `/slots` during a scripted stream (generating, then gone after a hang-up) and while a prompt is read (half done, and the reply text unchanged); auth; and no model load. Against real models, a 13,570-token prompt on Qwen3-8B showed MLX advancing 512 tokens at a time at about 336 tokens a second, and GGUF showing loading for 15 s and then 2,048-token steps.

**Amended 2026-09-28 (the app):**
- **`ActivityMonitor`** polls `/slots` and samples the Mac: every second while something is happening, every two seconds otherwise, only while the server runs.
- **`SystemMonitor`** takes its readings without special rights:
  - CPU from Mach's per-core ticks;
  - the server's CPU and memory from `proc_pid_rusage` on its process and any children (llama-server's per-model processes); on Apple silicon the footprint includes GPU buffers;
  - GPU busy % from the `IOAccelerator` service's `PerformanceStatistics["Device Utilization %"]` (it read 99–100% while Qwen3-8B read a prompt);
  - memory used as Activity Monitor counts it (internal pages less purgeable, plus wired and compressed).
- **Menu bar:** the label is the bird plus the busiest thing happening: "Loading…", then "Reading n%" for the longest prompt being read, then the total tokens a second, with "+n" for other requests. Nothing when idle, and `Config.menuBarActivity` turns it off. The menu repeats the line.
- **Activity… window:** a minute's GPU and CPU sparklines, memory, models, and a row per request. It floats above other windows unless "Keep on top" is unchecked.
- **With llama.cpp** (no `/slots`), only loading and the Mac's figures are shown.

**Amended 2026-09-29 (issue #133):** the Activity window now shows the Mac with the server stopped, and charts memory.
- **When it samples:** the Mac is sampled while the server runs **or** the window is open. The window's appear and disappear events count watchers, and `/slots` is still polled only while the server runs.
  - Stopping the server clears only the server's figures. The Mac's history goes on while the window is open.
  - Nothing is sampled with the window closed and the server stopped.
  - The first reading after the window opens is followed half a second later by a second, so CPU (a rate between two readings) shows at once.
- **History:** kept as timestamped readings for 15 minutes, and drawn by time rather than by index. The window shows the last 1, 5 or 15 minutes, chosen in the window and remembered between launches.
  - Before, "a minute" was 60 readings taken 1 or 2 s apart.
  - A pause of more than 10 s breaks the line rather than joining across it.
- **Memory chart:** memory is a chart like CPU and GPU, replacing the single bar.
  - The y-axis runs from 0 to the Mac's total memory, so the chart shows how full the Mac is.
  - The area is green, orange above 80% and red above 90%.
  - While the server runs, its share is drawn inside in indigo, with a matching dot in its caption.
  - All three charts share one `HistoryChart`, drawn with Canvas. Swift Charts would bring axis chrome that doesn't suit a 340 pt window.
**Amended 2026-09-30 (ADR-0067):** each request row names its client (app and machine), and a Clients section shows each client's load over the chosen window.
