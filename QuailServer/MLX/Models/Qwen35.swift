// Adapted from mlx-swift-lm 3.31.4, Libraries/MLXLLM/Models/Qwen35.swift and Qwen35MoE.swift, with the parts of
// Qwen3Next.swift and MLXLMCommon/GatedDelta.swift they use (MIT; Copyright (c) 2024 ml-explore), themselves ports of
// mlx-lm's qwen3_5 and gated_delta. Quail's own copy (ADR D-066, #141): Qwen3.5 and 3.6, dense and mixture of
// experts, registered in place of mlx-swift-lm's.
//
// Changes from the source, to close the gap to mlx-lm, oMLX and Rapid-MLX on the same weights:
// - The small element-wise functions mlx-lm compiles are compiled here too (`compile(shapeless:)`): the decay `g`,
//   the gated norm's SwiGLU, the MLPs' SwiGLU and the attention output gate, so each is one GPU kernel, not several.
// - `beta` stays in the activations' type, as in mlx-lm (mlx-swift-lm casts it to float32).
// - One request's next token goes through each GatedDeltaNet layer's convolution, norms, recurrence and gated norm as
//   one Metal kernel, adapted from Rapid-MLX (Apache-2.0; see "Fused single-token decode" below), where it gives the
//   separate kernels' bytes.
// - Types are prefixed `QQwen35` so they don't meet mlx-swift-lm's own; its configuration types are internal there,
//   so they are copied too.
//
// Compared with mlx-swift-lm 0dcfe2f8a, the commit pinned (main, 2026-09-29): its Qwen3.5 now fuses the four
// GatedDeltaNet input projections into one, compiles decode segments and fuses the router's top-k. On the Mac mini it
// took 10.99 ms a token on Qwen3.6 35B-A3B, against 11.22 ms for this copy and 10.79 ms with the fused GatedDeltaNet
// decode kernel (#148), so this copy stays.
//
// When mlx-swift-lm's pin moves, `MLXModelCopiesTests` fails until the source files have been compared with this
// one at the new pin and this header names it.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

// MARK: - Configuration (Qwen35.swift)

private enum QQwen35RopeParametersCodingKey: String, CodingKey {
    case ropeParameters = "rope_parameters"
}

struct QQwen35TextConfiguration: Codable, Sendable {
    var modelType: String = ""
    var hiddenSize: Int = 4096
    var hiddenLayers: Int = 32
    var intermediateSize: Int = 14336
    var attentionHeads: Int = 32
    var kvHeads: Int = 8
    var linearNumValueHeads: Int = 64
    var linearNumKeyHeads: Int = 16
    var linearKeyHeadDim: Int = 192
    var linearValueHeadDim: Int = 128
    var linearConvKernelDim: Int = 4
    var rmsNormEps: Float = 1e-6
    var vocabularySize: Int = 151_936
    var ropeTheta: Float = 100_000.0
    var partialRotaryFactor: Float = 0.25
    var maxPositionEmbeddings: Int = 131_072
    var tieWordEmbeddings: Bool = false
    var attentionBias: Bool = false
    var headDim: Int?
    var ropeScaling: [String: StringOrNumber]?
    var fullAttentionInterval: Int = 4

    // MoE fields
    var numExperts: Int = 0
    var numExpertsPerTok: Int = 0
    var decoderSparseStep: Int = 1
    var sharedExpertIntermediateSize: Int = 0
    var moeIntermediateSize: Int = 0
    var normTopkProb: Bool = true

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case hiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case attentionHeads = "num_attention_heads"
        case kvHeads = "num_key_value_heads"
        case linearNumValueHeads = "linear_num_value_heads"
        case linearNumKeyHeads = "linear_num_key_heads"
        case linearKeyHeadDim = "linear_key_head_dim"
        case linearValueHeadDim = "linear_value_head_dim"
        case linearConvKernelDim = "linear_conv_kernel_dim"
        case rmsNormEps = "rms_norm_eps"
        case vocabularySize = "vocab_size"
        case ropeTheta = "rope_theta"
        case partialRotaryFactor = "partial_rotary_factor"
        case maxPositionEmbeddings = "max_position_embeddings"
        case tieWordEmbeddings = "tie_word_embeddings"
        case attentionBias = "attention_bias"
        case headDim = "head_dim"
        case ropeScaling = "rope_scaling"
        case fullAttentionInterval = "full_attention_interval"
        case numExperts = "num_experts"
        case numExpertsPerTok = "num_experts_per_tok"
        case decoderSparseStep = "decoder_sparse_step"
        case sharedExpertIntermediateSize = "shared_expert_intermediate_size"
        case moeIntermediateSize = "moe_intermediate_size"
        case normTopkProb = "norm_topk_prob"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaultRopeParameters: [String: StringOrNumber] = [
            "type": .string("default"),
            "mrope_section": .ints([11, 11, 10]),
            "rope_theta": .float(100_000.0),
            "partial_rotary_factor": .float(0.25),
        ]

        modelType = try container.decodeIfPresent(String.self, forKey: .modelType) ?? ""
        hiddenSize = try container.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? 4096
        hiddenLayers = try container.decodeIfPresent(Int.self, forKey: .hiddenLayers) ?? 32
        intermediateSize =
            try container.decodeIfPresent(Int.self, forKey: .intermediateSize) ?? 14336
        attentionHeads = try container.decodeIfPresent(Int.self, forKey: .attentionHeads) ?? 32
        kvHeads = try container.decodeIfPresent(Int.self, forKey: .kvHeads) ?? 8
        linearNumValueHeads =
            try container.decodeIfPresent(Int.self, forKey: .linearNumValueHeads) ?? 64
        linearNumKeyHeads =
            try container.decodeIfPresent(Int.self, forKey: .linearNumKeyHeads) ?? 16
        linearKeyHeadDim =
            try container.decodeIfPresent(Int.self, forKey: .linearKeyHeadDim) ?? 192
        linearValueHeadDim =
            try container.decodeIfPresent(Int.self, forKey: .linearValueHeadDim) ?? 128
        linearConvKernelDim =
            try container.decodeIfPresent(Int.self, forKey: .linearConvKernelDim) ?? 4
        rmsNormEps = try container.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        vocabularySize =
            try container.decodeIfPresent(Int.self, forKey: .vocabularySize) ?? 151_936
        maxPositionEmbeddings =
            try container.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings) ?? 131_072
        tieWordEmbeddings =
            try container.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? false
        attentionBias =
            try container.decodeIfPresent(Bool.self, forKey: .attentionBias) ?? false
        headDim = try container.decodeIfPresent(Int.self, forKey: .headDim)
        fullAttentionInterval =
            try container.decodeIfPresent(Int.self, forKey: .fullAttentionInterval) ?? 4

        // MoE fields
        numExperts = try container.decodeIfPresent(Int.self, forKey: .numExperts) ?? 0
        numExpertsPerTok =
            try container.decodeIfPresent(Int.self, forKey: .numExpertsPerTok) ?? 0
        decoderSparseStep =
            try container.decodeIfPresent(Int.self, forKey: .decoderSparseStep) ?? 1
        sharedExpertIntermediateSize =
            try container.decodeIfPresent(Int.self, forKey: .sharedExpertIntermediateSize) ?? 0
        moeIntermediateSize =
            try container.decodeIfPresent(Int.self, forKey: .moeIntermediateSize) ?? 0
        normTopkProb = try container.decodeIfPresent(Bool.self, forKey: .normTopkProb) ?? true

        let ropeContainer = try decoder.container(keyedBy: QQwen35RopeParametersCodingKey.self)
        let ropeParameters = try ropeContainer.decodeIfPresent(
            [String: StringOrNumber].self, forKey: .ropeParameters
        )

        if var ropeParameters {
            if ropeParameters["type"] == nil, let ropeType = ropeParameters["rope_type"] {
                ropeParameters["type"] = ropeType
            }
            ropeTheta = ropeParameters["rope_theta"]?.asFloat() ?? 100_000.0
            partialRotaryFactor =
                ropeParameters["partial_rotary_factor"]?.asFloat() ?? 0.25
            ropeScaling = ropeParameters
        } else {
            ropeTheta =
                try container.decodeIfPresent(Float.self, forKey: .ropeTheta) ?? 100_000.0
            partialRotaryFactor =
                try container.decodeIfPresent(Float.self, forKey: .partialRotaryFactor) ?? 0.25
            ropeScaling =
                try container.decodeIfPresent([String: StringOrNumber].self, forKey: .ropeScaling)
                    ?? defaultRopeParameters
        }

        if headDim == nil {
            headDim = hiddenSize / attentionHeads
        }
    }
}

