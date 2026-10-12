# ADR-0064: `quail bench --url`: timing any server from the client

**Date:** 2026-10-02 · **Status:** Accepted

**Decision:** `quail bench --url URL [model] [--api-key KEY] [--json]` runs a speed benchmark against any server that speaks OpenAI's `/v1/chat/completions`, from the CLI process, with no app or control socket involved. It's a suite of its own, `quail-bench-url-1` (`URLBenchmarkSuite`, `Shared/URLBenchmark.swift`):
- **Tests:** `quail-bench-1`'s shape, so results read alike. Prompts of 512 and 4,096 tokens; 256 tokens generated; time to first token on the 512 prompt; a returning turn (2,048 tokens, then the same with 64 more, its cache allowed); four requests of 128 tokens at once. One warm-up and three measured runs each, with the median and range.
- **No load test:** only Quail and llama-server's router can be asked to load or unload a model.
- **Prompts are text,** from `quail-bench-1`'s passage (now `BenchmarkPassage`, shared, unchanged). Two calibration requests (one passage and four, at `max_tokens` 1) give the server's tokens per word and what its chat template adds, from `usage`, so each test asks for the words that come to its size. The size the server counted is reported with the result.
- **Timing is the client's:** prompt speed is the prompt's tokens over the time to the first token, which includes the request's trip and the first token, as GuideLLM measures it. Generation is the tokens after the first over the time from the first to the last. Token counts come from `usage` (`stream_options.include_usage`), or from streamed chunks with a note when a server sends none.
- **No prefix-cache hits:** every timed prompt starts with a tag of its own (`Request 7-1a2b3c4d:`). Only the returning turn shares a prefix, on purpose.
- **Requests** ask for `temperature` 0, `seed` 42 and `ignore_eos`. A server that ignores `ignore_eos` (Ollama, oMLX and Rapid-MLX, ADR-0063's smoke test) and stops early gets a note; its speed is over what it wrote. A prompt the server refuses with a 4xx, usually longer than its context, is skipped with the server's reason.
- **Nothing is saved:** the result isn't a `BenchmarkResult` (no model file, no engine build), and isn't compared with `quail-bench-1`'s, whose prompts are token ids and whose timings are the server's own.

**Cross-checked** on the M4 Pro against GuideLLM 0.7.4 (the ADR-0063 harness's tool) on quail-server 0.67.3 with Qwen3.6 35B-A3B (GGUF), alternating the two. The Mac was busy (load average about 25), so absolute numbers moved between runs.
- **Generation:** 51.9 and 53.1 tok/s, against GuideLLM's 54.3 and 51.4 (1000 / inter-token latency).
- **Time to first token,** 512-token prompt: 782 and 834 ms, against GuideLLM's 712 ms on its first run. Its later runs repeated the same synthetic prompts and hit the prefix cache (163–180 ms), which the tags avoid.
- The server's own `timings` for a 576-token prompt said 633 tok/s and 38.1 tok/s generation, against 655 and 38.0 from the client on a run a minute apart.

**Alternatives:**
- Run GuideLLM from the CLI: it needs Python and a tokenizer folder for the model, which Quail doesn't bundle (AGENTS.md: no Python).
- Make `quail-bench-1` itself work over any URL: its exact token-id prompts and server timings are what make it comparable across runs, and other servers offer neither.

**Revisit if:** a server streams `usage` in another shape, or a widely used one rejects `stream_options` or `ignore_eos`.
