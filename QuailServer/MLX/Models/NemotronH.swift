// Adapted from mlx-swift-lm 0dcfe2f8a, Libraries/MLXLLM/Models/NemotronH.swift (MIT; Copyright (c) 2024 ml-explore),
// itself a port of mlx-lm's nemotron_h. Quail's own copy (ADR D-066): Nemotron-H (Nemotron 3 Nano, Nemotron 3.5
// Lightning), registered in place of mlx-swift-lm's with the config adapter in `MLXConfigAdapters.nemotronH`.
//
// Changes from the source:
// - The gated norm's identity weight is in the activations' type. The source makes it float32, which makes the norm's
//   output float32 and, through each Mamba layer's output projection, the residual stream: twice the bytes, and
//   replies that differ from mlx-lm's. Nemotron 3.5 Lightning 30B-A3B (mlx-community 4-bit, release build, M4 Pro)
//   went from 56 to 76 tokens a second, and its greedy replies now match mlx-lm 0.31.3's (89 there).
// - Types are prefixed `Q` so they don't meet mlx-swift-lm's own; the configuration is the library's, which is public.
// - `filterLMHeadWeights` is package access in MLXLMCommon, so its two lines are here.
//
// Checked against mlx-swift-lm 3.32.3, the release pinned (2026-09-30): its only changes since 0dcfe2f8a are
// mlx-swift 0.32.3 and tests, so nothing here changes.
//
// When mlx-swift-lm's pin moves, `MLXModelCopiesTests` fails until the source file has been compared with this one at
// the new pin and this header names it.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

// MARK: - Block Type

private enum QNemotronHBlockType {
    case mamba // "M"
    case attention // "*"
    case mlp // "-"
    case moe // "E"

    init(from char: Character) {
        switch char {
        case "M": self = .mamba
        case "*": self = .attention
        case "-": self = .mlp
        case "E": self = .moe
        default: fatalError("Unknown NemotronH block type: \(char)")
        }
    }
}

// MARK: - Mixer Protocol

/// Protocol for all mixer types in NemotronH blocks
private protocol QNemotronHMixer: Module {
    func callAsFunction(
        _ x: MLXArray,
        attentionMask: MLXFast.ScaledDotProductAttentionMaskMode,
        ssmMask: MLXArray?,
        cache: KVCache?
    ) -> MLXArray
}

// MARK: - Activations

/// Squared ReLU activation: relu(x)^2
private func qRelu2(_ x: MLXArray) -> MLXArray {
    let y = MLX.maximum(x, MLXArray(0))
    return y * y
}

// MARK: - MambaRMSNormGated

private class QNemotronHRMSNormGated: Module {
    @ParameterInfo(key: "weight") var weight: MLXArray
    let eps: Float
    let groupSize: Int

    init(dimensions: Int, eps: Float, groupSize: Int) {
        self.eps = eps
        self.groupSize = groupSize
        _weight.wrappedValue = MLXArray.ones([dimensions])
        super.init()
    }

    func callAsFunction(_ x: MLXArray, gate: MLXArray?) -> MLXArray {
        var states = x
        if let gate {
            states = states * silu(gate)
        }

        // Python: x = mx.unflatten(x, axis=-1, shape=(-1, self.group_size))
        // Reshape [..., hidden] -> [..., nGroups, groupSize] for per-group normalization
        let shape = states.shape
        var newShape = Array(shape.dropLast())
        newShape.append(-1)
        newShape.append(groupSize)
        let unflattened = states.reshaped(newShape)

        // Python: x = mx.fast.rms_norm(x, weight=None, eps=self.eps)
        // Apply RMS norm per group WITHOUT scaling (pass ones as weight)
        // Swift rmsNorm doesn't accept nil, so we use identity weight, in the activations' type: a float32 one (the
        // source's) makes the norm's output float32, and with it every layer after (Quail's change).
        let identityWeight = MLXArray.ones([groupSize], dtype: unflattened.dtype)
        let normed = MLXFast.rmsNorm(unflattened, weight: identityWeight, eps: eps)

        // Python: return self.weight * x.flatten(-2)
        // Flatten back to [..., hidden] and apply learned weight
        let flattened = normed.reshaped(shape)
        return weight * flattened
    }
}

