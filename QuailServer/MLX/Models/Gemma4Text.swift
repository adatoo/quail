// Adapted from mlx-swift-lm 3.31.4, Libraries/MLXVLM/Models/Gemma4.swift (MIT; Copyright (c) 2024 ml-explore),
// itself based on mlx-vlm's gemma4. Quail's own copy (ADR D-066, #140): the language model of Gemma 4's vision
// checkpoints, mixture-of-experts layers included, loaded text-only and registered in place of mlx-swift-lm's
// text-only Gemma 4 (which has no experts, so Gemma 4 26B-A4B could only load through the vision model).
//
// Changes from the source:
// - Text only: the vision and audio towers, token types, bidirectional vision masks and the MTP drafter state are
//   gone. Image turns still load mlx-swift-lm's vision model (`MLXEngine.loadedFor`).
// - Positions come from the cache's `ropeOffset` (`applyRotaryPosition`), not the scalar `offset`, so the model runs
//   over a batch of sequences of different lengths (`BatchKVCache`, `BatchSlidingKVCache`).
// - Types are prefixed `QGemma4` so they don't meet mlx-swift-lm's own.
//
// Compared with mlx-swift-lm 0dcfe2f8a (main, 2026-09-29), and the same at 3.32.3: its own text-only Gemma 4
// (MLXLLM/Models/Gemma4Text.swift) now has the experts and takes positions from `ropeOffset`, and in Quail it loaded
// Gemma 4 26B-A4B text-only and batched it. This copy stays until that's checked across Gemma 4's other checkpoints.
//
// Checked against mlx-swift-lm 3.32.3, the release pinned (2026-09-30): its only changes since 0dcfe2f8a are
// mlx-swift 0.32.3 and tests, so nothing here changes.
//
// When mlx-swift-lm's pin moves, `MLXModelCopiesTests` fails until the source file's text model has been compared
// with this one at the new pin and this header names it.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM

// MARK: - Model

/// Gemma 4's language model as an `LLMModel`, from a checkpoint that holds the vision model's weights too.
final class QGemma4Model: Module, LLMModel, KVCacheDimensionProvider {
    @ModuleInfo(key: "language_model") var languageModel: QGemma4LanguageModel

    var vocabularySize: Int {
        languageModel.config.vocabularySize
    }

    var kvHeads: [Int] {
        languageModel.kvHeads
    }

    /// Whether every layer has a cache of its own: a model whose later layers reuse earlier layers' keys and values
    /// (Gemma 4 E2B and E4B) reads their positions as one number, so isn't batched.
    var ownsEveryCache: Bool {
        languageModel.config.numKVSharedLayers == 0
    }

    init(_ config: MLXVLM.Gemma4TextConfiguration) {
        _languageModel.wrappedValue = QGemma4LanguageModel(config)
        super.init()
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        languageModel(inputs, cache: cache).logits
    }

    func newCache(parameters: GenerateParameters?) -> [any KVCache] {
        languageModel.newCache(parameters: parameters)
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        languageModel.sanitize(weights: weights).filter { key, _ in key.hasPrefix("language_model.") }
    }

    var loraLayers: [Module] {
        languageModel.model.layers
    }
}

// MARK: - Layers

final class QGemma4RMSNormNoScale: Module, UnaryLayer {
    let eps: Float

    init(eps: Float = 1e-6) {
        self.eps = eps
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: MLXArray.mlxNone, eps: eps)
    }
}

final class QGemma4RMSNormZeroShift: Module, UnaryLayer {
    let eps: Float
    @ModuleInfo var weight: MLXArray

    init(dimensions: Int, eps: Float = 1e-6) {
        self.eps = eps
        _weight.wrappedValue = MLXArray.ones([dimensions])
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: weight, eps: eps)
    }
}

final class QGemma4MLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear

    init(config: MLXVLM.Gemma4TextConfiguration, layerIdx: Int) {
        let firstKVSharedLayer = config.hiddenLayers - config.numKVSharedLayers
        let isKVSharedLayer = layerIdx >= firstKVSharedLayer && firstKVSharedLayer > 0
        let useDoubleWide = config.useDoubleWideMLP && isKVSharedLayer
        let hiddenDimensions = config.intermediateSize * (useDoubleWide ? 2 : 1)

        _gateProj.wrappedValue = Linear(config.hiddenSize, hiddenDimensions, bias: false)
        _downProj.wrappedValue = Linear(hiddenDimensions, config.hiddenSize, bias: false)
        _upProj.wrappedValue = Linear(config.hiddenSize, hiddenDimensions, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(geluApproximate(gateProj(x)) * upProj(x))
    }
}

