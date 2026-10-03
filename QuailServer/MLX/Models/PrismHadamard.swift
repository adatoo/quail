// Adapted from mlx-swift-lm 0dcfe2f8a, with its open PR #630 (bac826f): Libraries/MLXLMCommon/HadamardQuantized.swift
// and Libraries/MLXLLM/Models/PrismHadamardQwen35.swift (MIT; Copyright (c) 2024 ml-explore). Quail's own copy
// (ADR D-066 amendment, D-069): Bonsai 2 27B, PrismML's Hadamard-rotated ternary Qwen3.6 27B
// (`model_type: prism_hadamard_qwen35`), which the pinned mlx-swift-lm doesn't load.
//
// Checked against mlx-swift-lm 3.32.3, the release pinned (2026-09-30): its only changes since 0dcfe2f8a are
// mlx-swift 0.32.3 and tests, so nothing here changes.
//
// Changes from the source:
// - Built on Quail's own Qwen3.5 copy (`QQwen35Model`, Qwen35.swift) rather than mlx-swift-lm's, so the pack gets
//   its compiled functions and fused decode kernel. That copy keeps the GatedDeltaNet input projections apart, as
//   the manifest names them.
// - The manifest, its validation and the choice of tensors to cast are in QuailServerCore
//   (`PrismHadamardManifest`), where they're tested without MLX.
// - Text only: mlx-swift-lm's vision Qwen3.5 isn't open to subclass.
// - Both placeholders are shaped from the manifest's quantization without quantizing anything; the source's
//   embedding quantizes a random table (lazily, never evaluated).
//
// Delete this file when mlx-swift-lm ships #630 and the pin moves past it. A rotation applied wrongly still writes
// fluent text, so this was checked token for token against a Python reference built from Rapid-MLX's runtime (D-066).

import Foundation
import MLX
import MLXLMCommon
import MLXNN
import QuailServerCore

// MARK: - Rotation

/// A signed, blockwise Walsh–Hadamard rotation of an array's last axis.
///
/// Rotated checkpoints fold `R = H·S / √n` into every packed weight, where `H` is the Sylvester Walsh–Hadamard
/// matrix of order `n` (the block size) and `S` a diagonal of ±1 signs. Activations take the same rotation before
/// the packed matmul, and embedding rows the inverse after lookup. Computed in float32 and returned in the input's
/// dtype, as the reference runtime does.
struct QSignedBlockHadamard: Sendable, Equatable {
    let blockSize: Int
    private let scale: Float

    init(blockSize: Int) {
        precondition(PrismHadamardManifest.isValidBlockSize(blockSize), "blockSize must be a power of two")
        self.blockSize = blockSize
        scale = 1 / Float(blockSize).squareRoot()
    }

    /// `R·x` along the last axis: flip signs, then transform each block.
    func forward(_ x: MLXArray, signs: MLXArray) -> MLXArray {
        transform(x.asType(.float32) * signs).asType(x.dtype)
    }

    /// `Rᵀ·x` along the last axis: transform each block, then flip signs.
    func inverse(_ x: MLXArray, signs: MLXArray) -> MLXArray {
        (transform(x.asType(.float32)) * signs).asType(x.dtype)
    }

    private func transform(_ x: MLXArray) -> MLXArray {
        precondition(x.dim(-1) % blockSize == 0, "last axis must be a multiple of blockSize")
        let shape = x.shape
        return hadamardTransform(x.reshaped(-1, blockSize), scale: scale).reshaped(shape)
    }
}

// MARK: - Layers

/// A `QuantizedLinear` whose weights were quantized in a rotated input basis: it rotates its input, then runs the
/// packed matmul. `signs` is the rotation's ±1 vector, one entry per input feature, loaded from the checkpoint.
final class QHadamardQuantizedLinear: QuantizedLinear {
    let rotation: QSignedBlockHadamard
    let signs: MLXArray

    /// A placeholder shaped like the checkpoint's affine arrays (the only mode the manifest accepts), standing in for
    /// `linear` until the weights load.
    init(replacing linear: Linear, quantization: PrismHadamardManifest.Quantization, rotation: QSignedBlockHadamard) {
        let (outputs, inputs) = linear.shape
        let groups = inputs / quantization.groupSize
        self.rotation = rotation
        signs = MLXArray.ones([inputs], dtype: .float32)
        super.init(
            weight: MLXArray.zeros([outputs, inputs * quantization.bits / 32], dtype: .uint32),
            bias: linear.bias,
            scales: MLXArray.zeros([outputs, groups], dtype: .float16),
            biases: MLXArray.zeros([outputs, groups], dtype: .float16),
            groupSize: quantization.groupSize, bits: quantization.bits, mode: .affine
        )
        freeze()
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        super.callAsFunction(rotation.forward(x, signs: signs))
    }
}

