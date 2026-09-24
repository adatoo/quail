# Quail — Implementation Plan

*As of 2026-09-24. Read [ARCHITECTURE.md](ARCHITECTURE.md) first; this document says what to build in what order, and how to know each step is done.*

Five phases. Each ends with something usable every day. Phase 1 is deliberately llama.cpp-only so packaging and signing are solved before any Python enters the picture. Phase 5 was added 2026-09-23 (D-016) — see its own section for why it's ordered after Phase 3.

| Phase | Delivers | Exit criterion |
| --- | --- | --- |
| 1 — Skeleton | MenuBarExtra, `Runtime` protocol, bundled llama-server, start/stop, endpoint settings, health ping, log window, open at login | A signed, notarized DMG from CI that serves a GGUF placed by hand in the store |
| 2 — Models | Unified store, HF downloader with quant picker, catalog, device-fit verdicts, hot swap via `/models/load` | First public beta: a fresh Mac goes from download to a working endpoint with no terminal |
| 3 — MLX runtimes | Bundled uv, oMLX and Rapid-MLX adapters, install/update/rollback flow, tested version ranges | Switching runtime in Settings works, and a runtime update can be rolled back |
| 4 — Polish and Store | Sparkle, import from other tools, LAN warning, App Store scheme, measured-speed calibration | App Store submission accepted; Sparkle update applied on a real machine |
| 5 — Multiple endpoints | Concurrent `ServerController`s, per-endpoint config/logs/menu row, cross-endpoint RAM accounting | Two runtimes serve concurrently on distinct ports, each ping-passes, and fit verdicts account for both |

## Project layout

```
quail/
  Quail.xcodeproj
  Quail/
    QuailApp.swift                 @main, MenuBarExtra + Settings scenes
    App/
      AppState.swift               observable root: config, server state, model store
      Config.swift                 Codable config.json + Keychain for API key/HF token
      Paths.swift                  Application Support / Logs / Models locations
    Server/
      ServerController.swift       state machine: stopped/starting/ready/stopping/failed
      ProcessSupervisor.swift      spawn, pipes, log writer, restart with back-off
      HealthProbe.swift            /health, /v1/models, 1-token streamed probe with timings
      LogStore.swift               ring buffer + file rotation
    Runtimes/
      Runtime.swift                the protocol + shared types (LaunchSpec, Health, ServedModel)
      LlamaCppRuntime.swift
      OMLXRuntime.swift            #if !APPSTORE
      RapidMLXRuntime.swift        #if !APPSTORE
      RuntimeInstaller.swift       #if !APPSTORE — uv wrapper, manifest, PyPI version check
    Models/
      ModelStore.swift             catalog.json, folder layout, presets.ini generation
      Catalog.swift                curated + remote + user entries
      HFDownloader.swift           file listing, resumable download, sha256
      GGUFMetadata.swift           header parser (enough for layers/kv heads/dim)
      MLXMetadata.swift            config.json parser
    DeviceFit/
      DeviceInfo.swift             sysctl, Metal working set, free memory, bandwidth table
      FitEstimator.swift           RAM/context/speed verdicts
    UI/
      MenuView.swift
      SettingsView.swift           tabs: General, Endpoint, Models, Runtimes, Logs, About
      ModelsPane.swift, RuntimesPane.swift, LogsPane.swift, PingSheet.swift
    Resources/
      catalog.json                 curated models + chip bandwidth table
      Assets.xcassets              menu bar icon states
  Vendor/
    llama.cpp/                     populated by scripts/vendor-llama.sh (git-ignored)
    uv/                            populated by scripts/vendor-uv.sh (git-ignored)
  scripts/
    vendor-llama.sh                fetch pinned release, verify sha256, fix @rpath, sign
    vendor-uv.sh
    sign-and-notarize.sh
    make-dmg.sh
  QuailTests/                      unit tests: GGUF parser, fit estimator, config, presets.ini
  docs/
  .github/workflows/release.yml
```

## Phase 1 — Skeleton

Goal: a menu bar app that runs the bundled `llama-server` against a folder and tells you it's alive.