final class QGemma4Router: Module {
    let topKExperts: Int
    let config: MLXVLM.Gemma4TextConfiguration
    private let rootSize: Float

    @ModuleInfo(key: "proj") var proj: Linear
    @ParameterInfo(key: "scale") var scale: MLXArray
    @ParameterInfo(key: "per_expert_scale") var perExpertScale: MLXArray

    init(config: MLXVLM.Gemma4TextConfiguration) {
        guard let numExperts = config.numExperts, let topKExperts = config.topKExperts else {
            fatalError("Gemma4 MoE router requires numExperts and topKExperts")
        }
        self.topKExperts = topKExperts
        self.config = config
        rootSize = pow(Float(config.hiddenSize), -0.5)
        _proj.wrappedValue = Linear(config.hiddenSize, numExperts, bias: false)
        _scale.wrappedValue = MLXArray.ones([config.hiddenSize])
        _perExpertScale.wrappedValue = MLXArray.ones([numExperts])
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> (MLXArray, MLXArray) {
        let normed = MLXFast.rmsNorm(x, weight: (scale * rootSize).asType(x.dtype), eps: config.rmsNormEps)
        let scores = proj(normed)
        let topKIndices = MLX.argPartition(scores, kth: -topKExperts, axis: -1)[.ellipsis, (-topKExperts)...]
        var topKWeights = MLX.takeAlong(scores, topKIndices, axis: -1)
        topKWeights = MLX.softmax(topKWeights, axis: -1)
        topKWeights = topKWeights * perExpertScale[topKIndices].asType(topKWeights.dtype)
        return (topKIndices, topKWeights)
    }
}

final class QGemma4Experts: Module {
    @ModuleInfo(key: "switch_glu") var switchGLU: SwitchGLU

    init(config: MLXVLM.Gemma4TextConfiguration) {
        guard let numExperts = config.numExperts, let moeIntermediateSize = config.moeIntermediateSize else {
            fatalError("Gemma4 MoE experts require numExperts and moeIntermediateSize")
        }
        _switchGLU.wrappedValue = SwitchGLU(
            inputDims: config.hiddenSize, hiddenDims: moeIntermediateSize, numExperts: numExperts,
            activation: geluApproximate, bias: false
        )
        super.init()
    }

    func callAsFunction(_ x: MLXArray, topKIndices: MLXArray, topKWeights: MLXArray) -> MLXArray {
        let (batch, length, hidden) = (x.dim(0), x.dim(1), x.dim(2))
        let topK = topKIndices.dim(-1)
        let expertOutput = switchGLU(
            x.reshaped(batch * length, hidden), topKIndices.reshaped(batch * length, topK)
        )
        let weights = topKWeights.reshaped(batch * length, topK).asType(expertOutput.dtype)
        return weightedExpertSum(expertOutput, weights).reshaped(batch, length, hidden)
    }
}

/// Keys and values a layer produced, which a later layer that shares them reads (Gemma 4 E2B and E4B).
enum QGemma4SharedKVState {
    case regular(keys: MLXArray, values: MLXArray)
    case quantized(
        keys: (MLXArray, MLXArray, MLXArray?),
        values: (MLXArray, MLXArray, MLXArray?),
        groupSize: Int,
        bits: Int,
        mode: QuantizationMode
    )

    var sequenceLength: Int {
        switch self {
        case let .regular(keys, _): keys.dim(2)
        case let .quantized(keys, _, _, _, _): keys.0.dim(-2)
        }
    }
}

/// A mask for fewer keys than it was made for keeps its last columns.
func qGemma4AdjustAttentionMask(
    _ mask: MLXFast.ScaledDotProductAttentionMaskMode, keyLength: Int
) -> MLXFast.ScaledDotProductAttentionMaskMode {
    switch mask {
    case let .array(maskArray):
        let maskLength = maskArray.dim(-1)
        guard maskLength > keyLength else { return mask }
        return .array(maskArray[.ellipsis, (maskLength - keyLength)...])
    case .arrays, .causal, .none:
        return mask
    }
}

final class QGemma4Attention: Module {
    let config: MLXVLM.Gemma4TextConfiguration
    let layerIdx: Int
    let layerType: String
    let isSliding: Bool
    let headDim: Int
    let numHeads: Int
    let numKVHeads: Int
    let scale: Float
    let isKVSharedLayer: Bool
    let useKEqV: Bool

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear?
    @ModuleInfo(key: "v_proj") var vProj: Linear?
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: QGemma4RMSNormZeroShift
    @ModuleInfo(key: "k_norm") var kNorm: QGemma4RMSNormZeroShift?
    @ModuleInfo(key: "v_norm") var vNorm: QGemma4RMSNormNoScale?
    @ModuleInfo var rope: RoPELayer

