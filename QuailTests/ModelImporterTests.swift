import Foundation
import Testing
@testable import Quail

@Suite("ModelImporter")
struct ModelImporterTests {
    /// A home folder with a model in each of the four places, and an empty store.
    private struct Fixture {
        let root: URL
        let home: URL
        let store: ModelStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("quail-import-\(UUID().uuidString)")
            home = root.appendingPathComponent("home")
            store = ModelStore(rootURL: root.appendingPathComponent("store"))
            let fm = FileManager.default
            func write(_ path: String, _ bytes: Int = 16) throws {
                let url = home.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 7, count: bytes).write(to: url)
            }
            try write(".cache/llama.cpp/bartowski_Qwen3-8B-GGUF_Qwen3-8B-Q4_K_M.gguf", 400)
            try write(".cache/llama.cpp/bartowski_Qwen3-8B-GGUF_mmproj-F16.gguf", 40)
            try write(".cache/llama.cpp/bartowski_Qwen3-8B-GGUF_Qwen3-8B-Q4_K_M.gguf.json")
            try write(".lmstudio/models/lmstudio-community/Gemma-GGUF/gemma-Q4_K_M.gguf", 300)
            try write(".lmstudio/models/mlx-community/Llama-4bit/config.json")
            try write(".lmstudio/models/mlx-community/Llama-4bit/model.safetensors", 200)
            try write(".omlx/models/Phi-4bit/config.json")
            try write(".omlx/models/Phi-4bit/model.safetensors", 100)
            try write(".omlx/models/not-a-model/readme.txt")
            // The Hugging Face cache: snapshot entries are links into blobs.
            let repo = ".cache/huggingface/hub/models--mlx-community--Qwen3-0.6B-4bit"
            try write("\(repo)/blobs/aaa", 20)
            try write("\(repo)/blobs/bbb", 500)
            try write("\(repo)/refs/main")
            try "abc".write(to: home.appendingPathComponent("\(repo)/refs/main"), atomically: true, encoding: .utf8)
            let snapshot = home.appendingPathComponent("\(repo)/snapshots/abc")
            try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                atPath: snapshot.appendingPathComponent("config.json").path,
                withDestinationPath: "../../blobs/aaa"
            )
            try fm.createSymbolicLink(
                atPath: snapshot.appendingPathComponent("model.safetensors").path,
                withDestinationPath: "../../blobs/bbb"
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("finds a model in each app's folder, with the store's names, largest first")
    func scansFourPlaces() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let found = ModelImporter.scan(home: fixture.home, store: fixture.store)
        #expect(found.map(\.id) == [
            "mlx-community--Qwen3-0.6B-4bit", "bartowski_Qwen3-8B-GGUF_Qwen3-8B-Q4_K_M", "gemma-Q4_K_M",
            "mlx-community--Llama-4bit", "Phi-4bit",
        ])
        let llama = try #require(found.first { $0.source == .llamaCpp })
        #expect(llama.files.map(\.destination) == [
            "bartowski_Qwen3-8B-GGUF_Qwen3-8B-Q4_K_M.gguf", "mmproj-bartowski_Qwen3-8B-GGUF_Qwen3-8B-Q4_K_M.gguf",
        ])
        #expect(llama.bytes == 440)
        let hub = try #require(found.first { $0.source == .huggingFace })
        #expect(hub.format == .mlxSafetensors)
        #expect(hub.bytes == 520)
        #expect(hub.files.allSatisfy { $0.link != nil })
    }

    @Test("moves each model into the store, removes the originals, and finds nothing the second time")
    func movesAndIsIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fm = FileManager.default
        for candidate in ModelImporter.scan(home: fixture.home, store: fixture.store) {
            try ModelImporter.move(candidate, into: fixture.store)
        }
        let store = fixture.store
        #expect(fm.fileExists(atPath: store.ggufDirectory
                .appendingPathComponent("bartowski_Qwen3-8B-GGUF_Qwen3-8B-Q4_K_M.gguf").path))
        #expect(fm.fileExists(atPath: store.ggufDirectory
                .appendingPathComponent("mmproj-bartowski_Qwen3-8B-GGUF_Qwen3-8B-Q4_K_M.gguf").path))
        #expect(fm.fileExists(atPath: store.ggufDirectory.appendingPathComponent("gemma-Q4_K_M.gguf").path))
        let hubModel = store.mlxDirectory.appendingPathComponent("mlx-community--Qwen3-0.6B-4bit")
        #expect(try Data(contentsOf: hubModel.appendingPathComponent("model.safetensors")).count == 500)
        #expect(store.installedMLXDirectories().map(\.lastPathComponent).sorted() == [
            "Phi-4bit", "mlx-community--Llama-4bit", "mlx-community--Qwen3-0.6B-4bit",
        ])
        // Moved, not copied: the originals, and the Hugging Face links and blobs, are gone.
        let home = fixture.home
        #expect(!fm.fileExists(atPath: home.appendingPathComponent(
            ".cache/llama.cpp/bartowski_Qwen3-8B-GGUF_Qwen3-8B-Q4_K_M.gguf"
        ).path))
        #expect(!fm.fileExists(atPath: home.appendingPathComponent(".omlx/models/Phi-4bit").path))
        let repo = home.appendingPathComponent(".cache/huggingface/hub/models--mlx-community--Qwen3-0.6B-4bit")
        #expect(!fm.fileExists(atPath: repo.appendingPathComponent("blobs/bbb").path))
        #expect((try? fm
                .destinationOfSymbolicLink(atPath: repo.appendingPathComponent("snapshots/abc/config.json").path))
            == nil)
        #expect(ModelImporter.scan(home: fixture.home, store: fixture.store).isEmpty)
    }

    @Test("an MLX download missing a shard its index names isn't offered")
    func skipsIncompleteDownload() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.home.appendingPathComponent(".omlx/models/Phi-4bit")
        try Data(#"{"weight_map": {"a": "model.safetensors", "b": "model-00002.safetensors"}}"#.utf8)
            .write(to: folder.appendingPathComponent("model.safetensors.index.json"))
        #expect(!ModelImporter.scan(home: fixture.home, store: fixture.store).contains { $0.id == "Phi-4bit" })
    }

    @Test("a model already in the store is skipped when scanning, and refused when moving")
    func skipsWhatsInTheStore() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let candidate = try #require(ModelImporter.scan(home: fixture.home, store: fixture.store)
            .first { $0.id == "gemma-Q4_K_M" })
        try fixture.store.ensureDirectoriesExist()
        try Data().write(to: fixture.store.ggufDirectory.appendingPathComponent("gemma-Q4_K_M.gguf"))
        #expect(!ModelImporter.scan(home: fixture.home, store: fixture.store).contains { $0.id == "gemma-Q4_K_M" })
        #expect(throws: ModelImporter.ImportError.alreadyInStore("gemma-Q4_K_M")) {
            try ModelImporter.move(candidate, into: fixture.store)
        }
        #expect(FileManager.default.fileExists(atPath: candidate.files[0].source.path))
    }

    @Test("a failure part-way puts back what had moved")
    func failureRestoresSources() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let llama = try #require(ModelImporter.scan(home: fixture.home, store: fixture.store)
            .first { $0.source == .llamaCpp })
        // The projector vanishes after the scan: the model file moves first, then the move fails.
        try FileManager.default.removeItem(at: llama.files[1].source)
        #expect(throws: ModelImporter.ImportError.self) {
            try ModelImporter.move(llama, into: fixture.store)
        }
        #expect(FileManager.default.fileExists(atPath: llama.files[0].source.path))
        #expect(fixture.store.installedGGUFFiles().isEmpty)
    }
}
