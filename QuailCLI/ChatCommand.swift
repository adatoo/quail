import ArgumentParser
import Darwin
import Foundation

/// `quail chat [model] [prompt…]` — chat with a model in the terminal
/// (ADR D-021: for judging a model; no saved history, attachments or tools).
/// Whether the first word is a model or the start of the prompt is decided
/// by `ChatTarget` (ADR D-025).
struct ChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Chat with a model. With a prompt (or piped input), answer once and exit.",
        discussion: """
        The first word is the model if it names an installed model (a unique \
        prefix is enough); otherwise everything is the prompt and the default \
        model answers. Use -m to name the model outright.

        Examples:
          quail chat                        default model, interactive
          quail chat qwen3                  qwen3, interactive
          quail chat why is the sky blue    default model, one answer
          quail chat qwen3 why is the sky blue
          quail chat -m qwen3 why is the sky blue

        In a chat: /clear forgets the conversation, /bye exits.
        """
    )

    @Option(
        name: .shortAndLong,
        help: "Model name (see `quail list`); a unique prefix is enough. Defaults to the default model."
    )
    var model: String?

    @Argument(parsing: .remaining, help: "[model] [prompt…] — a prompt is answered once, then exit.")
    var words: [String] = []

    @Flag(help: "Hide a reasoning model's thinking.") var hideThinking = false

    func run() async throws {
        let endpoint = try await Self.endpoint()
        guard let base = URL(string: endpoint.baseURL) else { throw CLIError("No endpoint from Quail.") }

        var target = ChatTarget.Resolved(model: nil, prompt: words)
        if model != nil || !words.isEmpty {
            let response = try await AppLink.request(ControlRequest(command: .list))
            try AppLink.check(response)
            do {
                target = try ChatTarget.resolve(
                    words: words,
                    explicitModel: model,
                    installed: (response.models ?? []).map(\.id)
                )
            } catch let failure as ChatTarget.Failure {
                throw CLIError(failure.description)
            }
        }
        guard let model = target.model ?? endpoint.defaultModel else {
            throw CLIError("No model given and no default set. Use -m <model> (see `quail list`).")
        }
        let chat = Chat(base: base, apiKey: endpoint.apiKey, model: model, showThinking: !hideThinking)

        if !target.prompt.isEmpty {
            return try await Self.send(target.prompt.joined(separator: " "), with: chat)
        }
        if isatty(STDIN_FILENO) == 0 {
            let piped = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            return try await Self.send(piped, with: chat)
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
                    try await Self.send(text, with: chat)
                } catch {
                    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
                }
            }
        }
    }

    /// Makes sure Quail's server is up, then asks the app where it is.
    private static func endpoint() async throws -> EndpointInfo {
        try await AppLink.ensureRunning()
        let response = try await AppLink.request(ControlRequest(command: .endpoint))
        try AppLink.check(response)
        guard let endpoint = response.endpoint else { throw CLIError("No endpoint from Quail.") }
        return endpoint
    }

    /// Sends one turn; if the server couldn't be reached or refused the
    /// key — it was restarted, stopped, or given a new key since the chat
    /// began — asks the app for the endpoint again (starting the server
    /// if need be) and retries once, keeping the conversation.
    private static func send(_ text: String, with chat: Chat) async throws {
        do {
            try await chat.send(text)
        } catch where Chat.isReconnectable(error) {
            let endpoint = try await endpoint()
            guard let base = URL(string: endpoint.baseURL) else { throw CLIError("No endpoint from Quail.") }
            chat.retarget(base: base, apiKey: endpoint.apiKey)
            do {
                try await chat.send(text)
            } catch let error as URLError {
                throw CLIError(
                    "Can't reach Quail's server at \(base.absoluteString) (\(error.localizedDescription)). See `quail status`."
                )
            }
        } catch let error as URLError {
            // URLError's own description is an NSError dump.
            throw CLIError(error.localizedDescription)
        }
    }
}

/// One conversation's worth of messages, streamed from
/// `/v1/chat/completions`.
final class Chat: @unchecked Sendable {
    private var base: URL
    private var apiKey: String?
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

    /// Points the rest of the conversation at a (possibly new) endpoint.
    func retarget(base: URL, apiKey: String?) {
        self.base = base
        self.apiKey = apiKey
    }

    /// Errors worth re-asking Quail for the endpoint over: nothing
    /// listening (server stopped or restarting) or a stale API key.
    static func isReconnectable(_ error: Error) -> Bool {
        if let error = error as? HTTPStatusError {
            return error.status == 401
        }
        guard let error = error as? URLError else { return false }
        return [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet]
            .contains(error.code)
    }

    /// Sends one user turn and streams the reply. A failed turn leaves the
    /// conversation as it was — not with an unanswered user message that
    /// the next request would carry.
    func send(_ text: String) async throws {
        messages.append(["role": "user", "content": text])
        do {
            let reply = try await stream()
            messages.append(["role": "assistant", "content": reply])
        } catch {
            messages.removeLast()
            throw error
        }
    }

    private func stream() async throws -> String {
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
            throw HTTPStatusError(status: http.statusCode, message: message)
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
        return reply
    }
}

struct HTTPStatusError: Error, CustomStringConvertible {
    let status: Int
    let message: String?

    var description: String {
        "HTTP \(status)\(message.map { ": \($0)" } ?? "")"
    }
}
