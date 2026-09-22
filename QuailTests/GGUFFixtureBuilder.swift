import Foundation

/// A minimal from-scratch GGUF writer, just enough to build fixture files
/// for `GGUFMetadataTests` and the `ModelStore`/`ModelInstallController`
/// tests that need a *real* (parseable) GGUF on disk. There's no
/// dependency on a real GGUF file anywhere in this suite — every header
/// byte is spelled out here, matching the format `GGUFMetadata.swift`
/// itself documents.
///
/// `tensor_count` is always 0 and `build(minBytes:)` pads the tail with
/// junk — `GGUFMetadata`'s parser stops at the end of the metadata
/// section and never reads further, so padded fixtures can stand in for
/// multi-gigabyte models in size-dependent tests (fit verdicts, progress
/// accounting) without multi-gigabyte temporary files.
/// A minimal from-scratch GGUF writer, just enough to build fixture files
/// for `GGUFMetadataTests` below. There's no dependency on a real GGUF
/// file anywhere in this test suite — every header byte is spelled out
/// here, matching the format `GGUFMetadata.swift` itself documents.
struct GGUFFixtureBuilder {
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
        try data(minBytes: 0).write(to: url)
        return url
    }

    /// The built bytes, optionally padded to exactly `minBytes`.
    func data(minBytes: Int = 0) -> Data {
        var data = build()
        if data.count < minBytes {
            data.append(Data(repeating: 0x20, count: minBytes - data.count))
        }
        return data
    }

    /// Writes the fixture at `path`, padded so the file is exactly
    /// `minBytes` large (no-op if the header alone is longer).
    func write(to path: URL, minBytes: Int = 0) throws {
        try data(minBytes: minBytes).write(to: path)
    }
}
