import Foundation
import Testing
@testable import QuailServerCore

@Suite("Inference routes", .timeLimit(.minutes(1)))
struct InferenceRoutesTests {
    private struct Harness {
        let routes: ServerRoutes
        let router: ModelRouter
        let world = ScriptedWorld()

        init(
            apiKey: String? = nil,
            ids: [String] = ["Alpha", "Beta"],
            engine: @escaping @Sendable (ScriptedWorld) -> ScriptedEngine = { ScriptedEngine(world: $0) },
            failLoad: Bool = false
        ) {
            let world = world
            let log = ServerLog(toStandardError: false)
            router = ModelRouter(
                entries: ids.map { .fake($0) },
                modelsMax: 1,
                makeEngine: { entry in
                    if failLoad, entry.id == "Beta" {
                        throw EngineError.loadFailed("out of memory")
                    }
                    return engine(world)
                },
                log: log
            )
            routes = ServerRoutes(router: router, apiKey: apiKey, log: log, buildLabel: "quail-server test")
        }

        func send(
            _ method: String, _ target: String, body: String = "", headers: [String: String] = [:]
        ) async -> HTTPResponse {
            await routes.handle(HTTPRequest(method: method, target: target, headers: headers, body: Data(body.utf8)))
        }

        func json(_ method: String, _ target: String, body: String = "") async -> (status: Int, json: [String: Any]) {
            let response = await send(method, target, body: body)
            guard case let .data(data) = response.body else { return (response.status, [:]) }
            return (response.status, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
        }

        func post(_ path: String, _ body: String) async -> (status: Int, json: [String: Any]) {
            await json("POST", path, body: body)
        }

        /// A streamed response's frames, each `data:` payload, ending at `[DONE]`.
        func stream(_ path: String, _ body: String) async -> (status: Int, frames: [String]) {
            let response = await send("POST", path, body: body)
            guard case let .stream(chunks) = response.body else { return (response.status, []) }
            var text = ""
            for await chunk in chunks {
                text += String(decoding: chunk, as: UTF8.self)
            }
            let frames = text.components(separatedBy: "\n\n").compactMap { frame -> String? in
                frame.hasPrefix("data: ") ? String(frame.dropFirst(6)) : nil
            }
            return (response.status, frames)
        }
    }

