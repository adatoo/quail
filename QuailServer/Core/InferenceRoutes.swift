import Foundation
import Jinja

/// The routes that run a model: `/v1/completions` (the benchmark's), `/tokenize`, `/detokenize`
/// and `/props`. Written once over the `Engine` seam, so GGUF and MLX models answer the same way.
struct InferenceRoutes: Sendable {
    let router: ModelRouter
    let log: ServerLog
    /// Reported as `system_fingerprint` and `build_info`.
    let buildLabel: String
    /// Whether `/` serves the chat page; `/props` says so.
    var webUI = true
    private let templates = TemplateCache()

    /// `nil` for a path this type doesn't serve.
    func handle(_ request: HTTPRequest) async -> HTTPResponse? {
        switch request.path {
        case "/v1/completions":
            await guarded(request, method: "POST") { try await completions(request) }
        case "/v1/chat/completions", "/chat/completions":
            await guarded(request, method: "POST") { try await chatCompletions(request) }
        case "/v1/messages", "/messages":
            await guarded(request, method: "POST", style: .anthropic) { try await messages(request) }
        case "/v1/messages/count_tokens", "/messages/count_tokens":
            await guarded(request, method: "POST", style: .anthropic) { try await countTokens(request) }
        case "/v1/responses", "/responses":
            await guarded(request, method: "POST") { try await responses(request) }
        case "/tokenize":
            await guarded(request, method: "POST") { try await tokenize(request) }
        case "/detokenize":
            await guarded(request, method: "POST") { try await detokenize(request) }
        case "/props":
            await guarded(request, method: "GET") { try await props(request) }
        default:
            nil
        }
    }

    /// How a route words its errors: OpenAI's `{"error": {…}}` or Anthropic's `{"type": "error", …}`.
    enum ErrorStyle {
        case openAI
        case anthropic
    }

    func guarded(
        _ request: HTTPRequest,
        method: String,
        style: ErrorStyle = .openAI,
        _ body: () async throws -> HTTPResponse
    ) async -> HTTPResponse {
        guard request.method == method else {
            return style.response(RequestError(
                status: 405,
                type: "invalid_request_error",
                message: "Method Not Allowed"
            ))
        }
        do {
            return try await body()
        } catch let error as RequestError {
            return style.response(error)
        } catch let error as RouterError {
            return style.response(Self.requestError(for: error))
        } catch let EngineError.invalidRequest(message) {
            return style.response(.invalid(message))
        } catch {
            return style.response(RequestError(status: 500, type: "server_error", message: error.localizedDescription))
        }
    }

    // MARK: Shared

    func jsonBody(_ request: HTTPRequest) throws -> Value {
        do {
            let value = try OrderedJSON.parse(request.body)
            guard case .object = value else { throw RequestError.invalid("the request body must be a JSON object") }
            return value
        } catch let error as OrderedJSON.ParseError {
            throw RequestError.invalid(error.localizedDescription)
        }
    }

    /// The model a request names: `model` in the body, or `?model=` for the GET routes. A router
    /// has no default, so a request that names none is refused (llama-server's behaviour).
    func modelID(body: Value?, request: HTTPRequest) async throws -> String {
        var id = body?["model"]?.stringValue
        if id == nil, let query = URLComponents(string: request.target)?.queryItems {
            id = query.first { $0.name == "model" }?.value
        }
        guard let id, !id.isEmpty else { throw RequestError.invalid("model name is missing from the request") }
        guard await router.snapshot(id) != nil else { throw RequestError.invalid("model '\(id)' not found") }
        return id
    }

    static func requestError(for error: RouterError) -> RequestError {
        switch error {
        case .unknownModel: .invalid(error.localizedDescription)
        case .shuttingDown: RequestError(status: 503, type: "unavailable_error", message: error.localizedDescription)
        case .loadFailed: RequestError(status: 500, type: "server_error", message: error.localizedDescription)
        }
    }