    init(config: MLXVLM.Gemma4TextConfiguration, layerIdx: Int) {
        self.config = config
        self.layerIdx = layerIdx
        layerType = config.layerTypes[layerIdx]
        isSliding = layerType == "sliding_attention"
        headDim = layerType == "full_attention" && config.globalHeadDim > 0 ? config.globalHeadDim : config.headDim
        numHeads = config.attentionHeads
        useKEqV = config.attentionKEqV && !isSliding
        numKVHeads = useKEqV ? (config.globalKVHeads ?? config.kvHeads) : config.kvHeads
        scale = 1.0

        let firstKVSharedLayer = config.hiddenLayers - config.numKVSharedLayers
        isKVSharedLayer = layerIdx >= firstKVSharedLayer && firstKVSharedLayer > 0

        _qProj.wrappedValue = Linear(config.hiddenSize, numHeads * headDim, bias: false)
        _kProj.wrappedValue = Linear(config.hiddenSize, numKVHeads * headDim, bias: false)
        if !useKEqV {
            _vProj.wrappedValue = Linear(config.hiddenSize, numKVHeads * headDim, bias: false)
        }
        _kNorm.wrappedValue = QGemma4RMSNormZeroShift(dimensions: headDim, eps: config.rmsNormEps)
        _vNorm.wrappedValue = QGemma4RMSNormNoScale(eps: config.rmsNormEps)
        _oProj.wrappedValue = Linear(numHeads * headDim, config.hiddenSize, bias: false)
        _qNorm.wrappedValue = QGemma4RMSNormZeroShift(dimensions: headDim, eps: config.rmsNormEps)

        let ropeKey = isSliding ? "sliding_attention" : "full_attention"
        let ropeConfig = config.ropeParameters[ropeKey]
        let ropeTheta = ropeConfig?["rope_theta"]?.asFloat() ?? (isSliding ? 10000 : 1_000_000)
        _rope.wrappedValue = initializeRope(
            dims: headDim, base: ropeTheta, traditional: config.ropeTraditional, scalingConfig: ropeConfig,
            maxPositionEmbeddings: config.maxPositionEmbeddings
        )
        super.init()
    }

    /// - Parameters:
    ///   - sharedKV, offset: an earlier layer's keys and values, and the positions they were made at, for a layer
    ///     that shares them.
    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode = .none, cache: KVCache? = nil,
        sharedKV: QGemma4SharedKVState? = nil, offset: RoPEOffset? = nil
    ) -> (MLXArray, QGemma4SharedKVState?, RoPEOffset?) {
        let (batch, length, _) = (x.dim(0), x.dim(1), x.dim(2))

        var queries = qProj(x).reshaped(batch, length, numHeads, headDim)
        queries = qNorm(queries)

        let positions: RoPEOffset?
        let kvState: QGemma4SharedKVState
        if let sharedKV {
            positions = offset
            kvState = sharedKV
        } else {
            guard let kProj, let kNorm, let vNorm else {
                fatalError("Gemma4 attention called without sharedKV on a layer without its own keys")
            }
            // Each sequence's own position: its token count, not the batch's padded width.
            positions = cache?.ropeOffset
            var keys = kProj(x).reshaped(batch, length, numKVHeads, headDim)
            var values = useKEqV ? keys : vProj!(x).reshaped(batch, length, numKVHeads, headDim)
            keys = kNorm(keys).transposed(0, 2, 1, 3)
            values = vNorm(values).transposed(0, 2, 1, 3)
            keys = applyRotaryPosition(rope, to: keys, offset: positions)
            if let quantizedCache = cache as? QuantizedKVCacheProtocol {
                let (quantizedKeys, quantizedValues) = quantizedCache.updateQuantized(keys: keys, values: values)
                kvState = .quantized(
                    keys: quantizedKeys, values: quantizedValues, groupSize: quantizedCache.groupSize,
                    bits: quantizedCache.bits, mode: quantizedCache.mode
                )
            } else {
                if let cache {
                    (keys, values) = cache.update(keys: keys, values: values)
                }
                kvState = .regular(keys: keys, values: values)
            }
        }

        queries = queries.transposed(0, 2, 1, 3)
        queries = applyRotaryPosition(rope, to: queries, offset: positions)

        let localMask = qGemma4AdjustAttentionMask(mask, keyLength: kvState.sequenceLength)
        let output: MLXArray = switch kvState {
        case let .regular(keys, values):
            MLXFast.scaledDotProductAttention(
                queries: queries, keys: keys, values: values, scale: scale, mask: localMask
            )
        case let .quantized(keys, values, groupSize, bits, mode):
            quantizedScaledDotProductAttention(
                queries: queries, quantizedKeys: keys, quantizedValues: values, scale: scale, mask: localMask,
                groupSize: groupSize, bits: bits, mode: mode
            )
        }
        return (oProj(output.transposed(0, 2, 1, 3).reshaped(batch, length, -1)), kvState, positions)
    }
}

