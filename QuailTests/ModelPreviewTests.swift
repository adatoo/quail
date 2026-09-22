import CryptoKit
import Foundation
import Testing
@testable import Quail

@Suite("ModelPreview")
struct ModelPreviewTests {
    private static let device = DeviceInfo(
        chipName: "Apple M4 Pro",
        gpuWorkingSetCeilingBytes: 12_884_901_888
    )

    private static func makeDownloader(body: Data) -> HFDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = { _ in StubResponse(statusCode: 200, body: body) }
        return HFDownloader(urlSession: URLSession(configuration: config), hubBaseURL: URL(string: "http://hub.test")!)
    }

    /// llama arch, 32 layers, 8 KV heads, 4096/32 → d=128 — Llama-3.1-8B's
    /// real shape, same as `FitEstimatorTests`' 8B stand-in.
    private static func llamaFixture() -> GGUFFixtureBuilder {
        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "llama")
        fixture.addUInt32("llama.block_count", 32)
        fixture.addUInt32("llama.attention.head_count", 32)
        fixture.addUInt32("llama.attention.head_count_kv", 8)
        fixture.addUInt32("llama.embedding_length", 4096)
        return fixture
    }

    @Test("installed: a real GGUF on disk gets a comfortable verdict")
    func installedGGUFComfortable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-preview-\(UUID().uuidString)", isDirectory: true)
        let store = ModelStore(rootURL: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.ensureDirectoriesExist()
        try Self.llamaFixture().write(to: store.ggufDirectory.appendingPathComponent("Tiny8B.gguf"))

        let entry = InstalledModel(id: "Tiny8B", format: .gguf, bytes: 4_900_000_000, addedAt: .init())
        let estimate = try #require(ModelPreview.installed(
            entry: entry, store: store, device: Self.device,
            ggufRuntime: .llamaCpp, bandwidthTable: ["Apple M4 Pro": 273]
        ))
        #expect(estimate.verdict == .comfortable)
        // 8B Q4_K_M on an M4 Pro-class machine: community numbers land in
        // the 20–40 tok/s band; 0.7·273e9/4.9e9 ≈ 39 — inside it.
        #expect((20.0 ..< 60.0).contains(estimate.estimatedTokensPerSecond ?? 0))
    }

    @Test("installed: a model with no readable shape gets no verdict, not a wrong one")
    func installedUnreadableNoVerdict() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-preview-\(UUID().uuidString)", isDirectory: true)
        let store = ModelStore(rootURL: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.ensureDirectoriesExist()
        try Data("junk".utf8).write(to: store.ggufDirectory.appendingPathComponent("Junk.gguf"))

        let entry = InstalledModel(id: "Junk", format: .gguf, bytes: 4, addedAt: .init())
        #expect(ModelPreview.installed(
            entry: entry, store: store, device: Self.device,
            ggufRuntime: .llamaCpp, bandwidthTable: [:]
        ) == nil)
    }

    @Test("remote: pre-download verdict comes from a header fetch plus listing size")
    func remoteGGUFVerdict() async throws {
        let fixture = Self.llamaFixture().data()
        let downloader = Self.makeDownloader(body: fixture)
        let listing = HFRepo(id: "org/x", files: [
            HFFile(remotePath: "X-Q4_K_M.gguf", sizeBytes: 4_900_000_000, sha256: nil),
            HFFile(remotePath: "README.md", sizeBytes: 1000, sha256: nil),
        ])

        let maybeEstimate = try await ModelPreview.remote(
            repo: "org/x", format: .gguf, listing: listing,
            ggufFile: listing.files[0], downloader: downloader,
            device: Self.device, ggufRuntime: .llamaCpp, bandwidthTable: [:]
        )
        let estimate = try #require(maybeEstimate)
        #expect(estimate.verdict == .comfortable)
    }

    @Test("remote: the listing's size, not the fetched header, is what the formula weighs")
    func remoteUsesListingSize() async throws {
        // The header fixture is ~200 bytes; the listing claims 19 GB — a
        // Q4_K_M of a 32B model on this 16 GB-class device must come
        // back Won't fit if the (correct) listing size is used, and would
        // come back comfortable if the (wrong) header buffer size were.
        let fixture = Self.llamaFixture().data()
        let downloader = Self.makeDownloader(body: fixture)
        let listing = HFRepo(id: "org/x", files: [
            HFFile(remotePath: "Big-Q4_K_M.gguf", sizeBytes: 19_000_000_000, sha256: nil),
        ])

        let maybeEstimate = try await ModelPreview.remote(
            repo: "org/x", format: .gguf, listing: listing,
            ggufFile: listing.files[0], downloader: downloader,
            device: Self.device, ggufRuntime: .llamaCpp, bandwidthTable: [:]
        )
        let estimate = try #require(maybeEstimate)
        #expect(estimate.verdict == .wontFit)
    }

    @Test("remote: an MLX verdict weighs the whole directory listing")
    func remoteMLXVerdict() async throws {
        let config = Data(#"""
        { "model_type": "llama", "num_hidden_layers": 28, "num_key_value_heads": 4,
          "hidden_size": 3584, "num_attention_heads": 28,
          "quantization": { "bits": 4, "group_size": 64 } }
        """#.utf8)
        let downloader = Self.makeDownloader(body: config)
        let listing = HFRepo(id: "mlx-community/x", files: [
            HFFile(remotePath: "config.json", sizeBytes: Int64(config.count), sha256: nil),
            HFFile(remotePath: "model.safetensors", sizeBytes: 4_300_000_000, sha256: nil),
            HFFile(remotePath: "tokenizer.json", sizeBytes: 7_000_000, sha256: nil),
        ])

        let maybeEstimate = try await ModelPreview.remote(
            repo: "mlx-community/x", format: .mlxSafetensors, listing: listing,
            ggufFile: nil, downloader: downloader,
            device: Self.device, ggufRuntime: .llamaCpp, bandwidthTable: [:]
        )
        let estimate = try #require(maybeEstimate)

        // MLX rows always evaluate under the .omlx overhead (2.5 GB)
        // regardless of the pane's current GGUF runtime — 4.3 GB weights
        // is still comfortable here either way; what's being pinned is
        // that a verdict exists at all through the config.json path.
        #expect(estimate.verdict == .comfortable)
    }
}
