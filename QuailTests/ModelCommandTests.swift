import Foundation
import Testing
@testable import Quail

@Suite("CLI model commands", .timeLimit(.minutes(1)))
@MainActor
struct ModelCommandTests {
    private static let qwen = Catalog.Family(
        id: "qwen3-8b", name: "Qwen3 8B", paramsB: 8, role: "general", rank: 1,
        gguf: Catalog.GGUFVariant(repo: "Qwen/Qwen3-8B-GGUF", quants: ["Q4_K_M", "Q8_0"], defaultQuant: "Q4_K_M"),
        isCurated: true
    )
    private static let mlxOnly = Catalog.Family(
        id: "only-mlx", name: "Only MLX", mlx: Catalog.MLXVariant(repo: "mlx-community/x"), isCurated: true
    )
    private static let catalog = Catalog(families: [qwen, mlxOnly])

    // MARK: - PullSpec

    @Test("a catalog name resolves to its GGUF repo, with an optional quant")
    func catalogNames() throws {
        let plain = try PullSpec.parse("qwen3-8b", catalog: Self.catalog)
        #expect(plain == PullSpec(family: Self.qwen, repo: "Qwen/Qwen3-8B-GGUF", quant: nil))
        #expect(try PullSpec.parse("Qwen3-8B:q8_0", catalog: Self.catalog).quant == "q8_0")
        #expect(try PullSpec.parse("Qwen3 8B", catalog: Self.catalog).family == Self.qwen)
    }

    @Test("owner/repo and URLs pass through; a curated repo keeps its family")
    func repos() throws {
        let pasted = try PullSpec.parse("unsloth/gemma-4-12b-it-GGUF:Q5_K_M", catalog: Self.catalog)
        #expect(pasted == PullSpec(family: nil, repo: "unsloth/gemma-4-12b-it-GGUF", quant: "Q5_K_M"))
        let url = try PullSpec.parse("https://huggingface.co/unsloth/gemma-4-12b-it-GGUF", catalog: Self.catalog)
        #expect(url.repo == "unsloth/gemma-4-12b-it-GGUF")
        #expect(try PullSpec.parse("hf.co/qwen/qwen3-8b-gguf", catalog: Self.catalog).family == Self.qwen)
    }

