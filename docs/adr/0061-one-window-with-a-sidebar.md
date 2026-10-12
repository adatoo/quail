# ADR-0061: One Quail window with a sidebar, instead of six Settings tabs

**Date:** 2026-09-28 · **Status:** Accepted

**Situation:** Settings had six tabs holding three kinds of thing:
- preferences (General, Endpoint)
- the app's work surfaces (Models, Connect, Benchmark)
- a page of facts (This Mac)

The server's settings were spread over three of them:
- auto-start and keep-awake under General
- runtime, host, port, API key and "Max loaded models" under Endpoint, in a section that was also called "Models"
- the default model and context size in Models

Settings had no server status and no Start/Stop, though Endpoint's runtime picker said to stop the server. The owner found they had to think several times to work out where anything was.

**Decision:** Settings becomes one resizable `Window("Quail", id: "main")` with a sidebar. The pages are Server, Models, Connect and Benchmark, then a gap, then General and About.
- **Server** takes everything about the server. It is today's Endpoint, plus "Start the server when Quail opens" and the Power section, which leave General; "Max loaded models" becomes "Models loaded at once" under Memory.
- **General** is Quail itself: open at login, menu bar activity, the `quail` command and updates.
- **About** is now a page of its own, amending ADR-0029: versions, licences, and the This Mac facts. It has one Copy Details for a bug report, covering both Quail and this Mac. The This Mac tab is gone.
- **Scene:** a `Window` scene rather than `Settings`. The window now shows live state, runs tests and benchmarks, and can be resized, so pages fill it and scroll. The old window sized itself to each tab, with a minimum height per pane and a fixed height for Connect. Removing that cleared those workarounds.
- **The menu:** "Open Quail" (⌘,) opens the window on the page it last showed, the Server page the first time. The window also takes ⌘, while it's key, through `CommandGroup(replacing: .appSettings)`. Add model…, Benchmark… and Connect a Tool… open it at their page (`AppState.mainPage`, which replaced `settingsTab`).
- **Messages** from the app and the CLI say "Quail → Server" or "Quail → Models" where they said "Settings → Endpoint" or "Settings → Models". The CLI's suggest a `quail` command first.
- **Windows:** `opensInFront(id:)` registers each window under its scene id, so `bringToFront(id:)` fronts the one asked for rather than the newest visible window. Windows are no longer restorable, so they don't reappear by themselves after a relaunch; `Settings` never did.

**Alternatives:**
- **A main window plus a slimmer Settings window.** This is closer to the Mac convention, but you'd still have to know which window holds what.
- **Keeping the tabs and regrouping.** This was the least work, but it leaves preferences and tools mixed in "Settings".

**Follow-ups, in order (docs/IMPLEMENTATION_PLAN.md, Road to 1.0):**
1. The Server page proper: status and Start/Stop; usable addresses instead of `0.0.0.0`; a This Mac / Local network / Custom choice instead of a free-text host; a restart banner.
2. Per-model settings in a popover instead of a small "ctx" menu.
3. "Learn more" links to the website instead of long captions.

**Checked:**
- snapshots of every page, rendered in the window, and the sidebar alone (inside the split view, offscreen rendering leaves the sidebar blank)
- unit tests

**Revisit if:** Phase 5's multiple endpoints need a list of servers: the Server page is written over one controller and config so it can sit under one.

**Amended 2026-09-28 (the Server page):**
- **Status at the top:** the server's state and what's loaded, with Start, Stop and Test…. When it failed, the reason and Show Logs. With no model, Add Model….
  - A line with Restart appears when a restart is needed: `AppState.restartReason`, for changed models as before, or for a changed address, port, key or models-at-once. That is `endpointChangedSinceStart`, which compares `ServerController.launchedConfig` with what Start would use.
  - The menu shows the same line.
- **Address shows addresses a client can use,** never `0.0.0.0`. "On this Mac" is loopback when listening everywhere. "From other devices" is this Mac's network address, and appears only when other devices can connect.
  - Both show the launched address while the server runs, and otherwise what Start will use: `AppState.localBaseURL` no longer keeps the last run's address after a stop.
  - The API key is masked, with Show (where it can be edited, saved on Return), Copy, and New Key… behind a confirmation.
- **"Reachable from: This Mac only | Local network | Custom" replaces the free-text Host** (`EndpointAddress.Reach`).
  - The first two write `127.0.0.1` and `0.0.0.0`.
  - Custom takes an address, saved on Return or Save; the old field saved on every keystroke, so its warnings flipped as you typed.
  - A host from an older config that is neither loopback nor wildcard shows as Custom, unchanged, so there is no migration.
  - The exposure warnings (ADR-0039) sit under it. Start from the page gives the same one-time warning as the menu (`ServerActions`).

**Amended 2026-09-28 (model settings):**
- Each Models row's context size and KV cache used to sit behind a small "8K ctx ⌄" menu, and the default model was a star explained only in a tooltip. They now open a **settings popover**, from a sliders button on the row, from the row's "8K context · 8-bit KV" text, or from Model Settings… in its right-click menu.
- **The popover holds:**
  - the id to copy (what a client sends as `"model"`)
  - Context size and KV cache, each option labelled with its fit
  - "Load when the server starts" (the star)
  - Benchmark… and Delete…

  It's a popover rather than an inspector: an inspector would take about 250 pt from every page, and Form rows have no selection.
- **A "This Mac: Apple M4 Pro · 64 GB · comfortable up to ~55B" line** heads the page, with Details for the About page. It is `DeviceInfo.summaryLine`, shared with the Add Model sheet.
- **Add Model:** every "Add Model…" outside the page (the menu, the Server page, Connect, Benchmark) opens the sheet itself, through `AppState.addModelRequested`.


**Amended 2026-09-28 (links to the website, ADR-0062):**
- **`Website`** holds every link out of the app. The website's address is `Info.plist`'s `QuailWebsiteURL` (from `project.yml`), so a new domain is a one-line change. It is empty until the site is published, and empty hides every website link.
- **"Learn more"** (`LearnMoreLink`) now sits beside captions cut to one line, pointing at the matching docs section:
  - the address and key, and the network (Server page)
  - power, and the lid-closed option
  - the `quail` command (General)
  - the benchmark suite
  - a model's settings
- **The menu** gains Quail Help: the docs, or the README without a website.
- **About** gains:
  - links: Release Notes, Report an Issue, Source Code, plus Website and Documentation when there is a website
  - an MLX row: the mlx-swift-lm and mlx-swift pins, read from the notices file. `quail-server`'s version is the app's own, so it needs no row of its own (Phase 4 step 6).

**Amended 2026-09-29 (issue #134): loaded models at the top of the Models page.** A loaded model used to show only as a small "loaded" badge among every installed row.
- **A Loaded section:** while the server is ready, it heads the page with every loaded or loading model. It comes from the same app-wide `GET /models` poll as the menu's "Loaded: …" line, and each row shows:
  - the model's format and context;
  - its memory: MLX's own figure from `/slots`, or the server's footprint for GGUF;
  - what it's doing: "Loading 6 s", "Idle", or "1 request · 43 tok/s".
- **Actions:** **Unload** (`POST /models/unload` through a new `Runtime.unload`, finishing the model's requests in flight first) and the default star.
- **With nothing loaded,** one line says what will load and when.
- **Installed still lists every model,** loaded ones included, so it doesn't reshuffle as models load and unload.
- **Layout:** the rows share one Form row. As separate rows, the grouped Form drew only the first inside the section's card.
