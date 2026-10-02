import Foundation

/// `quail bench --url` (ADR D-064): a speed benchmark for any server that speaks OpenAI's chat completions, timed
/// from the client. It's the same shape of test as `quail-bench-1`: prompts of 512 and 4,096 tokens, 256 tokens
/// generated, time to first token, a returning turn and four requests at once. But it can't use what only
/// llama-server and Quail offer (`/tokenize`, the server's own `timings`, loading and unloading), so it's a
/// suite of its own and its numbers aren't compared with `quail-bench-1`'s:
/// - Prompts are text, sized from the server's own token counts (`usage`) after two calibration requests.
/// - Prompt speed is the prompt's tokens over the time to the first token, so it includes the network and the
///   first token's generation, as GuideLLM's does.
/// - Generation speed is the tokens after the first over the time from the first to the last.
/// - Every timed prompt starts with a tag of its own, so no server's prefix cache can answer it.
/// - There's no load time: a server that isn't Quail can't be asked to load a model.
enum URLBenchmarkSuite {
    static let id = "quail-bench-url-1"

    static let promptSizes = [512, 4096]
    static let generateTokens = 256
    static let warmupRuns = 1
    static let measuredRuns = 3
    static let returningTurnPromptTokens = 2048
    static let returningTurnNewTokens = 64
    static let concurrentRequests = 4
    static let concurrentTokens = 128
    /// The generation test's prompt, about this many tokens.
    static let generationPromptTokens = 16

    /// The text prompts are made of: `quail-bench-1`'s passage, so the two suites read the same words.
    static var words: [Substring] {
        BenchmarkPassage.text.split(separator: " ")
    }

    /// `count` words of the passage, repeated as needed and starting `offset` words in, after `tag`.
    static func prompt(tag: String, words count: Int, offset: Int = 0) -> String {
        let source = words
        guard count > 0 else { return tag }
        let body = (0 ..< count).map { source[($0 + offset) % source.count] }.joined(separator: " ")
        return "\(tag) \(body)"
    }
}

/// The text both benchmark suites' prompts are made of. `quail-bench-1` tokenizes it per model; changing it
/// would make earlier results incomparable, so it's never edited.
enum BenchmarkPassage {
    static let text = """
    The lighthouse keeper kept a log of every ship that passed the point, \
    noting the hour, the weather, the direction of the wind and the colour \
    of the water. Over forty years the entries grew into a record of the \
    coast itself: storms that moved the sandbars, winters when the harbour \
    froze, summers when the fishing boats came home early because the \
    shoals had gone somewhere else. Scientists later used the log to study \
    how the currents had shifted, and historians used it to date the \
    wrecks that divers found along the reef. The keeper never thought of \
    it as data. To him it was simply the day's work, written down in the \
    same careful hand each evening before he climbed the stairs to light \
    the lamp.
    """
}

/// One streamed chat reply, timed from when the request was sent.
struct StreamedReply: Sendable, Equatable {
    /// The server's own counts (`usage`), when it sends them.
    var promptTokens: Int?
    var completionTokens: Int?
    /// Chunks that carried text, reasoning or a tool call: the token count when the server sends no `usage`.
    var chunks: Int
    var firstTokenSeconds: Double?
    var lastTokenSeconds: Double?

    /// The tokens it generated, by the server's count if it gave one.
    var generated: Int {
        completionTokens ?? chunks
    }
}

/// What the URL benchmark asks of a server.
protocol URLBenchmarkClient: Sendable {
    /// The ids `/v1/models` lists.
    func models() async throws -> [String]
    func chat(model: String, prompt: String, maxTokens: Int) async throws -> StreamedReply
}

enum URLBenchmarkError: Error, Equatable, CustomStringConvertible {
    case http(Int, String?)
    case badResponse(String)
    case noModels
    case noUsage