// MARK: - Configuration (Qwen35MoE.swift)

struct QQwen35Configuration: Codable, Sendable {
    var modelType: String
    var textConfig: QQwen35TextConfiguration

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case textConfig = "text_config"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try container.decode(String.self, forKey: .modelType)

        if let textConfig = try container.decodeIfPresent(
            QQwen35TextConfiguration.self, forKey: .textConfig
        ) {
            self.textConfig = textConfig
        } else {
            textConfig = try QQwen35TextConfiguration(from: decoder)
        }
    }
}

// MARK: - Helpers (Qwen3Next.swift)

// MARK: - Helpers

/// The attention output's gate, as one kernel.
let qSigmoidMultiply: @Sendable (MLXArray, MLXArray) -> MLXArray = compile(shapeless: true) { x, gate in
    x * sigmoid(gate)
}

/// The gated norm's SwiGLU in float32, compiled as mlx-lm's `_precise_swiglu` is.
private let qPreciseSwiGLU: @Sendable (MLXArray, MLXArray, MLXArray) -> MLXArray = compile(shapeless: true) {
    hiddenStates, gate, x in
    (silu(gate.asType(.float32)) * x.asType(.float32)).asType(hiddenStates.dtype)
}

// MARK: - Model Components

final class QQwen35RMSNormGated: Module {
    @ParameterInfo(key: "weight") var weight: MLXArray
    let eps: Float

    init(dimensions: Int, eps: Float) {
        self.eps = eps
        _weight.wrappedValue = MLXArray.ones([dimensions])
        super.init()
    }

    func callAsFunction(_ hiddenStates: MLXArray, gate: MLXArray? = nil) -> MLXArray {
        var x = MLXFast.rmsNorm(hiddenStates, weight: weight, eps: eps)
        if let gate {
            x = qPreciseSwiGLU(hiddenStates, gate, x)
        }
        return x
    }
}

final class QQwen35MLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear

    init(dimensions: Int, hiddenDimensions: Int) {
        _gateProj.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
        _downProj.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
        _upProj.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(compiledSiluProduct(gateProj(x), upProj(x)))
    }
}

// MARK: - Gated delta (GatedDelta.swift)

// MARK: - Compute G

/// The decay, compiled as mlx-lm's `compute_g` is.
let qComputeGatedDeltaG: @Sendable (MLXArray, MLXArray, MLXArray) -> MLXArray = compile(shapeless: true) {
    aLog, a, dtBias in
    exp(-exp(aLog.asType(.float32)) * softplus(a + dtBias))
}

// MARK: - Metal Kernel

private func qMakeGatedDeltaKernel(hasMask: Bool) -> MLXFast.MLXFastKernel? {
    let maskSource = hasMask ? "mask[b_idx * T + t]" : "true"

    let source = """
        auto n = thread_position_in_grid.z;
        auto b_idx = n / Hv;
        auto hv_idx = n % Hv;
        auto hk_idx = hv_idx / (Hv / Hk);
        constexpr int n_per_t = Dk / 32;

        // q, k: [B, T, Hk, Dk]
        auto q_ = q + b_idx * T * Hk * Dk + hk_idx * Dk;
        auto k_ = k + b_idx * T * Hk * Dk + hk_idx * Dk;

        // v, y: [B, T, Hv, Dv]
        auto v_ = v + b_idx * T * Hv * Dv + hv_idx * Dv;
        y += b_idx * T * Hv * Dv + hv_idx * Dv;

        auto dk_idx = thread_position_in_threadgroup.x;
        auto dv_idx = thread_position_in_grid.y;

        // g: [B, T, Hv]
        auto g_ = g + b_idx * T * Hv;
        auto beta_ = beta + b_idx * T * Hv;

        // state_in, state_out: [B, Hv, Dv, Dk]
        auto i_state = state_in + (n * Dv + dv_idx) * Dk;
        auto o_state = state_out + (n * Dv + dv_idx) * Dk;

        float state[n_per_t];
        for (int i = 0; i < n_per_t; ++i) {
          auto s_idx = n_per_t * dk_idx + i;
          state[i] = static_cast<float>(i_state[s_idx]);
        }

        for (int t = 0; t < T; ++t) {
          if (\(maskSource)) {
            float kv_mem = 0.0f;
            for (int i = 0; i < n_per_t; ++i) {
              auto s_idx = n_per_t * dk_idx + i;
              state[i] = state[i] * g_[hv_idx];
              kv_mem += state[i] * k_[s_idx];
            }
            kv_mem = simd_sum(kv_mem);

            auto delta = (v_[dv_idx] - kv_mem) * beta_[hv_idx];

            float out = 0.0f;
            for (int i = 0; i < n_per_t; ++i) {
              auto s_idx = n_per_t * dk_idx + i;
              state[i] = state[i] + k_[s_idx] * delta;
              out += state[i] * q_[s_idx];
            }
            out = simd_sum(out);
            if (thread_index_in_simdgroup == 0) {
              y[dv_idx] = static_cast<InT>(out);
            }
          } else {
            y[dv_idx] = static_cast<InT>(0);
          }
          // Increment data pointers to next time step
          q_ += Hk * Dk;
          k_ += Hk * Dk;
          v_ += Hv * Dv;
          y += Hv * Dv;
          g_ += Hv;
          beta_ += Hv;
        }
        for (int i = 0; i < n_per_t; ++i) {
          auto s_idx = n_per_t * dk_idx + i;
          o_state[s_idx] = static_cast<StT>(state[i]);
        }
    """

    var inputNames = ["q", "k", "v", "g", "beta", "state_in", "T"]
    if hasMask {
        inputNames.append("mask")
    }

    let suffix = hasMask ? "_mask" : ""

    return MLXFast.metalKernel(
        name: "gated_delta_step\(suffix)",
        inputNames: inputNames,
        outputNames: ["y", "state_out"],
        source: source
    )
}