// MARK: - Mamba2Mixer

private class QNemotronHMamba2Mixer: Module, QNemotronHMixer {
    let numHeads: Int
    let hiddenSize: Int
    let ssmStateSize: Int
    let convKernelSize: Int
    let intermediateSize: Int
    let numGroups: Int
    let headDim: Int
    let timeStepLimit: (Float, Float)
    let headsPerGroup: Int

    let convDim: Int

    @ModuleInfo(key: "conv1d") var conv1d: Conv1d
    @ModuleInfo(key: "in_proj") var inProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    @ParameterInfo(key: "dt_bias") var dtBias: MLXArray
    @ParameterInfo(key: "A_log") var aLog: MLXArray
    @ParameterInfo(key: "D") var D: MLXArray

    @ModuleInfo(key: "norm") var norm: QNemotronHRMSNormGated

    init(_ args: NemotronHConfiguration) {
        numHeads = args.mambaNumHeads
        hiddenSize = args.hiddenSize
        ssmStateSize = args.ssmStateSize
        convKernelSize = args.convKernel
        intermediateSize = args.mambaNumHeads * args.mambaHeadDim
        numGroups = args.nGroups
        headDim = args.mambaHeadDim
        timeStepLimit = (args.timeStepLimitMin, args.timeStepLimitMax)
        headsPerGroup = numHeads / numGroups
        convDim = intermediateSize + 2 * numGroups * ssmStateSize

        _conv1d.wrappedValue = Conv1d(
            inputChannels: convDim,
            outputChannels: convDim,
            kernelSize: convKernelSize,
            groups: convDim,
            bias: args.useConvBias
        )

        let projectionSize = intermediateSize + convDim + numHeads
        _inProj.wrappedValue = Linear(hiddenSize, projectionSize, bias: args.mambaProjBias)

        _dtBias.wrappedValue = MLXArray.ones([numHeads])
        let headsRange = (MLXArray(0 ..< numHeads).asType(.float32) + 1)
        _aLog.wrappedValue = MLX.log(headsRange)
        _D.wrappedValue = MLXArray.ones([numHeads])

        let groupSize = intermediateSize / numGroups
        _norm.wrappedValue = QNemotronHRMSNormGated(
            dimensions: intermediateSize,
            eps: args.layerNormEpsilon,
            groupSize: groupSize
        )

        _outProj.wrappedValue = Linear(intermediateSize, hiddenSize, bias: args.mambaProjBias)

        super.init()
    }

    private func applyConv(_ input: MLXArray, mask: MLXArray?, cache: MambaCache?) -> MLXArray {
        var convInput = input

        // Apply mask if present
        if let mask {
            let expandedMask = expandedDimensions(mask, axis: -1)
            convInput = MLX.where(expandedMask, convInput, MLXArray.zeros(like: convInput))
        }

        let batch = convInput.dim(0)
        let dtype = convInput.dtype
        var convState = cache?[0]

        if convState == nil {
            if convKernelSize > 1 {
                convState = MLXArray.zeros([batch, convKernelSize - 1, convDim], dtype: dtype)
            } else {
                convState = MLXArray.zeros([batch, 0, convDim], dtype: dtype)
            }
        }

        let padded = concatenated([convState!, convInput], axis: 1)

        if let cache {
            let end = padded.dim(1)
            let start = max(0, end - (convKernelSize - 1))
            cache[0] = contiguous(padded[0..., start ..< end, 0...])
        }

        let convOutput = conv1d(padded)
        return silu(convOutput)
    }

