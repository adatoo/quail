# ADR-0021: Terminal chat (`quail chat`) — narrowing ADR-0001

**Date:** 2026-09-23 · **Status:** Accepted

**Decision:** `quail chat [model] [prompt]` (originally `quail run`, renamed by ADR-0025) chats with a model in the terminal: streaming output, one conversation per invocation, a tok/s line after each reply. It exists to judge a model, not to be a chat app: no saved history, no attachments, no system-prompt library, no tools. The menu-bar app itself still has no chat UI ("Open Chat in Browser" links to the runtime's own).
**Alternatives:** Keep ADR-0001 absolute (point users at the web UI or `curl`).
**Why:** A CLI "like ollama" (user request) is expected to have a way to chat; trying a model from the terminal is the fastest way to judge it, and it costs one streaming request loop, not a UI.
**Trade-off:** ADR-0001's "never" is now "never in the app"; the list of things `quail chat` will not do is the guard against scope creep.
**Line editing (amended 2026-09-26):** reported: ↑ didn't recall earlier messages. `quail chat` read lines with `readLine()`, which has no editing at all. It now uses the system's libedit (loaded with `dlopen`, so there's no build setting, and it falls back to `readLine()`), for ↑/↓, ←/→, Ctrl-A/E and Ctrl-R. What you typed is kept across chats in `Application Support/Quail/chat-history` (mode 0600, the last 500 lines), as `ollama run` keeps its own. That's input history, like a shell's. Conversations are still not saved, which is the history this record rules out.
**Revisit if:** requests arrive for history, attachments or tools — the answer should stay no.
