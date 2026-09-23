import Foundation
import Testing
@testable import Quail

@Suite("GGUFMetadata")
struct GGUFMetadataTests {
    @Test("reads a realistic llama-architecture header")
    func readsRealisticHeader() throws {
        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "llama")
        fixture.addString("general.name", "Qwen3-0.6B")
        fixture.addUInt32("llama.block_count", 28)
        fixture.addUInt32("llama.attention.head_count", 16)
        fixture.addUInt32("llama.attention.head_count_kv", 8)
        fixture.addUInt32("llama.embedding_length", 1024)
        fixture.addUInt32("general.file_type", 15) // LLAMA_FTYPE_MOSTLY_Q4_K_M
        // A large-ish string array, standing in for tokenizer.ggml.tokens
        // in a real file — must be skipped without being decoded.
        fixture.addStringArray("tokenizer.ggml.tokens", (0 ..< 5000).map { "tok\($0)" })
        let url = try fixture.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try GGUFMetadata.read(from: url)

        #expect(metadata.architecture == "llama")
        #expect(metadata.blockCount == 28)
        #expect(metadata.headCount == 16)
        #expect(metadata.headCountKV == 8)
        #expect(metadata.embeddingLength == 1024)
        #expect(metadata.fileType == 15)
    }

    @Test("reads key_length/value_length when the architecture writes them explicitly")
    func readsExplicitKeyAndValueLength() throws {
        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "gemma2")
        // Mirrors mlx-community/gemma-2-9b-it-4bit's real config: hidden
        // 3584 over 16 heads is 224, but the real per-head dim is 256 —
        // key_length/value_length is how GGUF spells that out explicitly.
        fixture.addUInt32("gemma2.embedding_length", 3584)
        fixture.addUInt32("gemma2.attention.head_count", 16)
        fixture.addUInt32("gemma2.attention.key_length", 256)
        fixture.addUInt32("gemma2.attention.value_length", 256)
        let url = try fixture.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try GGUFMetadata.read(from: url)

        #expect(metadata.keyLength == 256)
        #expect(metadata.valueLength == 256)
    }

    @Test("key_length/value_length are nil when the architecture doesn't write them")
    func missingKeyAndValueLengthAreNil() throws {
        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "llama")
        fixture.addUInt32("llama.embedding_length", 4096)
        fixture.addUInt32("llama.attention.head_count", 32)
        let url = try fixture.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try GGUFMetadata.read(from: url)

        #expect(metadata.keyLength == nil)
        #expect(metadata.valueLength == nil)
    }

    @Test("reads expert_count/expert_used_count for a MoE architecture")
    func readsExpertCounts() throws {
        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "qwen3moe")
        fixture.addUInt32("qwen3moe.expert_count", 128)
        fixture.addUInt32("qwen3moe.expert_used_count", 8)
        let url = try fixture.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try GGUFMetadata.read(from: url)

        #expect(metadata.expertCount == 128)
        #expect(metadata.expertUsedCount == 8)
    }

    @Test("expert_count/expert_used_count are nil for a dense architecture")
    func missingExpertCountsAreNilForDenseModel() throws {
        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "llama")
        fixture.addUInt32("llama.block_count", 32)
        let url = try fixture.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try GGUFMetadata.read(from: url)

        #expect(metadata.expertCount == nil)
        #expect(metadata.expertUsedCount == nil)
    }

    @Test("general.architecture appearing after the keys it namespaces still resolves")
    func architectureOrderIndependent() throws {
        var fixture = GGUFFixtureBuilder()
        // Deliberately out of the order every real GGUF writer uses, to
        // prove the two-pass parse doesn't assume general.architecture
        // comes first.
        fixture.addUInt32("llama.block_count", 32)
        fixture.addString("general.architecture", "llama")
        fixture.addUInt32("llama.embedding_length", 4096)
        let url = try fixture.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try GGUFMetadata.read(from: url)

        #expect(metadata.architecture == "llama")
        #expect(metadata.blockCount == 32)
        #expect(metadata.embeddingLength == 4096)
    }

    @Test("head_count_kv written as a per-layer array takes the first element")
    func headCountKVArrayTakesFirstElement() throws {
        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "llama")
        fixture.addUInt32Array("llama.attention.head_count_kv", [8, 8, 4, 4])
        let url = try fixture.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try GGUFMetadata.read(from: url)

        #expect(metadata.headCountKV == 8)
    }

    @Test("keys for a different architecture are ignored")
    func differentArchitectureKeysIgnored() throws {
        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "gemma")
        // Not gemma.*, so must not populate blockCount.
        fixture.addUInt32("llama.block_count", 999)
        fixture.addUInt32("gemma.block_count", 42)
        let url = try fixture.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try GGUFMetadata.read(from: url)

        #expect(metadata.blockCount == 42)
    }

    @Test("missing keys leave the corresponding fields nil")
    func missingKeysAreNil() throws {
        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "llama")
        let url = try fixture.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try GGUFMetadata.read(from: url)

        #expect(metadata.architecture == "llama")
        #expect(metadata.blockCount == nil)
        #expect(metadata.headCountKV == nil)
        #expect(metadata.embeddingLength == nil)
        #expect(metadata.headCount == nil)
        #expect(metadata.fileType == nil)
        #expect(metadata.keyLength == nil)
        #expect(metadata.valueLength == nil)
        #expect(metadata.expertCount == nil)
        #expect(metadata.expertUsedCount == nil)
    }

    @Test("no general.architecture key leaves architecture and every namespaced field nil")
    func noArchitectureKey() throws {
        var fixture = GGUFFixtureBuilder()
        fixture.addUInt32("llama.block_count", 28)
        let url = try fixture.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try GGUFMetadata.read(from: url)

        #expect(metadata.architecture == nil)
        #expect(metadata.blockCount == nil)
    }

    @Test("wrong magic throws notAGGUFFile")
    func wrongMagicThrows() throws {
        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "llama")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-gguf-fixture-\(UUID().uuidString).gguf")
        try fixture.build(magic: 0xDEAD_BEEF).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: GGUFMetadata.GGUFReadError.notAGGUFFile) {
            try GGUFMetadata.read(from: url)
        }
    }

    @Test("unsupported version throws unsupportedVersion")
    func unsupportedVersionThrows() throws {
        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "llama")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-gguf-fixture-\(UUID().uuidString).gguf")
        try fixture.build(version: 1).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: GGUFMetadata.GGUFReadError.unsupportedVersion(1)) {
            try GGUFMetadata.read(from: url)
        }
    }

    @Test("truncated file throws truncated rather than trapping")
    func truncatedFileThrows() throws {
        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "llama")
        fixture.addUInt32("llama.block_count", 28)
        var data = fixture.build()
        data.removeLast(20) // cut off mid metadata section
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-gguf-fixture-\(UUID().uuidString).gguf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: GGUFMetadata.GGUFReadError.truncated) {
            try GGUFMetadata.read(from: url)
        }
    }

    @Test("nonexistent file throws")
    func nonexistentFileThrows() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-gguf-does-not-exist-\(UUID().uuidString).gguf")
        #expect(throws: (any Error).self) {
            try GGUFMetadata.read(from: url)
        }
    }

    /// Shaped like the live case: shape keys first, then a tokenizer array
    /// far bigger than the ranged fetch — the buffer is cut mid-array.
    @Test("parsePrefix returns the shape when only trailing tokenizer data is cut off; parse still throws")
    func parsePrefixToleratesTruncatedTokenizer() throws {
        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "gemma4")
        fixture.addUInt32("gemma4.block_count", 48)
        fixture.addUInt32("gemma4.attention.head_count", 16)
        fixture.addUInt32("gemma4.attention.head_count_kv", 8)
        fixture.addUInt32("gemma4.attention.key_length", 256)
        fixture.addStringArray("tokenizer.ggml.tokens", (0 ..< 5000).map { "token-\($0)" })
        var data = fixture.build()
        data.removeLast(data.count / 2)

        let metadata = try GGUFMetadata.parsePrefix(data)
        #expect(metadata.blockCount == 48)
        #expect(metadata.headCountKV == 8)
        #expect(metadata.keyLength == 256)
        #expect(throws: GGUFMetadata.GGUFReadError.truncated) { try GGUFMetadata.parse(data) }
    }

    @Test("parsePrefix still throws when the cut lands before the shape keys")
    func parsePrefixNeedsTheShape() {
        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "llama")
        fixture.addStringArray("tokenizer.ggml.tokens", (0 ..< 5000).map { "token-\($0)" })
        fixture.addUInt32("llama.block_count", 28)
        var data = fixture.build()
        data.removeLast(data.count / 2)

        #expect(throws: GGUFMetadata.GGUFReadError.truncated) { try GGUFMetadata.parsePrefix(data) }
    }
}