    var description: String {
        switch self {
        case let .http(status, message): "The server answered HTTP \(status)\(message.map { ": \($0)" } ?? "")."
        case let .badResponse(what): "Unexpected answer from the server (\(what))."
        case .noModels: "The server lists no models at /v1/models; name one with --model."
        case .noUsage:
            "The server doesn't report token counts (usage), so prompts of a given size can't be made for it."
        }
    }
}

/// A `quail bench --url` run, as `--json` prints it.
struct URLBenchmarkResult: Codable, Sendable, Equatable {
    var suite = URLBenchmarkSuite.id
    var date: Date
    var quailVersion: String?
    var url: String
    var model: String
    /// The same fields as `quail-bench-1`'s, `loadSeconds` always empty.
    var measurements: BenchmarkResult.Measurements
    /// Each prompt test's size as the server counted it ("512" → 517): text prompts can't hit a size exactly.
    var promptTokens: [String: Int] = [:]
    /// What makes these numbers less exact, in words.
    var notes: [String] = []
}

struct URLBenchmarkRunner: Sendable {
    let client: any URLBenchmarkClient

    /// Runs the suite on `model`. `progress` gets each step's description and the fraction done.
    func run(
        model: String, url: String, quailVersion: String? = nil, date: Date = .init(),
        progress: @Sendable (String, Double) async -> Void = { _, _ in }
    ) async throws -> URLBenchmarkResult {
        var result = URLBenchmarkResult(
            date: date,
            quailVersion: quailVersion,
            url: url,
            model: model,
            measurements: .init()
        )
        var counter = 0
        /// A tag no earlier prompt started with, so no prefix cache answers it.
        func tag() -> String {
            counter += 1
            return "Request \(counter)-\(UUID().uuidString.prefix(8)):"
        }

        // Calibration: how many tokens a word of the passage is on this server, and what the chat template adds.
        await progress("Measuring the server's tokens…", 0.02)
        let wordsPerPassage = URLBenchmarkSuite.words.count
        let one = try await client.chat(
            model: model, prompt: URLBenchmarkSuite.prompt(tag: tag(), words: wordsPerPassage), maxTokens: 1
        )
        let four = try await client.chat(
            model: model, prompt: URLBenchmarkSuite.prompt(tag: tag(), words: 4 * wordsPerPassage), maxTokens: 1
        )
        guard let small = one.promptTokens, let large = four.promptTokens, large > small else {
            throw URLBenchmarkError.noUsage
        }
        let tokensPerWord = Double(large - small) / Double(3 * wordsPerPassage)
        let overhead = Double(small) - tokensPerWord * Double(wordsPerPassage)
        func words(for tokens: Int) -> Int {
            max(1, Int((Double(tokens) - overhead) / tokensPerWord))
        }

        let generationPrompt = { (tag: String) in
            URLBenchmarkSuite.prompt(tag: tag, words: words(for: URLBenchmarkSuite.generationPromptTokens))
        }
        for run in 0 ..< URLBenchmarkSuite.warmupRuns {
            await progress("Warming up (\(run + 1)/\(URLBenchmarkSuite.warmupRuns))…", 0.08)
            _ = try await client.chat(model: model, prompt: generationPrompt(tag()), maxTokens: 16)
        }

        let runs = URLBenchmarkSuite.measuredRuns
        let steps = Double((URLBenchmarkSuite.promptSizes.count + 3) * runs)
        var done = 0.0
        func fraction() -> Double {
            0.1 + 0.88 * done / steps
        }

        for size in URLBenchmarkSuite.promptSizes {
            var speeds: [Double] = [], firstTokens: [Double] = [], counted: [Int] = []
            var refused: String?
            for run in 0 ..< runs {
                defer { done += 1 }
                guard refused == nil else { continue }
                await progress("Prompt \(size) tokens (\(run + 1)/\(runs))…", fraction())
                let reply: StreamedReply
                do {
                    reply = try await client.chat(
                        model: model, prompt: URLBenchmarkSuite.prompt(
                            tag: tag(),
                            words: words(for: size),
                            offset: run
                        ),
                        maxTokens: 1
                    )
                } catch let URLBenchmarkError.http(status, message) where (400 ..< 500).contains(status) {
                    // Most likely longer than the model's context.
                    refused = "HTTP \(status)\(message.map { ": \($0)" } ?? "")"
                    continue
                }
                guard let tokens = reply.promptTokens, let first = reply.firstTokenSeconds, first > 0 else { continue }
                speeds.append(Double(tokens) / first)
                firstTokens.append(first * 1000)
                counted.append(tokens)
            }
            if let refused {
                result.measurements.skipped.append("prompt \(size): the server refused it (\(refused))")
                continue
            }
            if let median = BenchmarkResult.Stat.of(counted.map(Double.init))?.median {
                result.promptTokens[String(size)] = Int(median)
            }
            switch size {
            case 512:
                result.measurements.prompt512 = .of(speeds)
                result.measurements.timeToFirstTokenMs = .of(firstTokens)
            case 4096:
                result.measurements.prompt4096 = .of(speeds)
            default:
                break
            }
        }

        var speeds: [Double] = []
        var short: [Int] = []
        for run in 0 ..< runs {
            await progress("Generating \(URLBenchmarkSuite.generateTokens) tokens (\(run + 1)/\(runs))…", fraction())
            let reply = try await client.chat(
                model: model, prompt: generationPrompt(tag()), maxTokens: URLBenchmarkSuite.generateTokens
            )
            done += 1
            if let speed = Self.generationSpeed(reply) {
                speeds.append(speed)
            }
            if reply.generated < URLBenchmarkSuite.generateTokens {
                short.append(reply.generated)
            }
        }
        result.measurements.generation256 = .of(speeds)
        if !short.isEmpty {
            result.notes.append(
                "the server stopped early (\(short.map(String.init).joined(separator: ", ")) of "
                    + "\(URLBenchmarkSuite.generateTokens) tokens): it doesn't honour ignore_eos, so generation was "
                    + "timed over what it wrote"
            )
        }
        if speeds.isEmpty || one.completionTokens == nil {
            result.notes.append("the server sent no token counts for replies, so streamed chunks were counted instead")
        }

        // A returning conversation: a 2,048-token prompt, then the same with 64 tokens more, its cache allowed.
        var returning: [Double] = []
        for run in 0 ..< runs {
            await progress("Returning turn (\(run + 1)/\(runs))…", fraction())
            let base = words(for: URLBenchmarkSuite.returningTurnPromptTokens)
            let more = Int(Double(URLBenchmarkSuite.returningTurnNewTokens) / tokensPerWord)
            let label = tag()
            _ = try await client.chat(
                model: model, prompt: URLBenchmarkSuite.prompt(tag: label, words: base, offset: run), maxTokens: 1
            )
            let next = try await client.chat(
                model: model, prompt: URLBenchmarkSuite.prompt(tag: label, words: base + more, offset: run),
                maxTokens: 1
            )
            done += 1
            if let first = next.firstTokenSeconds {
                returning.append(first * 1000)
            }
        }
        result.measurements.returningTurnMs = .of(returning)

        var totals: [Double] = []
        for run in 0 ..< runs {
            await progress("\(URLBenchmarkSuite.concurrentRequests) requests at once (\(run + 1)/\(runs))…", fraction())
            let prompts = (0 ..< URLBenchmarkSuite.concurrentRequests).map { _ in generationPrompt(tag()) }
            let started = ContinuousClock.now
            let generated = try await withThrowingTaskGroup(of: Int.self) { group in
                for prompt in prompts {
                    group.addTask {
                        try await client.chat(
                            model: model, prompt: prompt, maxTokens: URLBenchmarkSuite.concurrentTokens
                        ).generated
                    }
                }
                return try await group.reduce(0, +)
            }
            let seconds = Self.seconds(ContinuousClock.now - started)
            if seconds > 0 {
                totals.append(Double(generated) / seconds)
            }
            done += 1
        }
        result.measurements.concurrent4 = .of(totals)
        result.measurements.skipped.append("load: a server other than Quail can't be asked to load a model")
        return result
    }