    private func object(_ text: String) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]) ?? [:]
    }

    private func firstChoice(_ json: [String: Any]) -> [String: Any] {
        (json["choices"] as? [[String: Any]])?.first ?? [:]
    }

    private func errorMessage(_ json: [String: Any]) -> String? {
        (json["error"] as? [String: Any])?["message"] as? String
    }

    // MARK: /v1/completions

    @Test("a completion answers in llama-server's shape")
    func completionShape() async {
        let harness = Harness()
        let reply = await harness.post(
            "/v1/completions",
            #"{"model":"Alpha","prompt":"Hi","max_tokens":10,"temperature":0}"#
        )
        #expect(reply.status == 200)
        #expect(reply.json["object"] as? String == "text_completion")
        #expect(reply.json["model"] as? String == "Alpha")
        #expect((reply.json["id"] as? String)?.hasPrefix("chatcmpl-") == true)
        #expect((reply.json["id"] as? String)?.count == 41)
        #expect(reply.json["system_fingerprint"] as? String == "quail-server test")
        #expect(reply.json["created"] as? Int != nil)

        let choice = firstChoice(reply.json)
        #expect(choice["text"] as? String == "Hello, world")
        #expect(choice["finish_reason"] as? String == "stop")
        #expect(choice["index"] as? Int == 0)
        #expect(choice.keys.contains("logprobs"))
        #expect(choice["logprobs"] is NSNull)

        let usage = reply.json["usage"] as? [String: Any]
        #expect(usage?["prompt_tokens"] as? Int == 2)
        #expect(usage?["completion_tokens"] as? Int == 3)
        #expect(usage?["total_tokens"] as? Int == 5)
        #expect((usage?["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int == 0)

        // The benchmark reads exactly these.
        let timings = reply.json["timings"] as? [String: Any]
        #expect(timings?["prompt_n"] as? Int == 2)
        #expect(timings?["predicted_n"] as? Int == 3)
        #expect(timings?["prompt_per_second"] as? Double == 4) // 2 tokens in 0.5 s
        #expect(timings?["predicted_per_second"] as? Double == 12) // 3 tokens in 0.25 s
        #expect(timings?["prompt_ms"] as? Double == 500)
        #expect(timings?["cache_n"] as? Int == 0)
    }

    @Test("prompt tokens served from the cache count in usage but not in prompt_n")
    func cachedTokens() async {
        let harness =
            Harness(engine: { var engine = ScriptedEngine(world: $0); engine.cachedTokens = 8; return engine })
        let reply = await harness.post("/v1/completions", #"{"model":"Alpha","prompt":[1,2,3,4,5,6,7,8,9,10]}"#)
        let usage = reply.json["usage"] as? [String: Any]
        let timings = reply.json["timings"] as? [String: Any]
        #expect(usage?["prompt_tokens"] as? Int == 10)
        #expect((usage?["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int == 8)
        #expect(timings?["prompt_n"] as? Int == 2)
        #expect(timings?["cache_n"] as? Int == 8)
    }

    @Test("a string prompt is tokenized with the model's special tokens; an id array is used as is")
    func promptForms() async {
        let harness = Harness()
        _ = await harness.post("/v1/completions", #"{"model":"Alpha","prompt":"Hi"}"#)
        #expect(harness.world.tokenizations.count == 1)
        #expect(harness.world.tokenizations[0].text == "Hi")
        #expect(harness.world.tokenizations[0].addSpecial)
        #expect(harness.world.tokenizations[0].parseSpecial)
        #expect(harness.world.requests[0].promptTokens == [72, 105])

        _ = await harness.post("/v1/completions", #"{"model":"Alpha","prompt":[5,6,7]}"#)
        #expect(harness.world.tokenizations.count == 1) // not tokenized again
        #expect(harness.world.requests[1].promptTokens == [5, 6, 7])

        _ = await harness.post("/v1/completions", #"{"model":"Alpha","prompt":["Hi"]}"#)
        #expect(harness.world.requests[2].promptTokens == [72, 105])
    }

    @Test("sampling and length settings reach the engine; defaults match llama-server's")
    func settingsReachEngine() async {
        let harness = Harness()
        _ = await harness.post("/v1/completions", #"{"model":"Alpha","prompt":"x"}"#)
        let defaults = harness.world.requests[0]
        #expect(defaults.sampling == SamplingParameters())
        #expect(defaults.cachePrompt)
        #expect(!defaults.ignoreEndOfSequence)
        #expect(defaults.maxTokens == 4095) // the context, less the prompt

        _ = await harness.post("/v1/completions", """
        {"model":"Alpha","prompt":"x","max_tokens":7,"temperature":0,"top_k":10,"top_p":0.5,"min_p":0.1,
         "seed":42,"ignore_eos":true,"cache_prompt":false,"repeat_penalty":1.1,"presence_penalty":0.2,"frequency_penalty":0.3}
        """)
        let set = harness.world.requests[1]
        #expect(set.maxTokens == 7)
        #expect(set.sampling.temperature == 0)
        #expect(set.sampling.topK == 10)
        #expect(set.sampling.topP == 0.5)
        #expect(set.sampling.minP == 0.1)
        #expect(set.sampling.seed == 42)
        #expect(set.sampling.repeatPenalty == 1.1)
        #expect(set.sampling.presencePenalty == 0.2)
        #expect(set.sampling.frequencyPenalty == 0.3)
        #expect(set.ignoreEndOfSequence)
        #expect(!set.cachePrompt)

        // The sampler options only some engines have (ADR D-043): parsed for every engine.
        let samplerHarness = Harness()
        _ = await samplerHarness.post("/v1/completions", """
        {"model":"Alpha","prompt":"x","dry_multiplier":0.8,"dry_base":2,"dry_allowed_length":3,"dry_penalty_last_n":64,
         "dry_sequence_breakers":["\\n","."],"xtc_probability":0.5,"xtc_threshold":0.2,"typical_p":0.9,
         "top_n_sigma":1.5,"mirostat":2,"mirostat_tau":4,"mirostat_eta":0.2}
        """)
        let extra = samplerHarness.world.requests.last?.sampling
        #expect(extra?.dryMultiplier == 0.8)
        #expect(extra?.dryBase == 2)
        #expect(extra?.dryAllowedLength == 3)
        #expect(extra?.dryPenaltyLastN == 64)
        #expect(extra?.drySequenceBreakers == ["\n", "."])
        #expect(extra?.xtcProbability == 0.5)
        #expect(extra?.xtcThreshold == 0.2)
        #expect(extra?.typicalP == 0.9)
        #expect(extra?.topNSigma == 1.5)
        #expect(extra?.mirostat == 2)
        #expect(extra?.mirostatTau == 4)
        #expect(extra?.mirostatEta == 0.2)
        #expect(extra?.usesExtraSamplers == true)
        // The older spelling of typical_p, and defaults that mean "off".
        _ = await samplerHarness.post("/v1/completions", #"{"model":"Alpha","prompt":"x","typ_p":0.8}"#)
        #expect(samplerHarness.world.requests.last?.sampling.typicalP == 0.8)
        #expect(SamplingParameters().usesExtraSamplers == false)

        // n_predict and max_completion_tokens are aliases; -1 and a negative seed mean "unset".
        _ = await harness.post("/v1/completions", #"{"model":"Alpha","prompt":"x","n_predict":3,"seed":-1}"#)
        #expect(harness.world.requests[2].maxTokens == 3)
        #expect(harness.world.requests[2].sampling.seed == nil)
        _ = await harness.post("/v1/completions", #"{"model":"Alpha","prompt":"x","max_tokens":-1}"#)
        #expect(harness.world.requests[3].maxTokens == 4095)
    }

    @Test("running out of max_tokens finishes with length")
    func length() async {
        let reply = await Harness().post("/v1/completions", #"{"model":"Alpha","prompt":"x","max_tokens":2}"#)
        #expect(firstChoice(reply.json)["text"] as? String == "Hello,")
        #expect(firstChoice(reply.json)["finish_reason"] as? String == "length")
    }

    @Test("a streamed completion sends text chunks, then a final chunk with usage and timings, then [DONE]")
    func streamShape() async throws {
        let harness = Harness()
        let (status, frames) = await harness.stream("/v1/completions", #"{"model":"Alpha","prompt":"x","stream":true}"#)
        #expect(status == 200)
        #expect(frames.last == "[DONE]")
        let chunks = frames.dropLast().map(object)
        #expect(chunks.count == 4) // three pieces and the final chunk
        #expect(chunks.prefix(3).compactMap { firstChoice($0)["text"] as? String } == ["Hello", ",", " world"])
        for chunk in chunks.prefix(3) {
            #expect(firstChoice(chunk)["finish_reason"] is NSNull)
            #expect(chunk["timings"] == nil)
        }
        let last = try #require(chunks.last)
        #expect(firstChoice(last)["text"] as? String == "")
        #expect(firstChoice(last)["finish_reason"] as? String == "stop")
        #expect((last["timings"] as? [String: Any])?["predicted_n"] as? Int == 3)
        #expect((last["usage"] as? [String: Any])?["completion_tokens"] as? Int == 3)
        // Every chunk of one response shares its id.
        #expect(Set(chunks.compactMap { $0["id"] as? String }).count == 1)
        #expect(await harness.router.leaseCount("Alpha") == 0)
    }

    @Test("a stop string ends generation, isn't in the text, and stops the engine")
    func stopString() async {
        let harness = Harness(engine: { var engine = ScriptedEngine(world: $0); engine.pieces = [
            "a",
            "b",
            "<",
            "/s",
            ">",
            "never",
        ]; return engine })
        let reply = await harness.post("/v1/completions", #"{"model":"Alpha","prompt":"x","stop":["</s>"]}"#)
        #expect(firstChoice(reply.json)["text"] as? String == "ab")
        #expect(firstChoice(reply.json)["finish_reason"] as? String == "stop")
        #expect(await eventually { harness.world.cancelled == 1 })
        #expect(await harness.router.leaseCount("Alpha") == 0)
    }

    @Test("stop accepts a single string too")
    func stopSingleString() async {
        let harness = Harness(engine: { var engine = ScriptedEngine(world: $0); engine.pieces = [
            "one",
            " two",
            " three",
        ]; return engine })
        let reply = await harness.post("/v1/completions", #"{"model":"Alpha","prompt":"x","stop":" two"}"#)
        #expect(firstChoice(reply.json)["text"] as? String == "one")
    }

    @Test("a client that goes away mid-stream stops the engine and frees the model")
    func clientLeaves() async {
        let harness = Harness(engine: { var engine = ScriptedEngine(world: $0); engine.endless = true; return engine })
        /// The connection's whole life is inside this function: when it returns, nothing holds the
        /// stream, which is what the HTTP server's own write loop leaves behind when a send fails.
        func readThreeChunksThenHangUp() async {
            let response = await harness.send(
                "POST", "/v1/completions", body: #"{"model":"Alpha","prompt":"x","stream":true}"#
            )
            guard case let .stream(chunks) = response.body else { Issue.record("expected a stream"); return }
            var seen = 0
            for await _ in chunks {
                seen += 1
                if seen == 3 {
                    break
                }
            }
        }
        await readThreeChunksThenHangUp()
        #expect(await eventually { harness.world.cancelled == 1 })
        #expect(await eventually { await harness.router.leaseCount("Alpha") == 0 })
    }

    @Test("a stream that can't start is an HTTP error, not a 200 with an error inside")
    func streamStartFailure() async {
        let harness =
            Harness(engine: { var engine = ScriptedEngine(world: $0); engine.failFirstToken = "kaboom"; return engine })
        let response = await harness.send(
            "POST",
            "/v1/completions",
            body: #"{"model":"Alpha","prompt":"x","stream":true}"#
        )
        #expect(response.status == 500)
        if case let .data(data) = response.body {
            #expect(String(decoding: data, as: UTF8.self).contains("kaboom"))
        } else {
            Issue.record("expected a plain error body")
        }
        #expect(await harness.router.leaseCount("Alpha") == 0)
    }

    @Test("a request for a model that isn't loaded loads it")
    func autoload() async {
        let harness = Harness()
        #expect(await harness.router.snapshot("Beta")?.state == .unloaded)
        let reply = await harness.post("/v1/completions", #"{"model":"Beta","prompt":"x"}"#)
        #expect(reply.status == 200)
        #expect(await harness.router.snapshot("Beta")?.state == .loaded)
    }

    // MARK: errors

    @Test("bad requests are 400s with llama-server's messages", arguments: [
        (#"{"prompt":"x"}"#, "model name is missing from the request"),
        (#"{"model":"nope","prompt":"x"}"#, "model 'nope' not found"),
        (#"{"model":"Alpha"}"#, "\"prompt\" is required"),
        (#"{"model":"Alpha","prompt":5}"#, "\"prompt\" must be a string or an array of token ids"),
        (#"{"model":"Alpha","prompt":["a","b"]}"#, "only one prompt per request is supported"),
        (#"{"model":"Alpha","prompt":"x","n":2}"#, "only n = 1 is supported"),
        (#"{"model":"Alpha","prompt":"x","temperature":"hot"}"#, "'temperature' must be a number"),
        (#"{"model":"Alpha","prompt":"x","stop":5}"#, "'stop' must be a string or an array of strings"),
        (#"{"model":"Alpha","prompt":"x","stream":"yes"}"#, "'stream' must be a boolean"),
        (#"{"model":"Alpha","prompt":"x","top_k":1.5}"#, "'top_k' must be an integer"),
        (#"{"model":"Alpha","prompt":"x","dry_multiplier":"lots"}"#, "'dry_multiplier' must be a number"),
        (
            #"{"model":"Alpha","prompt":"x","dry_sequence_breakers":"\\n"}"#,
            "'dry_sequence_breakers' must be an array of strings"
        ),
        (#"{"model":"Alpha","prompt":"x","mirostat":3}"#, "'mirostat' must be 0, 1 or 2"),
        (#"{"model":"Alpha","prompt":"x","xtc_probability":true}"#, "'xtc_probability' must be a number"),
        (#"[1,2]"#, "the request body must be a JSON object"),
    ])
    func badRequests(body: String, message: String) async {
        let reply = await Harness().post("/v1/completions", body)
        #expect(reply.status == 400)
        #expect(errorMessage(reply.json) == message)
        #expect((reply.json["error"] as? [String: Any])?["type"] as? String == "invalid_request_error")
    }

    @Test("a body that isn't JSON is a 400 that says where")
    func notJSON() async {
        let reply = await Harness().post("/v1/completions", "{bad")
        #expect(reply.status == 400)
        #expect(errorMessage(reply.json)?.contains("invalid JSON at byte") == true)
    }

    @Test("a prompt that doesn't fit the context is refused with the exceed-context error type")
    func contextExceeded() async {
        let harness = Harness(engine: { var engine = ScriptedEngine(world: $0); engine.contextSize = 8; return engine })
        let reply = await harness.post("/v1/completions", #"{"model":"Alpha","prompt":[1,2,3,4,5,6,7,8]}"#)
        #expect(reply.status == 400)
        #expect((reply.json["error"] as? [String: Any])?["type"] as? String == "exceed_context_size_error")
        // And a shorter prompt has its generation capped to what's left.
        _ = await harness.post("/v1/completions", #"{"model":"Alpha","prompt":[1,2,3,4,5],"max_tokens":100}"#)
        #expect(harness.world.requests.last?.maxTokens == 3)
    }

    @Test("a model that fails to load is a 500 naming the reason")
    func loadFailure() async {
        let reply = await Harness(failLoad: true).post("/v1/completions", #"{"model":"Beta","prompt":"x"}"#)
        #expect(reply.status == 500)
        #expect(errorMessage(reply.json)?.contains("out of memory") == true)
    }

    @Test("the wrong method is a 405, and the API key is required")
    func methodAndAuth() async {
        let harness = Harness(apiKey: "k")
        #expect(await harness.json("GET", "/v1/completions").status == 401)
        let keyed = await harness.send("GET", "/v1/completions", headers: ["authorization": "Bearer k"])
        #expect(keyed.status == 405)
        let post = await harness.send(
            "POST",
            "/v1/completions",
            body: #"{"model":"Alpha","prompt":"x"}"#,
            headers: ["x-api-key": "k"]
        )
        #expect(post.status == 200)
    }

    // MARK: /tokenize, /detokenize

    @Test("/tokenize returns ids, or id and piece pairs, and honours add_special / parse_special")
    func tokenize() async {
        let harness = Harness()
        let plain = await harness.post("/tokenize", #"{"model":"Alpha","content":"Hi"}"#)
        #expect(plain.json["tokens"] as? [Int] == [72, 105])
        #expect(harness.world.tokenizations.last?.addSpecial == false) // llama-server's default
        #expect(harness.world.tokenizations.last?.parseSpecial == true)

        _ = await harness.post(
            "/tokenize",
            #"{"model":"Alpha","content":"Hi","add_special":true,"parse_special":false}"#
        )
        #expect(harness.world.tokenizations.last?.addSpecial == true)
        #expect(harness.world.tokenizations.last?.parseSpecial == false)

        let pieces = await harness.post("/tokenize", #"{"model":"Alpha","content":"Hi","with_pieces":true}"#)
        let items = pieces.json["tokens"] as? [[String: Any]]
        #expect(items?.map { $0["id"] as? Int } == [72, 105])
        #expect(items?.map { $0["piece"] as? String } == ["H", "i"])

        let empty = await harness.post("/tokenize", #"{"model":"Alpha"}"#)
        #expect(empty.status == 200)
        #expect((empty.json["tokens"] as? [Int])?.isEmpty == true)
    }

    @Test("/tokenize and /detokenize need a model, like the rest of a router")
    func tokenizeNeedsModel() async {
        let harness = Harness()
        let reply = await harness.post("/tokenize", #"{"content":"Hi"}"#)
        #expect(reply.status == 400)
        #expect(errorMessage(reply.json) == "model name is missing from the request")
        #expect(await harness.post("/detokenize", #"{"tokens":[72]}"#).status == 400)
    }

    @Test("/detokenize turns ids back into text")
    func detokenize() async {
        let harness = Harness()
        let reply = await harness.post("/detokenize", #"{"model":"Alpha","tokens":[72,105]}"#)
        #expect(reply.json["content"] as? String == "Hi")
        #expect(await harness.post("/detokenize", #"{"model":"Alpha"}"#).json["content"] as? String == "")
    }

    // MARK: /props

    @Test("/props with no model describes the router; with ?model= it describes that model")
    func props() async {
        let harness =
            Harness(engine: {
                var engine = ScriptedEngine(world: $0); engine.template = "{{ x }}"; engine
                    .contextSize = 2048; return engine
            })
        let router = await harness.json("GET", "/props")
        #expect(router.status == 200)
        #expect(router.json["role"] as? String == "router")
        #expect(router.json["max_instances"] as? Int == 1)
        #expect(router.json["build_info"] as? String == "quail-server test")

        let model = await harness.json("GET", "/props?model=Alpha")
        #expect(model.status == 200)
        let settings = model.json["default_generation_settings"] as? [String: Any]
        #expect(settings?["n_ctx"] as? Int == 2048)
        #expect((settings?["params"] as? [String: Any])?["temperature"] as? Double == 0.8)
        #expect(model.json["total_slots"] as? Int == 1)
        #expect(model.json["chat_template"] as? String == "{{ x }}")
        #expect(model.json["bos_token"] as? String == "<s>")
        #expect(model.json["eos_token"] as? String == "</s>")
        #expect(model.json["build_info"] as? String == "quail-server test")
        #expect(model.json["model_alias"] as? String == "Alpha")

        let unknown = await harness.json("GET", "/props?model=nope")
        #expect(unknown.status == 400)
    }
}