/// A `QuantizedEmbedding` whose rows were quantized in a rotated basis: lookup un-rotates the dequantized rows, and
/// `asLinear` (a tied head) rotates its input first, as the linear layer does.
final class QHadamardQuantizedEmbedding: QuantizedEmbedding {
    let rotation: QSignedBlockHadamard
    let signs: MLXArray

    /// A placeholder shaped like the checkpoint's arrays, standing in for `embedding` until the weights load.
    init(
        replacing embedding: Embedding, quantization: PrismHadamardManifest.Quantization,
        rotation: QSignedBlockHadamard
    ) {
        let (count, dimensions) = embedding.shape
        let groups = dimensions / quantization.groupSize
        self.rotation = rotation
        signs = MLXArray.ones([dimensions], dtype: .float32)
        super.init(
            weight: MLXArray.zeros([count, dimensions * quantization.bits / 32], dtype: .uint32),
            scales: MLXArray.zeros([count, groups], dtype: .float16),
            biases: MLXArray.zeros([count, groups], dtype: .float16),
            groupSize: quantization.groupSize, bits: quantization.bits, mode: .affine
        )
        freeze()
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        rotation.inverse(super.callAsFunction(x), signs: signs)
    }

    override func asLinear(_ x: MLXArray) -> MLXArray {
        super.asLinear(rotation.forward(x, signs: signs))
    }
}

// MARK: - Checkpoint

/// Replaces every manifest module of `model` with its rotated, pre-quantized placeholder. Call it after building
/// the model and before the weights load: the loader's quantize pass leaves the placeholders alone (they're already
/// `Quantized`) and its parameter update fills them in, signs included.
func substitutePrismHadamardModules(in model: Module, manifest: PrismHadamardManifest, pathPrefix: String) throws {
    let modulesByPath = Dictionary(uniqueKeysWithValues: model.leafModules().flattened())
    var updates = [(String, Module)]()
    for entry in manifest.modules {
        let path = pathPrefix + entry.path
        guard let module = modulesByPath[path] else {
            throw PrismHadamardManifest.Error.moduleNotFound(path)
        }
        let rotation = QSignedBlockHadamard(blockSize: entry.block)
        switch module {
        case let embedding as Embedding where entry.embedding && type(of: module) == Embedding.self:
            updates.append((path, QHadamardQuantizedEmbedding(
                replacing: embedding, quantization: manifest.quantization, rotation: rotation
            )))
        case let linear as Linear where !entry.embedding && type(of: module) == Linear.self:
            updates.append((path, QHadamardQuantizedLinear(
                replacing: linear, quantization: manifest.quantization, rotation: rotation
            )))
        default:
            throw PrismHadamardManifest.Error.moduleNotSubstitutable(path, found: "\(type(of: module))")
        }
    }
    model.update(modules: ModuleChildren.unflattened(updates))
}

/// Bonsai 2: Quail's Qwen3.5 text model with the manifest's modules rotated, and the pack's float32 tensors cast
/// to the activation dtype as they load.
final class QPrismHadamardQwen35Model: QQwen35Model {
    private static let pathPrefix = "language_model."

    let manifest: PrismHadamardManifest
    private let activationDType: DType?

    /// Validates the manifest before anything is allocated, then builds the base model and swaps in the rotated
    /// placeholders.
    init(_ configuration: QQwen35Configuration, manifest: PrismHadamardManifest) throws {
        try manifest.validate(baseModelType: "qwen3_5", tensorNamespace: "mlx-vlm-qwen3_5")
        self.manifest = manifest
        activationDType = switch try manifest.activationDType() {
        case "float16"?: .float16
        case "bfloat16"?: .bfloat16
        default: nil
        }
        super.init(configuration)
        try substitutePrismHadamardModules(in: self, manifest: manifest, pathPrefix: Self.pathPrefix)
    }

    override func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var weights = super.sanitize(weights: weights)
        guard let activationDType else { return weights }
        for (key, value) in weights
            where value.dtype.isFloatingPoint && value.dtype != activationDType
            && manifest.castsUnpacked(key, pathPrefix: Self.pathPrefix)
        {
            weights[key] = value.asType(activationDType)
        }
        return weights
    }
}
