# ADR-0010: API key off by default, regardless of host

**Date:** 2026-09-22 · **Status:** Superseded by ADR-0039

> **Reversed by ADR-0039 (2026-09-25):** the key is now on by default, because the threat this decision didn't consider is a web page in the user's own browser.

**Decision:** `Config.apiKeyEnabled` defaults to `false`. A freshly-launched Quail runs `llama-server` with no `--api-key` at all, on `127.0.0.1`, same as it always has. The Settings → Endpoint toggle is the only way to turn one on; enabling it generates a random 32-byte key (Keychain-only, never in `config.json`) and passes it as `--api-key`.
**Why:** Matches Postgres.app's "trust" default on loopback (cited in ARCHITECTURE.md's own open question) — a local dev tool serving `127.0.0.1` isn't meaningfully more secure with an API key, since anything on the same machine that can reach loopback can also read the key out of Keychain or `ps`. The real risk is binding to `0.0.0.0` (LAN) with no key; Phase 4's one-time LAN-binding warning (ARCHITECTURE.md's UI table) is the point where Quail should actively steer users towards enabling one, not Phase 1 forcing it on unconditionally for everyone including the common loopback-only case.
**Alternatives:** Default on everywhere (rejected — friction for the common case, and a key sitting in Keychain that every loopback process can already read isn't protecting much); default on only when host isn't loopback (deferred to Phase 4 alongside the LAN warning this PR doesn't implement, rather than half-building host-dependent defaulting now).
**Answers ARCHITECTURE.md's open question:** "Should the API key default to on (random, shown once) or off for loopback?" — off, matching Postgres.app.
**Revisit if:** Phase 4's LAN-binding warning ships and it turns out users routinely miss it — at that point, forcing the toggle on when `host != "127.0.0.1"` (rather than just warning) is worth reconsidering.
