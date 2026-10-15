# ADR-0073: One pinned swiftformat for the Mac and CI

**Date:** 2026-10-15 · **Status:** Accepted

**Decision:** `task lint` and `task format` run the swiftformat in `Vendor/swiftformat/`, never one from the PATH. `task vendor:swiftformat` fetches the release named in `Vendor/swiftformat.version` (SwiftFormat's own `swiftformat.zip` from GitHub, a universal binary), checks it against `Vendor/swiftformat.sha256` and that the binary reports that version, as the other vendored tools are pinned. CI no longer installs swiftformat with Homebrew. The weekly `upstream-watch` workflow reads swiftformat's latest release and, the first time one is newer than the pin, opens an issue to move it and fails, so the owner hears of it.

**Why:** nothing chose a version before. CI's hosted `macos-26` image ships a swiftformat of its own date, and CI only installed one when it was missing; the Mac had whatever Homebrew last upgraded to. On 2026-10-13 Homebrew moved the Mac to 0.63.1, whose `docComments` rule wants `//`, not `///`, on comments above nested functions. Local `task lint` failed on four files CI passed, and formatting them locally failed CI (#212, #213). Every new swiftformat or runner image could do this again.

**Moving the pin:** change both files in `Vendor/`. The sha256 line names the download `swiftformat-<version>.zip`, so a new version without a new checksum fails to fetch. Then `task format`, and commit what it changes in the same PR.

**Alternatives:** `brew install swiftformat@x` (Homebrew keeps no old swiftformat versions). Mint or mise (another tool to install, for one binary). Building from source with SwiftPM (slow on every CI run, for the same binary). Pinning only in CI (the Mac would still drift).

**Revisit if:** SwiftFormat stops publishing a macOS binary with its releases, or Quail adds lint tools that want a shared tool manager.
