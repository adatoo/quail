# Quail — Implementation Plan

*As of 2026-09-21. Read [ARCHITECTURE.md](ARCHITECTURE.md) first; this document says what to build in what order, and how to know each step is done.*

Four phases. Each ends with something usable every day. Phase 1 is deliberately llama.cpp-only so packaging and signing are solved before any Python enters the picture.

| Phase | Delivers | Exit criterion |
| --- | --- | --- |
| 1 — Skeleton | MenuBarExtra, `Runtime` protocol, bundled llama-server, start/stop, endpoint settings, health ping, log window, open at login | A signed, notarized DMG from CI that serves a GGUF placed by hand in the store |
| 2 — Models | Unified store, HF downloader with quant picker, catalog, device-fit verdicts, hot swap via `/models/load` | First public beta: a fresh Mac goes from download to a working endpoint with no terminal |
| 3 — MLX runtimes | Bundled uv, oMLX and Rapid-MLX adapters, install/update/rollback flow, tested version ranges | Switching runtime in Settings works, and a runtime update can be rolled back |
| 4 — Polish and Store | Sparkle, import from other tools, LAN warning, App Store scheme, measured-speed calibration | App Store submission accepted; Sparkle update applied on a real machine |

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

1. **Xcode project.** macOS app target `Quail`, bundle id `com.datoos.quail`, deployment target macOS 14, Swift 6 strict concurrency, `LSUIElement = YES` (no Dock icon). Two configurations: `Debug`, `Release`; two schemes: `Quail` (Developer ID) and `Quail-AppStore` (adds `APPSTORE` compile flag and sandbox entitlements). No Swift packages yet.
2. **Vendor llama.cpp.** `scripts/vendor-llama.sh <tag>` downloads the `llama-<tag>-bin-macos-arm64.zip` release asset, checks its sha256 against `scripts/llama.sha256`, copies `llama-server` and `*.dylib` into `Vendor/llama.cpp/`, runs `install_name_tool` so every dylib is found via `@executable_path`, and ad-hoc signs for debug. An Xcode "Copy Files" phase puts them in `Contents/MacOS`. Verify: `otool -L Vendor/llama.cpp/llama-server` shows only `@executable_path` and system paths.
3. **Runtime protocol + LlamaCppRuntime.** Implement `launchSpec` (`--host --port --api-key --models-dir --log-file --no-webui` off by default so the web UI stays available), `health` via `GET /health`, `listModels` via `GET /models`, `select` via `POST /models/load`.
4. **ProcessSupervisor.** `Process` with explicit `environment`, stdin closed, stdout/stderr piped to `LogStore`. Wait for port bind by polling `/health` up to 90 s. Restart up to 3 times with 2/4/8 s back-off on unexpected exit. Kill the child on app termination (`applicationWillTerminate` and a `SIGTERM` handler).
5. **ServerController** state machine and `AppState`.
6. **Menu.** Status line, model name, Start/Stop, Test…, Logs…, Settings…, Quit. Icon states: stopped/starting/running/failed (SF Symbols with template rendering).
7. **Settings → Endpoint.** Runtime picker (only llama.cpp enabled in this phase), host, port, API key toggle (random key stored in Keychain, "copy"). "Copy base URL" button.
8. **Ping sheet.** Three rows with timings: server up (`/health`), model loaded (`/v1/models` non-empty), first token (`/v1/chat/completions` streamed, `max_tokens: 1`, time to first SSE chunk). No chat.
9. **Logs window.** Live tail of the ring buffer, level filter (parse llama-server's `level` prefix where present), Reveal in Finder, Copy last 200 lines.
10. **Open at login.** `SMAppService.mainApp.register()/unregister()`; "start server automatically" restores the last runtime and model.
11. **CI.** `release.yml` on tag: vendor, `xcodebuild archive`, `notarytool submit --wait`, staple, `create-dmg`. Secrets: Developer ID cert (p12), App Store Connect API key. Until secrets exist the workflow runs everything up to signing.

**Done when:** placing a GGUF in `~/Library/Application Support/Quail/Models/gguf/` and clicking Start yields a passing ping test, and a notarized DMG installs on a second Mac without Gatekeeper complaint.

## Phase 2 — Models

1. **ModelStore.** Create the folder layout on first run; `catalog.json` read/write; `presets.ini` generation per GGUF (context size, `n_gpu_layers 99`, sampling defaults). Store path relocatable via a security-scoped bookmark.
2. **GGUFMetadata.** Parse the header (magic, version, tensor count, KV pairs) far enough to read `general.architecture`, `<arch>.block_count`, `<arch>.attention.head_count_kv`, `<arch>.embedding_length`, `<arch>.attention.head_count`, and `general.file_type`. Unit-test against small fixture headers.
3. **MLXMetadata.** Parse `config.json` for layers, KV heads, head dim, quantization bits, MoE fields.
4. **DeviceInfo + FitEstimator.** Implement the formula in ARCHITECTURE §7; bandwidth table in `catalog.json`. Unit-test with known chips and models (e.g. 8B Q4_K_M on 16 GB → Comfortable at 8K; 32B Q4_K_M on 16 GB → Won't fit).
5. **HFDownloader.** `GET https://huggingface.co/api/models/{repo}?blobs=true` for files, sizes and LFS sha256; `resolve/main/{file}` with `Range` resume; optional bearer token from Keychain. Concurrency 1 file at a time, progress by bytes. Cancel and resume across app restarts (partial files under `Models/.partial/`).
6. **Catalog.** Ship an initial curated list (see `Resources/catalog.json` seed in this repo): 8–12 families with both GGUF and MLX variants and RAM tiers. Weekly remote refresh from a URL set in `Info.plist`; user-added repo URLs become uncurated entries.
7. **Models pane + "Add model…" sheet.** Rows per family with format badges, size, verdict per current runtime, loaded state; quant picker for GGUF; download progress; delete with confirm.
8. **Hot swap.** Selecting a GGUF while llama.cpp runs calls `POST /models/load`; `--models-max` from Settings (default 1).

**Done when:** a fresh user picks a recommended model, downloads it, and passes the ping test without touching a terminal.

## Phase 3 — MLX runtimes (direct build only)

1. **Vendor uv.** `scripts/vendor-uv.sh` fetches the pinned `uv-aarch64-apple-darwin.tar.gz`, verifies sha256, signs. Copied to `Contents/MacOS/uv`.
2. **RuntimeInstaller.** Env: `UV_TOOL_DIR`, `UV_TOOL_BIN_DIR`, `UV_PYTHON_INSTALL_DIR`, `UV_CACHE_DIR` under `Application Support/Quail/Runtimes/`. Commands: `uv python install 3.12`, `uv tool install --python 3.12 'omlx==X'`, same for `rapid-mlx`. Stream output to the log window. Write `manifest.json` (package, pinned version, previous pin, installed-at, smoke-test result).
3. **Version checks.** Daily `GET https://pypi.org/pypi/{pkg}/json`; compare with installed and with the adapter's `testedRange`. Three UI states: Up to date / Update available (tested) / Newer exists (untested).
4. **Update flow.** Install new pin → smoke test (`serve` on a random port with the smallest MLX model in the store, `/v1/models` within 60 s) → promote → keep previous pin for rollback. Rollback = reinstall previous pin from cache.
5. **OMLXRuntime.** `omlx serve --model-dir <store>/mlx --port --api-key`; health via `/v1/models`; web UI `/admin`; select = set default model, auto-load. Investigate `/admin` load/unload endpoints; use only if stable.
6. **RapidMLXRuntime.** `rapid-mlx serve <model-path> --models-dir <store>/mlx --port --api-key` with `HF_HOME=<store>/hf-cache`; health via `/readyz`; select = restart. Never call `launch` or `service`.
7. **Runtimes pane.** Per-runtime card: state, version, tested range, Install / Update / Roll back / Uninstall, "open log".
8. **Supervisor hardening.** `PYTHONUNBUFFERED=1`, `TERM=dumb`, stdin closed, 90 s bind timeout with a clear failure message.

**Done when:** all three runtimes start from Settings against the same model folder, and a deliberate bad update (pin a broken version) rolls back cleanly.

## Phase 4 — Polish and Store

1. Sparkle 2 (SPM), EdDSA key, appcast on GitHub Releases, `generate_appcast` in CI.
2. Import on first run from `~/.cache/llama.cpp`, `~/.omlx/models`, `~/.cache/huggingface/hub`, `~/.lmstudio/models` (move, not copy; never symlink).
3. LAN binding one-time warning; API key strongly suggested when host is `0.0.0.0`.
4. Measured-speed calibration: store TTFT and tok/s per (model, chip) after each ping; prefer measurements over estimates.
5. App Store scheme: sandbox entitlements, `llama-server` signed with `app-sandbox` + `inherit`, model store inside the container by default, `#if !APPSTORE` compiled out and verified by a CI grep that no uv/PyPI code survives in that binary.
6. About pane with the full version matrix (app, llama.cpp tag, uv, runtime pins, catalog revision) and Acknowledgements.

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