    @Test("unknown names suggest close matches; MLX-only and empty specs are refused")
    func refusals() {
        #expect(throws: PullSpec.ParseError.unknownModel("qwen3", suggestions: ["qwen3-8b"])) {
            try PullSpec.parse("qwen3", catalog: Self.catalog)
        }
        #expect(throws: PullSpec.ParseError.mlxOnly("Only MLX")) {
            try PullSpec.parse("only-mlx", catalog: Self.catalog)
        }
        #expect(throws: PullSpec.ParseError.empty) {
            try PullSpec.parse("  ", catalog: Self.catalog)
        }
    }

    @Test("quant choice: as asked (any case), else the family default, else Q4_K_M, else the first")
    func quantChoice() {
        let available = ["Q8_0", "Q4_K_M", "Q6_K"]
        #expect(PullSpec.chooseQuant(requested: "q6_k", available: available, familyDefault: nil) == "Q6_K")
        #expect(PullSpec.chooseQuant(requested: "Q2_K", available: available, familyDefault: nil) == nil)
        #expect(PullSpec.chooseQuant(requested: nil, available: available, familyDefault: "Q8_0") == "Q8_0")
        #expect(PullSpec.chooseQuant(requested: nil, available: available, familyDefault: nil) == "Q4_K_M")
        #expect(PullSpec.chooseQuant(requested: nil, available: ["Q8_0"], familyDefault: "Q4_K_M") == "Q8_0")
    }

    // MARK: - rm, default, ctx, config against a scratch store

    private func makeAppState() throws -> (AppState, URL) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-modelcmd-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let appState = AppState(
            config: Config(),
            configURL: scratch.appendingPathComponent("config.json"),
            secretStore: FakeSecretStore(),
            runtime: FakeRuntime(launchSpec: LaunchSpec(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
                currentDirectoryURL: nil
            )),
            modelsRootURL: scratch.appendingPathComponent("Models", isDirectory: true),
            catalogLocations: .init(bundle: .main, directory: scratch),
            benchmarkStore: BenchmarkStore(fileURL: scratch.appendingPathComponent("benchmarks.json")),
            serverPreflight: nil
        )
        try appState.modelStore.ensureDirectoriesExist()
        for name in ["Qwen3-8B-Q4_K_M", "Qwen3-8B-Q8_0", "Gemma-4-12B-Q4_K_M"] {
            try Data("x".utf8).write(to: appState.modelStore.ggufDirectory.appendingPathComponent("\(name).gguf"))
        }
        return (appState, scratch)
    }

    @Test("names resolve exactly, case-insensitively, or by a unique prefix")
    func nameResolution() async throws {
        let (appState, scratch) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        await appState.reconcileStore()

        #expect(try appState.installedEntry(named: "Qwen3-8B-Q8_0").get().id == "Qwen3-8B-Q8_0")
        #expect(try appState.installedEntry(named: "qwen3-8b-q8_0").get().id == "Qwen3-8B-Q8_0")
        #expect(try appState.installedEntry(named: "gemma").get().id == "Gemma-4-12B-Q4_K_M")
        guard case let .failure(ambiguous) = appState.installedEntry(named: "qwen3") else {
            Issue.record("expected an ambiguity error")
            return
        }
        #expect(ambiguous.message.contains("be more specific"))
        guard case .failure = appState.installedEntry(named: "llama") else {
            Issue.record("expected not found")
            return
        }
    }

    @Test("default: set by prefix, show, clear")
    func defaultModel() async throws {
        let (appState, scratch) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        await appState.reconcileStore()

        let set = await appState.handleControl(ControlRequest(command: .setDefault, model: "gemma"))
        #expect(set.ok)
        #expect(appState.config.defaultModelID == "Gemma-4-12B-Q4_K_M")
        let shown = await appState.handleControl(ControlRequest(command: .setDefault))
        #expect(shown.message == "Default model: Gemma-4-12B-Q4_K_M")
        _ = await appState.handleControl(ControlRequest(command: .setDefault, clear: true))
        #expect(appState.config.defaultModelID == nil)
        #expect(await !appState.handleControl(ControlRequest(command: .setDefault, model: "nope")).ok)
    }

    @Test("rm deletes the file and its catalog row")
    func remove() async throws {
        let (appState, scratch) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        await appState.reconcileStore()

        let response = await appState.handleControl(ControlRequest(command: .remove, model: "Qwen3-8B-Q8_0"))
        #expect(response.ok)
        #expect(response.message == "Deleted Qwen3-8B-Q8_0.")
        let file = appState.modelStore.ggufDirectory.appendingPathComponent("Qwen3-8B-Q8_0.gguf")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!appState.modelStore.loadCatalog().entries.contains { $0.id == "Qwen3-8B-Q8_0" })
    }

    @Test("ctx: a size that isn't an option is refused; auto clears the override")
    func context() async throws {
        let (appState, scratch) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        await appState.reconcileStore()

        // The fixture files have no GGUF header, so options are the plain
        // list with unknown fit.
        let options = await appState.handleControl(ControlRequest(command: .context, model: "gemma"))
        let sizes = try #require(options.contextOptions).options.map(\.tokens)
        #expect(sizes.contains(8192))

        let set = await appState.handleControl(ControlRequest(command: .context, model: "gemma", contextSize: 8192))
        #expect(set.ok)
        #expect(appState.modelStore.loadCatalog().entries.first { $0.id == "Gemma-4-12B-Q4_K_M" }?
            .userContextSize == 8192)

        #expect(await !appState.handleControl(ControlRequest(command: .context, model: "gemma", contextSize: 1000)).ok)

        _ = await appState.handleControl(ControlRequest(command: .context, model: "gemma", automatic: true))
        #expect(appState.modelStore.loadCatalog().entries.first { $0.id == "Gemma-4-12B-Q4_K_M" }?
            .userContextSize == nil)
    }

    @Test("config reports the store, endpoint and settings")
    func config() async throws {
        let (appState, scratch) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let config = try #require(await appState.handleControl(ControlRequest(command: .config)).config)
        #expect(config.modelsDirectory == appState.modelStore.rootURL.path)
        #expect(config.port == 8080)
        #expect(config.baseURL == "http://127.0.0.1:8080")
        #expect(!config.running)
    }
}
