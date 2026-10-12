# ADR-0072: Models that don't chat: a task for every model, narrowing ADR-0001

**Date:** 2026-10-03 · **Status:** Accepted

**Decision:** Quail serves models that don't chat, through standard APIs, and the app only downloads and manages them. ADR-0001 ("no chat, agent, image or audio UI") becomes "no chat, agent, image or audio *UI* in the app"; serving those models is in scope. The first are embedding and reranking models (`/v1/embeddings`, `/v1/rerank`; #181), then speech and images (#179). AGENTS.md and ARCHITECTURE §1 say the same.

Every model now has a **task**: `chat`, `embedding` or `rerank`.
- **Where it comes from:** the catalog family a model was downloaded as (`task`, plus `pooling` when the model's header doesn't say it). Otherwise from the model itself, read at each store refresh:
  - A GGUF's `<arch>.pooling_type` gives 1 mean, 2 CLS or 3 last for an embedding model, and 4 rank for a reranker. `<arch>.classifier.output_labels` means a reranker. `<arch>.attention.causal = false` means an encoder, so an embedding model. Checked on the headers of Qwen3-Embedding 0.6B, EmbeddingGemma 300M, nomic-embed v1.5, bge-m3 and Qwen3-Reranker 0.6B. gpustack's bge-reranker-v2-m3 has neither key, so the catalog must name its task.
  - An MLX folder's sentence-transformers files (`modules.json`, `config_sentence_transformers.json`, `1_Pooling/`), an encoder-only `model_type` (BERT and its kin), or a `…ForSequenceClassification` architecture for a reranker.
- **How the server learns it:** from `presets.ini`, in **llama-server's own keys**: `embeddings = true`, `reranking = true` and `pooling = …`. llama-server b11306's router accepts them and starts that model's instance with `--embeddings --pooling mean` (checked), so llama-server serves a GGUF embedding model's `/v1/embeddings` from the same presets. `quail-server` reads the same keys, and for an MLX folder without a preset it detects the task from the files, the same rule the app uses.
- **What it changes:**
  - Only a chat model can be the default model, be pinged, be benchmarked, or be offered in Connect and the chat page.
  - A chat route (`/v1/chat/completions`, `/v1/completions`, `/v1/messages`, `/v1/responses`) refuses another task's model with a 400 that names the route serving it.
  - `/v1/models` adds `task` and gives `output_modalities` of `embedding` or `score`.
  - The Models pane badges the task, and Add Model lists these models in a section of their own.
  - Recommendations stay chat-only.

**Why:** Nativ (#179) and Ollama, oMLX and Rapid-MLX serve embeddings; Quail didn't, so RAG tools, editors' codebase indexing and memory tools couldn't use it. The catalog already had nomic-embed, but nothing could serve it: Quail would download a model it then couldn't use. Serving a model through an API keeps ADR-0001's reason intact, that the desktop apps are bloated by trying to be everything in their UI.

**Alternatives:**
- **A `task =` preset key of Quail's own:** llama-server refuses a key it doesn't know ("option not recognized in preset"), so the presets would differ by runtime. Its own keys work for both.
- **Reading the GGUF header inside `quail-server` too:** that needs a second header parser in the server. The app writes the presets, and a model placed by hand for `quail-server` alone gets a preset line, as llama-server needs.
- **Deciding the task from `role`:** that's a display string, and the server never sees it.

**Revisit if:** a model of one task needs another (an embedding model that also chats), or speech and image models need a field the presets can't carry.

**Amended 2026-10-03 (serving them, #181):** `quail-server` serves `/v1/embeddings` and `/v1/rerank` (also at `/rerank`, `/v1/reranking` and `/reranking`) for both formats, through an `EmbeddingEngine` beside the chat engines. `main.swift` picks it by the model's task.
- **GGUF (`LlamaEmbeddingEngine`):**
  - libllama's embedding mode, as llama-server's `--embeddings` and `--reranking` use it, with the preset's pooling or the model's own.
  - Inputs are packed into as few forward passes as fit, each input its own sequence, and read back with `llama_get_embeddings_seq`.
  - One pass holds a whole input (`n_ubatch` = `n_batch` = the context, 8,192 tokens unless the preset says), because an encoder can't split one. An input longer than that is a 400.
  - A reranker joins query and document as llama-server does: the GGUF's own `rerank` template, or else `[BOS] query [EOS] [SEP] document [EOS]`. Its score is the ranking head's first output, unscaled.
- **MLX (`MLXEmbeddingEngine`):**
  - mlx-swift-lm's `MLXEmbedders` and `MLXRerankers` products, from the release already pinned, so there's no new package.
  - Inputs run one at a time, with no padding, because padding needs a mask every family reads the same way.
  - A model that pools itself (EmbeddingGemma) gives its own vector.
  - MLX downloads are flat, so `1_Pooling/config.json` isn't fetched. The catalog's `pooling` covers the families that need one.
- **Shapes and defaults are llama-server's:**
  - OpenAI's embeddings response. Vectors are L2-normalized unless `embd_normalize: -1`. `encoding_format: base64` sends float32 bytes. `dimensions` cuts the vector and normalizes it again.
  - Rerank answers in Jina's shape (`relevance_score`, best first, `top_n`), or as TEI's bare array when sent `texts`.
- **Checked:** against llama-server b11306 on the same GGUF files, the vectors were the same to a cosine of 1.0 (nomic-embed v1.5 Q4_0, Qwen3-Embedding 0.6B Q8_0), and the rerank scores agreed to 4e-4 (bge-reranker-v2-m3, Qwen3-Reranker 0.6B). On MLX, Qwen3-Embedding 0.6B at 8-bit matched the GGUF Q8_0 to a cosine of 0.9995; the `mxfp8` build only to 0.975, so the catalog offers the 8-bit one. Qwen3-Reranker 0.6B (MLX, 4-bit) ranked the same documents in the same order.
- **Catalog:** Qwen3 Embedding 0.6B and EmbeddingGemma 300M (GGUF and MLX), Qwen3 Reranker 0.6B (GGUF and MLX), and BGE Reranker v2 M3 (GGUF). Connect has Embeddings and Reranking entries with a Test button.
