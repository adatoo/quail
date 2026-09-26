import Foundation
import Testing
@testable import Quail

@Suite("Control (quail CLI ↔ app)", .timeLimit(.minutes(1)))
struct ControlTests {
    @Test("a request round-trips through a real ControlServer socket")
    func socketRoundTrip() async throws {
        // Short path: sun_path is limited to 104 bytes.
        let path = "/tmp/quail-test-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(path: path) { request in
            ControlResponse(ok: true, error: "echo \(request.command.rawValue) \(request.tool ?? "")")
        }
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600) // only this user can connect

        let response = try await Task.detached {
            try LineSocket.request(ControlRequest(command: .launch, tool: "claude"), path: path)
        }.value
        #expect(response == ControlResponse(ok: true, error: "echo launch claude"))
    }

    @Test("connecting with no app running fails with ENOENT, which the CLI treats as 'launch the app'")
    func noServer() {
        #expect(throws: LineSocket.SocketError.system("connect", ENOENT)) {
            try LineSocket.request(ControlRequest(command: .status), path: "/tmp/quail-nothing-here.sock")
        }
    }

    @Test("ChatStreamParser: content deltas, reasoning, timings, and [DONE]")
    func chatStream() {
        #expect(ChatStreamParser
            .events(fromLine: #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#) == [.delta("Hel")])
        #expect(ChatStreamParser.events(fromLine: #"data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#)
            == [.reasoning("hmm")])
        let final = #"data: {"choices":[{"delta":{}}],"timings":{"prompt_per_second":1500.5,"predicted_per_second":42.0,"predicted_n":80}}"#
        #expect(ChatStreamParser.events(fromLine: final)
            == [.timings(promptPerSecond: 1500.5, predictedPerSecond: 42.0, predictedTokens: 80)])
        #expect(ChatStreamParser.events(fromLine: "data: [DONE]") == [.done])
        #expect(ChatStreamParser.events(fromLine: ": keep-alive").isEmpty)
    }

    @Test("launch recipes: every one renders fully except {{tempDir}}, and aliases resolve")
    func launchRecipes() throws {
        let values = try SnippetRenderer.Values(
            baseURL: #require(URL(string: "http://127.0.0.1:8080")),
            apiKey: "k",
            model: "M"
        )
        let launchable = Integration.bundled().filter { $0.launch != nil }
        #expect(Set(launchable.map(\.id)).isSuperset(of: ["claude-code", "codex-cli", "opencode", "qwen-code"]))
        for integration in launchable {
            let recipe = try #require(integration.launch)
            let rendered = (recipe.args + (recipe.trailingArgs ?? []) + Array(recipe.env.values)
                + Array((recipe.files ?? [:]).values))
                .map { SnippetRenderer.render($0, with: values) }
                .joined(separator: "\n")
            let leftovers = SnippetRenderer.unfilledPlaceholders(in: rendered).filter { $0 != "{{tempDir}}" }
            #expect(leftovers.isEmpty, "\(integration.id): \(leftovers)")
        }
    }
}

@Suite("AppState control handling", .timeLimit(.minutes(1)))
@MainActor
struct AppStateControlTests {
    private func makeAppState() throws -> (AppState, URL) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-control-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let appState = AppState(
            // Not the default `.load()` — that reads the real config.json.
            config: Config(),
            configURL: scratch.appendingPathComponent("config.json"),
            secretStore: FakeSecretStore(),
            runtime: FakeRuntime(launchSpec: LaunchSpec(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
                currentDirectoryURL: nil
            )),
            modelsRootURL: scratch.appendingPathComponent("Models", isDirectory: true),
            catalogLocations: .init(bundle: .main, directory: scratch),
            shapeCache: ModelShapeCache(url: nil),
            serverPreflight: nil
        )
        return (appState, scratch)
    }

    @Test("launch: resolves an alias, fills the model and address, warns when the context is too small")
    func launch() async throws {
        let (appState, scratch) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try appState.modelStore.ensureDirectoriesExist()
        try Data("x".utf8).write(to: appState.modelStore.ggufDirectory.appendingPathComponent("Small.gguf"))
        await appState.reconcileStore()
        await appState.setContextSize(8192, forModel: "Small")

        let response = appState.launchResponse(tool: "claude", model: "Small")
        let launch = try #require(response.launch)
        #expect(launch.command == "claude")
        #expect(launch.env["ANTHROPIC_MODEL"] == "Small")
        #expect(launch.env["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:8080")
        #expect(launch.warnings.contains { $0.contains("needs at least 32K") })

        #expect(launch.env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] == "8192")

        // opencode 2: the config travels in the environment (its background
        // service would ignore it), sized to the model, with --standalone
        // after any `run …` the user passes.
        let opencode = try #require(appState.launchResponse(tool: "opencode", model: "Small").launch)
        #expect(opencode.trailingArgs == ["--standalone"])
        #expect(opencode.env["QUAIL_API_KEY"]?.isEmpty == false)
        let content = try #require(opencode.env["OPENCODE_CONFIG_CONTENT"])
        let config = try #require(
            JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
        )
        #expect(config["model"] as? String == "quail/Small")
        let agents = try #require(config["agents"] as? [String: [String: String]])
        #expect(agents["build"]?["model"] == "quail/Small")
        #expect(agents["plan"]?["model"] == "quail/Small")
        #expect(content.contains(#""limit":{"context":8192,"output":2048}"#))
        #expect(content.contains(#""apiKey":"{env:QUAIL_API_KEY}""#)) // the key itself stays out of the config

        #expect(appState.launchResponse(tool: "", model: nil).error?.contains("Name a tool") == true)
        #expect(appState.launchResponse(tool: "nope", model: nil).error?.contains("Unknown tool") == true)
        #expect(appState.launchResponse(tool: "codex", model: "Missing").error?.contains("No installed model") == true)
    }

    @Test("service enable turns on open-at-login's partner, auto-start")
    func service() async throws {
        let (appState, scratch) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        #expect(!appState.config.autoStartServer)
        appState.setAutoStartServer(true)
        #expect(appState.config.autoStartServer)
        let status = await appState.handleControl(ControlRequest(command: .status))
        #expect(status.status?.phase == "stopped")
    }
}
