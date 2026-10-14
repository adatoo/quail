# ADR-0040: Tool calls: read from the model's text by family, sent whole

**Date:** 2026-10-15 · **Status:** Accepted

**Decision:** `ChatOutputParser` reads a chat reply's tool calls out of the text the model generates. It uses the format the model's chat template says the model speaks: `ToolCallFormat.detect` looks at what the template renders for a call. The reasoning splitter runs first, so only the answer text is searched for calls.

## Formats

| Format | What the model writes | Families | Detected by the template containing |
|---|---|---|---|
| Hermes JSON | `<tool_call>{"name", "arguments"}</tool_call>` | Qwen 2.5 and 3 | `<tool_call>` |
| Qwen XML | `<tool_call><function=NAME><parameter=KEY>VALUE</parameter></function></tool_call>` | Qwen3-Coder, Qwen 3.5 and later, their fine-tunes | `<function=` |
| Bare JSON | a reply that is exactly `{"name", "parameters"}`, or `<|python_tag|>` and calls joined by `;` | Llama 3.x | `<|python_tag|>` or `Environment: ipython` |
| Harmony | `<|channel|>commentary to=functions.NAME<|message|>{…}<|call|>` | gpt-oss | `<|channel|>` and `commentary` |
| Gemma 4 | `<|tool_call>call:NAME{key:<|"|>text<|"|>,n:2.5}<tool_call|>` | Gemma 4 | `'<|tool_call>call:'`, as llama.cpp checks |
| Muse Glimmer | `<|start|>assistant to=NAME<|message|><atem:function_calls>…` | Muse Glimmer | `<atem:function_calls>` and `to=self` |
| Python calls | `<|tool_call_start|>[NAME(key='text', n=1), …]<|tool_call_end|>` | LFM2, LFM2.5 | `<|tool_call_start|>` |
| MiniCPM XML | `<function name="NAME"><param name="KEY">VALUE</param></function>`, with no wrapping tag | MiniCPM5 | `<function name="` |

A family with no known format (Gemma 3) keeps its calls as content, as llama-server does. So does a request with no tools. Mistral's `[TOOL_CALLS]` and DeepSeek's formats aren't implemented.

## How each format's values are read

- **Typed by the tool's schema.** A value written as text (Qwen XML, MiniCPM XML, and a Python call's or a bare-JSON call's string) is read as the type the tool's JSON schema gives its parameter. A `string` parameter stays `"007"`, and a `number` becomes `2.5`. A parameter the schema doesn't name, and a value that doesn't parse as its type, stay as written. A boolean parameter also reads Python's `True` and `False`, and any non-string parameter reads `None` as null: Qwen3.6 writes them, and llama-server's grammar holds typed parameters to JSON, so its parse was right where Quail's kept the string. Llama 3.1 writes numbers as strings (`"base": "10"`). MiniCPM5 writes a list or dict as Python (`['a', 'b']`, `{'min': 1.0}`), which is read as JSON's, and a whole number with a decimal point (`40.0`) for an integer parameter is that integer, as llama-server reads them: before this, MiniCPM5 scored 160 of 200 on BFCL against llama-server's 169, and after it 171. Hermes JSON is read as written: it hasn't been seen to do any of these.
- **Qwen XML:** a `<function=…>` body that is a JSON object (MiMo V2.6) is that object. Several functions in one `<tool_call>` are several calls.
- **Gemma 4:** keys are bare, strings sit raw between `<|"|>` marks with nothing escaped, and numbers, booleans and `null` are JSON's. Keys and strings quoted either way are accepted too. A closing tag inside a string doesn't end the call. The arguments come out as compact JSON in the order written, as llama-server writes them.
- **Harmony:** the engine ends generation at `<|call|>` and keeps the token, so whole JSON at the end of the output is the call. It needs the engine to decode special tokens (`<|channel|>` …) into the text, as llama.cpp does.
- **Muse Glimmer** has its own parser (`MuseGlimmerParser`), as Harmony does, because it carries the reasoning too. `to=self` is reasoning, `to=user` (or no recipient) the answer, and `to=NAME` a call whose body is an ATEM block. A string parameter is kept exactly, spaces and newlines included; a parameter the schema types otherwise is read as JSON, as mlx-swift-lm's `ATEMToolCallParser` does.
- **Python calls (LFM2):** a Python list of calls with keyword arguments. The template writes a string in single quotes with Python's escapes and any other value as JSON, so a value is read as a Python literal: a quoted string (either quote), a number, `True`/`False`/`None` (or JSON's spelling), or a list or dict of them. The list's brackets may be left out. JSON calls inside the tags (`{"name", "arguments"}`, alone or in a list) are calls too: LFM2 writes them when a system prompt asks.
- **MiniCPM XML:** each `<function name=…>` is a call. A value with `<`, `&` or a newline sits in a CDATA section, so a closing tag inside one doesn't end the call.

## Wire shape and layout