- [x] 1. **Xcode project.** macOS app target `Quail`, bundle id `com.datoos.quail`, deployment target macOS 14, Swift 6 strict concurrency, `LSUIElement = YES` (no Dock icon). Four build configurations (`Debug`, `Release`, `Debug-AppStore`, `Release-AppStore` — the AppStore pair carries the `APPSTORE` compile condition and a separate entitlements file) mapped onto two schemes: `Quail` (Developer ID) and `Quail-AppStore`. No Swift packages yet. Generated from `project.yml` via XcodeGen and committed as `Quail.xcodeproj`; see ADR D-008.
- [x] 2. **Vendor llama.cpp.** `scripts/vendor-llama.sh <tag>` downloads the `llama-<tag>-bin-macos-arm64.tar.gz` release asset, checks its sha256 against `scripts/llama.sha256`, and copies `llama-server` plus the full `@rpath` dependency closure (computed by walking `otool -L` recursively, not a hardcoded list) into `Vendor/llama.cpp/`. No `install_name_tool` rewriting is needed — every binary already ships with an `@loader_path` `LC_RPATH` and `@rpath/<name>` install names, so co-locating the closure is sufficient. `scripts/verify-macho.sh` checks the result, then everything is ad-hoc signed for local runs. An Xcode "Embed llama.cpp" run-script build phase (`scripts/embed-llama.sh`) copies and (re-)signs the same files into `Contents/MacOS` on every build, using the project's resolved signing identity. Verify: `otool -L Vendor/llama.cpp/llama-server` shows only `@rpath` and system paths (`scripts/verify-macho.sh` automates this). See ADR D-009.
- [x] 3. **Runtime protocol + LlamaCppRuntime.** Implement `launchSpec` (`--host --port --api-key --models-dir --log-file --no-webui` off by default so the web UI stays available), `health` via `GET /health`, `listModels` via `GET /models`, `select` via `POST /models/load`.
- [x] 4. **ProcessSupervisor.** `Process` with explicit `environment`, stdin closed, stdout/stderr piped to `LogStore`. Wait for port bind by polling `/health` up to 90 s. Restart up to 3 times with 2/4/8 s back-off on unexpected exit. Kill the child on app termination (`applicationShouldTerminate` and a `SIGTERM` handler — `AppDelegate.swift`, added in PR 7 once real testing showed quitting Quail left `llama-server` running as an orphan; `NSApplication.terminate()` alone sends nothing to a spawned `Process`). **Notes:** (1) router-mode `llama-server` forks a child process per loaded model, but a plain `SIGTERM` to the *router's* PID only is sufficient — tested against a real model load: the router's own shutdown handler logs "cleaning up before exit… stopping model instance… exit command received" and the child exits cleanly on its own before the router does. No process-group kill needed (an earlier note here, written before this was tested, claimed otherwise — see the correction in ADR D-009). (2) the very first launch of a freshly (re-)signed `llama-server` binary took ~16 s to reach "listening" in local testing (subsequent launches of the same signed binary were ~1 s) — almost certainly one-time AMFI/Gatekeeper validation of the new code signature. The 90 s bind timeout already covers this; don't tighten it without re-testing a freshly-signed binary.
- [x] 5. **ServerController** state machine. (`AppState` wiring lands in PR 6 with the menu/settings UI.)
- [x] 6. **Menu.** Status line, Start/Stop, Settings…, Quit. Icon states: stopped/starting/running/failed (SF Symbols). Model name, Test… and Logs… land with steps 8–9 (they need the ping sheet/log window to open). Note: `Config.swift` and `Keychain.swift` (this step's "later PR" in step 5's note) landed here too, since the menu needs real settings to drive `ServerController.start(config:)`.
- [x] 7. **Settings → Endpoint.** Runtime picker (only llama.cpp enabled in this phase — disabled, since there's nothing to switch to yet), host, port, API key toggle (random key stored in Keychain, "copy"). "Copy base URL" button.
- [x] 8. **Ping sheet.** Three rows with timings: server up (`/health`), model loaded (`/models` non-empty), first token (`/v1/chat/completions` streamed, `max_tokens: 1`, time to first SSE chunk). No chat. Opened as its own `Window` scene, not a `.sheet` presented from the `MenuBarExtra` — see `PingSheet.swift`. Two things only found by testing against a real b11081 build: router mode lists a never-used model as `"unloaded"`, not `"loaded"`, so "model loaded" checks list non-emptiness (matching this step's own wording above) rather than filtering by status; and `/v1/chat/completions` 400s with "model name is missing from the request" without an explicit `"model"` field, so the first-token step uses the id `listModels` returned.
- [x] 9. **Logs window.** Live tail of the ring buffer (polling `LogStore.recentLines` twice a second — no publisher, per AGENTS.md's "No Combine"), level filter, Reveal in Finder, Copy last 200 lines.
- [x] 10. **Open at login.** `SMAppService.mainApp.register()/unregister()` via `LoginItem.swift`. "start server automatically" (`Config.autoStartServer`) is stored but not yet wired to anything — there's no app-launch-time auto-start call yet; that belongs with step 8/9's PR once there's a model to auto-start with.
- [x] 11. **CI.** `release.yml` on a `v*` tag push: vendor, `xcodebuild archive` + `-exportArchive` (Developer ID, reusing the same identity `lookout` already uses — same Apple Developer account), `notarytool submit --wait`, staple, `create-dmg`, GitHub Release. The actual sign/export/notarize/staple logic lives in `scripts/sign-and-notarize.sh`/`scripts/make-dmg.sh`, shared with the local dev entry point `scripts/install.sh` — not duplicated CI-only logic. CI-specific: importing the cert into a dedicated build keychain (`.github/workflows/release.yml`'s own step, copied from the `documail` project's own release workflow). Secrets: `APPLE_DEVELOPER_ID_APPLICATION_CERT_P12`/`_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD` — see ADR D-018. App Store Connect submission is a separate, not-yet-built path (Phase 4).

**Done when:** placing a GGUF in `~/Library/Application Support/Quail/Models/gguf/` and clicking Start yields a passing ping test, and a notarized DMG installs on a second Mac without Gatekeeper complaint.

## Phase 2 — Models

- [x] 1. **ModelStore.** Create the folder layout on first run (`ensureDirectoriesExist`, called from `AppState.start()` on every Start, not just first run); `catalog.json` read/write; `presets.ini` regenerated from whatever `.gguf` files are actually on disk (not from the catalog, so a hand-placed model still gets one) every time `start()` runs. Store path relocatable via a security-scoped bookmark — `Paths.resolveModelsDirectory`/`makeModelsDirectoryBookmark` are the mechanism; nothing calls `makeModelsDirectoryBookmark` yet since that needs step 7's open panel. **Found only by testing against the real binary:** `--models-preset`'s INI keys are the CLI flag's own name — `n-gpu-layers` (dashes), not `n_gpu_layers` (underscores); the latter fails the router at startup with "option 'n_gpu_layers' not recognized in preset". Sampling defaults (temperature, top-p, ...) aren't written to `presets.ini` — llama-server has its own, and there's no Settings surface yet to override them; writing arbitrary numbers with no UI behind them would be guessing, not a decision.
- [x] 2. **GGUFMetadata.** Parses the header (magic, version, tensor count, KV pairs) far enough to read `general.architecture`, `<arch>.block_count`, `<arch>.attention.head_count_kv`, `<arch>.embedding_length`, `<arch>.attention.head_count`, and `general.file_type`. The file is memory-mapped so this is cheap regardless of the model's on-disk size — tensor data is never touched, and unwanted metadata values (including a full tokenizer vocab array) are skipped by advancing past their byte length, never decoded. `general.file_type` is kept as the raw `ggml_ftype` int; turning it into a human quant label like "Q4_K_M" is left to whatever displays it. Unit-tested against synthetic fixture headers built by a small GGUF writer in the test file itself (no real `.gguf` committed to the repo) — covers a realistic header, out-of-order `general.architecture`, a per-layer `head_count_kv` array (takes the first element), wrong-architecture keys being ignored, missing keys, missing `general.architecture` entirely, bad magic, unsupported version, and a truncated file.
- [x] 3. **MLXMetadata.** Parses `config.json` (the HuggingFace-`transformers`-style file `mlx-lm`'s converter writes) for layers (`num_hidden_layers`), KV heads (`num_key_value_heads`), head dim, quantization bits/group size (`quantization`, falling back to `quantization_config`), and the two MoE fields (`num_experts_per_tok`, `num_local_experts`). `head_dim` prefers the config's own explicit field over `hidden_size / num_attention_heads` — confirmed against a real repo (mlx-community's Gemma 2 9B: 3584/16=224 computed, but its real head_dim is 256) that the two aren't interchangeable. Unit-tested against real `config.json` bodies fetched from mlx-community's Qwen2.5-7B-Instruct-4bit (dense, computed head_dim), Mixtral-8x7B-Instruct-v0.1-4bit (MoE fields), and gemma-2-9b-it-4bit (explicit head_dim), plus synthetic cases for `quantization_config` fallback, unquantized models, missing/zero-division-guarded fields, and malformed JSON.
- [x] 4. **DeviceInfo + FitEstimator.** `DeviceInfo.current()` reads `machdep.cpu.brand_string`/`hw.memsize`/`hw.perflevel0.physicalcpu` via `sysctlbyname`, `MTLDevice.recommendedMaxWorkingSetSize` for the GPU ceiling, and `host_statistics64` for free+inactive+purgeable memory. `FitEstimator` implements ARCHITECTURE §7's formula as pure functions over a format-agnostic `ModelShape` (built from either `GGUFMetadata` or `MLXMetadata` plus a file size) — verdicts (`.comfortable`, `.tight(reducedContextSize:)`, `.wontFit`) and the `0.7 × bandwidth / active_bytes` speed estimate, with per-runtime overhead (~1.5 GB llama.cpp, ~2.5 GB Python, confirmed against ARCHITECTURE §7's own figures). `ChipBandwidthTable` loads the `chipBandwidthGBps` table already seeded in `Resources/catalog.json` (decoding only that one key — the full curated-catalog schema is step 6's `Catalog.swift` to parse). **Found while implementing:** GGUF also carries `<arch>.attention.key_length`/`value_length` (confirmed present in the vendored llama.cpp binary's own string table) and `<arch>.expert_count`/`expert_used_count` — added to `GGUFMetadata` in this PR, since without them GGUF's head dim would have the same "not always `embedding_length / head_count`" bug MLX's `head_dim` has, and GGUF MoE models would get no speed estimate at all. Unit-tested with fabricated `DeviceInfo`/`ModelShape` values against the plan's own two scenarios (8B Q4_K_M on 16 GB → Comfortable at 8K; 32B Q4_K_M on 16 GB → Won't fit) plus Tight/reduced-context, per-runtime overhead changing the verdict, MoE vs dense speed, and unknown-chip → no speed estimate. This is also what should eventually start setting `InstalledModel.contextSize` (`StoreCatalog.swift`) to something other than `ModelStore`'s fixed 8,192 default — now wired: `ModelStore.refreshedCatalog` (step 7 plumbing PR) runs `FitEstimator` against every installed model on each Start and persists the `.tight` reduced context into `catalog.json`, which `regeneratePresets` then writes into `presets.ini`; `.comfortable`/`.wontFit` deliberately leave the override `nil` (see that method's doc comment).
- [x] 5. **HFDownloader.** `HFDownloader` actor: `GET /api/models/{repo}?blobs=true` for files, sizes and LFS sha256; `resolve/main/{file}` with `Range` resume via in-process `URLSession.bytes(for:)` streaming (see ADR D-015 for why not a background session); bearer token from Keychain (`AppState.hfToken`, no Settings UI yet — lands with step 7). One file at a time, progress by bytes via `AsyncStream<HFDownloadEvent>`. Cancel and resume across restarts: partial bytes + JSON sidecar under `Models/.partial/<owner--repo>/`, signed CDN URL never persisted (re-request `resolve` fresh). Verified incrementally as bytes land (existing prefix re-hashed on resume); size-only when no `lfs.sha256` exists (confirmed real for most MLX-repo files); corrupt partials deleted, never resumed. Atomic install: nothing appears in the destination until every file verifies. `rfilename` subdirectories flattened to basename. Unit-tested hermetically via shared `StubURLProtocol` (now with real redirect simulation) plus a manual real-Hub smoke test that doubles as `LlamaCppIntegrationSmokeTest` fixture setup.
- [x] 6. **Catalog.** `Catalog.swift` decodes the seed's full schema (families with GGUF/MLX variants, RAM tiers, chip bandwidth) — the download list, a different type from the store's own installed-models `StoreCatalog`. **All 11 seed families were verified against the live Hub API before shipping**: every repo id resolves, every quant label matches a real filename case-insensitively (which is why matching must be case-insensitive: `gpt-oss-20b-GGUF`'s "mxfp4" is `gpt-oss-20b-MXFP4.gguf`, and unsloth prefixes files with the repo name), and the Gemma vision families' `mmproj-F16.gguf` exists. A `CatalogTests` case re-checks that shipped file's self-consistency (default quant ∈ quants, ≥1 variant per family) on every test run. Weekly remote refresh: `CatalogRefresher` fetches the `QuailCatalogURL` `Info.plist` key (deliberately unset — no update host until Phase 4; the mechanism is built and stub-tested now so that's one plist key later), accepting a document only at revision ≥ max(bundled, cached), never letting a bad fetch degrade `Catalog.current()` below the bundled seed, and not updating `fetchedAt` on failure so the next launch retries. User-added repos: `user-catalog.json` via `AppState.addUserCatalogRepo`/`removeUserCatalogRepo`, merged as uncurated families (no params/rank/role — unknown), de-duplicated against curated variants, format optionally resolved by step 7's add-sheet. Refresh is checked at app launch (long-running menu-bar agents refresh at their restart cadence) — revisit with a timer only if that proves too rare.
- [x] 7. **Models pane + "Add model…" sheet.** Split into two PRs: the plumbing first (`ModelInstallController` + disk-driven `ModelStore.refreshedCatalog`, PR 17), then the UI — a Models tab in Settings with installed rows (format badge, size, live-computed fit verdict, loaded-state badges from the running router's `/models`), the All/GGUF/MLX filter the user asked for, delete with confirm (file + companions + row + preset section, in one action), `Relocate…` → `NSOpenPanel` → move + bookmark + persist (where `Paths.makeModelsDirectoryBookmark` finally gets called; `.partial` deliberately stays behind at the old root), the HF-token field `setHFToken`/`clearHFToken` have existed for since PR 15, and an "Add model…" sheet: curated families (or a pasted repo), format switch, quant picker (labels matched case-insensitively against real filenames with a separator boundary — `IQ8_0` must not answer to "Q8_0", confirmed against a real listing; `mxfp4`→`MXFP4` must), sharded quants resolving to all their parts, and a pre-download fit verdict via `ModelPreview.remote` — one ranged header fetch plus the listing's size, per ARCHITECTURE §7. `ModelAddPlan` keeps every filename decision in pure, unit-tested code; the views only sequence it. NOTE: interactive GUI pass pending (display was locked at build time; logic is unit-covered, app launch + Settings scene verified not to crash).
- [x] 8. **Hot swap.** `AppState.selectModel(id:)`: guards on server-running, installed, and GGUF-format (MLX rows say "needs MLX runtime (Phase 3)" rather than offering a button that must fail), then calls the `Runtime.select` path already verified against a real b11081 router in PR 7; the Models pane puts a small Load button on not-yet-loaded GGUF rows while the server is up and polls the router's own status for ~20s so the badge flips loading→loaded on its own. "Max loaded models" is a 1–8 stepper in the Endpoint pane (`setModelsMax`, persisted; applies next Start — it's a launch flag) with the honest subtext that every loaded model keeps its weights in RAM; default stays 1 per D-011.
- [x] 9. **Recommendations + This Mac.** `Recommender` + `AppState.loadCatalogVerdicts()` (every catalog family gets a live pre-download verdict, or a stated reason — `RemoteFit`); the Add-model sheet shows "Recommended for this Mac" — the top 5 families that run *Comfortable* here, any size, ordered by catalog rank then estimated speed (ADR D-019; originally gated by RAM tier, which hid comfortable 27–31B models on a 64 GB Mac). `AppState.canStart`/`hasServableModel` refuse Start with no installed GGUF. A "This Mac" Settings tab shows the device facts `FitEstimator` reads, GPU core count (IOKit `IOAccelerator` matching), and a model-size estimate from the measured GPU ceiling (`FitEstimator.approxMaxParamsB`).
- [x] 10. **Default model.** A star toggle on each installed GGUF row in the Models pane sets `Config.defaultModelID`; `ModelStore.regeneratePresets` writes `load-on-startup = true` into that one preset section (ADR D-017 — verified live against the real vendored binary, not just from its `--help`/strings). Usable while the server is stopped, unlike Load; cleared automatically if that model is deleted. Also fixed along the way (found via live testing, not part of this step's own scope but landed in the same pass): `project.yml`'s resources wiring, which meant `catalog.json` (and the app icon) never actually shipped in any build; the Add-model sheet had no Cancel button outside the downloading/installed states; and `ServerController` used to keep claiming `.ready` through a supervisor auto-restart instead of re-verifying `/health`, which is what made a Ping's "server up" step fail while the menu still said "Running".

**Done when:** a fresh user picks a recommended model, downloads it, and passes the ping test without touching a terminal.

## Phase 2b — Using the endpoint

Making the running endpoint easy to *use*, not just run. Everything talks to the endpoint over HTTP (OpenAI- and Anthropic-compatible routes), so it works unchanged when Phase 3 adds runtimes. Confirmed against the vendored b11081 `llama-server`: it serves `/v1/chat/completions`, `/v1/responses`, `/v1/messages` (Anthropic) and reports its own `prompt_per_second`/`predicted_per_second` timings.

1. **Connect.** A Settings tab listing coding tools, editors, chat apps and SDKs (Claude Code, Codex CLI, Continue, Cline/Roo, Zed, aider, opencode, Goose, Open WebUI, LibreChat, curl/Python/JS), defined as data in `Resources/integrations.json`. Each shows a copy-ready config snippet filled with this endpoint's base URL, API key and a chosen model, where it goes, a docs link, and a Test button. Copy-only — Quail never edits other apps' config files (and can't, sandboxed). Every snippet verified against the tool's current docs, not memory.
2. **Try (browser)** ✅. "Open Chat in Browser" in the menu opens the runtime's built-in web UI (`Runtime.webUIURL`) — D-001's own "link to them". A runtime with no web UI (`webUIURL` is `nil`) gets "Copy Terminal Chat Command" in the same slot — `quail run [model]` onto the clipboard (`ChatEntry`) — rather than an item that does nothing.
3. ~~**Try (native)**~~ — dropped: `quail run` (D-021) and the runtime's own web UI (step 2) cover "get a feel for a model"; revisit only if users ask for an in-app chat.
4. **Benchmark** ✅ (ADR D-023). A fixed, versioned suite (`quail-bench-1`, `Benchmark/BenchmarkSuite.swift`): load time (timed after an untimed load, so from the page cache), prompt processing at 512/4096 tokens (4096 skipped when the context is smaller), generation over 256 tokens (`ignore_eos`, temperature 0, seed 42, `cache_prompt: false`), TTFT on the 512 prompt; 1 warm-up + 3 runs, median/min/max. Prompts are sent as token ids built from `/tokenize`, so lengths are exact; speeds are the server's own `timings`. Each `BenchmarkResult` (`Shared/`, schema v1 — the future sharing format) records hardware, model (id, repo, quant, size, sha256, params, architecture), engine (llama.cpp build, ctx, slots, Quail version), conditions (thermal state, Low Power Mode, battery, other loaded models) and the estimate it's compared with. Whatever was loaded before is loaded again afterwards. Stored in `benchmarks.json`; a Benchmark window (menu, or a Models row's context menu) with compare, Copy as Markdown and Export JSON; `quail bench [model] [--json] [--history]`. The Models tab shows the measured generation speed per model (Phase 4 step 4, for installed models; the Add Model sheet still estimates).
5. **`quail` CLI** (ADRs D-021, D-022) — "like ollama": a thin client of the running app over a Unix control socket (`Shared/ControlProtocol.swift`, mode 0600), shipped at `Quail.app/Contents/Helpers/quail` (direct build only) and linked into `~/.local/bin` from Settings → General. v1: `start`/`stop`/`restart`/`status`, `list`/`ps`, `run <model> [prompt]` (terminal chat — D-021), `launch <tool>` (Claude Code, Codex, aider, Goose started pointed at Quail from `integrations.json`'s launch recipes — env vars, args and temp files, never the tool's own config), `logs [-f]`, `service enable|disable` (open at login + start the server automatically — wires the long-dormant `autoStartServer`). `bench` ✅ with step 4. v2 ✅: `pull <name|owner/repo>[:quant]` (catalog names like ollama's, any HF GGUF repo, progress bar, Ctrl-C cancels and a re-run resumes; `--list` shows the catalog with recommendations and what's installed), `rm`, `default [model|--clear]`, `ctx <model> [size|auto]` (with each size's fit), `config` (endpoint, key masked unless `--show-key`, store, logs, settings), `--version`.
6. **Benchmark sharing** — a separate project with its own backend (and ADR); the app only ships the result schema and export until then.

**Done when:** a user can copy a working config for Claude Code and one OpenAI-compatible tool, open a chat against their model, and benchmark a model with results comparable across machines.

## Phase 3 — MLX runtimes

Four MLX adapters, not one — see ADR D-014. Steps 1–3 are the native Swift server Quail builds and ships itself (works in **both** builds, App Store included, since there's no Python involved); steps 4–10 are the two uv-installed Python runtimes (**direct build only**, per D-006 — the sandbox forbids downloading executable code).

1. **MLXServer target.** New executable target (e.g. `Quail/MLXServer/`, `mlx-server` binary) linking `mlx-swift-lm` + `mlx-swift` via SwiftPM — the first dependency beyond Sparkle; needs its own ADR alongside AGENTS.md's rule update when this starts. `--host` (default `127.0.0.1`), `--port`, `--api-key`, `--models-dir <store>/mlx`.
2. **MLXServerRuntime.** `Runtime` adapter mimicking llama-server's router shape: `GET /v1/models` returning `status.value`-style entries, `POST /models/load` for hot swap where feasible (MLX model swap cost differs from GGUF's — measure before assuming parity). `/v1/chat/completions` with SSE streaming, reusing `Ping`'s existing timing.
3. **CI build + signing.** Compiling `mlx-swift`'s Metal shaders needs `xcodebuild`, not plain SwiftPM (already true for the whole project). Vendor nothing — this target is source, built and signed by Quail's own pipeline every release, unlike `llama-server`.
4. **Vendor uv.** `scripts/vendor-uv.sh` fetches the pinned `uv-aarch64-apple-darwin.tar.gz`, verifies sha256, signs. Copied to `Contents/MacOS/uv`.
5. **RuntimeInstaller.** Env: `UV_TOOL_DIR`, `UV_TOOL_BIN_DIR`, `UV_PYTHON_INSTALL_DIR`, `UV_CACHE_DIR` under `Application Support/Quail/Runtimes/`. Commands: `uv python install 3.12`, `uv tool install --python 3.12 'omlx==X'`, same for `rapid-mlx`. Stream output to the log window. Write `manifest.json` (package, pinned version, previous pin, installed-at, smoke-test result).
6. **Version checks.** Daily `GET https://pypi.org/pypi/{pkg}/json`; compare with installed and with the adapter's `testedRange`. Three UI states: Up to date / Update available (tested) / Newer exists (untested).
7. **Update flow.** Install new pin → smoke test (`serve` on a random port with the smallest MLX model in the store, `/v1/models` within 60 s) → promote → keep previous pin for rollback. Rollback = reinstall previous pin from cache.
8. **OMLXRuntime.** `omlx serve --model-dir <store>/mlx --port --api-key`; health via `/v1/models`; web UI `/admin`; select = set default model, auto-load. Investigate `/admin` load/unload endpoints; use only if stable.
9. **RapidMLXRuntime.** `rapid-mlx serve <model-path> --models-dir <store>/mlx --port --api-key` with `HF_HOME=<store>/hf-cache`; health via `/readyz`; select = restart. Never call `launch` or `service`.
10. **Runtimes pane.** Per-runtime card: state, version, tested range, Install / Update / Roll back / Uninstall, "open log".
11. **Supervisor hardening.** `PYTHONUNBUFFERED=1`, `TERM=dumb`, stdin closed, 90 s bind timeout with a clear failure message.
12. **Cross-runtime benchmark.** Run Phase 2b's benchmark suite per runtime — extending it into a real comparison across all MLX adapters present (same model, same chip) — measured TTFT and tok/s per (model, chip, runtime), per ARCHITECTURE §7's calibration story. Decides which MLX runtime the picker recommends by default; not assumed up front.

**Done when:** all four runtimes start from Settings against the same model folder, a deliberate bad Python-runtime update (pin a broken version) rolls back cleanly, and the benchmark has an answer for which MLX runtime is fastest on at least one real machine.

## Phase 4 — Polish and Store

1. Sparkle 2 (SPM), EdDSA key, appcast on GitHub Releases, `generate_appcast` in CI.
2. Import on first run from `~/.cache/llama.cpp`, `~/.omlx/models`, `~/.cache/huggingface/hub`, `~/.lmstudio/models` (move, not copy; never symlink).
3. LAN binding one-time warning; API key strongly suggested when host is `0.0.0.0`.
4. Measured-speed calibration: store TTFT and tok/s per (model, chip) — delivered by Phase 2b's benchmark, shown on installed models; still to do: feed measurements back into estimates for models not yet benchmarked (e.g. a per-chip correction factor).
5. App Store scheme: sandbox entitlements, `llama-server` signed with `app-sandbox` + `inherit`, model store inside the container by default, `#if !APPSTORE` compiled out and verified by a CI grep that no uv/PyPI code survives in that binary.
6. About pane with the full version matrix (app, llama.cpp tag, uv, runtime pins, catalog revision) and Acknowledgements.

## Phase 5 — Multiple endpoints

See ADR D-016 for why this is its own phase, ordered after Phase 3: a second concurrent *endpoint* is a distinct feature from router mode's existing multi-*model* support (`modelsMax`), and is only worth the design cost once there's more than one runtime to spread across endpoints.

1. **Plural server state.** `AppState.serverController: ServerController` becomes a collection keyed by an `EndpointID`; `Config.endpoints: [EndpointConfig]` replaces the single host/port/API-key/runtime fields, with a migration that turns an existing `config.json`'s single endpoint into a one-element array.
2. **Port-collision validation.** Two endpoints on the same host:port is refused in Settings before Start, not discovered as a bind failure.
3. **Per-endpoint logs.** `LogStore`/`Paths.logFile(for:)` keyed by endpoint, not just runtime — two llama.cpp endpoints need two log files.
4. **Menu.** One status row per endpoint (name, status dot, Start/Stop), replacing the single status line.
5. **Cross-endpoint RAM accounting.** `FitEstimator`'s verdicts subtract what every *other* running endpoint's loaded models already hold from the GPU working-set ceiling — today's estimate implicitly assumes Quail is the only thing using it.
6. **Settings.** An Endpoints list (add/remove/reorder) replacing today's single Endpoint pane.

**Done when:** two runtimes serve concurrently on distinct ports, each passes its own ping test, and a fit verdict for a third model correctly accounts for RAM both running endpoints' loaded models already hold.

## Loose ends

Found while reviewing the project on 2026-09-24; not part of any phase.

- [x] **Run Benchmark gave no immediate feedback.** The machine facts were gathered before the run counted as running, so the button stayed live and nothing changed on screen. `BenchmarkController.execute` now claims the run on the click ("Preparing…"), the window shows a spinner, elapsed time and a **Cancel** button, and a cancelled run saves nothing and still restores the models that were loaded (`BenchmarkRunner` restores in a task of its own).
- [x] **Compare didn't say which run is the baseline.** Two selected runs are now compared as "other, against baseline": the older run by default, tagged "Baseline" in the table, with a swap button and "Set as Baseline" in the row menu; each cell reads "1.23× faster" or "19% slower" (`BenchmarkComparison`).
- [x] **Open Chat on runtimes without a web UI.** See Phase 2b step 2. **Phase 3 must set `webUIURL` per adapter:** Quail's own `mlx-server` and Rapid-MLX have none (→ `nil`); oMLX's `/admin` manages models rather than chatting, so it likely stays `nil` too — decide with step 2 (`MLXServerRuntime`), and write an ADR if Quail ever serves a chat page of its own.
- [x] **Interactive GUI pass** (2026-09-24, Debug build, real server). Models pane (filters, empty MLX state, loaded/default/fit badges) and Add-model sheet (recommendations, verdicts, installed state, download progress, Cancel Download) work; the benchmark changes above were driven live (Preparing → progress → Cancel restores the loaded model; baseline default, swap button and row-menu swap). Fixed along the way: the Baseline tag was unreadable on a selected row, Cancel read as a red error, and the MLX filter's empty state recommended a GGUF quant. Left over: long model ids truncate in the Models list ("Qwen3…4_K_M" — two ids can collide), and the Add-model sheet is wider than its Settings window.
- [ ] **Signing and release.** A local sign/notarize script and a full CI release pipeline, reusing `lookout`'s Developer ID certificate and notary API key. What's left of Phase 1's exit criterion: a notarized DMG that installs on a second Mac.
- [ ] **Dependabot PR #29** — `softprops/action-gh-release` 2 → 3. Read its release notes against `release.yml`, then merge.

## Build and verify loop

- Build: `xcodebuild -scheme Quail -configuration Debug build`. Tests: `xcodebuild -scheme Quail test`.
- Smoke: launch the built app, put a small GGUF (e.g. `Qwen3-0.6B-Q8_0.gguf`, ~600 MB) in the store, Start, run Ping. Ping must pass in under 30 s on an M-series Mac.
- Vendor check: `otool -L` on every Mach-O in `Contents/MacOS` shows no absolute Homebrew or build-machine paths.
- Signing check: `codesign --verify --deep --strict --verbose=2 Quail.app` and `spctl --assess --type execute Quail.app` on a Release build.
- Every PR keeps unit tests green for `GGUFMetadata`, `FitEstimator`, `Config`, `presets.ini` generation, and the `ServerController` state machine (using a fake `Runtime`).

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| llama.cpp release layout changes (asset names, dylib set) | Vendor script pins a tag and a sha256; bumping is a deliberate PR |
| oMLX / Rapid-MLX CLI flags change | Tested version ranges per adapter; untested versions launch with a warning, never silently |
| Python runtime hangs without a TTY | Supervisor closes stdin, sets `TERM=dumb`, 90 s bind timeout; reproduce before each pinned bump |
| Notarization rejects a dylib | Sign inside-out with hardened runtime; CI runs `codesign --verify --strict` before submit |
| Model RAM estimate wrong | Verdicts use a 70% ceiling and reduce context before refusing; measured runs overwrite estimates |
| HF rate limits / gated repos | Token support; downloads are one file at a time with resume |

## First session with Claude Code (suggested order)

1. Create the Xcode project and the folder layout above; commit.
2. `scripts/vendor-llama.sh` against the current llama.cpp release; confirm `otool -L`.
3. `Runtime.swift`, `LlamaCppRuntime.swift`, `ProcessSupervisor.swift`, `ServerController.swift` with a fake-runtime unit test for the state machine.
4. Minimal `MenuView` with Start/Stop and a status dot; run it against a hand-placed GGUF.
5. Ping sheet. Stop there and review.
