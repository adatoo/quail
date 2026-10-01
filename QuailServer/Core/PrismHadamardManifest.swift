import Foundation

/// What a Hadamard-rotated checkpoint (PrismML's Bonsai 2, `model_type: prism_hadamard_qwen35`) declares in its
/// `config.json`, beside the base model's own configuration: which modules have a rotation folded into their
/// packed weights, and the quantization they share. The MLX layers that apply the rotation are in
/// `QuailServer/MLX/Models/PrismHadamard.swift`; this half needs no MLX, so it's tested here.
///
/// Adapted from mlx-swift-lm PR #630 (bac826f, `MLXLMCommon/HadamardQuantized.swift`; MIT), with the MLX types
/// replaced by their names so it builds without MLX.
public struct PrismHadamardManifest: Codable, Sendable, Equatable {
    /// One module whose weights carry a folded rotation.
    public struct Module: Codable, Sendable, Equatable {
        /// Relative to the language model, as `config.json` names it (`model.layers.0.mlp.up_proj`, `lm_head`).
        public var path: String
        /// The Hadamard block size folded into the weights.
        public var block: Int
        /// An embedding table (inverse rotation after lookup), not a linear layer (forward rotation first).
        public var embedding: Bool
        /// The activation dtype the module was packed for (`"float16"`), when the entry says.
        public var dtype: String?

        public init(path: String, block: Int, embedding: Bool = false, dtype: String? = nil) {
            self.path = path
            self.block = block
            self.embedding = embedding
            self.dtype = dtype
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            block = try container.decode(Int.self, forKey: .block)
            embedding = try container.decodeIfPresent(Bool.self, forKey: .embedding) ?? false
            dtype = try container.decodeIfPresent(String.self, forKey: .dtype)
        }
    }

    public struct Quantization: Codable, Sendable, Equatable {
        public var bits: Int
        public var groupSize: Int
        public var mode: String

        enum CodingKeys: String, CodingKey {
            case bits
            case groupSize = "group_size"
            case mode
        }

        public init(bits: Int, groupSize: Int, mode: String = "affine") {
            self.bits = bits
            self.groupSize = groupSize
            self.mode = mode
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bits = try container.decode(Int.self, forKey: .bits)
            groupSize = try container.decode(Int.self, forKey: .groupSize)
            mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "affine"
        }
    }

    /// The manifest schema this reads.
    public static let supportedSchemaVersion = 2

