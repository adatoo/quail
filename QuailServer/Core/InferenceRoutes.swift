import Foundation
import Jinja

/// The routes that run a model: `/v1/completions` (the benchmark's), `/tokenize`, `/detokenize`
/// and `/props`. Written once over the `Engine` seam, so GGUF and MLX models answer the same way.
struct InferenceRoutes: Sendable {
    let router: ModelRouter
    let log: ServerLog
    /// Reported as `system_fingerprint` and `build_info`.
    let buildLabel: String
    private let templates = TemplateCache()

    /// `nil` for a path this type doesn't serve.
    func handle(_ request: HTTPRequest) async -> HTTPResponse? {
        switch request.path {
        case "/v1/completions":
            await guarded(request, method: "POST") { try await completions(request) }
        case "/v1/chat/completions", "/chat/completions":
            await guarded(request, method: "POST") { try await chatCompletions(request) }
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

    private func guarded(
        _ request: HTTPRequest,
        method: String,
        _ body: () async throws -> HTTPResponse
    ) async -> HTTPResponse {
        guard request.method == method else {
            return .error(405, type: "invalid_request_error", message: "Method Not Allowed")
        }
        do {
            return try await body()
        } catch let error as RequestError {
            return error.response
        } catch let error as RouterError {
            return Self.response(for: error)
        } catch {
            return .error(500, type: "server_error", message: error.localizedDescription)
        }
    }

    // MARK: Shared

    private func jsonBody(_ request: HTTPRequest) throws -> Value {
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
    private func modelID(body: Value?, request: HTTPRequest) async throws -> String {
        var id = body?["model"]?.stringValue
        if id == nil, let query = URLComponents(string: request.target)?.queryItems {
            id = query.first { $0.name == "model" }?.value
        }
        guard let id, !id.isEmpty else { throw RequestError.invalid("model name is missing from the request") }
        guard await router.snapshot(id) != nil else { throw RequestError.invalid("model '\(id)' not found") }
        return id
    }

    static func response(for error: RouterError) -> HTTPResponse {
        switch error {
        case .unknownModel: .error(400, type: "invalid_request_error", message: error.localizedDescription)
        case .shuttingDown: .error(503, type: "unavailable_error", message: error.localizedDescription)
        case .loadFailed: .error(500, type: "server_error", message: error.localizedDescription)
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

    private func generationRequest(
        tokens: [Int],
        settings: GenerationSettings,
        info: EngineInfo
    ) throws -> GenerationRequest {
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
            cachePrompt: settings.cachePrompt
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
    private func streamResponse<Event: Sendable>(
        first: Event?,
        pump: EventPump<Event>,
        lease: ModelLease,
        opening: Data? = nil,
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
                    continuation.yield(InferenceJSON.sseError(
                        message: error.localizedDescription,
                        type: "server_error",
                        code: 500
                    ))
                }
                continuation.yield(InferenceJSON.done)
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
        let lease = try await router.acquire(id)

        let responseID = InferenceJSON.newID()
        let created = Int(Date().timeIntervalSince1970)
        do {
            let info = await lease.engine.info()
            let prompt = try await renderPrompt(chat, engine: lease.engine, info: info)
            // A template that starts with the BOS text already has one; don't add a second.
            let addSpecial = info.bosToken.isEmpty || !prompt.text.hasPrefix(info.bosToken)
            let tokens = try await lease.engine.tokenize(prompt.text, addSpecial: addSpecial, parseSpecial: true)
            let generation = try generationRequest(tokens: tokens, settings: settings, info: info)
            let text = TextGenerator.stream(engine: lease.engine, request: generation, stop: settings.stop)
            let parser = ChatOutputParser(
                format: prompt.toolFormat,
                tools: chat.toolsEnabled ? chat.tools ?? [] : [],
                startsInReasoning: prompt.thinkingIsOpen
            )
            let pump = EventPump(ChatStream.events(from: text, parser: parser))

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
                var content = "", reasoning = ""
                var calls: [InferenceJSON.ToolCall] = []
                var finished: (FinishReason, GenerationTimings)?
                while let event = try await pump.next() {
                    switch event {
                    case let .delta(.content(piece)): content += piece
                    case let .delta(.reasoning(piece)): reasoning += piece
                    case let .delta(.toolCall(call)): calls.append(InferenceJSON.ToolCall(call))
                    case let .finished(reason, timings): finished = (reason, timings)
                    }
                }
                await router.release(lease)
                let (reason, timings) = finished ?? (.stop, GenerationTimings(
                    promptTokens: tokens.count, promptSeconds: 0, generatedTokens: 0, generatedSeconds: 0
                ))
                return .json(200, InferenceJSON.ChatCompletion(
                    choices: [.init(
                        message: .init(
                            content: content,
                            reasoningContent: reasoning.isEmpty ? nil : reasoning,
                            toolCalls: calls.isEmpty ? nil : calls
                        ),
                        finishReason: InferenceJSON.finishReason(reason)
                    )],
                    created: created, model: id, systemFingerprint: buildLabel, id: responseID,
                    usage: InferenceJSON.Usage(timings), timings: InferenceJSON.Timings(timings)
                ))
            }

            let first = try await pump.next()
            let includeUsage = settings.includeUsage
            let callCounter = CallCounter()
            // The role goes out first, as its own chunk, then the deltas.
            let opening = chunk(.init(role: "assistant", nullContent: true))
            return streamResponse(first: first, pump: pump, lease: lease, opening: opening) { event in
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
        } catch {
            await router.release(lease)
            throw error
        }
    }

    /// The prompt text for a chat request, and whether its template left a `<think>` open.
    private func renderPrompt(
        _ chat: ChatRequest, engine: any Engine, info: EngineInfo
    ) async throws -> (text: String, thinkingIsOpen: Bool, toolFormat: ToolCallFormat) {
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
                "ui": false,
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

    private static func json(_ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        return HTTPResponse(
            status: 200,
            headers: [("Content-Type", "application/json; charset=utf-8")],
            body: .data(data)
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