private final class QGatedDeltaKernelManager: Sendable {
    static let shared = QGatedDeltaKernelManager()

    let kernel: MLXFast.MLXFastKernel?
    let kernelMasked: MLXFast.MLXFastKernel?

    private init() {
        kernel = qMakeGatedDeltaKernel(hasMask: false)
        kernelMasked = qMakeGatedDeltaKernel(hasMask: true)
    }
}

// MARK: - Kernel Dispatch

func qGatedDeltaKernel(
    q: MLXArray,
    k: MLXArray,
    v: MLXArray,
    g: MLXArray,
    beta: MLXArray,
    state: MLXArray,
    mask: MLXArray? = nil
) -> (MLXArray, MLXArray) {
    let B = k.dim(0)
    let T = k.dim(1)
    let Hk = k.dim(2)
    let Dk = k.dim(3)
    let Hv = v.dim(2)
    let Dv = v.dim(3)
    let inputType = q.dtype
    let stateType = state.dtype

    let selectedKernel: MLXFast.MLXFastKernel?
    var inputs: [MLXArray] = [q, k, v, g, beta, state, MLXArray(T)]
    if let mask {
        selectedKernel = QGatedDeltaKernelManager.shared.kernelMasked
        inputs.append(mask)
    } else {
        selectedKernel = QGatedDeltaKernelManager.shared.kernel
    }

    guard let kernel = selectedKernel else {
        fatalError("Gated delta kernel not available")
    }

    let outputs = kernel(
        inputs,
        template: [
            ("InT", inputType),
            ("StT", stateType),
            ("Dk", Dk),
            ("Dv", Dv),
            ("Hk", Hk),
            ("Hv", Hv),
        ],
        grid: (32, Dv, B * Hv),
        threadGroup: (32, 4, 1),
        outputShapes: [[B, T, Hv, Dv], state.shape],
        outputDTypes: [inputType, stateType]
    )

    return (outputs[0], outputs[1])
}

// MARK: - Ops Fallback

private func qGatedDeltaStepOps(
    q: MLXArray,
    k: MLXArray,
    v: MLXArray,
    g: MLXArray,
    beta: MLXArray,
    state: MLXArray,
    mask: MLXArray? = nil
) -> (MLXArray, MLXArray) {
    let oldState = state
    let decay: MLXArray
    if g.ndim == 2 {
        decay = expandedDimensions(g, axes: [2, 3])
    } else if g.ndim == 3 {
        decay = expandedDimensions(g, axis: -2)
    } else {
        fatalError("Unsupported gating shape \(g.shape)")
    }

    var state = state * decay
    let kvMem = (state * expandedDimensions(k, axis: -2)).sum(axis: -1)
    let delta = (v - kvMem) * expandedDimensions(beta, axis: -1)
    state = state + expandedDimensions(k, axis: -2) * expandedDimensions(delta, axis: -1)
    let y = (state * expandedDimensions(q, axis: -2)).sum(axis: -1)

    if let mask {
        let expandedMask: MLXArray
        if mask.ndim == 1 {
            expandedMask = expandedDimensions(mask, axes: [1, 2, 3])
        } else if mask.ndim == 2 {
            expandedMask = expandedDimensions(mask, axes: [2, 3])
        } else if mask.ndim == 3 {
            expandedMask = expandedDimensions(mask, axis: -1)
        } else {
            fatalError("Unsupported mask shape \(mask.shape)")
        }
        state = MLX.where(expandedMask, state, oldState)
    }

    return (y.asType(q.dtype), state)
}

func qGatedDeltaOps(
    q: MLXArray,
    k: MLXArray,
    v: MLXArray,
    g: MLXArray,
    beta: MLXArray,
    state: MLXArray? = nil,
    mask: MLXArray? = nil
) -> (MLXArray, MLXArray) {
    let B = q.dim(0)
    let T = q.dim(1)
    let Hk = q.dim(2)
    let Dk = q.dim(3)
    let Hv = v.dim(2)
    let Dv = v.dim(3)

    var q = q
    var k = k

    let repeatFactor = Hv / Hk
    if repeatFactor > 1 {
        q = repeated(q, count: repeatFactor, axis: -2)
        k = repeated(k, count: repeatFactor, axis: -2)
    }

    var state = state ?? MLXArray.zeros([B, Hv, Dv, Dk], dtype: .float32)

    var ys = [MLXArray]()
    ys.reserveCapacity(T)

    for t in 0 ..< T {
        let qT = q[0..., t]
        let kT = k[0..., t]
        let vT = v[0..., t]
        let gT = g[0..., t]
        let betaT = beta[0..., t]
        let maskT = mask == nil ? nil : mask![0..., t]

        let (y, newState) = qGatedDeltaStepOps(
            q: qT,
            k: kT,
            v: vT,
            g: gT,
            beta: betaT,
            state: state,
            mask: maskT
        )
        ys.append(y)
        state = newState
    }

    let y = MLX.stacked(ys, axis: 1)
    return (y, state)
}

// MARK: - Public API

func qGatedDeltaUpdate(
    q: MLXArray,
    k: MLXArray,
    v: MLXArray,
    a: MLXArray,
    b: MLXArray,
    aLog: MLXArray,
    dtBias: MLXArray,
    state: MLXArray? = nil,
    mask: MLXArray? = nil
) -> (MLXArray, MLXArray) {
    let beta = sigmoid(b)
    let g = qComputeGatedDeltaG(aLog, a, dtBias)

    let B = q.dim(0)
    let Dk = q.dim(3)
    let Hv = v.dim(2)
    let Dv = v.dim(3)

    // State kept in fp32 to match Python mlx-lm. Using q.dtype (bf16) loses
    // precision across T-step recurrence, compounding rounding error.
    var state = state ?? MLXArray.zeros([B, Hv, Dv, Dk], dtype: .float32)
    if state.dtype != .float32 {
        state = state.asType(.float32)
    }

    if QGatedDeltaKernelManager.shared.kernel != nil {
        return qGatedDeltaKernel(q: q, k: k, v: v, g: g, beta: beta, state: state, mask: mask)
    }

    return qGatedDeltaOps(q: q, k: k, v: v, g: g, beta: beta, state: state, mask: mask)
}