    /// Tokens after the first over the time from the first to the last; `nil` with fewer than two.
    static func generationSpeed(_ reply: StreamedReply) -> Double? {
        guard reply.generated > 1, let first = reply.firstTokenSeconds, let last = reply.lastTokenSeconds,
              last > first else { return nil }
        return Double(reply.generated - 1) / (last - first)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// `URLBenchmarkClient` over HTTP: `/v1/models` and streamed `/v1/chat/completions`, asking for `usage` in the
/// stream (`stream_options.include_usage`) and for every token asked (`ignore_eos`, which llama-server and Quail
/// honour and others ignore). Deterministic sampling, as `quail-bench-1`.
struct OpenAIBenchmarkClient: URLBenchmarkClient {
    let base: URL
    let apiKey: String?
    var urlSession: URLSession = .shared

    /// `http://host:port`, `…/` or `…/v1` all mean the same server.
    static func base(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.hasSuffix("/v1") {
            trimmed.removeLast(3)
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    func models() async throws -> [String] {
        struct Response: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        let (data, response) = try await urlSession
            .data(for: authorized(URLRequest(url: base.appending(path: "v1/models"))))
        try Self.check(response, data)
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw URLBenchmarkError.badResponse("/v1/models")
        }
        return decoded.data.map(\.id)
    }

    func chat(model: String, prompt: String, maxTokens: Int) async throws -> StreamedReply {
        let body: [String: Any] = [
            "model": model, "messages": [["role": "user", "content": prompt]], "max_tokens": maxTokens,
            "stream": true, "stream_options": ["include_usage": true], "temperature": 0, "seed": 42,
            "ignore_eos": true,
        ]
        var request = authorized(URLRequest(url: base.appending(path: "v1/chat/completions")))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = ContinuousClock.now
        let (bytes, response) = try await urlSession.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            try Self.check(response, data)
        }
        var reply = StreamedReply(chunks: 0)
        for try await line in bytes.lines {
            let elapsed = Self.seconds(ContinuousClock.now - started)
            switch Self.parse(line) {
            case .done:
                return reply
            case let .chunk(hasToken, usage):
                if hasToken {
                    reply.chunks += 1
                    reply.firstTokenSeconds = reply.firstTokenSeconds ?? elapsed
                    reply.lastTokenSeconds = elapsed
                }
                if let usage {
                    reply.promptTokens = usage.prompt ?? reply.promptTokens
                    reply.completionTokens = usage.completion ?? reply.completionTokens
                }
            case .none:
                break
            }
        }
        return reply
    }

    struct Usage: Equatable {
        var prompt: Int?
        var completion: Int?
    }

    enum Line: Equatable {
        case chunk(hasToken: Bool, usage: Usage?)
        case done
    }

    /// One SSE line: a chunk (whether it carried a token, and its `usage`), the end, or nothing.
    static func parse(_ line: String) -> Line? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return .done
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            return nil
        }
        var hasToken = false
        if let delta = (object["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] {
            for key in ["content", "reasoning_content", "reasoning"] {
                if let text = delta[key] as? String, !text.isEmpty {
                    hasToken = true
                }
            }
            if let calls = delta["tool_calls"] as? [Any], !calls.isEmpty {
                hasToken = true
            }
        }
        let usage = (object["usage"] as? [String: Any]).map {
            Usage(prompt: $0["prompt_tokens"] as? Int, completion: $0["completion_tokens"] as? Int)
        }
        return .chunk(hasToken: hasToken, usage: usage)
    }

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw URLBenchmarkError.badResponse("no HTTP response") }
        guard (200 ..< 300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap {
                ($0["error"] as? [String: Any])?["message"] as? String ?? $0["error"] as? String
            }
            throw URLBenchmarkError.http(http.statusCode, message)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
