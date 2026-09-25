# Captured from llama-server b11081

What the vendored llama-server answers to `/v1/messages` and `/v1/responses`, recorded against
Qwen3-8B (Q4_K_M) with `--jinja`. `QuailTests/MessagesFixtureTests.swift` checks that quail-server's replies
carry every field these do. Long thinking streams are cut to three deltas.

Where quail-server differs on purpose:

- **Anthropic streams** close a content block before the next opens, and end a thinking block
  with a `signature_delta` right there; llama-server sends the `signature_delta` and all the
  `content_block_stop`s at the very end.
- **Responses events** carry `sequence_number`, `output_index` and `content_index`, as OpenAI's do;
  llama-server's leave them out. Reasoning is a `reasoning` output item; llama-server's Responses
  route drops it.
- **Errors** on `/v1/messages` are Anthropic's `{"type":"error",…}`; llama-server sends its 500 in the OpenAI shape.
- llama-server accepts an empty `messages` list and answers with an unrelated reply; quail-server refuses it.

To re-record: start `llama-server -m <Qwen3-8B GGUF> --jinja` and post the requests in `MessagesFixtureTests.swift` and
`MessagesRoutesTests.swift` (with a tool, a system prompt, `"stream": true`) to `/v1/messages` and `/v1/responses`.
