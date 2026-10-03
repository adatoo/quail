import Foundation
import Testing
@testable import Quail
@testable import QuailServerCore

/// Models that don't chat (ADR D-072): how a model's task is found, written into the presets, read back by the
/// server, and kept away from the routes and app features that need a chat model.
@Suite("Model tasks")
struct ModelTaskTests {
    private static func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quail-task-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func header(_ build: (inout GGUFFixtureBuilder) -> Void) throws -> GGUFMetadata {
        var builder = GGUFFixtureBuilder()
        builder.addString("general.architecture", "qwen3")
        build(&builder)
        return try GGUFMetadata.parse(builder.build())
    }

    // MARK: Detection

    @Test("a GGUF's pooling, classifier and causal keys say what it's for")
    func ggufDetection() throws {
        let chat = try Self.header { $0.addUInt32("qwen3.block_count", 28) }
        #expect(ModelTask.detected(in: chat) == nil)

        let embedding = try Self.header { $0.addUInt32("qwen3.pooling_type", 3) }
        #expect(ModelTask.detected(in: embedding)?.task == .embedding)
        #expect(ModelTask.detected(in: embedding)?.pooling == "last")

        let reranker = try Self.header {
            $0.addUInt32("qwen3.pooling_type", 4)
            $0.addStringArray("qwen3.classifier.output_labels", ["yes", "no"])
        }
        #expect(ModelTask.detected(in: reranker)?.task == .rerank)
        #expect(ModelTask.detected(in: reranker)?.pooling == "rank")

        var builder = GGUFFixtureBuilder()
        builder.addString("general.architecture", "bert")
        builder.addBool("bert.attention.causal", false)
        let encoder = try GGUFMetadata.parse(builder.build())
        #expect(encoder.causalAttention == false)
        #expect(ModelTask.detected(in: encoder)?.task == .embedding)
        #expect(ModelTask.detected(in: encoder)?.pooling == nil)
    }

