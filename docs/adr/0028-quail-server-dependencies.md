# ADR-0028: Dependencies for `quail-server`: mlx-swift-lm, swift-transformers, swift-jinja

**Date:** 2026-09-24 · **Status:** Accepted

**Decision:** AGENTS.md's dependency rule gains a third exception beside Sparkle and swift-argument-parser (ADR-0022): the `quail-server` target (ADR-0027), and only that target, links `mlx-swift` and `mlx-swift-lm` (`MLXLLM`, `MLXLMCommon`), `swift-transformers` (`Tokenizers`, which brings `swift-jinja`) and `OrderedCollections`. The HTTP layer is hand-written on `Network.framework`, not swift-nio. None of them is linked into the app or the `quail` CLI. Three build facts, all found in the ADR-0027 spike, are part of the decision:
- `mlx-swift` compiles its Metal shaders at build time, so the server is built with `xcodebuild`, never plain `swift build`, on a machine with Xcode's Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`, ~840 MB) and with `-skipPackagePluginValidation` (a build-tool plugin in `mlx-swift`). CI needs both.
- `swift-collections` is pinned to 1.3.x. 1.7.0 compiled with Xcode 27's Swift 6.4 emits a runtime symbol (`_swift_initBorrow`) that macOS 26 doesn't have, so the binary dies in `dyld` at launch. CI's Xcode 26.6 may not hit it; a local Xcode 27 does. Lift the pin only after a launch test on the oldest supported macOS.
- `mlx-swift`'s `default.metallib` ships in a SwiftPM resource bundle (`mlx-swift_Cmlx.bundle`) that has to be embedded next to the server binary.
**Alternatives:** swift-nio for HTTP (more transitive dependencies and an Apache-2.0 NOTICE; nothing Quail needs that `Network.framework` lacks). The `MLXHuggingFace` macros (pull in `swift-huggingface`, a downloader Quail doesn't use — ADR-0002 keeps downloads in `HFDownloader`); a small `TokenizerLoader` over `Tokenizers.AutoTokenizer.from(modelFolder:)` is about 25 lines instead.
**Revisit if:** an `mlx-swift-lm` release needs a newer macOS than 14, or the `quail-server` binary's size becomes a problem for the App Store build.
