# Quail — Decision Records

Short ADRs. Newest first. Each states the decision, the alternatives, and what would make us revisit it.

## D-007 · 2026-09-21 · Name: Quail

**Decision:** The product is Quail ("quick AI, local"). Bundle id `com.datoos.quail`, CLI/paths `quail`.
**Alternatives:** Infer.app, Bellows, Llamp, Corral, Applai. Applai rejected on Apple trademark and App Store guideline 5.2.5 grounds; Llamp rejected as tying the brand to one runtime.
**Revisit if:** a trademark search turns up a conflicting software product.

## D-006 · 2026-09-21 · Two builds: Developer ID direct + Mac App Store

**Decision:** One codebase, two schemes. Direct build has everything; App Store build is llama.cpp-only with `#if !APPSTORE` compiling out runtime installs.
**Why:** The sandbox forbids downloading executable code and spawning unsandboxed processes, which rules out oMLX/Rapid-MLX on the Store. The Store is still useful for discovery.
**Revisit if:** Store review rejects even the bundled `llama-server` helper, or the Store channel brings no users.

## D-005 · 2026-09-21 · Python runtimes installed by app-managed uv, not bundled or Homebrew

**Decision:** Ship the `uv` binary; install oMLX and Rapid-MLX into `Application Support/Quail/Runtimes` with pinned versions, tested ranges, smoke-tested updates and cached rollback.
**Alternatives:** Bundle a Python + wheels (multi-GB, brittle notarization, forces an app release for every runtime release); depend on Homebrew (PATH/version detection, no control over updates).
**Revisit if:** either runtime ships a self-contained native binary, or uv changes its tool layout incompatibly.

## D-004 · 2026-09-21 · llama.cpp is bundled and is the default runtime

**Decision:** Vendor a pinned `llama-server` release into the bundle. It is the only runtime in the App Store build and the default everywhere.
**Why:** Zero dependencies, router-mode hot swap (`/models/load`), `/health`, `--log-file`, widest model catalogue. Postgres.app-faithful.
**Trade-off:** MLX decodes 1.4–1.8× faster on large dense/MoE models; that is what the optional runtimes are for.
**Revisit if:** mlx-serve or similar offers a signed native binary with an equivalent management API — then it could become a second bundled runtime.

## D-003 · 2026-09-21 · Child-process supervision, not a LaunchAgent

**Decision:** The app spawns the runtime as a child `Process`; quitting the app stops the server. Open-at-login gives "always on while logged in".
**Alternatives:** `SMAppService.agent` LaunchAgent so the server outlives the app; Rapid-MLX's system LaunchDaemon.
**Why:** Simplest correct behaviour, no `launchctl` state to reconcile, matches Postgres.app. A LaunchAgent can be added later behind the same `Runtime` protocol.
**Revisit if:** users routinely want the server up without the menu bar icon.

## D-002 · 2026-09-21 · Quail owns the model store and does all downloads itself

**Decision:** One folder with `gguf/` and `mlx/` subtrees, an app-maintained `catalog.json`, and an in-app Hugging Face downloader. Runtimes are always pointed at the store explicitly; `HF_HOME` is redirected into it.
**Alternatives:** Let each runtime download into its own default location and try to reconcile; symlink farms.
**Why:** Uniform progress/resume/checksum, one place to compute fit verdicts, no cross-runtime symlink quirks.
**Revisit if:** a runtime starts refusing models outside its own cache layout.

## D-001 · 2026-09-21 · Scope: serving only, no chat

**Decision:** No chat, agent, image or audio UI. The ping test is a streamed one-token completion with timings, not a conversation.
**Why:** The existing desktop apps are bloated precisely because they try to be everything. Runtimes already ship web UIs; link to them.
**Revisit if:** never, for v1.
