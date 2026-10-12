# ADR-0006: Two builds: Developer ID direct + Mac App Store

**Date:** 2026-09-21 · **Status:** Superseded by ADR-0053

**Superseded by ADR-0053 (2026-09-26):** publication now targets Homebrew and the signed DMG; the Store configuration remains only until a separate cleanup.

**Decision:** One codebase, two schemes. Direct build has everything; App Store build is llama.cpp-only with `#if !APPSTORE` compiling out runtime installs.
**Why:** The sandbox forbids downloading executable code and spawning unsandboxed processes, which rules out oMLX/Rapid-MLX on the Store. The Store is still useful for discovery.
**Revisit if:** Store review rejects even the bundled `llama-server` helper, or the Store channel brings no users.
