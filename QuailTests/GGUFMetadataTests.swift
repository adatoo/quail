import Foundation
import Testing
@testable import Quail

/// A minimal from-scratch GGUF writer, just enough to build fixture files
/// for `GGUFMetadataTests` below. There's no dependency on a real GGUF
/// file anywhere in this test suite — every header byte is spelled out
/// here, matching the format `GGUFMetadata.swift` itself documents.
private struct GGUFFixtureBuilder {
    private var keys: [(name: String, type: UInt32, encode: () -> Data)] = []

    private static func string(_ s: String) -> Data {
        var data = Data()
        var length = UInt64(s.utf8.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(contentsOf: s.utf8)
        return data
    }

    mutating func addString(_ key: String, _ value: String) {
        keys.append((key, 8, { Self.string(value) }))
    }

    mutating func addUInt32(_ key: String, _ value: UInt32) {
        keys.append((key, 4, {
            var v = value.littleEndian
            return withUnsafeBytes(of: &v) { Data($0) }
        }))
    }

    mutating func addUInt64(_ key: String, _ value: UInt64) {
        keys.append((key, 10, {
            var v = value.littleEndian
            return withUnsafeBytes(of: &v) { Data($0) }
        }))
    }

    /// A `uint32` array, for exercising the "array stands in for a
    /// scalar" and "skip an array we don't care about" paths.
    mutating func addUInt32Array(_ key: String, _ values: [UInt32]) {
        keys.append((key, 9, {
            var data = Data()
            var elementType: UInt32 = 4 // uint32
            withUnsafeBytes(of: &elementType) { data.append(contentsOf: $0) }
            var count = UInt64(values.count).littleEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            for v in values {
                var le = v.littleEndian
                withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
            }
            return data
        }))
    }

    /// A `string` array — the shape of `tokenizer.ggml.tokens` in a real
    /// file, used here to confirm skipping doesn't require decoding.
    mutating func addStringArray(_ key: String, _ values: [String]) {
        keys.append((key, 9, {
            var data = Data()
            var elementType: UInt32 = 8 // string
            withUnsafeBytes(of: &elementType) { data.append(contentsOf: $0) }
            var count = UInt64(values.count).littleEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            for v in values {
                data.append(Self.string(v))
            }
            return data
        }))
    }

    /// Builds the file bytes: magic, version, tensor_count (always 0 —
    /// no test needs real tensor data), metadata_kv_count, then every key
    /// added above in order.
    func build(version: UInt32 = 3, magic: UInt32 = 0x4655_4747) -> Data {
        var data = Data()
        var m = magic.littleEndian
        withUnsafeBytes(of: &m) { data.append(contentsOf: $0) }
        var v = version.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        var tensorCount: UInt64 = 0
        withUnsafeBytes(of: &tensorCount) { data.append(contentsOf: $0) }
        var kvCount = UInt64(keys.count).littleEndian
        withUnsafeBytes(of: &kvCount) { data.append(contentsOf: $0) }
        for (name, type, encode) in keys {
            data.append(Self.string(name))
            var t = type.littleEndian
            withUnsafeBytes(of: &t) { data.append(contentsOf: $0) }
            data.append(encode())
        }
        return data
    }

    func write() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-gguf-fixture-\(UUID().uuidString).gguf")
        try build().write(to: url)
        return url
    }
}

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
}