/// A GatedDeltaNet layer's work between its input and output projections, kernel by kernel: the output before
/// `out_proj` (`[B, S, valueHeads, valueHeadDim]`) and the new convolution and recurrent states.
func qGatedDeltaNetStep(
    qkv: MLXArray, z: MLXArray, b: MLXArray, a: MLXArray, convState: MLXArray, state: MLXArray?,
    convWeight: MLXArray, aLog: MLXArray, dtBias: MLXArray, normWeight: MLXArray, eps: Float,
    keyHeads: Int, valueHeads: Int, keyHeadDim: Int, valueHeadDim: Int, convKernel: Int, mask: MLXArray?
) -> (MLXArray, MLXArray, MLXArray) {
    let B = qkv.dim(0)
    let S = qkv.dim(1)
    let keyDim = keyHeads * keyHeadDim
    var qkv = qkv
    if let mask {
        qkv = MLX.where(mask[.ellipsis, .newAxis], qkv, 0)
    }

    let convInput = concatenated([convState, qkv], axis: 1)
    let newConvState = contiguous(convInput[0..., (-(convKernel - 1))..., 0...])

    let convOut = silu(conv1d(convInput, convWeight, groups: convWeight.dim(0)))

    let convSplit = MLX.split(convOut, indices: [keyDim, 2 * keyDim], axis: -1)
    let q = convSplit[0].reshaped(B, S, keyHeads, keyHeadDim)
    let k = convSplit[1].reshaped(B, S, keyHeads, keyHeadDim)
    let v = convSplit[2].reshaped(B, S, valueHeads, valueHeadDim)

    let dtype = q.dtype
    let invScale = pow(Float(keyHeadDim), -0.5)
    let qNormed =
        MLXArray(pow(invScale, 2)).asType(dtype)
            * MLXFast.rmsNorm(q, weight: MLXArray.mlxNone, eps: 1e-6)
    let kNormed =
        MLXArray(invScale).asType(dtype)
            * MLXFast.rmsNorm(k, weight: MLXArray.mlxNone, eps: 1e-6)

    let (out, newState) = qGatedDeltaUpdate(
        q: qNormed,
        k: kNormed,
        v: v,
        a: a,
        b: b,
        aLog: aLog,
        dtBias: dtBias,
        state: state,
        mask: mask
    )

    // The gated norm (`QQwen35RMSNormGated`).
    let normed = MLXFast.rmsNorm(out, weight: normWeight, eps: eps)
    return (qPreciseSwiGLU(out, z, normed), newConvState, newState)
}

// MARK: - Fused single-token decode

// Adapted from Rapid-MLX 0.15.2, rapid_mlx/kernels/qwen4_fused_gdn_decode.py and qwen35_fused_gdn_decode.py
// (Apache-2.0; Copyright 2025-2026 Rapid-MLX contributors), whose Metal reduction and precision structure is itself
// adapted from mlx-vlm #2105 (MIT; Copyright (c) 2025 Prince Canuma). Only the Qwen3.5-family semantics are kept.
//
// One request's next token (B = 1, one position) through a GatedDeltaNet layer is a dozen small kernels between
// the input projections and the output projection: the causal convolution and its cache shift, the SiLU, the two
// RMSNorms and their scales, the decay and `beta`, the recurrence, and the gated norm. This does them in one launch,
// in the same order and at the same rounding points, so it gives the same bytes; `QFusedGatedDeltaDecode.probe`
// checks that on this GPU before the first use, and the layer keeps the separate kernels if it doesn't
// (or with `QUAIL_MLX_FUSED_GDN=0`).

private let qFusedGatedDeltaHeader = """
template <typename U>
inline U mlx_sigmoid_precise(U x) {
  U e = static_cast<U>(metal::precise::exp(metal::abs(x)));
  U y = static_cast<U>(1) / (static_cast<U>(1) + e);
  return (x < 0) ? y : (static_cast<U>(1) - y);
}

template <typename U>
inline U mlx_sigmoid_fast(U x) {
  U e = static_cast<U>(metal::exp(metal::abs(x)));
  U y = static_cast<U>(1) / (static_cast<U>(1) + e);
  return (x < 0) ? y : (static_cast<U>(1) - y);
}

template <typename U>
inline U mlx_log1p_fast(U x) {
  float xf = float(x);
  float xp1 = 1.0f + xf;
  float out = xp1 == 1.0f ? xf : xf * (metal::log(xp1) / (xp1 - 1.0f));
  return static_cast<U>(out);
}

template <typename U>
inline U mlx_softplus_fast(U x) {
  if (metal::isnan(x))
    return metal::numeric_limits<U>::quiet_NaN();
  constexpr U inf = metal::numeric_limits<U>::infinity();
  U zero = static_cast<U>(0);
  U hi = metal::max(x, zero);
  U lo = metal::min(x, zero);
  return (lo == -inf || hi == inf)
      ? hi
      : (hi + mlx_log1p_fast(static_cast<U>(metal::exp(lo - hi))));
}
"""

