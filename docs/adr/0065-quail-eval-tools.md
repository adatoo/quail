# ADR-0065: `quail eval tools`: a quick check that tool calling works

**Date:** 2026-10-02 · **Status:** Accepted

**Decision:** `quail eval tools [model] [--url URL] [--api-key KEY] [--json]` sends 16 hand-written tool-calling requests (`ToolEval`, `Shared/ToolEval.swift`, suite `quail-tools-1`) to Quail's server, or to any OpenAI-compatible one with `--url`, and checks each reply:
- **Kinds:** five single calls (string, enum, integer, number, boolean and array arguments), three where the right tool must be chosen from six, two parallel calls of one tool, two calls of different tools, three where no tool fits (two must also answer correctly), and one answer from a tool's result.
- **Checking:** as BFCL's checker does it. The tool's name must match. Every expected argument must be present and of its schema's type: an integer as a JSON number with no fraction (`25.0` passes, `"25"` doesn't), and a boolean as `true` or `false`, not a string. Each value must be one of the accepted answers, ignoring case and surrounding spaces. A parameter the tool doesn't take fails. Expected calls are matched to returned ones in any order, each used once.
- **Requests:** non-streamed, `tool_choice` auto, temperature 0, seed 42 and 4,096 tokens, so a thinking model has room. Thinking is left as the server's default.
- **Nothing is saved;** `--json` prints every case with the calls and text that came back.

**Why:** the bugs ADR-0070's BFCL run found are ones a user meets as "tool calls come back as text": gpt-oss's `<|call|>`, Llama 3.1's `<|python_tag|>` and `"10"` for an integer, and MiMo's JSON body. Finding those needed the bench Mac and Python. This finds the same kind of failure in about a minute, on any Mac, against any server, and says which case failed and why.

**Not a score:** 16 cases can't rank models; BFCL's 200 on the bench Mac do that (ADR-0070). The cases are written for Quail, not taken from BFCL, so there's no dataset licence to carry and no overlap with what models may have been trained on.

**Checked** on the M4 Pro, quail-server 0.67.3:
- Qwen3.6 35B-A3B and Gemma 4 26B-A4B (GGUF) passed 16 of 16.
- Qwen3-0.6B passed 14. It answered in text where it should have started a timer, and called `get_weather` for a haiku.
- Under llama-server b11306, Qwen3.6 35B-A3B passed 15: it made one call where two different tools were asked for.

**Alternatives:** bundle BFCL's cases and checker (Python, AGENTS.md: no Python), or a subset of its JSON (its licence and notices to carry, for a check that doesn't need them).

**Revisit if:** a format family needs a case these don't exercise (a nested object argument, say), or a server needs a request field to call tools at all.
