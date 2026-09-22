import Foundation

/// Just enough of a GGUF file's own header to feed the device-fit formula
/// in docs/ARCHITECTURE.md §7 ("What Quail reads from the model"). A real
/// GGUF file can carry hundreds of metadata keys (full tokenizer vocab,
/// chat template, training hyperparameters, ...) and megabytes of tensor
/// descriptors after that; none of it is read here beyond the metadata
/// key-value section, and unwanted values within that section — including
/// huge string arrays like `tokenizer.ggml.tokens` — are skipped by
/// advancing past their byte length, never decoded.
///
/// Beyond the fields ARCHITECTURE.md §7 lists by name, this also reads
/// `key_length`/`value_length` and `expert_count`/`expert_used_count` —
/// confirmed present as real keys in the vendored llama.cpp binary's own
/// string table (`strings Vendor/llama.cpp/libllama*.dylib`). `FitEstimator`
/// needs a true head dimension (not always `embedding_length / head_count`
/// — see `keyLength`'s doc comment) and MoE active-expert counts for the
/// speed estimate.
struct GGUFMetadata: Sendable, Equatable {
    var architecture: String?
    var blockCount: Int?
    var headCountKV: Int?
    var embeddingLength: Int?
    var headCount: Int?
    /// The raw `ggml_ftype` enum value from `general.file_type` (e.g. the
    /// llama.cpp source's `LLAMA_FTYPE_MOSTLY_Q4_K_M == 15`). Left
    /// undecoded — turning this into a human quant label like "Q4_K_M" is
    /// a display concern for whatever reads this struct, not this parser.
    var fileType: Int?
    /// `<arch>.attention.key_length` — the true per-head attention
    /// dimension, when the architecture writes one explicitly. Confirmed
    /// against the vendored llama.cpp binary's own string table that this
    /// key exists in real builds; only present when it differs from
    /// `embedding_length / head_count` (mirrors MLX's `head_dim`, which
    /// has the same "don't assume it divides evenly" caveat — see
    /// `MLXMetadata.swift`). `nil` when the architecture doesn't write it,
    /// in which case `embedding_length / head_count` is the fallback.
    var keyLength: Int?
    /// `<arch>.attention.value_length` — same story as `keyLength`, for
    /// the value projection's per-head dimension.
    var valueLength: Int?
    /// `<arch>.expert_count` — total routable experts, for MoE
    /// architectures. `nil` for dense models.
    var expertCount: Int?
    /// `<arch>.expert_used_count` — experts activated per token, for MoE
    /// architectures. `nil` for dense models.
    var expertUsedCount: Int?

    enum GGUFReadError: Error, Equatable {
        case notAGGUFFile
        case unsupportedVersion(UInt32)
        case truncated
    }

    private static let magic: UInt32 = 0x4655_4747 // ASCII "GGUF", little-endian on disk

    /// Reads and parses a GGUF file's header. The file is memory-mapped
    /// (`.mappedIfSafe`) so this is cheap regardless of the model's actual
    /// size on disk — tensor data itself is never paged in, only the
    /// header bytes this parser actually touches.
    ///
    /// Two passes over the header: the first finds `general.architecture`
    /// (needed to recognize the architecture-namespaced keys below), the
    /// second extracts everything else. GGUF's own writers always emit
    /// `general.architecture` first in practice, but nothing in the
    /// format guarantees that ordering, so this doesn't assume it.
    static func read(from url: URL) throws -> GGUFMetadata {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let (version, kvCount, headerStart) = try readPreamble(data)

        let architecture = try findArchitecture(data, kvCount: kvCount, start: headerStart)

        var result = GGUFMetadata()
        result.architecture = architecture

        var cursor = Cursor(data: data, offset: headerStart)
        for _ in 0 ..< kvCount {
            let key = try cursor.readGGUFString()
            let type = try cursor.readUInt32()

            if key == "general.file_type" {
                result.fileType = try cursor.readScalarAsInt(type: type)
                continue
            }
            if let arch = architecture {
                switch key {
                case "\(arch).block_count":
                    result.blockCount = try cursor.readScalarAsInt(type: type)
                    continue
                case "\(arch).attention.head_count_kv":
                    result.headCountKV = try cursor.readScalarAsInt(type: type)
                    continue
                case "\(arch).embedding_length":
                    result.embeddingLength = try cursor.readScalarAsInt(type: type)
                    continue
                case "\(arch).attention.head_count":
                    result.headCount = try cursor.readScalarAsInt(type: type)
                    continue
                case "\(arch).attention.key_length":
                    result.keyLength = try cursor.readScalarAsInt(type: type)
                    continue
                case "\(arch).attention.value_length":
                    result.valueLength = try cursor.readScalarAsInt(type: type)
                    continue
                case "\(arch).expert_count":
                    result.expertCount = try cursor.readScalarAsInt(type: type)
                    continue
                case "\(arch).expert_used_count":
                    result.expertUsedCount = try cursor.readScalarAsInt(type: type)
                    continue
                default:
                    break
                }
            }
            try cursor.skipValue(ofType: type)
        }
        // Also silence the "version unused" warning while keeping it
        // available for callers that might want to branch on it later.
        _ = version

        return result
    }

    /// Reads the fixed-size preamble (magic, version, tensor_count,
    /// metadata_kv_count) and returns where the metadata key-value section
    /// starts. `tensor_count` itself is discarded — this parser never
    /// reaches the tensor info section that follows the metadata.
    private static func readPreamble(_ data: Data) throws -> (version: UInt32, kvCount: UInt64, headerStart: Int) {
        var cursor = Cursor(data: data, offset: 0)
        guard try cursor.readUInt32() == magic else {
            throw GGUFReadError.notAGGUFFile
        }
        let version = try cursor.readUInt32()
        guard version == 2 || version == 3 else {
            throw GGUFReadError.unsupportedVersion(version)
        }
        _ = try cursor.readUInt64() // tensor_count
        let kvCount = try cursor.readUInt64()
        return (version, kvCount, cursor.offset)
    }