    private func mambaForward(
        _ hiddenStates: MLXArray,
        mask: MLXArray?,
        cache: MambaCache?
    ) -> MLXArray {
        let projected = inProj(hiddenStates)
        let splits = split(
            projected, indices: [intermediateSize, intermediateSize + convDim], axis: -1
        )
        let gate = splits[0]
        let convInput = splits[1]
        let dt = splits[2]

        let convOutput = applyConv(convInput, mask: mask, cache: cache)
        let convSplits = split(
            convOutput,
            indices: [intermediateSize, intermediateSize + numGroups * ssmStateSize],
            axis: -1
        )

        var hidden = convSplits[0]
        var B = convSplits[1]
        var C = convSplits[2]

        hidden = hidden.reshaped([hidden.dim(0), hidden.dim(1), numHeads, headDim])
        B = B.reshaped([B.dim(0), B.dim(1), numGroups, ssmStateSize])
        C = C.reshaped([C.dim(0), C.dim(1), numGroups, ssmStateSize])

        let dtArray = dt.reshaped([dt.dim(0), dt.dim(1), numHeads])

        let previousState = cache?[1]
        let (y, nextState) = ssmUpdate(
            hiddenStates: hidden,
            ALog: aLog,
            B: B,
            C: C,
            D: D,
            dt: dtArray,
            dtBias: dtBias,
            state: previousState,
            timeStepLimit: timeStepLimit,
            mask: mask
        )

        if let cache {
            cache[1] = nextState
            cache.advance(hiddenStates.dim(1))
        }

        let flattenedY = y.flattened(start: 2)
        return outProj(norm(flattenedY, gate: gate))
    }

    /// Protocol conformance
    func callAsFunction(
        _ x: MLXArray,
        attentionMask _: MLXFast.ScaledDotProductAttentionMaskMode,
        ssmMask: MLXArray?,
        cache: KVCache?
    ) -> MLXArray {
        mambaForward(x, mask: ssmMask, cache: cache as? MambaCache)
    }
}

// MARK: - Attention

private class QNemotronHAttention: Module, QNemotronHMixer {
    let args: NemotronHConfiguration
    let scale: Float
    let numHeads: Int
    let numKeyValueHeads: Int
    let headDim: Int

    @ModuleInfo(key: "q_proj") var wq: Linear
    @ModuleInfo(key: "k_proj") var wk: Linear
    @ModuleInfo(key: "v_proj") var wv: Linear
    @ModuleInfo(key: "o_proj") var wo: Linear

    // NOTE: NemotronH attention does NOT use RoPE (unlike most transformer models)
    // The Python implementation at mlx_lm/models/nemotron_h.py lines 247-274 shows
    // direct attention without position embeddings

    init(_ args: NemotronHConfiguration) {
        self.args = args
        numHeads = args.numAttentionHeads
        numKeyValueHeads = args.numKeyValueHeads
        headDim = args.headDim ?? (args.hiddenSize / args.numAttentionHeads)
        scale = pow(Float(headDim), -0.5)

        let dim = args.hiddenSize
        let attentionBias = args.attentionBias

        _wq.wrappedValue = Linear(dim, numHeads * headDim, bias: attentionBias)
        _wk.wrappedValue = Linear(dim, numKeyValueHeads * headDim, bias: attentionBias)
        _wv.wrappedValue = Linear(dim, numKeyValueHeads * headDim, bias: attentionBias)
        _wo.wrappedValue = Linear(numHeads * headDim, dim, bias: attentionBias)

        super.init()
    }

