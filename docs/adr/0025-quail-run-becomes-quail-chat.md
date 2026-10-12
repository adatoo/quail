# ADR-0025: `quail run` becomes `quail chat`; a prompt doesn't need a model

**Date:** 2026-09-24 · **Status:** Accepted

**Decision:** The terminal-chat command is `quail chat [model] [prompt…]`; `quail run` is removed, with no alias. The first word is the model only if it names exactly one installed model (exact id, then case-insensitive, then a unique prefix — the same matching as `rm`, `ctx` and `default`, now one function, `ModelNameMatch`); otherwise every word is the prompt and the default model answers. `-m/--model` names the model outright (strictly: unknown or ambiguous is an error, and every word is the prompt). An ambiguous first word is an error rather than a guess. A quoted prompt is one argument containing spaces, so it is never read as a model. "Copy Terminal Chat Command" emits `quail chat -m <model>` so a model id with a space in it can't read as a prompt.
**Alternatives:** `-m` only (predictable, but loses ollama-style `quail chat <model>`); keep `run` as a hidden alias (ollama muscle memory, but the user chose a clean break).
**Why:** `run` suggests starting or loading a model, and the command only chats. With the model as a required first positional, `quail run why is the sky blue` took "why" as the model and failed; a one-shot prompt to the default model was impossible.
**Trade-off:** A prompt whose first word is a prefix of exactly one installed model's id (e.g. `quail chat gemma is …` with a Gemma installed) is read as a model choice; `-m` or quoting the prompt avoids it. Anyone with `quail run` in scripts or muscle memory gets an unknown-command error.
**Revisit if:** the auto-detection bites people in practice — then `-m` only.
