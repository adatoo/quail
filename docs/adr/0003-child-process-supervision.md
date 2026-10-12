# ADR-0003: Child-process supervision, not a LaunchAgent

**Date:** 2026-09-21 · **Status:** Accepted

**Decision:** The app spawns the runtime as a child `Process`; quitting the app stops the server. Open-at-login gives "always on while logged in".
**Alternatives:** `SMAppService.agent` LaunchAgent so the server outlives the app; Rapid-MLX's system LaunchDaemon.
**Why:** Simplest correct behaviour, no `launchctl` state to reconcile, matches Postgres.app. A LaunchAgent can be added later behind the same `Runtime` protocol.
**Revisit if:** users routinely want the server up without the menu bar icon.