    private func attentionForward(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cache: KVCache?
    ) -> MLXArray {
        let B = x.dim(0)
        let L = x.dim(1)

        let queries = wq(x).reshaped(B, L, numHeads, headDim).transposed(0, 2, 1, 3)
        let keys = wk(x).reshaped(B, L, numKeyValueHeads, headDim).transposed(0, 2, 1, 3)
        let values = wv(x).reshaped(B, L, numKeyValueHeads, headDim).transposed(0, 2, 1, 3)

        // No RoPE applied - NemotronH attention uses direct attention without position embeddings

        let output = attentionWithCacheUpdate(
            queries: queries,
            keys: keys,
            values: values,
            cache: cache,
            scale: scale,
            mask: mask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(B, L, -1)

        return wo(output)
    }

    /// Protocol conformance
    func callAsFunction(
        _ x: MLXArray,
        attentionMask: MLXFast.ScaledDotProductAttentionMaskMode,
        ssmMask _: MLXArray?,
        cache: KVCache?
    ) -> MLXArray {
        attentionForward(x, mask: attentionMask, cache: cache)
    }
}

// MARK: - MLP

private class QNemotronHMLP: Module, UnaryLayer, QNemotronHMixer {
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(_ args: NemotronHConfiguration, intermediateSize: Int? = nil) {
        let intermediate = intermediateSize ?? args.intermediateSize
        _upProj.wrappedValue = Linear(args.hiddenSize, intermediate, bias: args.mlpBias)
        _downProj.wrappedValue = Linear(intermediate, args.hiddenSize, bias: args.mlpBias)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(qRelu2(upProj(x)))
    }

    /// Protocol conformance
    func callAsFunction(
        _ x: MLXArray,
        attentionMask _: MLXFast.ScaledDotProductAttentionMaskMode,
        ssmMask _: MLXArray?,
        cache _: KVCache?
    ) -> MLXArray {
        callAsFunction(x)
    }
}

// MARK: - MoE Gate

private func qGroupExpertSelect(
    gates: MLXArray,
    eSCB: MLXArray, // e_score_correction_bias
    topK: Int,
    nGroup: Int,
    topkGroup: Int,
    routedScalingFactor: Float,
    normTopkProb: Bool
) -> (MLXArray, MLXArray) {
    let (bsz, seqLen) = (gates.dim(0), gates.dim(1))

    // Original scores using sigmoid
    let origScores = sigmoid(gates.asType(.float32))
    var scores = origScores + eSCB

    // Group-based selection if n_group > 1
    if nGroup > 1 {
        let numExperts = scores.dim(-1)
        let expertsPerGroup = numExperts / nGroup

        // Reshape to [batch, seq, n_group, experts_per_group]
        let groupScores = scores.reshaped(bsz, seqLen, nGroup, -1)

        // Get top-2 per group and sum for group scores (using sorted to get top values)
        let topKGroupScores = sorted(groupScores, axis: -1)[.ellipsis, ..<2].sum(
            axis: -1, keepDims: true
        )

        // Keep only top topkGroup groups (zero out the rest)
        let k = nGroup - topkGroup
        var groupIdx = argPartition(topKGroupScores, kth: k - 1, axis: -2)[.ellipsis, ..<k, 0...]
        groupIdx = broadcast(groupIdx, to: [bsz, seqLen, k, expertsPerGroup])

        // Zero out scores from non-selected groups
        scores = putAlong(groupScores, groupIdx, values: MLXArray(0.0), axis: -2)

        // Flatten back
        scores = flattened(scores, start: -2, end: -1)
    }

    // Get top-k experts
    let inds = argPartition(-scores, kth: topK - 1, axis: -1)[.ellipsis, ..<topK]
    var finalScores = takeAlong(origScores, inds, axis: -1)

    // Normalize if needed
    if topK > 1, normTopkProb {
        let denominator = finalScores.sum(axis: -1, keepDims: true) + 1e-20
        finalScores = finalScores / denominator
    }

    // Apply scaling factor
    finalScores = finalScores * routedScalingFactor

    return (inds, finalScores)
}

private class QNemotronHMoEGate: Module {
    let topK: Int
    let nGroup: Int
    let topkGroup: Int
    let routedScalingFactor: Float
    let normTopkProb: Bool

    @ParameterInfo(key: "weight") var weight: MLXArray
    @ParameterInfo(key: "e_score_correction_bias") var eSCB: MLXArray

