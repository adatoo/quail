# Quail

**Quick AI, local.** A Postgres.app-style menu bar app for running local LLM servers on Apple Silicon.

**Website and docs: [quail-ai.app](https://quail-ai.app)**

Quail starts a runtime, exposes an OpenAI-compatible endpoint, and gets out of the way. It runs **Quail server**, its own server for both GGUF and MLX models, with **llama.cpp**'s `llama-server` bundled as a fallback for GGUF, from one shared model folder and one honest opinion about what fits on your machine.

## Install

Quail is free and open source, built for developers on Apple Silicon Macs. Homebrew is the recommended installation path; Mac App Store publication is not planned (D-053 in [the decision records](docs/DECISIONS.md)).

```
brew install --cask adatoo/tap/quail-ai
```

or download the DMG from the [latest release](https://github.com/adatoo/quail/releases/latest). The build is signed and notarized. Quail then updates itself (Quail → General → Updates); Homebrew leaves that to Quail unless you run `brew upgrade --greedy`. The `brew` install also puts the `quail` command on your PATH.

## What it does

- **Runs a model server from the menu bar.** Start and stop it, see what it's doing, and keep the Mac awake while it works, even with a laptop's lid closed when plugged in.
- **One server for GGUF and MLX.** Quail server runs llama.cpp for GGUF and Apple's MLX for MLX models, from one model folder. llama.cpp's `llama-server` stays bundled as a fallback for GGUF.
- **Knows what fits.** Every model gets a verdict for this Mac before you download it, with an estimated speed. Each model's context size and KV cache are labelled with how they fit.
- **Finds models:** a curated catalog, recommendations for your memory, over a hundred MLX models, any Hugging Face GGUF repo, and the models other apps already downloaded.
- **Connects your tools.** Copy-ready setup for Claude Code, Codex, opencode, Continue, Cline, Zed, Open WebUI and more, each with a Test. It speaks OpenAI Chat Completions, Responses and Embeddings, and Anthropic Messages, and reranks search results too.
- **Includes a `quail` command,** like ollama: `quail pull`, `chat`, `launch claude`, `bench`, `ps`, `logs` and more.
- **Benchmarks** a model on your own Mac, the same way every time, and compares runs.
- **Keeps your data on your Mac.** It listens only to this Mac by default, requires an API key from the start, and works offline once models are downloaded (`task check:offline` proves it).

## What it deliberately doesn't do

It has no chat window of its own: the server's chat page opens in your browser, and `quail chat` works in the terminal. There are no agents, no image or audio generation, and nothing in the cloud: no account and no telemetry.

## Status

1.0. What's planned next is at the end of [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md): serving speech, images and MCP through the API (#179). Every merge to `main` is a signed, notarized release that installed copies update to.

## Documents

| Doc | What it covers |
| --- | --- |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | The design: distribution, app shell, runtime adapters, model store, device fit, packaging |
| [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) | Phases, tasks, acceptance criteria, build/verify loop |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Decision records with the trade-offs behind them |
| [docs/benchmarks/](docs/benchmarks/2026-09-30/README.md) | Quail measured against llama-server, Ollama, oMLX and Rapid-MLX on the same weights, including where Quail is slower (D-063). The [first run](docs/benchmarks/2026-09-29/README.md) is kept for comparison |
| [AGENTS.md](AGENTS.md) | Conventions for humans and coding agents working in this repo |
| [website/](website/) | The website at [quail-ai.app](https://quail-ai.app): landing page and user docs, plain HTML (D-062) |

## Requirements

- macOS 14 Sonoma or later, Apple Silicon
- Xcode 16 or later to build
- An Apple Developer ID for signed/notarized builds (unsigned debug builds run locally)

## Licence

[MIT](LICENSE). The open-source components Quail ships, and their licences, are listed in [THIRD_PARTY_NOTICES.md](Quail/Resources/THIRD_PARTY_NOTICES.md) and in the app (About → Third-party licences).
