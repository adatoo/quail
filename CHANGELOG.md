# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Every PR adds its entries under [Unreleased] and cuts them into its own
version's section with `task version:bump` (ADR D-024); every merge to
`main` is released as that version.

## [Unreleased]

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
