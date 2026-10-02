import ArgumentParser
import Darwin
import Foundation

/// `quail eval tools` (ADR D-065): checks that tool calling works for a model, on Quail's server or any other.
struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check what a model can do on a server.",
        subcommands: [EvalTools.self]
    )
}

struct EvalTools: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tools",
        abstract: "Check that tool calling works: 16 requests, each checked against the call it should make.",
        discussion: """
        A quick check of the whole path (the model's template, the server's parser, \
        the arguments' types), not a score to compare models with: one call, choosing \
        a tool, two calls, two tools, no tool that fits, and answering from a tool's \
        result. Runs on Quail's server unless --url names another, and saves nothing.
        """
    )

    @Argument(help: "Model name. Defaults to Quail's default model, or the server's first.")
    var model: String?

    @Option(help: "Check this server instead, e.g. http://127.0.0.1:11434 (its /v1 is implied).")
    var url: String?
    @Option(help: "With --url: the server's API key, sent as a Bearer token.")
    var apiKey: String?
    @Flag(help: "Print the full result as JSON.") var json = false

    func run() async throws {
        let base: URL
        let key: String?
        var target = model
        if let url {
            guard let parsed = OpenAIBenchmarkClient.base(from: url) else {
                throw CLIError("\(url) isn't a server address. Give one like http://127.0.0.1:8080.")
            }
            base = parsed
            key = apiKey
        } else {
            try await AppLink.ensureRunning()
            let response = try await AppLink.request(ControlRequest(command: .endpoint))
            try AppLink.check(response)
            guard let endpoint = response.endpoint, let parsed = OpenAIBenchmarkClient.base(from: endpoint.baseURL)
            else { throw CLIError("No endpoint from Quail.") }
            base = parsed
            key = endpoint.apiKey
            target = target ?? endpoint.defaultModel
        }
        if target == nil {
            target = try await OpenAIBenchmarkClient(base: base, apiKey: key).models().first
        }
        guard let target else { throw URLBenchmarkError.noModels }

        let endpoint = base.appending(path: "v1/chat/completions")
        let send: @Sendable (Data) async throws -> Data = { body in
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 600
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                throw URLBenchmarkError.http(http.statusCode, message)
            }
            return data
        }
        let progress: @Sendable (Int, Int) async -> Void = { done, total in
            guard isatty(STDERR_FILENO) != 0 else { return }
            FileHandle.standardError.write(Data("\r\u{1B}[2K\(done + 1)/\(total)".utf8))
        }
        let result = try await ToolEval.run(model: target, url: base.absoluteString, send: send, progress: progress)
        if isatty(STDERR_FILENO) != 0 {
            FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
        }
        if json {
            return try print(String(decoding: BenchmarkResult.encoder().encode(result), as: UTF8.self))
        }
        print(Self.summary(result))
    }

    static func summary(_ result: ToolEval.Result) -> String {
        var lines = ["\(result.model) at \(result.url)", Output.dim("\(result.suite) · tool calling"), ""]
        for kind in ToolEval.Kind.allCases {
            let cases = result.cases.filter { $0.kind == kind }
            let passed = cases.filter(\.passed).count
            let mark = passed == cases.count ? "✓" : "✗"
            lines
                .append(
                    "\(mark) \(kind.title.padding(toLength: 18, withPad: " ", startingAt: 0))\(passed)/\(cases.count)"
                )
            for failure in cases where !failure.passed {
                lines.append(Output.dim("    \(failure.id): \(failure.reason ?? "failed")"))
            }
        }
        lines.append("")
        lines.append("\(result.passed) of \(result.cases.count) passed")
        return lines.joined(separator: "\n")
    }
}
