# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Phase 2 progress (see docs/IMPLEMENTATION_PLAN.md), not yet a tagged release:

### Added

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

### Fixed

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