    init(_ args: NemotronHConfiguration) {
        topK = args.numExpertsPerTok
        nGroup = args.nGroup
        topkGroup = args.topkGroup
        routedScalingFactor = args.routedScalingFactor
        normTopkProb = args.normTopkProb

        _weight.wrappedValue = MLXArray.zeros([args.nRoutedExperts, args.hiddenSize])
        _eSCB.wrappedValue = MLXArray.zeros([args.nRoutedExperts])

        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> (MLXArray, MLXArray) {
        let gates = MLX.matmul(x, weight.transposed())
        return qGroupExpertSelect(
            gates: gates,
            eSCB: eSCB,
            topK: topK,
            nGroup: nGroup,
            topkGroup: topkGroup,
            routedScalingFactor: routedScalingFactor,
            normTopkProb: normTopkProb
        )
    }
}

// MARK: - SwitchMLP for NemotronH (uses qRelu2 instead of silu/glu)

private class QNemotronHSwitchMLP: Module {
    @ModuleInfo(key: "fc1") var fc1: SwitchLinear
    @ModuleInfo(key: "fc2") var fc2: SwitchLinear

    let inputDims: Int
    let hiddenDims: Int
    let numExperts: Int

    init(inputDims: Int, hiddenDims: Int, numExperts: Int) {
        self.inputDims = inputDims
        self.hiddenDims = hiddenDims
        self.numExperts = numExperts

        _fc1.wrappedValue = SwitchLinear(
            inputDims: inputDims, outputDims: hiddenDims, numExperts: numExperts, bias: false
        )
        _fc2.wrappedValue = SwitchLinear(
            inputDims: hiddenDims, outputDims: inputDims, numExperts: numExperts, bias: false
        )

        super.init()
    }

    func callAsFunction(_ x: MLXArray, _ indices: MLXArray) -> MLXArray {
        var x = MLX.expandedDimensions(x, axes: [-2, -3])

        let doSort = indices.size > 64

        var idx = indices
        var inverseOrder = MLXArray()

        if doSort {
            (x, idx, inverseOrder) = gatherSort(x: x, indices: indices)
        }

        var y = fc1(x, idx, sortedIndices: doSort)
        y = qRelu2(y)
        y = fc2(y, idx, sortedIndices: doSort)

        if doSort {
            y = scatterUnsort(x: y, invOrder: inverseOrder, shape: indices.shape)
        }

        return MLX.squeezed(y, axis: -2)
    }
}

// MARK: - MoE

private class QNemotronHMoE: Module, UnaryLayer, QNemotronHMixer {
    let numExpertsPerTok: Int
    let hasSharedExperts: Bool

    @ModuleInfo(key: "gate") var gate: QNemotronHMoEGate
    @ModuleInfo(key: "switch_mlp") var switchMLP: QNemotronHSwitchMLP
    @ModuleInfo(key: "shared_experts") var sharedExperts: QNemotronHMLP?

    init(_ args: NemotronHConfiguration) {
        numExpertsPerTok = args.numExpertsPerTok
        hasSharedExperts = args.nSharedExperts != nil && args.nSharedExperts! > 0

        _gate.wrappedValue = QNemotronHMoEGate(args)
        _switchMLP.wrappedValue = QNemotronHSwitchMLP(
            inputDims: args.hiddenSize,
            hiddenDims: args.moeIntermediateSize,
            numExperts: args.nRoutedExperts
        )

        if hasSharedExperts {
            _sharedExperts.wrappedValue = QNemotronHMLP(
                args,
                intermediateSize: args.moeSharedExpertIntermediateSize
            )
        }

        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let (inds, scores) = gate(x)
        var y = switchMLP(x, inds)
        y = weightedExpertSum(y, scores).asType(y.dtype)

        if let sharedExperts {
            y = y + sharedExperts(x)
        }

        return y
    }

    /// Protocol conformance
    func callAsFunction(
        _ x: MLXArray,
        attentionMask _: MLXFast.ScaledDotProductAttentionMaskMode,
        ssmMask _: MLXArray?,
        cache _: KVCache?
    ) -> MLXArray {
        callAsFunction(x)
    }
}

// MARK: - Decoder Block

private class QNemotronHBlock: Module {
    let blockType: QNemotronHBlockType

