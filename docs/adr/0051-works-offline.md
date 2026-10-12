# ADR-0051: Quail works offline, and a check proves it

**Date:** 2026-09-26 · **Status:** Accepted

**Decision:** Once models are downloaded, Quail needs no internet connection. `task check:offline` (`Config/check-offline.sh`) enforces this with `sandbox-exec`:
- quail-server (GGUF and MLX) and llama-server run with every connection beyond loopback fatal: load, chat, stream, `/v1/messages`, the web page.
- The Debug app runs on a scratch `QUAIL_DATA_ROOT` with those connections denied. The check drives it over its control socket (status, list, ps, config, default, ctx, bench, chat through its endpoint) and expects `pull` to fail at once with an offline message.
- opencode, Codex and Claude Code run from the app's own launch recipes in the same sandbox and must answer.

Only three things want the network, and each fails quickly and in plain words:
- The weekly catalog refresh and the Sparkle check run in the background and fail quietly.
- Hugging Face lookups (listing, fit headers, downloads) now carry request timeouts: 15 s for metadata, 30 s idle for downloads (URLSession's default is 60 s).
- Hugging Face lookups also map connection failures to `HFDownloadError.offline`: URL errors for no network, DNS or timeouts, and POSIX `EPERM`/unreachable from a firewall. The error reads "no internet connection — adding models needs one; installed models work as normal, and a download resumes where it stopped".

The Add Model list stops asking after its first offline answer. It fills the rest from `ModelShapeCache` where it can, or "Offline" otherwise, says "You're offline" at the top, and preselects the best candidate for the Mac's size instead of waiting for verdicts.

**Why:** requested ("we need to be able to work offline"). Tracing every network call showed the serving path was already local (ADR-0044 had checked MLX). The Add Model sheet was the weak spot: it waited for every family's fit check before selecting anything, showed raw `URLError` dumps, and on a network that looks connected but goes nowhere took minutes. The first run of the new check also found that llama-server's router talks to its model processes over loopback, which is why loopback stays open in the strict profile.

**Alternatives:** `NWPathMonitor` to detect offline up front. It reports "satisfied" on a captive portal or behind a firewall, the cases that were slowest, so a failed request is the better signal. A real Wi-Fi-off test in CI isn't possible, since the runner needs its network.

**Revisit if:** a feature needs the network on the serving path (for example remote tokenizers), or opencode, Codex or Claude Code start requiring a connection at start-up.