- **As llama-server's** (captured from real runs): `message.tool_calls[]` with a 32-character `id`, `type: "function"` and `function{name, arguments}`, where `arguments` is a JSON string; `content: ""`; `finish_reason: "tool_calls"`. Streamed as `delta.tool_calls[]` with an `index`.
- **Deliberately different:** a streamed call goes out whole in one delta, not as argument fragments. Fragments would need a partial-JSON parser to save a fragment's worth of latency, and every client that concatenates `arguments` handles a whole one.
- **Not a call:** a block that isn't a valid call (bad JSON, a tool the request didn't offer, cut off by `max_tokens`) is given back as content, not dropped.
- **Layout:** text before a call loses the newline the model put there, except for Gemma 4 and MiniCPM5, where llama-server keeps it. Whitespace between consecutive calls, and after the last, isn't content, however the tokens arrive.
- **Reasoning tags:** Gemma 4 thinks in `<|channel>thought…<channel|>`, not `<think>`, and can write a thought block anywhere in a reply or end with a stray `<channel|>`. `ReasoningTags` gives each family's tags to the splitter, to the check for a prompt that leaves reasoning open, and to the grammar that lets constrained output follow a thinking block. For Gemma 4 a thought block counts wherever it comes, and a lone closing tag is dropped, as in llama.cpp's own parser. LFM2.5's prompt always ends inside `<think>`, so its replies start in reasoning.
- **Reasoning strength:** OpenAI's `reasoning_effort` reaches the template as `reasoning_strength` (Muse Glimmer's) and as `reasoning_effort` (gpt-oss's). A value in `chat_template_kwargs` wins.
- **Thinking by default:** llama-server passes `enable_thinking: true` to any template that can think. Quail passes only what the request sends. So Gemma 4 doesn't think on Quail unless asked, while on llama-server it does. MiniCPM5 thinks either way: with the switch absent, its template opens nothing and the model opens `<think>` itself. Qwen3's template reads a missing value as on. Changing Quail's default is a separate decision.

## Forcing a call

`tool_choice` `required` or a named tool constrains the reply with a grammar (`ToolChoiceGrammar`), on the GGUF engine only:
- **Hermes JSON and bare JSON:** the call's JSON, held to the tool's parameter schema.
- **Muse Glimmer:** the grammar writes the headers too, since a reply starts inside its first one. Each call is ` to=NAME<|message|>` and its ATEM block, with the schema's parameters in order and required ones always present. A string, string-or-null or untyped parameter is any text without `</atem:parameter>`, a string enum one of its values, and any other type JSON from the schema. Parallel calls are joined by `<|eom|><|start|>assistant`. Constrained output (`json_schema`) is an optional reasoning message, then ` to=user<|message|>` and the JSON. llama.cpp's grammar sampler matches special tokens by their text.
- **Refused with a 400 naming the format:** Qwen XML, Harmony, Gemma 4, Python calls and MiniCPM XML, whose arguments aren't one JSON value; and anything on the MLX engine, which has no grammar.

## Verified against real output

The fixtures are real replies, not invented samples (`TestFixtures/ToolCalls`). For each, the parsed calls (their `arguments` byte for byte), the content and the reasoning equal llama-server's at four chunk sizes, and Quail's rendering of the template gives llama-server's prompt exactly.

| Model | Captured with | Conversations |
|---|---|---|
| Qwen3-8B (Hermes) | llama-server | five: two parallel calls, a call after thinking, typed arguments, no call, a call with a system prompt |
| Qwen3.6-35B-A3B (Qwen XML) | llama-server | the same five |
| Gemma 4 26B-A4B (unsloth Q4_K_M) | llama-server b11081 | the five (thinking on for the call after thinking), nested arguments, and a reply after a tool result |
| MiniCPM5 2B (bartowski Q4_K_M) | llama-server b11564 | the five |
| LFM2.5 24B-A2B (Liquid AI Q4_K_M) | llama-server b11564 | the five, each after its reasoning |

- **Templates:** each family's template also renders the five template cases byte for byte as llama-server does (`TestFixtures/ChatTemplates`, ADR-0035). Both Gemma 4 templates are there, the GGUF's and mlx-community's, since they differ. swift-jinja keeps a space after a literal `{` before a trimmed tag, which changed Gemma 4's tool declarations; `ChatTemplate` prints such a brace with `{{ '{' }}`.
- **Constructed examples only:** Harmony and Muse Glimmer's parser tests are built in the shape real replies took. gpt-oss, Llama 3.1, MiMo V2.6, Muse Glimmer, MiniCPM5 and LFM2.5 also ran through Quail's own BFCL scores or a live check on both engines (ADR-0070).
- **What the BFCL scores found (2026-10-02):** four models' calls were coming back as text. gpt-oss scored 0 on every call category but irrelevance until the Harmony fix, Llama 3.1 until the `<|python_tag|>` and `;` fix, and MiMo V2.6's JSON bodies were empty calls. Each fix has a test made from the model's real reply. llama-server b11306 answers Llama 3.1's two-call reply with a 500.

**Alternatives:** Stream arguments fragment by fragment (needs a resumable JSON parser; nothing needs it). Parse in each engine (ADR-0038's argument). Ask the model for JSON with a grammar on every request (only forced calls need it).

**Revisit if:** a client turns out to need fragment streaming, or a family's format is added. Add its template and a captured run to the fixtures first.