    @ModuleInfo(key: "norm") var norm: RMSNorm

    /// Single mixer property with base Module type - concrete type assigned at init
    /// This pattern is used by Jamba for feedForward: Module
    @ModuleInfo(key: "mixer") var mixer: Module

    init(_ args: NemotronHConfiguration, blockType: Character) {
        self.blockType = QNemotronHBlockType(from: blockType)

        _norm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.layerNormEpsilon)

        // Assign the appropriate concrete mixer type
        switch self.blockType {
        case .mamba:
            _mixer.wrappedValue = QNemotronHMamba2Mixer(args)
        case .attention:
            _mixer.wrappedValue = QNemotronHAttention(args)
        case .mlp:
            _mixer.wrappedValue = QNemotronHMLP(args)
        case .moe:
            _mixer.wrappedValue = QNemotronHMoE(args)
        }

        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        attentionMask: MLXFast.ScaledDotProductAttentionMaskMode,
        ssmMask: MLXArray?,
        cache: KVCache?
    ) -> MLXArray {
        let hidden = norm(x)

        // Cast to protocol and call - all mixer types conform to QNemotronHMixer
        let mixerFunc = mixer as! QNemotronHMixer
        let output = mixerFunc(hidden, attentionMask: attentionMask, ssmMask: ssmMask, cache: cache)

        return x + output
    }
}

// MARK: - Backbone (matches Python's QNemotronHModel which is stored as self.backbone)

private class QNemotronHBackbone: Module {
    let args: NemotronHConfiguration

    @ModuleInfo(key: "embeddings") var embeddings: Embedding
    @ModuleInfo(key: "layers") var layers: [QNemotronHBlock]
    @ModuleInfo(key: "norm_f") var normF: RMSNorm

    // Cache indices (into the cache list, not pattern indices)
    // Python: fa_idx counts Mamba layers before first Attention
    // Python: ssm_idx counts Attention layers before first Mamba
    let firstAttentionCacheIndex: Int?
    let firstMambaCacheIndex: Int?

    init(_ args: NemotronHConfiguration) {
        self.args = args
        precondition(args.vocabSize > 0)

        _embeddings.wrappedValue = Embedding(
            embeddingCount: args.vocabSize, dimensions: args.hiddenSize
        )

        let pattern = Array(args.hybridOverridePattern)
        _layers.wrappedValue = pattern.map { QNemotronHBlock(args, blockType: $0) }

        _normF.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.layerNormEpsilon)

        // Calculate cache indices (only Mamba + Attention have caches)
        // fa_idx: count Mamba layers (M) before the first Attention layer (*)
        var faIdx: Int? = nil
        var mambaCount = 0
        for char in pattern {
            if char == "*" {
                faIdx = mambaCount
                break
            } else if char == "M" {
                mambaCount += 1
            }
        }
        firstAttentionCacheIndex = faIdx

        // ssm_idx: count Attention layers (*) before the first Mamba layer (M)
        var ssmIdx: Int? = nil
        var attnCount = 0
        for char in pattern {
            if char == "M" {
                ssmIdx = attnCount
                break
            } else if char == "*" {
                attnCount += 1
            }
        }
        firstMambaCacheIndex = ssmIdx

        super.init()
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]? = nil) -> MLXArray {
        var hidden = embeddings(inputs)

        // Create attention mask using the first attention layer's cache
        let attentionMask: MLXFast.ScaledDotProductAttentionMaskMode = {
            guard let cacheIdx = firstAttentionCacheIndex,
                  let cache,
                  cacheIdx < cache.count
            else { return .none }
            return createAttentionMask(h: hidden, cache: cache[cacheIdx])
        }()

        // Create SSM mask using the first Mamba layer's cache
        // Python: ssm_mask = create_ssm_mask(hidden_states, cache[self.ssm_idx])
        let ssmMask: MLXArray? = {
            guard let cacheIdx = firstMambaCacheIndex,
                  let cache,
                  cacheIdx < cache.count,
                  let mambaCache = cache[cacheIdx] as? MambaCache
            else { return nil }
            return mambaCache.makeMask(N: hidden.dim(1))
        }()

        // Track which cache to use for each layer
        var cacheCounter = 0
        for layer in layers {
            let c: KVCache?
            if layer.blockType == .mamba || layer.blockType == .attention {
                c = cache?[cacheCounter]
                cacheCounter += 1
            } else {
                c = nil
            }

            hidden = layer(hidden, attentionMask: attentionMask, ssmMask: ssmMask, cache: c)
        }

        return normF(hidden)
    }
}