    @Test("an MLX folder's files say what it's for, the same in the app and the server")
    func mlxDetection() throws {
        let root = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        func folder(_ name: String, config: String, files: [String] = []) throws -> URL {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
            for file in files {
                try Data("{}".utf8).write(to: directory.appendingPathComponent(file))
            }
            return directory
        }
        let chat = try folder("chat", config: #"{"model_type": "qwen3"}"#)
        let sentenceTransformers = try folder("st", config: #"{"model_type": "qwen3"}"#, files: ["modules.json"])
        let bert = try folder("bert", config: #"{"model_type": "bert"}"#)
        let reranker = try folder(
            "rr", config: #"{"model_type": "xlm-roberta", "architectures": ["XLMRobertaForSequenceClassification"]}"#
        )

        #expect(ModelTask.detected(inMLXDirectory: chat) == nil)
        #expect(ModelTask.detected(inMLXDirectory: sentenceTransformers) == .embedding)
        #expect(ModelTask.detected(inMLXDirectory: bert) == .embedding)
        #expect(ModelTask.detected(inMLXDirectory: reranker) == .rerank)

        #expect(MLXEmbeddingDetector.task(of: chat) == .chat)
        #expect(MLXEmbeddingDetector.task(of: sentenceTransformers) == .embedding)
        #expect(MLXEmbeddingDetector.task(of: bert) == .embedding)
        #expect(MLXEmbeddingDetector.task(of: reranker) == .rerank)
    }

    // MARK: The store and presets

    @Test("the catalog family's task wins, the header decides otherwise, and presets say both in llama-server's keys")
    func storeAndPresets() throws {
        let root = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelStore(rootURL: root)
        try store.ensureDirectoriesExist()

        var chat = GGUFFixtureBuilder()
        chat.addString("general.architecture", "qwen3")
        try chat.write(to: store.ggufDirectory.appendingPathComponent("Chat.gguf"))
        var embedding = GGUFFixtureBuilder()
        embedding.addString("general.architecture", "nomic-bert")
        embedding.addUInt32("nomic-bert.pooling_type", 1)
        try embedding.write(to: store.ggufDirectory.appendingPathComponent("Nomic.gguf"))
        // A reranker whose header says nothing: only its catalog family knows.
        var bare = GGUFFixtureBuilder()
        bare.addString("general.architecture", "bert")
        try bare.write(to: store.ggufDirectory.appendingPathComponent("Reranker.gguf"))
        try store.saveCatalog(StoreCatalog(entries: [
            InstalledModel(id: "Reranker", family: "bge-reranker", format: .gguf, bytes: 0, addedAt: .init()),
        ]))
        let family = Catalog.Family(
            id: "bge-reranker", name: "BGE Reranker", taskName: "rerank", pooling: "rank", isCurated: true
        )

        let refreshed = store.refreshedCatalog(
            device: DeviceInfo(), ggufRuntime: .quail, bandwidthTable: [:], families: [family]
        )
        let tasks = Dictionary(uniqueKeysWithValues: refreshed.entries.map { ($0.id, $0.modelTask) })
        #expect(tasks == ["Chat": .chat, "Nomic": .embedding, "Reranker": .rerank])
        #expect(refreshed.entries.first { $0.id == "Chat" }?.task == nil) // chat stays nil, as before tasks

        try store.regeneratePresets(catalog: refreshed)
        let presets = PresetsFile.load(store.presetsFile)
        let entries = ModelDiscovery.discover(modelsDirectory: nil, mlxDirectory: nil, presets: presets)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        #expect(byID["Chat"]?.task == .chat)
        #expect(byID["Nomic"]?.task == .embedding)
        #expect(byID["Nomic"]?.pooling == .mean)
        #expect(byID["Reranker"]?.task == .rerank)
        #expect(byID["Reranker"]?.pooling == .rank)
        #expect(entries.flatMap(\.ignoredPresetKeys).isEmpty)
    }

    @Test("the server reads either spelling of llama-server's keys, and says when a pooling is unknown")
    func presetSpellings() {
        let ini = """
        [A]
        model = /m/A.gguf
        embedding = true

        [B]
        model = /m/B.gguf
        rerank = 1

        [C]
        model = /m/C.gguf
        embeddings = true
        pooling = sideways
        """
        let entries = ModelDiscovery.discover(modelsDirectory: nil, mlxDirectory: nil, presets: PresetsFile.parse(ini))
        #expect(entries.map(\.task) == [.embedding, .rerank, .embedding])
        #expect(entries[2].pooling == nil)
        #expect(entries[2].ignoredPresetKeys == ["pooling=sideways"])
    }

    @Test("a catalog family's task decodes, and one this version doesn't know isn't offered")
    func catalogTask() throws {
        let json = """
        {"revision": 1, "ramTiersGB": {}, "chipBandwidthGBps": {}, "families": [
          {"id": "a", "name": "A", "variants": {}},
          {"id": "b", "name": "B", "task": "embedding", "pooling": "last", "variants": {}},
          {"id": "c", "name": "C", "task": "transcription", "variants": {}}
        ]}
        """
        let catalog = try JSONDecoder().decode(Catalog.Document.self, from: Data(json.utf8)).catalog
        #expect(catalog.families.map(\.task) == [.chat, .embedding, nil])
        #expect(catalog.families[1].pooling == "last")
    }

    @Test("the bundled catalog's embedding families say so")
    func bundledCatalog() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Quail/Resources/catalog.json")
        let catalog = try JSONDecoder().decode(Catalog.Document.self, from: Data(contentsOf: url)).catalog
        for family in catalog.families where family.role == "embedding" {
            #expect(family.task == .embedding, "\(family.id)")
        }
        #expect(catalog.families.allSatisfy { $0.task != nil })
    }

    // MARK: Keeping them away from chat

    @Test("Ping passes over models that can't chat")
    @MainActor func pingSkipsNonChat() {
        func model(_ id: String, _ status: String, task: String? = nil) -> ServedModel {
            ServedModel(id: id, status: .init(value: status, failed: nil, exitCode: nil), task: task)
        }
        let embedder = model("Nomic", "loaded", task: "embedding")
        let chat = model("Qwen3-8B", "unloaded", task: "chat")
        #expect(PingRunner.choose(from: [embedder, chat], preferred: nil)?.id == "Qwen3-8B")
        // llama-server doesn't say, so the app's own list decides.
        let unmarked = model("Nomic", "loaded")
        #expect(PingRunner.choose(from: [unmarked, chat], preferred: nil, nonChat: ["Nomic"])?.id == "Qwen3-8B")
        #expect(PingRunner.choose(from: [embedder], preferred: nil) == nil)
    }

    @Test("recommendations leave out models that don't chat")
    func recommenderSkipsNonChat() {
        let device = DeviceInfo(unifiedMemoryBytes: 64 << 30, gpuWorkingSetCeilingBytes: 48 << 30)
        let catalog = Catalog(families: [
            Catalog.Family(id: "chat", name: "Chat", paramsB: 8, isCurated: true).withGGUF(),
            Catalog.Family(id: "emb", name: "Emb", paramsB: 0.6, taskName: "embedding", isCurated: true).withGGUF(),
        ])
        #expect(Recommender.candidates(catalog: catalog, device: device).map(\.id) == ["chat"])
    }

    @Test("a chat route refuses an embedding model and names the route that serves it")
    func chatRouteRefusesEmbeddingModel() async {
        var embedder = ModelEntry.fake("Nomic")
        embedder.task = .embedding
        let harness = RouteHarness(entries: [.fake("Alpha"), embedder])
        let chat = #"{"model": "Nomic", "messages": [{"role": "user", "content": "Hi"}]}"#
        let (status, json) = await harness.json("/v1/chat/completions", chat)
        #expect(status == 400)
        let message = (json["error"] as? [String: Any])?["message"] as? String ?? ""
        #expect(message.contains("/v1/embeddings"))

        let (completionStatus, _) = await harness.json("/v1/completions", #"{"model": "Nomic", "prompt": "Hi"}"#)
        #expect(completionStatus == 400)
        // Tokenizing doesn't need a chat model.
        let (tokenizeStatus, _) = await harness.json("/tokenize", #"{"model": "Nomic", "content": "Hi"}"#)
        #expect(tokenizeStatus == 200)
    }

    @Test("/v1/models says each model's task")
    func modelListSaysTask() async throws {
        var embedder = ModelEntry.fake("Nomic")
        embedder.task = .embedding
        let harness = RouteHarness(entries: [.fake("Alpha"), embedder])
        let response = await harness.get("/v1/models")
        guard case let .data(data) = response.body else { Issue.record("no body"); return }
        let list = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try #require(list["data"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0["id"] as? String ?? "", $0) })
        #expect(byID["Alpha"]?["task"] as? String == "chat")
        #expect(byID["Nomic"]?["task"] as? String == "embedding")
        let architecture = byID["Nomic"]?["architecture"] as? [String: Any]
        #expect(architecture?["output_modalities"] as? [String] == ["embedding"])
    }
}

private extension Catalog.Family {
    func withGGUF() -> Catalog.Family {
        var family = self
        family.gguf = Catalog.GGUFVariant(repo: "org/\(id)-GGUF", quants: ["Q4_K_M"], defaultQuant: "Q4_K_M")
        return family
    }
}