final class QGemma4DecoderLayer: Module {
    let layerType: String
    let enableMoE: Bool

    @ModuleInfo(key: "self_attn") var selfAttention: QGemma4Attention
    @ModuleInfo var mlp: QGemma4MLP
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: QGemma4RMSNormZeroShift
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: QGemma4RMSNormZeroShift
    @ModuleInfo(key: "pre_feedforward_layernorm") var preFeedforwardLayerNorm: QGemma4RMSNormZeroShift
    @ModuleInfo(key: "post_feedforward_layernorm") var postFeedforwardLayerNorm: QGemma4RMSNormZeroShift
    @ModuleInfo(key: "router") var router: QGemma4Router?
    @ModuleInfo(key: "experts") var experts: QGemma4Experts?
    @ModuleInfo(key: "post_feedforward_layernorm_1") var postFeedforwardLayerNorm1: QGemma4RMSNormZeroShift?
    @ModuleInfo(key: "post_feedforward_layernorm_2") var postFeedforwardLayerNorm2: QGemma4RMSNormZeroShift?
    @ModuleInfo(key: "pre_feedforward_layernorm_2") var preFeedforwardLayerNorm2: QGemma4RMSNormZeroShift?
    @ModuleInfo(key: "per_layer_input_gate") var perLayerInputGate: Linear?
    @ModuleInfo(key: "per_layer_projection") var perLayerProjection: Linear?
    @ModuleInfo(key: "post_per_layer_input_norm") var postPerLayerInputNorm: QGemma4RMSNormZeroShift?
    @ModuleInfo(key: "layer_scalar") var layerScalar: MLXArray