private let qFusedGatedDeltaSource = """
  const uint hv = threadgroup_position_in_grid.z;
  const uint hk = hv / RATIO;
  const uint lane = thread_position_in_threadgroup.x;
  const uint ty = thread_position_in_threadgroup.y;
  const uint tid = thread_index_in_threadgroup;

  constexpr int NT = 32 * TY;
  constexpr int NDK = DK / 32;
  constexpr int NDV = DV / TY;
  constexpr uint KD = (uint)(HK * DK);
  constexpr uint VD = (uint)(HV * DV);
  constexpr uint CD = 2u * KD + VD;

  threadgroup float sq[DK];
  threadgroup float sk[DK];
  threadgroup float sv[DV];
  threadgroup float sy[DV];
  threadgroup float shr[4];

  device const float* si = recurrent_state + (size_t)hv * DV * DK;
  device float* so = recurrent_state_out + (size_t)hv * DV * DK;
  float st[NDV][NDK];
  for (int j = 0; j < NDV; ++j) {
    uint dv = ty + (uint)TY * (uint)j;
    for (int i = 0; i < NDK; ++i)
      st[j][i] = si[(size_t)dv * DK + NDK * lane + i];
  }

  // The causal convolution and SiLU for this head's q, k and v columns, and the convolution cache shifted by
  // one (each column written by one head).
  for (uint idx = tid; idx < (uint)(2 * DK + DV); idx += NT) {
    uint part = idx / (uint)DK;
    uint d = idx - part * (uint)DK;
    uint c = part == 0u ? hk * DK + d
           : (part == 1u ? KD + hk * DK + d : 2u * KD + hv * DV + d);
    device const T* wc = conv_weight + (size_t)c * K;
    float acc = 0.0f;
    for (uint tap = 0; tap + 1 < (uint)K; ++tap)
      acc += float(conv_state[(size_t)tap * CD + c]) * float(wc[tap]);
    acc += float(qkv[c]) * float(wc[K - 1]);
    T xb = static_cast<T>(acc);
    T sig = mlx_sigmoid_fast(xb);
    T sl = xb * sig;
    if (part == 0u) sq[d] = float(sl);
    else if (part == 1u) sk[d] = float(sl);
    else sv[d] = float(sl);
    if (part == 2u || (hv % RATIO) == 0u) {
      for (uint tap = 0; tap + 2 < (uint)K; ++tap)
        conv_state_out[(size_t)tap * CD + c] =
            conv_state[(size_t)(tap + 1) * CD + c];
      conv_state_out[(size_t)(K - 2) * CD + c] = qkv[c];
    }
  }

  // The decay and beta.
  if (tid == 0u) {
    T av = alpha[hv] + dt_bias[hv];
    T sp = mlx_softplus_fast(av);
    shr[2] = metal::precise::exp(
        -metal::precise::exp(float(A_log[hv])) * float(sp));
    shr[3] = float(mlx_sigmoid_precise(beta[hv]));
  }
  threadgroup_barrier(mem_flags::mem_threadgroup);

  // q and k RMS-normalized as mx.fast.rms_norm does (float32 mean of squares and reciprocal square root, cast
  // back), then scaled in T.
  if (simdgroup_index_in_threadgroup == 0u) {
    float pq = 0.0f, pk = 0.0f;
    uint base = 4u * lane;
    for (int i = 0; i < 4; ++i) {
      pq += sq[base + i] * sq[base + i];
      pk += sk[base + i] * sk[base + i];
    }
    pq = simd_sum(pq);
    pk = simd_sum(pk);
    if (lane == 0u) {
      shr[0] = metal::precise::rsqrt(pq / float(DK) + 1.0e-6f);
      shr[1] = metal::precise::rsqrt(pk / float(DK) + 1.0e-6f);
    }
  }
  threadgroup_barrier(mem_flags::mem_threadgroup);
  T qscale = static_cast<T>(1.0f / float(DK));
  T kscale = static_cast<T>(metal::precise::rsqrt(float(DK)));
  for (uint d = tid; d < (uint)DK; d += NT) {
    T q_normalized = static_cast<T>(sq[d] * shr[0]);
    T k_normalized = static_cast<T>(sk[d] * shr[1]);
    sq[d] = float(static_cast<T>(q_normalized * qscale));
    sk[d] = float(static_cast<T>(k_normalized * kscale));
  }
  threadgroup_barrier(mem_flags::mem_threadgroup);

  // The recurrence.
  for (int j = 0; j < NDV; ++j) {
    uint dv = ty + (uint)TY * (uint)j;
    float kv = 0.0f;
    for (int i = 0; i < NDK; ++i) {
      uint s = NDK * lane + i;
      st[j][i] = st[j][i] * shr[2];
      kv += st[j][i] * sk[s];
    }
    kv = simd_sum(kv);
    float delta = (sv[dv] - kv) * shr[3];
    float out = 0.0f;
    for (int i = 0; i < NDK; ++i) {
      uint s = NDK * lane + i;
      st[j][i] = st[j][i] + sk[s] * delta;
      out += st[j][i] * sq[s];
    }
    out = simd_sum(out);
    if (thread_index_in_simdgroup == 0u)
      sy[dv] = float(static_cast<T>(out));
    for (int i = 0; i < NDK; ++i)
      so[(size_t)dv * DK + NDK * lane + i] = st[j][i];
  }
  threadgroup_barrier(mem_flags::mem_threadgroup);

  // The gated norm: RMSNorm, then the float32 SiLU of the gate times the normalized value.
  if (simdgroup_index_in_threadgroup == 0u) {
    float po = 0.0f;
    uint base = 4u * lane;
    for (int i = 0; i < 4; ++i) po += sy[base + i] * sy[base + i];
    po = simd_sum(po);
    if (lane == 0u)
      shr[0] = metal::precise::rsqrt(po / (float)DV + norm_eps);
  }
  threadgroup_barrier(mem_flags::mem_threadgroup);
  for (uint d = tid; d < (uint)DV; d += NT) {
    T normalized = static_cast<T>(sy[d] * shr[0]);
    normalized = norm_weight[d] * normalized;
    float zg = float(z[hv * DV + d]);
    float gate = zg * mlx_sigmoid_precise<float>(zg);
    float x = gate * float(normalized);
    output[hv * DV + d] = static_cast<T>(x);
  }
"""

/// A GatedDeltaNet layer's work between its input and output projections for one request's next token, as one
/// Metal kernel (see above).
enum QFusedGatedDeltaDecode {
    /// A layer's shape: key heads, value heads, head width (keys' and values' alike), convolution taps.
    struct Shape: Hashable {
        let keyHeads: Int
        let valueHeads: Int
        let headDim: Int
        let convKernel: Int

        var convDim: Int {
            (2 * keyHeads + valueHeads) * headDim
        }
    }

    /// Whether the kernel is written for a layer: 128-wide key and value heads (its reductions are one simdgroup of
    /// 32 lanes, 4 values each) and whole groups of value heads per key head.
    static func fits(_ shape: Shape, valueHeadDim: Int) -> Bool {
        shape.headDim == 128 && valueHeadDim == 128 && shape.valueHeads % shape.keyHeads == 0
            && shape.convKernel >= 2
    }

    static let enabled = ProcessInfo.processInfo.environment["QUAIL_MLX_FUSED_GDN"] != "0"

    private static let kernel = MLXFast.metalKernel(
        name: "quail_fused_gated_delta_decode",
        inputNames: [
            "qkv", "z", "beta", "alpha", "conv_state", "conv_weight", "A_log", "dt_bias", "recurrent_state",
            "norm_weight", "norm_eps",
        ],
        outputNames: ["output", "conv_state_out", "recurrent_state_out"],
        source: qFusedGatedDeltaSource,
        header: qFusedGatedDeltaHeader
    )

    /// Each shape's threadgroup height once probed; nil where the separate kernels are kept.
    private final class Probed: @unchecked Sendable {
        let lock = NSLock()
        var heights: [Shape: Int?] = [:]
    }

    private static let probed = Probed()

    /// The threadgroup height to run `shape` with, probing it the first time; nil to keep the separate kernels.
    static func threadgroupY(for shape: Shape) -> Int? {
        guard enabled else { return nil }
        return probed.lock.withLock {
            if let height = probed.heights[shape] {
                return height
            }
            let height = probe(shape)
            probed.heights[shape] = height
            FileHandle.standardError.write(Data((height.map {
                "quail-server: GatedDeltaNet decode fused into one kernel (threadgroup height \($0))\n"
            } ?? "quail-server: GatedDeltaNet decode kept as separate kernels (the fused one differed)\n").utf8))
            return height
        }
    }

    /// The layer's output before `out_proj` (`[1, 1, valueHeads × headDim]`), and its new convolution and recurrent
    /// states. `qkv`, `z`, `b` and `a` are the input projections' outputs for one position of one sequence.
    static func decode(
        qkv: MLXArray, z: MLXArray, b: MLXArray, a: MLXArray, convState: MLXArray, state: MLXArray,
        convWeight: MLXArray, aLog: MLXArray, dtBias: MLXArray, normWeight: MLXArray, eps: Float, shape: Shape,
        threadgroupY: Int
    ) -> (MLXArray, MLXArray, MLXArray) {
        let outputs = kernel(
            [qkv, z, b, a, convState, convWeight, aLog, dtBias, state, normWeight, MLXArray(eps)],
            template: [
                ("T", qkv.dtype), ("HK", shape.keyHeads), ("HV", shape.valueHeads), ("DK", shape.headDim),
                ("DV", shape.headDim), ("K", shape.convKernel), ("TY", threadgroupY),
                ("RATIO", shape.valueHeads / shape.keyHeads),
            ],
            grid: (32, threadgroupY, shape.valueHeads),
            threadGroup: (32, threadgroupY, 1),
            outputShapes: [
                [1, 1, shape.valueHeads * shape.headDim], [1, shape.convKernel - 1, shape.convDim],
                [1, shape.valueHeads, shape.headDim, shape.headDim],
            ],
            outputDTypes: [qkv.dtype, qkv.dtype, .float32]
        )
        return (outputs[0], outputs[1], outputs[2])
    }