    private static func findArchitecture(_ data: Data, kvCount: UInt64, start: Int) throws -> String? {
        var cursor = Cursor(data: data, offset: start)
        for _ in 0 ..< kvCount {
            let key = try cursor.readGGUFString()
            let type = try cursor.readUInt32()
            if key == "general.architecture" {
                return try cursor.readScalarAsString(type: type)
            }
            try cursor.skipValue(ofType: type)
        }
        return nil
    }

    /// A little-endian byte cursor over a memory-mapped GGUF file. Every
    /// read advances `offset`; every read range-checks against `data`'s
    /// bounds first, throwing `.truncated` rather than trapping on a
    /// corrupt or short file.
    private struct Cursor {
        let data: Data
        var offset: Int

        init(data: Data, offset: Int) {
            self.data = data
            self.offset = offset
        }

        private mutating func take(_ count: Int) throws -> Data {
            let start = data.startIndex + offset
            guard count >= 0, start + count <= data.endIndex else {
                throw GGUFReadError.truncated
            }
            defer { offset += count }
            return data.subdata(in: start ..< (start + count))
        }

        mutating func readUInt8() throws -> UInt8 {
            try take(1)[0]
        }

        mutating func readInt8() throws -> Int8 {
            try Int8(bitPattern: readUInt8())
        }

        mutating func readUInt16() throws -> UInt16 {
            try take(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        }

        mutating func readInt16() throws -> Int16 {
            try Int16(bitPattern: readUInt16())
        }

        mutating func readUInt32() throws -> UInt32 {
            try take(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }

        mutating func readInt32() throws -> Int32 {
            try Int32(bitPattern: readUInt32())
        }

        mutating func readUInt64() throws -> UInt64 {
            try take(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        }

        mutating func readInt64() throws -> Int64 {
            try Int64(bitPattern: readUInt64())
        }

        /// A GGUF string: `uint64` byte length, then that many UTF-8 bytes
        /// (not NUL-terminated).
        mutating func readGGUFString() throws -> String {
            let length = try readUInt64()
            let bytes = try take(Int(length))
            guard let string = String(data: bytes, encoding: .utf8) else {
                throw GGUFReadError.truncated
            }
            return string
        }

        /// The byte width of one element of a fixed-size scalar type, or
        /// `nil` for `string`/`array`, whose width depends on their
        /// content and must be read, not computed.
        private static func fixedElementSize(for type: UInt32) -> Int? {
            switch type {
            case 0, 1, 7: 1 // uint8, int8, bool
            case 2, 3: 2 // uint16, int16
            case 4, 5, 6: 4 // uint32, int32, float32
            case 10, 11, 12: 8 // uint64, int64, float64
            default: nil // 8 = string, 9 = array
            }
        }

        /// Advances past one value of `type` without decoding it. Arrays
        /// of a fixed-size scalar type skip in a single bounds-checked
        /// jump; arrays of strings (or, in principle, of arrays) skip
        /// element by element, since only each element's length prefix —
        /// never its content — needs to be read to find the next one.
        mutating func skipValue(ofType type: UInt32) throws {
            if let size = Cursor.fixedElementSize(for: type) {
                _ = try take(size)
                return
            }
            switch type {
            case 8: // string
                let length = try readUInt64()
                _ = try take(Int(length))
            case 9: // array
                let elementType = try readUInt32()
                let count = try readUInt64()
                if let size = Cursor.fixedElementSize(for: elementType) {
                    _ = try take(size * Int(count))
                } else {
                    for _ in 0 ..< count {
                        try skipValue(ofType: elementType)
                    }
                }
            default:
                throw GGUFReadError.truncated
            }
        }

        /// Reads a numeric scalar (or the first element of a numeric
        /// array, skipping the rest) as `Int`. Some architectures write
        /// `attention.head_count_kv` as a per-layer array rather than one
        /// shared value; the device-fit formula in ARCHITECTURE.md §7
        /// only has room for one number, so the first element stands in
        /// for all of them until FitEstimator needs anything smarter.
        mutating func readScalarAsInt(type: UInt32) throws -> Int {
            switch type {
            case 0: try Int(readUInt8())
            case 1: try Int(readInt8())
            case 2: try Int(readUInt16())
            case 3: try Int(readInt16())
            case 4: try Int(readUInt32())
            case 5: try Int(readInt32())
            case 10: try Int(readUInt64())
            case 11: try Int(readInt64())
            case 9:
                try readFirstOfArrayAsInt()
            default:
                throw GGUFReadError.truncated
            }
        }

        private mutating func readFirstOfArrayAsInt() throws -> Int {
            let elementType = try readUInt32()
            let count = try readUInt64()
            guard count > 0 else { throw GGUFReadError.truncated }
            let first = try readScalarAsInt(type: elementType)
            if count > 1 {
                if let size = Cursor.fixedElementSize(for: elementType) {
                    _ = try take(size * Int(count - 1))
                } else {
                    for _ in 1 ..< count {
                        try skipValue(ofType: elementType)
                    }
                }
            }
            return first
        }

        /// Reads a `string`-typed value. `general.architecture` is the
        /// only key this parser ever reads as a string.
        mutating func readScalarAsString(type: UInt32) throws -> String {
            guard type == 8 else { throw GGUFReadError.truncated }
            return try readGGUFString()
        }
    }
}