    public var schemaVersion: Int
    /// The `model_type` of the architecture the checkpoint runs.
    public var baseModelType: String?
    /// The tensor naming the pack uses, which fixes the module paths.
    public var tensorNamespace: String?
    /// How gated-delta activations are ordered; only `"grouped"` loads without a permutation.
    public var gdnActivationLayout: String?
    public var modules: [Module]
    public var quantization: Quantization

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case baseModelType = "base_model_type"
        case tensorNamespace = "tensor_namespace"
        case gdnActivationLayout = "gdn_activation_layout"
        case modules
        case quantization
    }

    public init(
        schemaVersion: Int = supportedSchemaVersion, baseModelType: String? = nil, tensorNamespace: String? = nil,
        gdnActivationLayout: String? = nil, modules: [Module], quantization: Quantization
    ) {
        self.schemaVersion = schemaVersion
        self.baseModelType = baseModelType
        self.tensorNamespace = tensorNamespace
        self.gdnActivationLayout = gdnActivationLayout
        self.modules = modules
        self.quantization = quantization
    }

    /// Rejects a manifest Quail can't load faithfully. A rotation applied wrongly decodes to fluent nonsense
    /// rather than failing, so anything unexpected is an error here.
    public func validate(baseModelType expectedType: String, tensorNamespace expectedNamespace: String) throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw Error.unsupportedSchemaVersion(schemaVersion)
        }
        guard baseModelType == expectedType else {
            throw Error.unsupportedBaseModelType(baseModelType, expected: expectedType)
        }
        guard tensorNamespace == expectedNamespace else {
            throw Error.unsupportedTensorNamespace(tensorNamespace, expected: expectedNamespace)
        }
        if let layout = gdnActivationLayout, layout != "grouped" {
            throw Error.unsupportedActivationLayout(layout)
        }
        guard !modules.isEmpty else {
            throw Error.emptyManifest
        }
        // The only mode packs use, and the only one whose placeholders are shaped here.
        guard quantization.mode == "affine" else {
            throw Error.unsupportedQuantizationMode(quantization.mode)
        }
        for module in modules where !Self.isValidBlockSize(module.block) {
            throw Error.unsupportedBlockSize(module.path, block: module.block)
        }
        _ = try activationDType()
    }

    /// The activation dtype the packed modules declare (`"float16"` or `"bfloat16"`), or nil when none does.
    /// Every declaring entry must agree.
    public func activationDType() throws -> String? {
        let declared = Set(modules.compactMap(\.dtype))
        guard let name = declared.first else { return nil }
        guard declared.count == 1 else {
            throw Error.mixedActivationDTypes(declared.sorted())
        }
        guard name == "float16" || name == "bfloat16" else {
            throw Error.unsupportedActivationDType(name)
        }
        return name
    }

    /// Whether the floating-point tensor `key` is one the checkpoint's activation-dtype cast applies to: a pack may
    /// store its norms, convolution taps and small projections in float32 while its packed modules run in float16,
    /// and MLX would then promote the residual stream to float32 after the first layer, at twice the KV cache. The
    /// cast is the one mlx-vlm's converter applies: everything except the packed modules' own tensors and `A_log`,
    /// which the gated-delta recurrence reads in float32.
    public func castsUnpacked(_ key: String, pathPrefix: String) -> Bool {
        guard !key.hasSuffix("A_log") else { return false }
        let module = key.lastIndex(of: ".").map { String(key[..<$0]) } ?? key
        return !packedPaths(prefix: pathPrefix).contains(module)
    }

    /// The manifest's module paths, as the model names them.
    public func packedPaths(prefix: String) -> Set<String> {
        Set(modules.map { prefix + $0.path })
    }

    /// Sylvester's construction defines only powers of two.
    public static func isValidBlockSize(_ block: Int) -> Bool {
        block > 0 && block & (block - 1) == 0
    }

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case unsupportedSchemaVersion(Int)
        case unsupportedBaseModelType(String?, expected: String)
        case unsupportedTensorNamespace(String?, expected: String)
        case unsupportedActivationLayout(String)
        case emptyManifest
        case mixedActivationDTypes([String])
        case unsupportedActivationDType(String)
        case unsupportedBlockSize(String, block: Int)
        case unsupportedQuantizationMode(String)
        case moduleNotFound(String)
        case moduleNotSubstitutable(String, found: String)

        public var description: String {
            switch self {
            case let .unsupportedSchemaVersion(version):
                "Rotated checkpoint schema_version \(version) is not supported (expected \(PrismHadamardManifest.supportedSchemaVersion))"
            case let .unsupportedBaseModelType(type, expected):
                "Rotated checkpoint base_model_type \(type ?? "nil") is not \(expected)"
            case let .unsupportedTensorNamespace(namespace, expected):
                "Rotated checkpoint tensor_namespace \(namespace ?? "nil") is not \(expected)"
            case let .unsupportedActivationLayout(layout):
                "Rotated checkpoint gdn_activation_layout \(layout) needs a permutation Quail doesn't apply"
            case .emptyManifest:
                "Rotated checkpoint declares no modules"
            case let .mixedActivationDTypes(names):
                "Rotated checkpoint modules disagree on their activation dtype: " + names.joined(separator: ", ")
            case let .unsupportedActivationDType(name):
                "Rotated checkpoint activation dtype \(name) is not supported (expected float16 or bfloat16)"
            case let .unsupportedBlockSize(path, block):
                "Rotated checkpoint module \(path) declares block \(block); only a positive power of two is supported"
            case let .unsupportedQuantizationMode(mode):
                "Rotated checkpoint quantization mode \(mode) is not supported (expected affine)"
            case let .moduleNotFound(path):
                "Rotated checkpoint names a module the model does not have: \(path)"
            case let .moduleNotSubstitutable(path, found):
                "Rotated checkpoint module \(path) is a \(found), not a plain Linear or Embedding"
            }
        }
    }
}