    /// The prompt as token ids: a string is tokenized (with the model's own special tokens, as
    /// llama-server does for `/v1/completions`), an array of integers is used as is.
    private func promptTokens(_ prompt: Value?, engine: any Engine) async throws -> [Int] {
        guard let prompt, !prompt.isNull else { throw RequestError.invalid("\"prompt\" is required") }
        if let text = prompt.stringValue {
            return try await engine.tokenize(text, addSpecial: true, parseSpecial: true)
        }
        if let items = prompt.arrayValue {
            if items.allSatisfy({ $0.intValue != nil }) {
                return items.compactMap(\.intValue)
            }
            if items.count == 1, let text = items[0].stringValue {
                return try await engine.tokenize(text, addSpecial: true, parseSpecial: true)
            }
            throw RequestError.invalid("only one prompt per request is supported")
        }
        throw RequestError.invalid("\"prompt\" must be a string or an array of token ids")
    }

    /// What the request asks for against what the engine can do: constrained output it can't produce is
    /// refused (ignoring it would return text that isn't the JSON the client is going to parse), a
    /// sampler option it doesn't have is ignored with a line in the log.
    func applyCapabilities(_ settings: GenerationSettings, forcesToolCall: Bool = false, engine: any Engine) throws {
        if settings.constraint != nil || forcesToolCall, !engine.capabilities.grammar {
            throw RequestError.invalid(
                "the engine serving this model can't constrain its output yet (response_format, json_schema, grammar, tool_choice)"
            )
        }
        if settings.sampling.usesExtraSamplers, !engine.capabilities.extraSamplers {
            log.log(.warn, "this model's engine ignores the dry, xtc, typical_p, top_n_sigma and mirostat settings")
        }
    }

    func generationRequest(
        tokens: [Int],
        settings: GenerationSettings,
        info: EngineInfo,
        reasoning: JSONSchemaGrammar.Reasoning = .none,
        forcedCall grammarOverride: String? = nil
    ) throws -> GenerationRequest {
        let grammar = try grammarOverride ?? settings.constraint?.gbnf(reasoning: reasoning)
        guard tokens.count < info.contextSize else {
            throw RequestError(
                status: 400,
                type: "exceed_context_size_error",
                message: "the request exceeds the available context size (\(tokens.count) prompt tokens, "
                    + "\(info.contextSize) in the context), try increasing it"
            )
        }
        return GenerationRequest(
            promptTokens: tokens,
            maxTokens: min(settings.maxTokens ?? Int.max, info.contextSize - tokens.count),
            sampling: settings.sampling,
            ignoreEndOfSequence: settings.ignoreEndOfSequence,
            cachePrompt: settings.cachePrompt,
            grammar: grammar
        )
    }

    // MARK: /v1/completions

    private func completions(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try jsonBody(request)
        let settings = try GenerationSettings(body)
        let id = try await modelID(body: body, request: request)
        let lease = try await router.acquire(id)

        let responseID = InferenceJSON.newID()
        let created = Int(Date().timeIntervalSince1970)
        do {
            try applyCapabilities(settings, engine: lease.engine)
            let info = await lease.engine.info()
            let tokens = try await promptTokens(body["prompt"], engine: lease.engine)
            let generation = try generationRequest(tokens: tokens, settings: settings, info: info)
            let pump = EventPump(TextGenerator.stream(engine: lease.engine, request: generation, stop: settings.stop))

            @Sendable func envelope(
                text: String,
                finish: FinishReason?,
                timings: GenerationTimings? = nil
            ) -> InferenceJSON.Completion {
                InferenceJSON.Completion(
                    choices: [.init(text: text, finishReason: finish.map(InferenceJSON.finishReason))],
                    created: created, model: id, systemFingerprint: buildLabel, id: responseID,
                    usage: timings.map(InferenceJSON.Usage.init), timings: timings.map(InferenceJSON.Timings.init)
                )
            }

            if !settings.stream {
                var text = ""
                var finished: (FinishReason, GenerationTimings)?
                while let event = try await pump.next() {
                    switch event {
                    case let .text(piece): text += piece
                    case let .finished(reason, timings): finished = (reason, timings)
                    }
                }
                await router.release(lease)
                let (reason, timings) = finished ?? (.stop, GenerationTimings(
                    promptTokens: tokens.count, promptSeconds: 0, generatedTokens: 0, generatedSeconds: 0
                ))
                return .json(200, envelope(text: text, finish: reason, timings: timings))
            }

            // Streaming: wait for the first event so a failure to start is a real HTTP error,
            // not a 200 with an error inside.
            let first = try await pump.next()
            return streamResponse(first: first, pump: pump, lease: lease) { event in
                switch event {
                case let .text(piece): InferenceJSON.sse(envelope(text: piece, finish: nil))
                case let .finished(reason, timings): InferenceJSON.sse(envelope(
                        text: "",
                        finish: reason,
                        timings: timings
                    ))
                }
            }
        } catch {
            await router.release(lease)
            throw error
        }
    }