    init(config: MLXVLM.Gemma4TextConfiguration, layerIdx: Int) {
        layerType = config.layerTypes[layerIdx]
        enableMoE = config.enableMoEBlock
        _selfAttention.wrappedValue = QGemma4Attention(config: config, layerIdx: layerIdx)
        _mlp.wrappedValue = QGemma4MLP(config: config, layerIdx: layerIdx)
        let norm = { QGemma4RMSNormZeroShift(dimensions: config.hiddenSize, eps: config.rmsNormEps) }
        _inputLayerNorm.wrappedValue = norm()
        _postAttentionLayerNorm.wrappedValue = norm()
        _preFeedforwardLayerNorm.wrappedValue = norm()
        _postFeedforwardLayerNorm.wrappedValue = norm()
        if config.enableMoEBlock {
            _router.wrappedValue = QGemma4Router(config: config)
            _experts.wrappedValue = QGemma4Experts(config: config)
            _postFeedforwardLayerNorm1.wrappedValue = norm()
            _postFeedforwardLayerNorm2.wrappedValue = norm()
            _preFeedforwardLayerNorm2.wrappedValue = norm()
        }
        if config.hiddenSizePerLayerInput > 0 {
            _perLayerInputGate.wrappedValue = Linear(config.hiddenSize, config.hiddenSizePerLayerInput, bias: false)
            _perLayerProjection.wrappedValue = Linear(config.hiddenSizePerLayerInput, config.hiddenSize, bias: false)
            _postPerLayerInputNorm.wrappedValue = norm()
        }
        _layerScalar.wrappedValue = MLXArray.ones([1])
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode = .none, cache: KVCache? = nil,
        perLayerInput: MLXArray? = nil, sharedKV: QGemma4SharedKVState? = nil, offset: RoPEOffset? = nil
    ) -> (MLXArray, QGemma4SharedKVState?, RoPEOffset?) {
        var residual = x
        var h = inputLayerNorm(x)
        let (attentionOutput, kvState, positions) = selfAttention(
            h, mask: mask, cache: cache, sharedKV: sharedKV, offset: offset
        )
        h = postAttentionLayerNorm(attentionOutput)
        h = residual + h

        residual = h
        if enableMoE, let router, let experts, let postFeedforwardLayerNorm1, let postFeedforwardLayerNorm2,
           let preFeedforwardLayerNorm2
        {
            var dense = preFeedforwardLayerNorm(h)
            dense = mlp(dense)
            dense = postFeedforwardLayerNorm1(dense)

            let (topKIndices, topKWeights) = router(h)
            var sparse = preFeedforwardLayerNorm2(h)
            sparse = experts(sparse, topKIndices: topKIndices, topKWeights: topKWeights)
            sparse = postFeedforwardLayerNorm2(sparse)
            h = dense + sparse
        } else {
            h = preFeedforwardLayerNorm(h)
            h = mlp(h)
        }
        h = postFeedforwardLayerNorm(h)
        h = residual + h

        if let perLayerInputGate, let perLayerProjection, let postPerLayerInputNorm, let perLayerInput {
            residual = h
            var gated = geluApproximate(perLayerInputGate(h))
            gated = gated * perLayerInput
            gated = postPerLayerInputNorm(perLayerProjection(gated))
            h = residual + gated
        }
        return (h * layerScalar, kvState, positions)
    }
}

