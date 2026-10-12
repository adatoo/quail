# ADR-0053: Developer distribution through Homebrew and a signed DMG

**Date:** 2026-09-26 · **Status:** Accepted

**Decision:** Quail is a free, open-source tool for developers on Apple Silicon Macs. Homebrew (`brew install --cask adatoo/tap/quail-ai`) is the primary installation path; the same Developer ID-signed, notarized app remains available as a DMG on GitHub Releases. Sparkle continues to provide in-app updates (ADR-0032), with the cask's existing update behavior (ADR-0033).

Mac App Store publication is dropped. This supersedes ADR-0006's two-channel distribution plan and cancels the Store submission work in Phase 4, including Store-specific helper signing and removing Sparkle from a Store product. Existing App Store configurations, compile guards and CI checks remain unchanged for now; removing that legacy machinery, and updating AGENTS.md's corresponding conventions, is a separate cleanup task.

**Why:** the intended audience is the developer community, for whom Homebrew is an acceptable distribution channel. Maintaining a second distribution variant would take time from offline reliability, coding-tool compatibility, model curation and reproducible benchmarks.

**Release requirements:** retain Developer ID signing, notarization, signed updates, dependency notices and model licence review. Validate installation on a fresh Mac through Homebrew and the DMG, plus CLI availability and an update from an existing release. Dropping Store publication does not remove these requirements or expand the deferred runtime scope.

**Alternatives:** Maintain a reduced App Store edition as a discovery channel (rejected because it adds packaging and validation work for a secondary audience). Homebrew only (keep the DMG too, so installation does not require Homebrew).

**Revisit if:** demonstrated demand from users who require App Store distribution justifies maintaining and testing another product variant.

**Amended 2026-09-28 (Phase 4 step 5a):** the legacy machinery is gone:
- the `Quail-AppStore` scheme, and the `Debug-AppStore`/`Release-AppStore` configurations of every target;
- `Quail/Quail-AppStore.entitlements`;
- all 18 `APPSTORE` compile guards, each resolved to the direct build's branch;
- `task build:appstore` and its CI step, and `embed:cli`'s App Store skip;
- `AppInfo.isAppStoreBuild`.

AGENTS.md's rule to keep runtime installs behind `#if !APPSTORE`, and its two-scheme definition of done, went with them. Unchanged: notarization's App Store Connect API key (that's Apple's name for the notary credential), the Developer ID signing, Sparkle and the Homebrew cask. The fallback to llama.cpp for a runtime that can't start remains, for the deferred oMLX and Rapid-MLX.