    /// Runs eight steps of a random layer of `shape` both ways, and keeps the first threadgroup height whose output
    /// and states match the separate kernels' byte for byte (as Rapid-MLX's install probe does).
    private static func probe(_ shape: Shape) -> Int? {
        let headDim = shape.headDim
        let dtype = DType.bfloat16
        func random(_ shape: [Int], _ seed: UInt64, scale: Float = 1) -> MLXArray {
            (MLXRandom.normal(shape, key: MLXRandom.key(seed)) * scale).asType(dtype)
        }
        let convWeight = random([shape.convDim, shape.convKernel, 1], 3501, scale: 0.1)
        let aLog = random([shape.valueHeads], 3502)
        let dtBias = random([shape.valueHeads], 3503)
        let normWeight = random([headDim], 3504)
        let convZeros = MLXArray.zeros([1, shape.convKernel - 1, shape.convDim], dtype: dtype)
        let stateZeros = MLXArray.zeros([1, shape.valueHeads, headDim, headDim], dtype: .float32)
        for threadgroupY in [32, 16, 8, 4] {
            let same = try? withError {
                var (stockConv, stockState, fusedConv, fusedState) = (convZeros, stateZeros, convZeros, stateZeros)
                for step in UInt64(0) ..< 8 {
                    let qkv = random([1, 1, shape.convDim], 3600 + step, scale: 0.3)
                    let z = random([1, 1, shape.valueHeads * headDim], 3700 + step, scale: 2)
                    let b = random([1, 1, shape.valueHeads], 3800 + step, scale: 2)
                    let a = random([1, 1, shape.valueHeads], 3900 + step, scale: 2)
                    let stock = qGatedDeltaNetStep(
                        qkv: qkv, z: z.reshaped(1, 1, shape.valueHeads, headDim), b: b, a: a, convState: stockConv,
                        state: stockState, convWeight: convWeight, aLog: aLog, dtBias: dtBias,
                        normWeight: normWeight, eps: 1e-6, keyHeads: shape.keyHeads, valueHeads: shape.valueHeads,
                        keyHeadDim: headDim, valueHeadDim: headDim, convKernel: shape.convKernel, mask: nil
                    )
                    let fused = decode(
                        qkv: qkv, z: z, b: b, a: a, convState: fusedConv, state: fusedState, convWeight: convWeight,
                        aLog: aLog, dtBias: dtBias, normWeight: normWeight, eps: 1e-6, shape: shape,
                        threadgroupY: threadgroupY
                    )
                    (stockConv, stockState, fusedConv, fusedState) = (stock.1, stock.2, fused.1, fused.2)
                    let equal = arrayEqual(stock.0.reshaped(fused.0.shape), fused.0).item(Bool.self)
                        && arrayEqual(stock.1, fused.1).item(Bool.self)
                        && arrayEqual(stock.2, fused.2).item(Bool.self)
                    if !equal {
                        return false
                    }
                }
                return true
            }
            if same == true {
                return threadgroupY
            }
        }
        return nil
    }
}

// MARK: - Model (Qwen35.swift)

// MARK: - GatedDeltaNet

final class QQwen35GatedDeltaNet: Module {
    let hiddenSize: Int
    let numVHeads: Int
    let numKHeads: Int
    let headKDim: Int
    let headVDim: Int
    let keyDim: Int
    let valueDim: Int
    let convKernelSize: Int
    let convDim: Int
    /// The fused single-token kernel's shape and threadgroup height for this layer, or nil to keep separate kernels.
    let fusedShape: QFusedGatedDeltaDecode.Shape
    let fusedHeight: Int?

    @ModuleInfo(key: "conv1d") var conv1d: Conv1d
    @ModuleInfo(key: "in_proj_qkv") var inProjQKV: Linear
    @ModuleInfo(key: "in_proj_z") var inProjZ: Linear
    @ModuleInfo(key: "in_proj_b") var inProjB: Linear
    @ModuleInfo(key: "in_proj_a") var inProjA: Linear

    @ParameterInfo(key: "dt_bias") var dtBias: MLXArray
    @ParameterInfo(key: "A_log") var aLog: MLXArray

    @ModuleInfo(key: "norm") var norm: QQwen35RMSNormGated
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(_ args: QQwen35TextConfiguration) {
        hiddenSize = args.hiddenSize
        numVHeads = args.linearNumValueHeads
        numKHeads = args.linearNumKeyHeads
        headKDim = args.linearKeyHeadDim
        headVDim = args.linearValueHeadDim
        keyDim = headKDim * numKHeads
        valueDim = headVDim * numVHeads
        convKernelSize = args.linearConvKernelDim
        convDim = keyDim * 2 + valueDim
        fusedShape = QFusedGatedDeltaDecode.Shape(
            keyHeads: numKHeads, valueHeads: numVHeads, headDim: headKDim, convKernel: convKernelSize
        )
        fusedHeight = QFusedGatedDeltaDecode.fits(fusedShape, valueHeadDim: headVDim)
            ? QFusedGatedDeltaDecode.threadgroupY(for: fusedShape) : nil

        precondition(
            numVHeads % numKHeads == 0,
            "num_v_heads (\(numVHeads)) must be divisible by num_k_heads (\(numKHeads))"
        )

        _conv1d.wrappedValue = Conv1d(
            inputChannels: convDim,
            outputChannels: convDim,
            kernelSize: convKernelSize,
            stride: 1,
            padding: 0,
            dilation: 1,
            groups: convDim,
            bias: false
        )

        _inProjQKV.wrappedValue = Linear(hiddenSize, keyDim * 2 + valueDim, bias: false)
        _inProjZ.wrappedValue = Linear(hiddenSize, valueDim, bias: false)
        _inProjB.wrappedValue = Linear(hiddenSize, numVHeads, bias: false)
        _inProjA.wrappedValue = Linear(hiddenSize, numVHeads, bias: false)

        _dtBias.wrappedValue = MLXArray.ones([numVHeads])
        let a = MLXRandom.uniform(low: 0, high: 16, [numVHeads])
        _aLog.wrappedValue = log(a)

        _norm.wrappedValue = QQwen35RMSNormGated(dimensions: headVDim, eps: args.rmsNormEps)
        _outProj.wrappedValue = Linear(valueDim, hiddenSize, bias: false)

        super.init()
    }

