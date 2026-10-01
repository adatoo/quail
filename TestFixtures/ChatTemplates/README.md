# Chat-template fixtures

Real chat templates and what llama.cpp's own engine renders from them, so `ChatTemplateTests` can
check `quail-server`'s swift-jinja renderer against it (ADR D-035).

- `templates/` — the Jinja text from each model's repository on Hugging Face: `Qwen/Qwen3-0.6B`,
  `unsloth/gemma-3-1b-it`, `unsloth/Llama-3.2-1B-Instruct` (all `tokenizer_config.json`'s `chat_template`)
  and `openai/gpt-oss-20b` (`chat_template.jinja`); Gemma 4 twice, since its two sources differ:
  `gemma4.jinja` is the template in `unsloth/gemma-4-26B-A4B-it-GGUF`'s Q4_K_M file (read from
  llama-server's `/props`), `gemma4-mlx.jinja` is `mlx-community/gemma-4-26b-a4b-it-4bit`'s
  `chat_template.jinja`; `muse-glimmer.jinja` is `meta-models/Muse-Glimmer-30B`'s `chat_template.jinja`. They are
  model-vendor files under their own licences, kept only as test data.
- `cases/` — OpenAI-style request bodies (messages, tools, tool calls).
- `golden/<family>/<case>.txt` — the prompt the vendored `llama-server` (b11081) returned from
  `POST /apply-template` with `--chat-template-file templates/<family>.jinja`. `.error` files are the
  message it returned when the template rejects that conversation.
- `oracle.json` — the token strings and date that server run used (`bos_token`/`eos_token` come from the
  loaded model, here Qwen3-0.6B, whichever template is under test). llama-server also passes
  `enable_thinking: true` to a template that can think; the Gemma 4 goldens are rendered that way.

The Muse Glimmer goldens were rendered on 2026-09-30; its template writes the day's date
(`strftime_now`), so their "Current date" line was set to the oracle's date afterwards, and nothing else changed.

To regenerate: run `llama-server -m <any model> --jinja --chat-template-file templates/<family>.jinja`
and POST each case to `/apply-template`.
