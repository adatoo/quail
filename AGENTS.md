# Working in this repo

Quail is a macOS menu bar app (SwiftUI, Swift 6, macOS 14+) that runs local LLM servers. Read `docs/ARCHITECTURE.md` for the design and `docs/IMPLEMENTATION_PLAN.md` for what to build next. Record any non-trivial design change in `docs/DECISIONS.md` as a new D-nnn entry.

## Conventions

- Swift 6 with strict concurrency. `Sendable` types, actors for the supervisor and model store, `@Observable` for UI state. No Combine.
- No third-party UI. The only permitted dependencies are Sparkle (Phase 4, via SPM) and swift-argument-parser, linked into the `quail` CLI target only (ADR D-022).
- App Store build must compile with every uv/PyPI/runtime-install code path removed: wrap those files or sections in `#if !APPSTORE`.
- Never inherit the user's shell environment when spawning a runtime. Build `environment` explicitly in `ProcessSupervisor`.
- Runtimes are always given explicit paths (`--models-dir`, `--model-dir`, `HF_HOME`). Never rely on a runtime's default folder.
- Never call `rapid-mlx launch` or `rapid-mlx service …`; Quail runs `serve` and `pull` only.
- Vendored binaries live in `Vendor/` and are git-ignored; `scripts/vendor-*.sh` are the only way they get there, and each pins a version and a sha256.
- Config is `~/Library/Application Support/Quail/config.json` (Codable). Secrets (API key, HF token) go in Keychain, never in the JSON.
- Logs go to `~/Library/Logs/Quail/`. Use `os.Logger` for app logs, the `LogStore` for runtime stdout/stderr.

## Build and test

```
xcodegen generate                  # only needed after editing project.yml; Quail.xcodeproj is committed
xcodebuild -scheme Quail -configuration Debug build
xcodebuild -scheme Quail test
scripts/vendor-llama.sh            # once per llama.cpp bump; updates Vendor/llama.cpp
otool -L Vendor/llama.cpp/llama-server   # must show only @executable_path and /usr/lib, /System
```

The Xcode project is generated from `project.yml` (see ADR D-008 in docs/DECISIONS.md). Edit `project.yml`, not the `.xcodeproj` directly, then re-run `xcodegen generate` and commit both.

Smoke test after any change to Server/ or Runtimes/: place a small GGUF in the store, Start, run the Ping sheet. Ping must pass.

## Definition of done for a task

- Builds with zero warnings in both schemes (`Quail`, `Quail-AppStore`).
- Unit tests pass; new logic in `Models/`, `DeviceFit/`, `Server/` has tests using a fake `Runtime` where a process would otherwise be needed.
- No absolute paths from the build machine end up in the bundle.
- `docs/IMPLEMENTATION_PLAN.md` checkbox or phase status updated if the task completes a listed item.

## Things not to do

- Don't add a chat window, an agent mode, or image/audio features. Link to the runtime's web UI instead.
- Don't bundle Python or wheels.
- Don't write outside `Application Support/Quail`, `Logs/Quail`, and the user-chosen model store.
- Don't commit `Vendor/`, signing identities, or `.p12` files.