// MARK: - Main Model (matches Python's Model class)

final class QNemotronHModel: Module, LLMModel, KVCacheDimensionProvider, LoRAModel {
    let vocabularySize: Int
    let kvHeads: [Int]

    @ModuleInfo(key: "backbone") private var backbone: QNemotronHBackbone
    let configuration: NemotronHConfiguration

    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    var loraLayers: [Module] {
        backbone.layers
    }

    init(_ args: NemotronHConfiguration) {
        configuration = args
        vocabularySize = args.vocabSize

        // kvHeads array: non-zero for attention layers, zero for others
        let pattern = Array(args.hybridOverridePattern)
        kvHeads = pattern.compactMap { char -> Int? in
            let blockType = QNemotronHBlockType(from: char)
            if blockType == .mamba || blockType == .attention {
                return blockType == .attention ? args.numKeyValueHeads : 0
            }
            return nil
        }

        _backbone.wrappedValue = QNemotronHBackbone(args)

        if !args.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(args.hiddenSize, args.vocabSize, bias: false)
        }
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        var out = backbone(inputs, cache: cache)
        if let lmHead {
            out = lmHead(out)
        } else {
            out = backbone.embeddings.asLinear(out)
        }
        return out
    }

    func newCache(parameters: GenerateParameters?) throws -> [KVCache] {
        let pattern = Array(configuration.hybridOverridePattern)
        return try pattern.compactMap { char -> KVCache? in
            let blockType = QNemotronHBlockType(from: char)
            switch blockType {
            case .mamba:
                return MambaCache()
            case .attention:
                return try makeAttentionKVCache(parameters: parameters)
            case .mlp, .moe:
                return nil // No cache needed for MLP/MoE layers
            }
        }
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized = [String: MLXArray]()

        // mlx-swift-lm's `filterLMHeadWeights` (package access there): a tied head owns no tensors.
        let owned = configuration.tieWordEmbeddings
            ? weights.filter { key, _ in !key.split(separator: ".").contains("lm_head") } : weights
        for (key, value) in owned {
            var finalValue = value

            // Handle conv1d weight axis swap
            if key.contains("conv1d.weight"), value.dim(-1) != 1 {
                finalValue = value.swappedAxes(1, 2)
            }

            sanitized[key] = finalValue
        }

        // Stack experts: backbone.layers.{l}.mixer.experts.{e}.{proj}.weight ->
        // backbone.layers.{l}.mixer.switch_mlp.{proj}.weight
        for l in 0 ..< configuration.numHiddenLayers {
            let prefix = "backbone.layers.\(l).mixer"
            for (m, n) in [("down_proj", "fc2"), ("up_proj", "fc1")] {
                if sanitized["\(prefix).experts.0.\(m).weight"] != nil {
                    let toJoin = (0 ..< configuration.nRoutedExperts).compactMap { e in
                        sanitized.removeValue(forKey: "\(prefix).experts.\(e).\(m).weight")
                    }
                    if !toJoin.isEmpty {
                        sanitized["\(prefix).switch_mlp.\(n).weight"] = MLX.stacked(toJoin)
                    }
                }
            }
        }

        return sanitized
    }

    /// Predicate for casting: some parameters should stay in float32
    var castPredicate: ((String) -> Bool)? {
        { key in
            !key.contains("e_score_correction_bias") && !key.contains("A_log")
        }
    }
}
