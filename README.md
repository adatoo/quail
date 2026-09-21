# Quail

**Quick AI, local.** A Postgres.app-style menu bar app for running local LLM servers on Apple Silicon.

Quail starts a runtime, exposes an OpenAI-compatible endpoint, and gets out of the way. It manages three runtimes behind one interface — **llama.cpp** (bundled), **oMLX** and **Rapid-MLX** (installed on demand) — with one shared model folder and one honest opinion about what fits on your machine.

## What it does

- Start, stop and supervise one runtime at a time; status in the menu bar
- Endpoint settings: runtime, host, port, API key
- Browse, download, select and delete models in a single store (GGUF and MLX)
- Fit and speed estimates per model, per runtime, for *this* Mac
- Ping test: server up, model loaded, time to first token — no chat window
- Live logs
- Open at login, auto-start last runtime and model

## What it deliberately doesn't do

Chat, agents, image/audio generation, multi-runtime concurrency, remote hosting. The runtimes' own web UIs are one click away for anything beyond serving.

## Status

Pre-alpha. See [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) for where things are.

## Documents

| Doc | What it covers |
| --- | --- |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | The design: distribution, app shell, runtime adapters, model store, device fit, packaging |
| [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) | Phases, tasks, acceptance criteria, build/verify loop |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Decision records with the trade-offs behind them |
| [AGENTS.md](AGENTS.md) | Conventions for humans and coding agents working in this repo |

## Requirements

- macOS 14 Sonoma or later, Apple Silicon
- Xcode 16 or later to build
- An Apple Developer ID for signed/notarized builds (unsigned debug builds run locally)

## Licence

TBD (MIT intended). Bundled llama.cpp is MIT; uv is MIT/Apache-2.0; oMLX and Rapid-MLX are Apache-2.0 and are installed, not redistributed.