    func callAsFunction(
        _ inputs: MLXArray,
        mask: MLXArray? = nil,
        cache: MambaCache? = nil
    ) -> MLXArray {
        let B = inputs.dim(0)
        let S = inputs.dim(1)

        let qkv = inProjQKV(inputs)
        let z = inProjZ(inputs)
        let b = inProjB(inputs)
        let a = inProjA(inputs)

        // One request's next token: the rest of the layer as one kernel, where it gives the same bytes.
        if B == 1, S == 1, mask == nil, let fusedHeight, let cache, let convState = cache[0],
           let state = cache[1], convState.dtype == .bfloat16, state.dtype == .float32, qkv.dtype == .bfloat16
        {
            let (out, newConvState, newState) = QFusedGatedDeltaDecode.decode(
                qkv: qkv, z: z, b: b, a: a, convState: convState, state: state, convWeight: conv1d.weight,
                aLog: aLog, dtBias: dtBias, normWeight: norm.weight, eps: norm.eps, shape: fusedShape,
                threadgroupY: fusedHeight
            )
            cache[0] = newConvState
            cache[1] = newState
            cache.advance(1)
            return outProj(out)
        }

        let convState: MLXArray = if let cacheState = cache?[0] {
            cacheState
        } else {
            MLXArray.zeros([B, convKernelSize - 1, convDim], dtype: inputs.dtype)
        }
        let (out, newConvState, newState) = qGatedDeltaNetStep(
            qkv: qkv, z: z.reshaped(B, S, numVHeads, headVDim), b: b, a: a, convState: convState, state: cache?[1],
            convWeight: conv1d.weight, aLog: aLog, dtBias: dtBias, normWeight: norm.weight, eps: norm.eps,
            keyHeads: numKHeads, valueHeads: numVHeads, keyHeadDim: headKDim, valueHeadDim: headVDim,
            convKernel: convKernelSize, mask: mask
        )
        if let cache {
            cache[0] = newConvState
            cache[1] = newState
            cache.advance(S)
        }
        return outProj(out.reshaped(B, S, -1))
    }
}

// MARK: - Attention

final class QQwen35Attention: Module {
    let attentionHeads: Int
    let kvHeads: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear

    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    let rope: RoPELayer

    init(_ args: QQwen35TextConfiguration) {
        let headDim = args.headDim ?? (args.hiddenSize / args.attentionHeads)
        attentionHeads = args.attentionHeads
        kvHeads = args.kvHeads
        scale = pow(Float(headDim), -0.5)

        _qProj.wrappedValue = Linear(
            args.hiddenSize, args.attentionHeads * headDim * 2, bias: args.attentionBias
        )
        _kProj.wrappedValue = Linear(
            args.hiddenSize, args.kvHeads * headDim, bias: args.attentionBias
        )
        _vProj.wrappedValue = Linear(
            args.hiddenSize, args.kvHeads * headDim, bias: args.attentionBias
        )
        _oProj.wrappedValue = Linear(
            args.attentionHeads * headDim, args.hiddenSize, bias: args.attentionBias
        )

        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)

        let ropeDims = Int(Float(headDim) * args.partialRotaryFactor)
        rope = initializeRope(
            dims: max(1, ropeDims),
            base: args.ropeTheta,
            traditional: false,
            scalingConfig: args.ropeScaling,
            maxPositionEmbeddings: args.maxPositionEmbeddings
        )

        super.init()
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let B = x.dim(0)
        let L = x.dim(1)

        let qProjOutput = qProj(x)
        let qSplit = qProjOutput.reshaped(B, L, attentionHeads, -1).split(parts: 2, axis: -1)
        var queries = qSplit[0]
        let gate = qSplit[1].reshaped(B, L, -1)

        var keys = kProj(x)
        var values = vProj(x)

        queries = qNorm(queries).transposed(0, 2, 1, 3)
        keys = kNorm(keys.reshaped(B, L, kvHeads, -1)).transposed(0, 2, 1, 3)
        values = values.reshaped(B, L, kvHeads, -1).transposed(0, 2, 1, 3)

        let offset = cache?.ropeOffset
        queries = applyRotaryPosition(rope, to: queries, offset: offset)
        keys = applyRotaryPosition(rope, to: keys, offset: offset)

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

        return oProj(qSigmoidMultiply(output, gate))
    }
}

// MARK: - SparseMoeBlock

final class QQwen35SparseMoeBlock: Module, UnaryLayer {
    let normTopkProb: Bool
    let numExperts: Int
    let topK: Int

    @ModuleInfo(key: "gate") var gate: Linear
    @ModuleInfo(key: "switch_mlp") var switchMLP: SwitchGLU

    @ModuleInfo(key: "shared_expert") var sharedExpert: QQwen35MLP
    @ModuleInfo(key: "shared_expert_gate") var sharedExpertGate: Linear

    init(_ args: QQwen35TextConfiguration) {
        normTopkProb = args.normTopkProb
        numExperts = args.numExperts
        topK = args.numExpertsPerTok

        _gate.wrappedValue = Linear(args.hiddenSize, args.numExperts, bias: false)
        _switchMLP.wrappedValue = SwitchGLU(
            inputDims: args.hiddenSize,
            hiddenDims: args.moeIntermediateSize,
            numExperts: args.numExperts
        )

        _sharedExpert.wrappedValue = QQwen35MLP(
            dimensions: args.hiddenSize,
            hiddenDimensions: args.sharedExpertIntermediateSize
        )
        _sharedExpertGate.wrappedValue = Linear(args.hiddenSize, 1, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var gates = gate(x)
        gates = MLX.softmax(gates, axis: -1, precise: true)

        let k = topK
        let kth = gates.dim(-1) - k
        let inds = MLX.argPartition(gates, kth: kth, axis: -1)[.ellipsis, kth...]
        var scores = MLX.takeAlong(gates, inds, axis: -1)
        if normTopkProb {
            scores = scores / scores.sum(axis: -1, keepDims: true)
        }

        let y = switchMLP(x, inds)
        let combined = weightedExpertSum(y, scores)

        var sharedY = sharedExpert(x)
        sharedY = sigmoid(sharedExpertGate(x)) * sharedY

        return combined + sharedY
    }
}

// MARK: - Decoder Layer

final class QQwen35DecoderLayer: Module {
    let isLinear: Bool

    @ModuleInfo(key: "self_attn") var selfAttn: QQwen35Attention?
    @ModuleInfo(key: "linear_attn") var linearAttn: QQwen35GatedDeltaNet?

    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    @ModuleInfo(key: "mlp") var mlp: Module

    init(_ args: QQwen35TextConfiguration, layerIdx: Int) {
        isLinear = (layerIdx + 1) % args.fullAttentionInterval != 0

        if isLinear {
            _linearAttn.wrappedValue = QQwen35GatedDeltaNet(args)
        } else {
            _selfAttn.wrappedValue = QQwen35Attention(args)
        }

        if args.numExperts > 0 {
            _mlp.wrappedValue = QQwen35SparseMoeBlock(args)
        } else {
            _mlp.wrappedValue = QQwen35MLP(
                dimensions: args.hiddenSize,
                hiddenDimensions: args.intermediateSize
            )
        }

        _inputLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize,
            eps: args.rmsNormEps
        )
        _postAttentionLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize,
            eps: args.rmsNormEps
        )

        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        attentionMask: MLXFast.ScaledDotProductAttentionMaskMode,
        ssmMask: MLXArray?,
        cache: KVCache?
    ) -> MLXArray {
        let r: MLXArray = if isLinear {
            linearAttn!(inputLayerNorm(x), mask: ssmMask, cache: cache as? MambaCache)
        } else {
            selfAttn!(inputLayerNorm(x), mask: attentionMask, cache: cache)
        }

        let h = x + r
        return h + (mlp as! UnaryLayer)(postAttentionLayerNorm(h))
    }
}

