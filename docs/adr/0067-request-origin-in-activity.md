# ADR-0067: Who a request is from, in the Activity window

**Date:** 2026-09-30 · **Status:** Accepted

**Situation:** the Activity window (ADR-0060) shows a row per request in progress, but not who sent it. With Claude Code, a chat app and a script sharing one server, the owner can't tell which is keeping it busy. Every client uses the same API key (ADR-0039), so the key says nothing.

**Decision:** quail-server notes two clues for each request, and the app names and totals them.
- **The app:** the `User-Agent` header's first product, without a numeric version: `claude-cli`, `OpenAI/Python`, `curl`. The whole header is also kept, cut to 160 characters.
- **The machine:** the connection's address. Loopback becomes "local", and a mapped IPv4 address is written plainly.
- **`GET /slots`** gives each request its `client`, and adds `clients`: one entry per app-and-machine seen since the server started, with its requests, prompt tokens read (reused ones not counted), tokens written, busy seconds (time with at least one request in progress, waiting for a model included) and requests active now. It also adds `uptime_seconds`.
- **The app** keeps each poll's totals for 15 minutes. For the window the charts show (1, 5 or 15 min), it subtracts the totals at the window's start.
  - A total that went down means the server restarted, so it counts from nothing.
  - A server younger than the window counts from its start.
- **Names:** the Connect list's new `userAgents` prefixes name the tool. Only strings seen on a real request were added: `claude-cli`, `codex_`, `curl` and `OpenAI/Python`. Anything else shows its own product name ("OpenAI/JS", "python-httpx"), or "Unknown app". The machine is "this Mac" or the address.
- **The window:**
  - Each request row gets a line, "Claude Code · this Mac".
  - A new Clients section lists each client busy now or in the window, busiest first, at most six. Each shows what it's running now, its requests and tokens in the window, and a bar of its busy share. The bar is green under 25%, orange up to 75% and red above: the memory chart's colours.

**Privacy:** the figures stay in the server's memory, behind the API key. They're never logged or written to disk, and they go when the server stops. The privacy page says so.

**Limits:**
- A tool that goes through a shared SDK shows as that SDK: one built on the OpenAI Python library reads as "Python".
- A tool can send any `User-Agent` it likes. This is a label, not authentication.
- llama-server has no `/slots`, so with it there are no clients to show.

**Alternatives:**
- **A key per tool:** it names clients reliably, but means a Keychain entry for each and new Connect flows; ADR-0039 chose one key.
- **An `X-Quail-Client` header:** no tool would send it.
- **Reverse DNS for addresses:** slow, and often nothing on a home network.

**Revisit if:** keys per tool arrive, or a tool Quail lists can't be told apart from its SDK.
