# ADR-0001: Scope: serving only, no chat

**Date:** 2026-09-21 · **Status:** Accepted

**Decision:** No chat, agent, image or audio UI. The ping test is a streamed one-token completion with timings, not a conversation.
**Why:** The existing desktop apps are bloated precisely because they try to be everything. Runtimes already ship web UIs; link to them.
**Revisit if:** never, for v1. *(Narrowed by ADR-0021: `quail chat` chats in the terminal; the app itself still has no chat UI. Narrowed again by ADR-0042: the `quail-server` it ships serves one small chat page at `/`. And by ADR-0072: serving models that don't chat, through APIs, is in scope; a UI for them is not.)*