final class QGemma4Backbone: Module {
    let config: MLXVLM.Gemma4TextConfiguration
    let firstKVSharedLayerIdx: Int
    let layerIdxToCacheIdx: [Int]
    let firstFullCacheIdx: Int
    let firstSlidingCacheIdx: Int
    let embedScale: Float
    let embedTokensPerLayerScale: Float
    let perLayerProjectionScale: Float
    /// Underscored so MLX's module reflection doesn't take it for a weight.
    private let _perLayerInputScale: MLXArray

    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "layers") var layers: [QGemma4DecoderLayer]
    @ModuleInfo(key: "norm") var norm: QGemma4RMSNormZeroShift
    @ModuleInfo(key: "embed_tokens_per_layer") var embedTokensPerLayer: Embedding?
    @ModuleInfo(key: "per_layer_model_projection") var perLayerModelProjection: Linear?
    @ModuleInfo(key: "per_layer_projection_norm") var perLayerProjectionNorm: QGemma4RMSNormZeroShift?

    init(_ config: MLXVLM.Gemma4TextConfiguration) {
        self.config = config
        firstKVSharedLayerIdx = config.hiddenLayers - config.numKVSharedLayers
        embedScale = pow(Float(config.hiddenSize), 0.5)
        embedTokensPerLayerScale = pow(Float(max(config.hiddenSizePerLayerInput, 1)), 0.5)
        _perLayerInputScale = rsqrt(MLXArray(2.0))

        let concreteLayers = Array(config.layerTypes.prefix(firstKVSharedLayerIdx))
        let sharedFullIdx = concreteLayers.lastIndex(of: "full_attention") ?? 0
        let sharedSlidingIdx = concreteLayers.lastIndex(of: "sliding_attention") ?? 0
        layerIdxToCacheIdx = config.layerTypes.enumerated().map { idx, layerType in
            idx < config.hiddenLayers - config.numKVSharedLayers
                ? idx : (layerType == "full_attention" ? sharedFullIdx : sharedSlidingIdx)
        }
        firstFullCacheIdx = concreteLayers.firstIndex(of: "full_attention") ?? 0
        firstSlidingCacheIdx = concreteLayers.firstIndex(of: "sliding_attention") ?? 0

        _embedTokens.wrappedValue = Embedding(embeddingCount: config.vocabularySize, dimensions: config.hiddenSize)
        _layers.wrappedValue = (0 ..< config.hiddenLayers).map { QGemma4DecoderLayer(config: config, layerIdx: $0) }
        _norm.wrappedValue = QGemma4RMSNormZeroShift(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        if config.hiddenSizePerLayerInput > 0 {
            perLayerProjectionScale = pow(Float(config.hiddenSize), -0.5)
            _embedTokensPerLayer.wrappedValue = Embedding(
                embeddingCount: config.vocabularySizePerLayerInput,
                dimensions: config.hiddenLayers * config.hiddenSizePerLayerInput
            )
            _perLayerModelProjection.wrappedValue = Linear(
                config.hiddenSize, config.hiddenLayers * config.hiddenSizePerLayerInput, bias: false
            )
            _perLayerProjectionNorm.wrappedValue = QGemma4RMSNormZeroShift(
                dimensions: config.hiddenSizePerLayerInput, eps: config.rmsNormEps
            )
        } else {
            perLayerProjectionScale = 1.0
        }
        super.init()
    }

    private func perLayerInputs(_ inputIds: MLXArray) -> MLXArray {
        guard let embedTokensPerLayer else {
            fatalError("Per-layer inputs requested for a model without embed_tokens_per_layer")
        }
        let valid = logicalAnd(inputIds .>= 0, inputIds .< config.vocabularySizePerLayerInput)
        let tokens = MLX.where(valid, inputIds, MLXArray.zeros(like: inputIds))
        var result = embedTokensPerLayer(tokens)
        result = (result * MLXArray(embedTokensPerLayerScale, dtype: .float32)).asType(result.dtype)
        return result.reshaped(Array(inputIds.shape) + [config.hiddenLayers, config.hiddenSizePerLayerInput])
    }

    private func projectPerLayerInputs(_ inputsEmbeds: MLXArray, perLayerInputs: MLXArray?) -> MLXArray? {
        guard let perLayerModelProjection, let perLayerProjectionNorm else { return nil }
        var projection = perLayerModelProjection(inputsEmbeds) * perLayerProjectionScale
        projection = projection.reshaped(
            Array(inputsEmbeds.shape.dropLast()) + [config.hiddenLayers, config.hiddenSizePerLayerInput]
        )
        projection = perLayerProjectionNorm(projection)
        guard let perLayerInputs else { return projection }
        return (projection + perLayerInputs) * _perLayerInputScale.asType(inputsEmbeds.dtype)
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache?]? = nil) -> MLXArray {
        let inputs = inputs.ndim == 1 ? inputs.expandedDimensions(axis: 0) : inputs
        let embeddings = embedTokens(inputs)
        let h0 = (embeddings * MLXArray(embedScale, dtype: .float32)).asType(embeddings.dtype)
        let finalPerLayerInputs = config.hiddenSizePerLayerInput > 0
            ? projectPerLayerInputs(h0, perLayerInputs: perLayerInputs(inputs)) : nil

        let localCache = cache ?? Array(repeating: nil as KVCache?, count: max(firstKVSharedLayerIdx, 1))
        let fullMask = createAttentionMask(
            h: h0, cache: firstFullCacheIdx < localCache.count ? localCache[firstFullCacheIdx] : nil
        )
        let slidingMask = createAttentionMask(
            h: h0, cache: firstSlidingCacheIdx < localCache.count ? localCache[firstSlidingCacheIdx] : nil,
            windowSize: config.slidingWindow
        )

        var h = h0
        var intermediates = [(kv: QGemma4SharedKVState?, offset: RoPEOffset?)](
            repeating: (nil, nil), count: config.hiddenLayers
        )
        for (idx, layer) in layers.enumerated() {
            let sourceIdx = layerIdxToCacheIdx[idx]
            let layerCache: KVCache? = idx < firstKVSharedLayerIdx && sourceIdx < localCache.count
                ? localCache[sourceIdx] : nil
            let shared = idx >= firstKVSharedLayerIdx
            let (output, kvState, positions) = layer(
                h,
                mask: layer.layerType == "full_attention" ? fullMask : slidingMask,
                cache: layerCache,
                perLayerInput: finalPerLayerInputs.map { $0[0..., 0..., idx, 0...] },
                sharedKV: shared ? intermediates[sourceIdx].kv : nil,
                offset: shared ? intermediates[sourceIdx].offset : nil
            )
            h = output
            intermediates[idx] = (kvState, positions)
        }
        return norm(h)
    }
}

