# ADR-0005: Python runtimes installed by app-managed uv, not bundled or Homebrew

**Date:** 2026-09-21 · **Status:** Accepted

**Decision:** Ship the `uv` binary; install oMLX and Rapid-MLX into `Application Support/Quail/Runtimes` with pinned versions, tested ranges, smoke-tested updates and cached rollback.
**Alternatives:** Bundle a Python + wheels (multi-GB, brittle notarization, forces an app release for every runtime release); depend on Homebrew (PATH/version detection, no control over updates).
**Revisit if:** either runtime ships a self-contained native binary, or uv changes its tool layout incompatibly.