    /// Sends events as SSE while a background task holds the model lease; the lease is released when
    /// the stream ends, however it ends, including the client going away.
    func streamResponse<Event: Sendable>(
        first: Event?,
        pump: EventPump<Event>,
        lease: ModelLease,
        opening: Data? = nil,
        closing: Data? = InferenceJSON.done,
        failure: @escaping @Sendable (any Error) -> Data = { error in
            InferenceJSON.sseError(message: error.localizedDescription, type: "server_error", code: 500)
        },
        encode: @escaping @Sendable (Event) -> Data
    ) -> HTTPResponse {
        let router = router
        let log = log
        let chunks = AsyncStream<Data> { continuation in
            let task = Task {
                do {
                    if let opening {
                        continuation.yield(opening)
                    }
                    var event = first
                    while let current = event {
                        continuation.yield(encode(current))
                        event = try await pump.next()
                    }
                } catch {
                    log.log(.warn, "generation failed mid-stream: \(error.localizedDescription)")
                    continuation.yield(failure(error))
                }
                if let closing {
                    continuation.yield(closing)
                }
                continuation.finish()
                await router.release(lease)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPResponse(
            status: 200,
            headers: [("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache")],
            body: .stream(chunks)
        )
    }

    // MARK: /v1/chat/completions

    private func chatCompletions(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try jsonBody(request)
        let settings = try GenerationSettings(body)
        let chat = try ChatRequest(body)
        let id = try await modelID(body: body, request: request)
        let run = try await startChat(chat, settings: settings, model: id)

        let responseID = InferenceJSON.newID()
        let created = Int(Date().timeIntervalSince1970)
        @Sendable func chunk(
            _ delta: InferenceJSON.ChatChunk.Delta, finish: FinishReason? = nil, timings: GenerationTimings? = nil,
            usage: Bool = false, noChoices: Bool = false
        ) -> Data {
            InferenceJSON.sse(InferenceJSON.ChatChunk(
                choices: noChoices ? [] : [.init(
                    delta: delta,
                    finishReason: finish.map(InferenceJSON.finishReason)
                )],
                created: created, id: responseID, model: id, systemFingerprint: buildLabel,
                usage: usage ? timings.map(InferenceJSON.Usage.init) : nil,
                timings: timings.map(InferenceJSON.Timings.init)
            ))
        }

        if !settings.stream {
            let reply = try await collect(run)
            return .json(200, InferenceJSON.ChatCompletion(
                choices: [.init(
                    message: .init(
                        content: reply.content,
                        reasoningContent: reply.reasoning.isEmpty ? nil : reply.reasoning,
                        toolCalls: reply.calls.isEmpty ? nil : reply.calls.map { InferenceJSON.ToolCall($0) }
                    ),
                    finishReason: InferenceJSON.finishReason(reply.reason)
                )],
                created: created, model: id, systemFingerprint: buildLabel, id: responseID,
                usage: InferenceJSON.Usage(reply.timings), timings: InferenceJSON.Timings(reply.timings)
            ))
        }

        let first = try await firstEvent(of: run)
        let includeUsage = settings.includeUsage
        let callCounter = CallCounter()
        // The role goes out first, as its own chunk, then the deltas.
        let opening = chunk(.init(role: "assistant", nullContent: true))
        return streamResponse(first: first, pump: run.pump, lease: run.lease, opening: opening) { event in
            switch event {
            case let .delta(.content(piece)): return chunk(.init(content: piece))
            case let .delta(.reasoning(piece)): return chunk(.init(reasoningContent: piece))
            case let .delta(.toolCall(call)):
                // A call goes out whole, in one delta; a client concatenates arguments either way.
                return chunk(.init(toolCalls: [InferenceJSON.ToolCall(call, index: callCounter.next())]))
            case let .finished(reason, timings):
                var frames = chunk(.init(), finish: reason, timings: timings)
                if includeUsage {
                    frames += chunk(.init(), timings: timings, usage: true, noChoices: true)
                }
                return frames
            }
        }
    }

    /// A chat generation under way. Whoever holds it must give the lease back, which `collect` and
    /// `streamResponse` do however they end.
    struct ChatRun: Sendable {
        let lease: ModelLease
        let pump: EventPump<ChatEvent>
        let promptTokens: Int
    }

    /// Everything a whole (non-streamed) reply says.
    struct ChatReply {
        var content = ""
        var reasoning = ""
        var calls: [ParsedToolCall] = []
        var reason = FinishReason.stop
        var timings: GenerationTimings
    }

    /// Loads the model if need be, renders and tokenizes the prompt, and starts generating.
    func startChat(_ chat: ChatRequest, settings: GenerationSettings, model id: String) async throws -> ChatRun {
        let lease = try await router.acquire(id)
        do {
            try applyCapabilities(settings, forcesToolCall: chat.toolChoice.forcesCall, engine: lease.engine)
            let info = await lease.engine.info()
            let tokens = try await promptTokens(for: chat, engine: lease.engine, info: info)
            // A constrained reply comes after the thinking block, if the template has one.
            let reasoning: JSONSchemaGrammar.Reasoning = tokens.thinkingIsOpen ? .open
                : tokens.supportsThinking ? .optional : .none
            if settings.constraint != nil, tokens.toolFormat == .harmony {
                throw RequestError
                    .invalid("constrained output isn't supported for this model's chat format (Harmony) yet")
            }
            var forcedCall: String?
            if chat.toolChoice.forcesCall {
                if settings.constraint != nil {
                    throw RequestError
                        .invalid("tool_choice can't be combined with response_format, json_schema or grammar")
                }
                var name: String?
                if case let .named(named) = chat.toolChoice {
                    name = named
                }
                forcedCall = try JSONSchemaGrammar.toolCalls(
                    tools: chat.tools ?? [],
                    name: name,
                    format: tokens.toolFormat,
                    parallel: chat.parallelToolCalls,
                    reasoning: reasoning
                )
            }
            let generation = try generationRequest(
                tokens: tokens.ids,
                settings: settings,
                info: info,
                reasoning: reasoning,
                forcedCall: forcedCall
            )
            let text = TextGenerator.stream(engine: lease.engine, request: generation, stop: settings.stop)
            let parser = ChatOutputParser(
                format: tokens.toolFormat,
                tools: chat.toolsEnabled ? chat.tools ?? [] : [],
                startsInReasoning: tokens.thinkingIsOpen
            )
            return ChatRun(
                lease: lease,
                pump: EventPump(ChatStream.events(from: text, parser: parser)),
                promptTokens: tokens.ids.count
            )
        } catch {
            await router.release(lease)
            throw error
        }
    }

    /// The chat prompt as token ids, with what the template says about the reply.
    func promptTokens(
        for chat: ChatRequest, engine: any Engine, info: EngineInfo
    ) async throws -> (ids: [Int], thinkingIsOpen: Bool, supportsThinking: Bool, toolFormat: ToolCallFormat) {
        let prompt = try await renderPrompt(chat, engine: engine, info: info)
        // A template that starts with the BOS text already has one; don't add a second.
        let addSpecial = info.bosToken.isEmpty || !prompt.text.hasPrefix(info.bosToken)
        let ids = try await engine.tokenize(prompt.text, addSpecial: addSpecial, parseSpecial: true)
        return (ids, prompt.thinkingIsOpen, prompt.supportsThinking, prompt.toolFormat)
    }

    /// Reads a run to its end, then releases the lease.
    func collect(_ run: ChatRun) async throws -> ChatReply {
        var reply = ChatReply(timings: GenerationTimings(
            promptTokens: run.promptTokens, promptSeconds: 0, generatedTokens: 0, generatedSeconds: 0
        ))
        do {
            while let event = try await run.pump.next() {
                switch event {
                case let .delta(.content(piece)): reply.content += piece
                case let .delta(.reasoning(piece)): reply.reasoning += piece
                case let .delta(.toolCall(call)): reply.calls.append(call)
                case let .finished(reason, timings): (reply.reason, reply.timings) = (reason, timings)
                }
            }
        } catch {
            await router.release(run.lease)
            throw error
        }
        await router.release(run.lease)
        return reply
    }

    /// Waits for the first event so a failure to start is a real HTTP error, not a 200 with an
    /// error inside.
    func firstEvent(of run: ChatRun) async throws -> ChatEvent? {
        do {
            return try await run.pump.next()
        } catch {
            await router.release(run.lease)
            throw error
        }
    }

    /// The prompt text for a chat request, and whether its template left a `<think>` open.
    private func renderPrompt(
        _ chat: ChatRequest, engine: any Engine, info: EngineInfo
    ) async throws -> (text: String, thinkingIsOpen: Bool, supportsThinking: Bool, toolFormat: ToolCallFormat) {
        let source = await engine.chatTemplate() ?? ChatMessages.chatMLTemplate
        let compiled: (template: ChatTemplate, style: ChatMessages.ContentStyle)
        do {
            compiled = try templates.compiled(source)
        } catch {
            throw RequestError(status: 500, type: "server_error", message: error.localizedDescription)
        }
        let messages = try ChatMessages.normalize(
            chat.messages,
            style: compiled.style,
            templateKnowsDeveloperRole: source.contains("developer")
        )
        do {
            let text = try compiled.template.render(.init(
                messages: messages,
                tools: chat.toolsEnabled ? chat.tools : nil,
                addGenerationPrompt: true,
                bosToken: info.bosToken,
                eosToken: info.eosToken,
                extra: chat.templateKwargs
            ))
            let tail = text.reversed().drop(while: { $0.isWhitespace })
            return (
                text,
                String(tail.reversed()).hasSuffix(ReasoningSplitter.open),
                source.contains(ReasoningSplitter.open),
                ToolCallFormat.detect(template: source)
            )
        } catch {
            throw RequestError.invalid(error.localizedDescription)
        }
    }

    // MARK: /tokenize, /detokenize

    private func tokenize(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try jsonBody(request)
        let id = try await modelID(body: body, request: request)
        guard let content = body["content"]?.stringValue else { return .json(200, ["tokens": [Int]()]) }
        let addSpecial = body["add_special"]?.boolValue ?? false
        let parseSpecial = body["parse_special"]?.boolValue ?? true
        let withPieces = body["with_pieces"]?.boolValue ?? false
        return try await router.withEngine(id) { engine in
            let tokens = try await engine.tokenize(content, addSpecial: addSpecial, parseSpecial: parseSpecial)
            guard withPieces else { return HTTPResponse.json(200, ["tokens": tokens]) }
            struct Piece: Encodable {
                let id: Int
                let piece: String
            }
            var pieces: [Piece] = []
            for token in tokens {
                try await pieces.append(Piece(id: token, piece: engine.detokenize([token])))
            }
            return HTTPResponse.json(200, ["tokens": pieces])
        }
    }

    private func detokenize(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try jsonBody(request)
        let id = try await modelID(body: body, request: request)
        let tokens = body["tokens"]?.arrayValue?.compactMap(\.intValue) ?? []
        return try await router.withEngine(id) { engine in
            try await HTTPResponse.json(200, ["content": engine.detokenize(tokens)])
        }
    }

    // MARK: /props

    private func props(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard URLComponents(string: request.target)?.queryItems?.contains(where: { $0.name == "model" }) == true else {
            // A router with no model chosen describes itself, as llama-server's does.
            let overview: [String: Any] = [
                "role": "router",
                "max_instances": router.modelsMax,
                "models_autoload": true,
                "model_alias": "quail-server",
                "model_path": "none",
                "default_generation_settings": ["params": NSNull(), "n_ctx": 0] as [String: Any],
                "ui_settings": [String: Any](),
                "build_info": buildLabel,
                "cors_proxy_enabled": false,
            ]
            return Self.json(overview)
        }
        let id = try await modelID(body: nil, request: request)
        let snapshot = await router.snapshot(id)
        return try await router.withEngine(id) { engine in
            let info = await engine.info()
            let template = await engine.chatTemplate() ?? ""
            let defaults = SamplingParameters()
            let params: [String: Any] = [
                "seed": 4_294_967_295,
                "temperature": defaults.temperature,
                "top_k": defaults.topK,
                "top_p": defaults.topP,
                "min_p": defaults.minP,
                "repeat_penalty": defaults.repeatPenalty,
                "presence_penalty": defaults.presencePenalty,
                "frequency_penalty": defaults.frequencyPenalty,
                "max_tokens": -1,
                "n_predict": -1,
                "ignore_eos": false,
                "stream": false,
            ]
            let props: [String: Any] = [
                "default_generation_settings": ["params": params, "n_ctx": info.contextSize] as [String: Any],
                "total_slots": 1,
                "model_alias": id,
                "model_path": snapshot?.entry.path.path ?? "",
                "modalities": [
                    "vision": snapshot?.entry.projector != nil,
                    "video": false,
                    "audio": false,
                ] as [String: Any],
                "endpoint_slots": false,
                "endpoint_props": false,
                "endpoint_metrics": false,
                "ui": webUI,
                "ui_settings": [String: Any](),
                "chat_template": template,
                "bos_token": info.bosToken,
                "eos_token": info.eosToken,
                "build_info": buildLabel,
                "is_sleeping": false,
                "cors_proxy_enabled": false,
            ]
            return Self.json(props)
        }
    }

    static func json(_ object: [String: Any]) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            headers: [("Content-Type", "application/json; charset=utf-8")],
            body: .data(InferenceJSON.jsonData(object))
        )
    }
}

/// One consumer at a time — the request handler reads the first event, then the streaming task
/// takes over — so the iterator needs no lock.
final class EventPump<Event: Sendable>: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Event, any Error>.AsyncIterator

    init(_ stream: AsyncThrowingStream<Event, any Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> Event? {
        try await iterator.next()
    }
}

/// Numbers a reply's tool calls 0, 1, 2… as they're sent.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}

/// Compiled templates, by source text: parsing an 8 KB Jinja template on every request would be
/// most of a short request's cost.
final class TemplateCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (template: ChatTemplate, style: ChatMessages.ContentStyle)] = [:]

    func compiled(_ source: String) throws -> (template: ChatTemplate, style: ChatMessages.ContentStyle) {
        if let hit = lock.withLock({ entries[source] }) {
            return hit
        }
        let template = try ChatTemplate(source)
        let entry = (template: template, style: ChatMessages.contentStyle(of: template))
        lock.withLock {
            if entries.count >= 8 {
                entries.removeAll()
            } // a handful of models is all one server holds
            entries[source] = entry
        }
        return entry
    }
}