// MARK: - Text Model

class QQwen35TextModelInner: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding

    fileprivate let layers: [QQwen35DecoderLayer]
    let norm: RMSNorm

    let ssmIdx: Int
    let faIdx: Int

    init(_ args: QQwen35TextConfiguration) {
        precondition(args.vocabularySize > 0)

        _embedTokens.wrappedValue = Embedding(
            embeddingCount: args.vocabularySize,
            dimensions: args.hiddenSize
        )

        layers = (0 ..< args.hiddenLayers).map { layerIdx in
            QQwen35DecoderLayer(args, layerIdx: layerIdx)
        }

        norm = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)

        ssmIdx = 0
        faIdx = args.fullAttentionInterval - 1

        super.init()
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache?]? = nil) -> MLXArray {
        var hiddenStates = embedTokens(inputs)

        var cacheArray = cache
        if cacheArray == nil {
            cacheArray = Array(repeating: nil as KVCache?, count: layers.count)
        }

        let faMask = createAttentionMask(h: hiddenStates, cache: cacheArray?[faIdx])
        let ssmMask = createSSMMask(h: hiddenStates, cache: cacheArray?[ssmIdx] as? MambaCache)

        for (i, layer) in layers.enumerated() {
            let mask = layer.isLinear ? ssmMask : nil
            let attnMask =
                layer.isLinear
                    ? MLXFast.ScaledDotProductAttentionMaskMode.none : faMask
            hiddenStates = layer(
                hiddenStates, attentionMask: attnMask, ssmMask: mask, cache: cacheArray?[i]
            )
        }

        return norm(hiddenStates)
    }
}

class QQwen35TextModel: Module, LLMModel, KVCacheDimensionProvider {
    let vocabularySize: Int
    let kvHeads: [Int]

    let model: QQwen35TextModelInner
    let configuration: QQwen35TextConfiguration

    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    init(_ args: QQwen35TextConfiguration) {
        configuration = args
        vocabularySize = args.vocabularySize
        kvHeads = (0 ..< args.hiddenLayers).map { _ in args.kvHeads }
        model = QQwen35TextModelInner(args)

        if !args.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(args.hiddenSize, args.vocabularySize, bias: false)
        }
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        var out = model(inputs, cache: cache)
        if let lmHead {
            out = lmHead(out)
        } else {
            out = model.embedTokens.asLinear(out)
        }
        return out
    }

    func newCache(parameters _: GenerateParameters?) -> [KVCache] {
        model.layers.map { layer in
            if layer.isLinear {
                return MambaCache()
            }
            return KVCacheSimple()
        }
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        let hasMTPWeights = weights.keys.contains { $0.contains("mtp.") }
        let hasUnsanitizedConv1d = weights.contains { key, value in
            key.contains("conv1d.weight") && value.dim(-1) != 1
        }
        let shouldShiftNormWeights = hasMTPWeights || hasUnsanitizedConv1d

        var weights = weights.filter { !$0.key.contains("mtp.") }

        if configuration.tieWordEmbeddings {
            weights["lm_head.weight"] = nil
        }

        let normKeys = [
            ".input_layernorm.weight",
            ".post_attention_layernorm.weight",
            "model.norm.weight",
            ".q_norm.weight",
            ".k_norm.weight",
        ]

        for k in Array(weights.keys) {
            guard let v = weights[k] else { continue }
            if k.contains("conv1d.weight"), v.dim(-1) != 1 {
                weights[k] = v.movedAxis(source: 2, destination: 1)
                continue
            }
            if shouldShiftNormWeights,
               normKeys.contains(where: { k.hasSuffix($0) }),
               v.ndim == 1
            {
                weights[k] = v + MLXArray(1, dtype: v.dtype)
            }
        }

        return weights
    }
}

extension QQwen35TextModel: LoRAModel {
    var loraLayers: [Module] {
        model.layers
    }
}

// MARK: - Top-level Model

class QQwen35Model: Module, LLMModel, KVCacheDimensionProvider {
    let vocabularySize: Int
    let kvHeads: [Int]

    @ModuleInfo(key: "language_model") var languageModel: QQwen35TextModel

    init(_ args: QQwen35Configuration) {
        let textModel = QQwen35TextModel(args.textConfig)
        vocabularySize = textModel.vocabularySize
        kvHeads = textModel.kvHeads
        _languageModel.wrappedValue = textModel
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        languageModel(inputs, cache: cache)
    }

    func newCache(parameters: GenerateParameters?) -> [KVCache] {
        languageModel.newCache(parameters: parameters)
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized = [String: MLXArray]()
        for (key, value) in weights {
            if key.hasPrefix("vision_tower") || key.hasPrefix("model.visual") {
                continue
            }

            var key = key
            if key.hasPrefix("model.language_model") {
                key = key.replacingOccurrences(
                    of: "model.language_model", with: "language_model.model"
                )
            } else if !key.hasPrefix("language_model.") {
                key = "language_model." + key
            }
            sanitized[key] = value
        }

        return languageModel.sanitize(weights: sanitized)
    }
}

extension QQwen35Model: LoRAModel {
    var loraLayers: [Module] {
        languageModel.model.layers
    }
}

// MARK: - MoE (Qwen35MoE.swift)

class QQwen35MoEModel: QQwen35Model {
    override func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var newWeights = [String: MLXArray]()
        for (key, value) in weights {
            if key.hasPrefix("vision_tower") || key.hasPrefix("model.visual") {
                continue
            }
            var key = key
            if key.hasPrefix("model.language_model") {
                key = key.replacingOccurrences(
                    of: "model.language_model", with: "language_model.model"
                )
            } else if !key.hasPrefix("language_model.") {
                key = "language_model." + key
            }
            newWeights[key] = value
        }

        for l in 0 ..< languageModel.configuration.hiddenLayers {
            let prefix = "language_model.model.layers.\(l).mlp"
            let gateUpKey = "\(prefix).experts.gate_up_proj"
            if let gateUp = newWeights[gateUpKey] {
                newWeights[gateUpKey] = nil
                let mid = gateUp.dim(-2) / 2
                newWeights["\(prefix).switch_mlp.gate_proj.weight"] =
                    gateUp[.ellipsis, ..<mid, 0...]
                newWeights["\(prefix).switch_mlp.up_proj.weight"] =
                    gateUp[.ellipsis, mid..., 0...]
                if let downProj = newWeights["\(prefix).experts.down_proj"] {
                    newWeights["\(prefix).experts.down_proj"] = nil
                    newWeights["\(prefix).switch_mlp.down_proj.weight"] = downProj
                }
            }
        }

        return languageModel.sanitize(weights: newWeights)
    }
}
