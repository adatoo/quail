import ArgumentParser
import Darwin
import Foundation

/// `quail run <model> [prompt]` — chat with a model in the terminal
/// (ADR D-021: for judging a model; no saved history, attachments or tools).
struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Chat with a model. With a prompt (or piped input), answer once and exit.",
        discussion: "In a chat: /clear forgets the conversation, /bye exits."
    )

    @Argument(help: "Model name (see `quail list`). Defaults to the default model.")
    var model: String?

    @Argument(parsing: .remaining, help: "A prompt to answer once, then exit.")
    var prompt: [String] = []

    @Flag(help: "Hide a reasoning model's thinking.") var hideThinking = false

    func run() async throws {
        try await AppLink.ensureRunning()
        let endpointResponse = try await AppLink.request(ControlRequest(command: .endpoint))
        try AppLink.check(endpointResponse)
        guard let endpoint = endpointResponse.endpoint, let base = URL(string: endpoint.baseURL) else {
            throw CLIError("No endpoint from Quail.")
        }
        guard let model = model ?? endpoint.defaultModel else {
            throw CLIError("No model given and no default set. See `quail list`.")
        }
        let chat = Chat(base: base, apiKey: endpoint.apiKey, model: model, showThinking: !hideThinking)

        if !prompt.isEmpty {
            return try await chat.send(prompt.joined(separator: " "))
        }
        if isatty(STDIN_FILENO) == 0 {
            let piped = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            return try await chat.send(piped)
        }

        print(Output.dim("Chatting with \(model). /clear to forget, /bye to exit."))
        while true {
            print(">>> ", terminator: "")
            fflush(stdout)
            guard let line = readLine() else { break }
            let text = line.trimmingCharacters(in: .whitespaces)
            switch text {
            case "": continue
            case "/bye", "/exit", "/quit": return
            case "/clear":
                chat.clear()
                print(Output.dim("Forgot the conversation."))
            default:
                do {
                    try await chat.send(text)
                } catch {
                    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
                }
            }
        }
    }
}

/// One conversation's worth of messages, streamed from
/// `/v1/chat/completions`.
final class Chat: @unchecked Sendable {
    private let base: URL
    private let apiKey: String?
    private let model: String
    private let showThinking: Bool
    private var messages: [[String: String]] = []

    init(base: URL, apiKey: String?, model: String, showThinking: Bool) {
        self.base = base
        self.apiKey = apiKey
        self.model = model
        self.showThinking = showThinking
    }

    func clear() {
        messages = []
    }

    func send(_ text: String) async throws {
        messages.append(["role": "user", "content": text])
        var request = URLRequest(url: base.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "messages": messages, "stream": true,
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw CLIError("No HTTP response") }
        guard (200 ..< 300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
            }
            let message = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw CLIError("HTTP \(http.statusCode)\(message.map { ": \($0)" } ?? "")")
        }

        var reply = ""
        var thinking = false
        var stats: String?
        for try await line in bytes.lines {
            for event in ChatStreamParser.events(fromLine: line) {
                switch event {
                case let .reasoning(text):
                    guard showThinking else { continue }
                    if !thinking {
                        thinking = true
                        print(Output.dim("Thinking…"))
                    }
                    print(Output.dim(text), terminator: "")
                case let .delta(text):
                    if thinking {
                        thinking = false
                        print("\n")
                    }
                    reply += text
                    print(text, terminator: "")
                case let .timings(_, perSecond, tokens):
                    if let perSecond {
                        stats = "\(tokens.map { "\($0) tokens · " } ?? "")\(String(format: "%.1f", perSecond)) tok/s"
                    }
                case .done:
                    break
                }
                fflush(stdout)
            }
        }
        print()
        if let stats {
            print(Output.dim(stats))
        }
        messages.append(["role": "assistant", "content": reply])
    }
}