final class QGemma4LanguageModel: Module, KVCacheDimensionProvider {
    let config: MLXVLM.Gemma4TextConfiguration
    let finalLogitSoftcapping: Float?

    @ModuleInfo(key: "model") var model: QGemma4Backbone
    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    var kvHeads: [Int] {
        (0 ..< config.hiddenLayers).map { idx in
            config.attentionKEqV && config.layerTypes[idx] == "full_attention"
                ? config.globalKVHeads ?? config.kvHeads : config.kvHeads
        }
    }

    init(_ config: MLXVLM.Gemma4TextConfiguration) {
        self.config = config
        finalLogitSoftcapping = config.finalLogitSoftcapping
        _model.wrappedValue = QGemma4Backbone(config)
        if !config.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(config.hiddenSize, config.vocabularySize, bias: false)
        }
        super.init()
    }

    func newCache(parameters _: GenerateParameters?) -> [any KVCache] {
        let slidingWindow = config.slidingWindow > 0 ? config.slidingWindow : 4096
        return config.layerTypes.prefix(config.hiddenLayers - config.numKVSharedLayers).map { layerType in
            layerType == "full_attention" ? StandardKVCache() : RotatingKVCache(maxSize: slidingWindow, keep: 0)
        }
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]? = nil) -> LMOutput {
        let hidden = model(inputs, cache: cache?.map { $0 as KVCache? })
        let logits = lmHead.map { $0(hidden) } ?? model.embedTokens.asLinear(hidden)
        guard let finalLogitSoftcapping, finalLogitSoftcapping > 0 else { return LMOutput(logits: logits) }
        let scale = MLXArray(finalLogitSoftcapping)
        return LMOutput(logits: tanh(logits / scale) * scale)
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        let firstKVSharedLayer = config.hiddenLayers - config.numKVSharedLayers
        var sanitized: [String: MLXArray] = [:]
        sanitized.reserveCapacity(weights.count + 1)

        for (key, value) in weights {
            if key.contains("rotary_emb") {
                continue
            }
            // KV-shared layers reuse an earlier layer's keys and values and own no K projection or K norm; some
            // checkpoints still ship them.
            if firstKVSharedLayer > 0, !key.contains("vision_tower"), !key.contains("audio_tower"),
               key.contains("self_attn.k_proj") || key.contains("self_attn.v_proj")
               || key.contains("self_attn.k_norm"),
               let layerIdx = Self.decoderLayerIndex(in: key), layerIdx >= firstKVSharedLayer
            {
                continue
            }

            var newKey = key
            if newKey.hasPrefix("model.") {
                newKey.removeFirst("model.".count)
            }
            if newKey.hasPrefix("language_model."), !newKey.hasPrefix("language_model.model."),
               !newKey.hasPrefix("language_model.lm_head.")
            {
                newKey = "language_model.model." + newKey.dropFirst("language_model.".count)
            }
            if newKey.hasSuffix(".experts.down_proj") {
                newKey = newKey.replacingOccurrences(
                    of: ".experts.down_proj", with: ".experts.switch_glu.down_proj.weight"
                )
            }
            if newKey.hasSuffix(".experts.gate_up_proj") {
                let mid = value.dim(-2) / 2
                sanitized[newKey.replacingOccurrences(
                    of: ".experts.gate_up_proj", with: ".experts.switch_glu.gate_proj.weight"
                )] = value[.ellipsis, ..<mid, 0...]
                sanitized[newKey.replacingOccurrences(
                    of: ".experts.gate_up_proj", with: ".experts.switch_glu.up_proj.weight"
                )] = value[.ellipsis, mid..., 0...]
                continue
            }
            sanitized[newKey] = value
        }

        if config.tieWordEmbeddings {
            sanitized = sanitized.filter { key, _ in !key.hasPrefix("language_model.lm_head.") }
        } else if sanitized["language_model.lm_head.weight"] == nil,
                  let embedWeight = sanitized["language_model.model.embed_tokens.weight"]
        {
            sanitized["language_model.lm_head.weight"] = embedWeight
        }
        return sanitized
    }

    private static func decoderLayerIndex(in key: String) -> Int? {
        guard let range = key.range(of: "layers.") else { return nil }
        return Int(key[range.upperBound...].prefix { $0.isNumber })
    }
}
