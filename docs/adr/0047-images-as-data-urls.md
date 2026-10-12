# ADR-0047: Images: `data:` URLs only, a marker in the prompt, the bytes beside it

**Date:** 2026-09-25 · **Status:** Accepted

**Decision:** A request's images are accepted as base64 `data:` URLs (chat completions `image_url`, Anthropic `image` blocks with a `base64` source, Responses `input_image`) and **never fetched**: an `http(s)`, `file:` or bare-path image is a 400 that says to send a data: URL. **Why:** fetching whatever address a request names is a network and privacy decision (server-side request forgery from a page's script to the local network, or a leak of the user's address to a third party) that the server shouldn't make for a client; llama-server does it, and the app's chat page and every local tool can send bytes. Each image is capped at 32 MB decoded.
**Design:** in `ChatMessages.normalize` an image part becomes a text part holding `<__media__>` (libmtmd's default marker, as in llama-server), so the chat template renders it wherever that model wants an image, and the decoded bytes go in `GenerationRequest.media` in marker order beside `promptText` (the rendered prompt). An engine that reads images tokenizes `promptText` itself, turning each marker into the image's embeddings; `promptTokens` stays the text's own tokenization, for the context check. A request with images to an engine without `EngineCapabilities.vision` is a 400 ("can't read images yet"), and to a model whose projector isn't loaded (`EngineInfo.supportsImages`) a 400 saying it has no mmproj.
**The engine (amended 2026-09-25):** `LlamaEngine` loads a model's `mmproj` file with libmtmd (`mtmd_init_from_file`, from the xcframework already linked) and sets `capabilities.vision` and `info.supportsImages`; **a projector that is missing, doesn't fit the model or can't read images fails the model's load**, as in llama-server. A request with images decodes them (`mtmd_helper_bitmap_init_from_buf`: JPEG, PNG, BMP, GIF; video files refused), has libmtmd tokenize `promptText` into text and image chunks, and evaluates the chunks into an emptied context one at a time, so a client that leaves stops it between chunks (a long text chunk or one image's encode is not interruptible). The reply's `max_tokens` is capped to what the context has left after the image tokens, and a prompt that doesn't fit is a 400 with llama-server's message. **No prefix reuse for a prompt with images:** the memory is cleared before and after such a request, so the next text request starts clean (the cache keys are token ids, and an image has none). The marker is checked against `mtmd_get_marker` at load. The projector's log lines go through the same warn-and-error filter as llama.cpp's.
**Checked against llama-server b11081 on SmolVLM2-500M-Video (Q8_0, with its Q8_0 projector), a generated 224x224 test image (two colour halves and a green square), temperature 0:** three questions (colours, a one-sentence description, a count) gave **identical text and identical prompt token counts (149 to 151) to llama-server**; two images in one message, `/v1/messages` `image` blocks and `/v1/responses` `input_image` parts work; text requests after an image request are unchanged (no `cache_n` on the first, reuse on the second); undecodable bytes are a 400. A model-gated test (`QUAIL_TEST_VISION_MODEL`, passed to the tests as `TEST_RUNNER_QUAIL_TEST_VISION_MODEL`) covers these on any vision model; the fixture image is `TestFixtures/Images/blocks.png`.
**Rules matched to llama-server (found by comparing, not reading):** a message with images is joined into one text, newlines between parts but none next to a marker, whatever the template's style (llama.cpp's `concat_content_parts`; for a template that only reads typed parts that text is then one typed part), and a template that only reads typed parts gets *every* message's string content as a typed part (before, a multi-turn conversation with such a template had its plain strings left as strings, and its prompt differed by seven tokens). The reply's tokens are placed by where the prompt ended, not by the memory's own count, because an M-RoPE model gives an image's tokens a smaller span than their number. **Qwen2.5-VL-3B (Q4_K_M, its Q8_0 projector, an M-RoPE model): ten questions about the test image gave text identical to llama-server's in ten of ten** (five of ten before the joining rule was matched), and SmolVLM2 ten of ten, plus image-first, image-between-texts and image-then-text-turn conversations, all with equal prompt token counts.
**Not yet:** prefix reuse across images; MLX vision (`MLXVLM`) isn't scheduled; audio input stays a 400.
**MLX models read images too (amended 2026-09-26):** reported: Qwen3.8 27B MLX refused an image, because the MLX engine loaded every model text-only (`LLMModelFactory`). Gemma 4 was asked for next and added in the same change.

**Which models:** an MLX folder whose `config.json` has a `vision_config`, whose `model_type` names an `MLXVision.Family`, and that has its processor config. The families are:
- `qwen3_5` and `qwen3_5_moe`: the Qwen3.5, 3.6 and 3.8 family;
- `gemma4`: Gemma 4 26B-A4B and 31B. Gemma 4 12B is `gemma4_unified`, which mlx-swift-lm doesn't load with its vision half.

`ModelEntry.supportsImages` reports such a model, and `/v1/models` `input_modalities`, `/props` and the chat page follow from that.

**When the vision half loads:** only when an image arrives. mlx-swift-lm's vision models generate text at about half the speed of its text models: Qwen3.6-35B-A3B measured 11 against 20 tokens a second on the same machine. So a model loads text-only, as before. A request with images reloads it through `VLMModelFactory`, from the same local folder with no download, and the next request without images reloads it text-only. Each switch takes a few seconds from the page cache. A chat with an image in its history resends it every turn, so it stays on the vision load.

**Gemma 4 26B-A4B:** it only loads that way. mlx-swift-lm's text-only Gemma 4 lacks the mixture-of-experts layers, so it failed with "Unhandled keys [experts, router…]", while the vision model has them. When the text-only load fails for a model that has a vision half, the engine loads the vision half and keeps it. That also fixes Gemma 4 26B-A4B MLX, which never loaded in Quail before: 25 tokens a second.

**How an image turn runs:**
1. The engine puts the template's own placeholder where each marker is: `<|vision_start|><|image_pad|><|vision_end|>` for Qwen, `<|image|>` for Gemma 4.
2. It runs each image through the model's processor (`Qwen3VLProcessor` or `Gemma4Processor`).
3. It widens each image token (`MLXVision.expand`; the library's own versions are internal):
   - Qwen: t·h·w/merge² pad tokens;
   - Gemma 4: begin-of-image, its `image_seq_length` soft tokens (280), then end-of-image.
4. It generates from a fresh cache and keeps nothing for the next request. Positions after an image aren't a plain token count, so the prefix can't be reused.

**Other changes:**
- Text turns on a vision load (Gemma 4 26B-A4B) skip the sliced prefill, because only the iterator's `prepare` resets the model's position state. They pass the prompt as a batch of one (`[1, n]`), which is what the vision half's language model reads: a flat prompt crashed it.
- **Colour fix:** Qwen's image path in the library renders pixels without colour matching, which leaves them in Core Image's linear working space. Mid-tones came out too dark, and the model read orange as red. The engine applies the sRGB tone curve first; Gemma 4's processor already does. After that, a four-colour test came back exact on all three models, and a text-reading test on Qwen3.8 and Gemma 4.
- Refusals now name both ways Quail reads images (`ImageInput.unsupportedMessage`).
- The catalog marks an MLX variant `vision` once checked: Qwen3.8-27B, Qwen3.6-35B-A3B and Gemma 4 26B-A4B.

**Why GGUF is simpler:** libmtmd does the processing and token accounting for every architecture it supports behind one call, given the `mmproj`. For MLX, each architecture's processor, placeholder and token layout is written into Quail, family by family.

**Revisit if:** a client genuinely needs remote images (a flag that allows named hosts, off by default), or the marker differs across libmtmd versions (the engine checks it at load).

**Amended 2026-10-01 (Muse Glimmer 30B):** a third MLX image family, `.museGlimmer`.
- mlx-swift-lm registers Muse Glimmer only as a vision model, so it always loads through the existing fallback, and text turns run on the vision load too, one request at a time.
- **The placeholder is `<|patch|>`.** Each widens to `<|image_start|>`, one `<|patch|>` per merged patch (t·h·w/merge²), then `<|image_end|>`, as the library's `MuseGlimmerProcessor` does.
- Its processor applies the sRGB curve itself.
- **Checked:** it named the three colours of the test image and where each is.
