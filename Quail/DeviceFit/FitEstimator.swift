import Foundation

/// The subset of a model's own shape `FitEstimator`'s formula needs,
/// independent of which format (GGUF or MLX) it came from. `weightBytes`
/// isn't part of either metadata parser's output — it's a file size, not
/// a header field — so every initializer takes it separately.
struct ModelShape: Sendable, Equatable, Codable {
    /// W in the formula: total weight bytes (file size for GGUF,
    /// directory size for MLX).
    var weightBytes: Int64
    /// L: transformer block/layer count.
    var layerCount: Int
    /// H_kv: KV attention heads.
    var kvHeadCount: Int
    /// d: per-head attention dimension.
    var headDim: Int
    /// Bytes actually active per forward pass, for the speed estimate
    /// only (ARCHITECTURE.md §7: "only the active experts for MoE") — not
    /// used by the RAM formula, which always needs the full weight size
    /// resident regardless of how many experts a given token visits.
    /// `nil` for dense models, where active bytes equal `weightBytes`.
    ///
    /// Approximated as `weightBytes * expertsUsed / expertsTotal` — a
    /// rough scaling of the *whole* file, including non-expert layers
    /// (attention, embeddings, ...) that are active on every token
    /// regardless of routing. Neither metadata parser reads per-tensor
    /// sizes (that needs the tensor info section, deliberately never
    /// touched — see `GGUFMetadata`'s doc comment), so a precise
    /// shared-vs-expert byte split isn't available from the header alone.
    /// Good enough for an estimate that ARCHITECTURE.md §7 already says
    /// gets replaced by real measurement after the first ping test.
    var activeWeightBytes: Int64?
    /// The context the model was trained for (`<arch>.context_length`),
    /// when the header says — caps the per-model context setting.
    var trainedContext: Int?
    /// The layers that keep a cache of past tokens, when they aren't all alike (ADR D-071): `nil` means every one
    /// of `layerCount` layers keeps `kvHeadCount` heads of `headDim` for every token, the plain formula.
    var kvLayers: [KVLayers]?

    init(
        weightBytes: Int64, layerCount: Int, kvHeadCount: Int, headDim: Int, activeWeightBytes: Int64? = nil,
        trainedContext: Int? = nil, kvLayers: [KVLayers]? = nil
    ) {
        self.weightBytes = weightBytes
        self.layerCount = layerCount
        self.kvHeadCount = kvHeadCount
        self.headDim = headDim
        self.activeWeightBytes = activeWeightBytes
        self.trainedContext = trainedContext
        self.kvLayers = kvLayers
    }

    /// Layers that cache alike: `count` of them, each holding `kvHeads` heads of keys and values
    /// (`keyValueDim` = key plus value dimension per head) for every token, or for at most `window` tokens.
    struct KVLayers: Sendable, Equatable, Codable {
        var count: Int
        var kvHeads: Int
        var keyValueDim: Int
        /// A sliding-window layer whose engine keeps only its window (MLX's rotating cache). `nil` for a layer
        /// that keeps every token, which includes a GGUF sliding-window layer: libllama's default full-size
        /// window cache (`swa_full`), which quail-server keeps (ADR D-048), sizes it like any other.
        var window: Int?
    }

    /// `layers`, one entry per layer (`nil` for a layer that keeps no cache), merged into groups; `nil` when
    /// that comes to the plain formula's single group, so a plain model's shape is as it always was.
    private static func kvLayers(
        _ layers: [KVLayers?], plain: (layers: Int, kvHeads: Int, headDim: Int)
    ) -> [KVLayers]? {
        var groups: [KVLayers] = []
        for case let layer? in layers where layer.kvHeads > 0 && layer.keyValueDim > 0 {
            if let index = groups.firstIndex(where: {
                ($0.kvHeads, $0.keyValueDim, $0.window) == (layer.kvHeads, layer.keyValueDim, layer.window)
            }) {
                groups[index].count += 1
            } else {
                groups.append(layer)
            }
        }
        let uniform = [KVLayers(count: plain.layers, kvHeads: plain.kvHeads, keyValueDim: 2 * plain.headDim)]
        return groups == uniform ? nil : groups
    }

    /// Builds a `ModelShape` from a GGUF header. `headDim` prefers
    /// `keyLength` (`<arch>.attention.key_length`) when the architecture
    /// writes one explicitly, falling back to `embeddingLength / headCount`
    /// otherwise — see `GGUFMetadata.keyLength`'s doc comment for why that
    /// fallback isn't always correct, but it's the best available when the
    /// explicit key is missing. Returns `nil` if a required field is
    /// missing.
    static func from(gguf metadata: GGUFMetadata, weightBytes: Int64) -> ModelShape? {
        // A missing `head_count_kv` means "same as head_count" (plain
        // multi-head attention) — llama.cpp's own loader defaults it that
        // way; BERT-style embedding models (e.g. nomic-bert) omit it.
        guard let layerCount = metadata.blockCount,
              let kvHeadCount = metadata.headCountKV ?? metadata.headCount
        else {
            return nil
        }

        let headDim: Int
        if let keyLength = metadata.keyLength {
            headDim = keyLength
        } else if let embeddingLength = metadata.embeddingLength,
                  let headCount = metadata.headCount, headCount > 0
        {
            headDim = embeddingLength / headCount
        } else {
            return nil
        }

        return ModelShape(
            weightBytes: weightBytes,
            layerCount: layerCount,
            kvHeadCount: kvHeadCount,
            headDim: headDim,
            activeWeightBytes: activeWeightBytes(
                total: weightBytes,
                used: metadata.expertUsedCount,
                of: metadata.expertCount
            ),
            trainedContext: metadata.contextLength,
            kvLayers: ggufKVLayers(metadata, layerCount: layerCount, kvHeadCount: kvHeadCount, headDim: headDim)
        )
    }

    /// Each layer's cache, from the per-layer keys llama.cpp reads: a sliding-window layer takes the `_swa` head
    /// dimensions, a hybrid's linear-attention layers (`full_attention_interval`) and its layers with no KV heads
    /// keep none, nor do layers that share an earlier one's. Every kept layer holds the whole context (`swa_full`).
    private static func ggufKVLayers(
        _ metadata: GGUFMetadata, layerCount: Int, kvHeadCount: Int, headDim: Int
    ) -> [KVLayers]? {
        let shared = metadata.sharedKVLayers ?? 0
        let layers: [KVLayers?] = (0 ..< layerCount).map { index in
            if index >= layerCount - shared {
                return nil
            }
            if let interval = metadata.fullAttentionInterval, interval > 0, (index + 1) % interval != 0 {
                return nil
            }
            let heads = metadata.headCountKVPerLayer.flatMap { index < $0.count ? $0[index] : nil } ?? kvHeadCount
            let sliding = metadata.slidingWindowPattern.flatMap { index < $0.count ? $0[index] : nil } ?? false
            let key = (sliding ? metadata.keyLengthSWA : nil) ?? metadata.keyLength ?? headDim
            let value = (sliding ? metadata.valueLengthSWA : nil) ?? metadata.valueLength ?? key
            return KVLayers(count: 1, kvHeads: heads, keyValueDim: key + value)
        }
        return kvLayers(layers, plain: (layerCount, kvHeadCount, headDim))
    }

    /// Builds a `ModelShape` from an MLX `config.json`. Returns `nil` if a
    /// required field is missing.
    static func from(mlx metadata: MLXMetadata, weightBytes: Int64) -> ModelShape? {
        guard let layerCount = metadata.hiddenLayers,
              let kvHeadCount = metadata.headCountKV,
              let headDim = metadata.headDim
        else {
            return nil
        }

        return ModelShape(
            weightBytes: weightBytes,
            layerCount: layerCount,
            kvHeadCount: kvHeadCount,
            headDim: headDim,
            activeWeightBytes: activeWeightBytes(
                total: weightBytes,
                used: metadata.numExpertsPerToken,
                of: metadata.numLocalExperts
            ),
            trainedContext: metadata.trainedContext,
            kvLayers: mlxKVLayers(metadata.layout, layerCount: layerCount, kvHeadCount: kvHeadCount, headDim: headDim)
        )
    }

    /// Each layer's cache, from the config's layer types: a sliding-window layer keeps only its window
    /// (mlx-swift-lm's and mlx-lm's rotating cache), a global layer of Gemma 4 has its own head count and size,
    /// and linear-attention, Mamba and MLP layers, and layers sharing an earlier one's cache, keep none.
    private static func mlxKVLayers(
        _ layout: MLXMetadata.AttentionLayout, layerCount: Int, kvHeadCount: Int, headDim: Int
    ) -> [KVLayers]? {
        let shared = layout.sharedKVLayers ?? 0
        let pattern = layout.hybridOverridePattern.map(Array.init)
        let layers: [KVLayers?] = (0 ..< layerCount).map { index in
            if index >= layerCount - shared {
                return nil
            }
            if let types = layout.layersBlockType, index < types.count, types[index] != "attention" {
                return nil
            }
            if let pattern, index < pattern.count, pattern[index] != "*" {
                return nil
            }
            let sliding: Bool
            if let types = layout.layerTypes, index < types.count {
                switch types[index] {
                case "sliding_attention": sliding = true
                case "full_attention", "attention": sliding = false
                default: return nil // linear attention and the like: a fixed-size state
                }
            } else if let interval = layout.fullAttentionInterval, interval > 0 {
                guard (index + 1) % interval == 0 else { return nil }
                sliding = false
            } else if let every = layout.slidingWindowPattern, every > 0 {
                sliding = (index + 1) % every != 0
            } else {
                sliding = false
            }
            if sliding, let window = layout.slidingWindow, window > 0 {
                return KVLayers(count: 1, kvHeads: kvHeadCount, keyValueDim: 2 * headDim, window: window)
            }
            return KVLayers(
                count: 1, kvHeads: layout.globalHeadCountKV ?? kvHeadCount,
                keyValueDim: 2 * (layout.globalHeadDim ?? headDim)
            )
        }
        return kvLayers(layers, plain: (layerCount, kvHeadCount, headDim))
    }

    private static func activeWeightBytes(total: Int64, used: Int?, of experts: Int?) -> Int64? {
        guard let used, let experts, experts > 0 else { return nil }
        return total * Int64(used) / Int64(experts)
    }
}

/// How a model's KV cache stores its elements, a per-model setting (ADR D-057): full precision, or quantized to
/// 8 or 4 bits for a longer context in the same memory. Written to `presets.ini` as llama-server's
/// `cache-type-k`/`cache-type-v`, which both runtimes read.
enum KVCacheSetting: String, Sendable, Equatable, Codable, CaseIterable {
    case full = "f16"
    case q8 = "q8_0"
    case q4 = "q4_0"

    /// `b` in the fit formula. The quantized types carry a scale (and, for MLX, a bias) per group of 32–64
    /// elements, which these round up to cover either engine.
    var bytesPerElement: Double {
        switch self {
        case .full: 2
        case .q8: 1.0625
        case .q4: 0.5625
        }
    }

    var label: String {
        switch self {
        case .full: "Full precision"
        case .q8: "8-bit"
        case .q4: "4-bit"
        }
    }
}

/// docs/ARCHITECTURE.md §7's three fit verdicts.
enum FitVerdict: Sendable, Equatable {
    /// RAM needed at the requested context is under 70% of the GPU
    /// working-set ceiling.
    case comfortable
    /// Doesn't clear the comfortable threshold, but fits under the full
    /// ceiling at a reduced context — the size Quail would set
    /// automatically.
    case tight(reducedContextSize: Int)
    /// Weights alone exceed the ceiling; no context size helps.
    case wontFit
}

/// Result of `FitEstimator.estimate`.
struct FitEstimate: Sendable, Equatable {
    var verdict: FitVerdict
    /// RAM needed at whatever context the verdict settled on —
    /// `requestedContextSize` for `.comfortable`, the reduced size for
    /// `.tight`, or the weights-only figure for `.wontFit`.
    var ramNeededBytes: Int64
    /// tok/s, when the chip's bandwidth is known. `nil` for an
    /// unrecognized chip — ARCHITECTURE.md §7: "unknown chip → no speed
    /// estimate", deliberately not a guess.
    var estimatedTokensPerSecond: Double?
    /// For a `.tight` verdict at full precision: the context a 4-bit KV cache would fit instead (ADR D-057),
    /// when that's more.
    var contextWith4BitKV: Int?
}

/// docs/ARCHITECTURE.md §7's fit and speed formulas, as pure functions
/// over `ModelShape` + `DeviceInfo` — no I/O, no runtime dependency, fully
/// unit-testable with fabricated inputs.
enum FitEstimator {
    /// ARCHITECTURE.md §7: "Default C is 8,192".
    static let defaultContextSize = 8192

    /// Comfortable is below this fraction of the GPU ceiling.
    private static let comfortableFraction = 0.70

    /// O in the formula: fixed overhead per runtime, in bytes.
    /// ARCHITECTURE.md §7: "~1.5 GB for llama.cpp, ~2.5 GB for the Python
    /// runtimes". quail-server is one native process like llama-server; its MLX engine's own overhead is
    /// what the Python runtimes' estimate stands in for, and MLX rows use `.omlx` for that reason.
    static func overheadBytes(for runtime: RuntimeID) -> Int64 {
        switch runtime {
        case .llamaCpp, .quail: 1_500_000_000
        case .omlx, .rapidMLX: 2_500_000_000
        }
    }

    /// The context sizes offered in a model's context picker: 4K–128K,
    /// capped at what the model was trained for (plus that exact size, if
    /// it isn't a power of two already offered).
    static func contextOptions(trainedContext: Int?) -> [Int] {
        let standard = [4096, 8192, 16384, 32768, 65536, 131_072]
        guard let trained = trainedContext, trained > 0 else { return standard }
        var options = standard.filter { $0 <= trained }
        if !options.contains(trained), trained < 131_072 {
            options.append(trained)
        }
        return options.isEmpty ? [trained] : options.sorted()
    }

    /// "Automatic" context (ADR D-020): the largest of 32K / 16K / 8K that
    /// is Comfortable on this Mac, capped at the trained context; if none
    /// is, the `.tight` reduced size at 8K (the old behaviour); `nil` when
    /// nothing can be estimated. 8K alone — the old fixed default — was
    /// too small for coding agents (Claude Code's first request measured
    /// 15,114 tokens).
    static func automaticContextSize(
        model: ModelShape, device: DeviceInfo, runtime: RuntimeID, kvCache: KVCacheSetting = .full
    ) -> Int? {
        let cap = model.trainedContext ?? Int.max
        func verdict(at context: Int) -> FitVerdict? {
            estimate(model: model, device: device, runtime: runtime, requestedContextSize: context, kvCache: kvCache)?
                .verdict
        }
        for candidate in [32768, 16384, 8192] where candidate <= cap {
            if verdict(at: candidate) == .comfortable {
                return candidate
            }
        }
        if cap < 8192, verdict(at: cap) == .comfortable {
            return cap
        }
        if case let .tight(reduced)? = verdict(at: defaultContextSize), reduced > 0 {
            return reduced
        }
        return nil
    }

    /// Rough size (billions of parameters) of the largest model that fits
    /// on a machine, for the "This Mac" pane — not for verdicts, which use
    /// each model's real shape. Assumes a 4-bit quant (Q4_K_M, ~4.8 bits
    /// or ~0.6 bytes per weight), a ~1.5 GB KV cache at the default
    /// context, and llama.cpp's overhead.
    ///
    /// - Parameter comfortable: `true` for the comfortable bound (70% of
    ///   the ceiling, as in `estimate`), `false` for "fits at all".
    static func approxMaxParamsB(gpuCeilingBytes: Int64, comfortable: Bool) -> Int {
        let bytesPerParam = 0.6
        let kvAllowance = 1_500_000_000.0
        let budget = Double(gpuCeilingBytes) * (comfortable ? comfortableFraction : 1.0)
            - kvAllowance - Double(overheadBytes(for: .llamaCpp))
        let params = max(0, budget / bytesPerParam / 1e9)
        // Round down to a figure that doesn't claim false precision.
        return params >= 20 ? Int(params / 5) * 5 : Int(params)
    }

    /// RAM_needed = W + KV(C) + O, where KV(C) = 2 · L · H_kv · d · b · C for a model whose layers are all alike.
    ///
    /// `b` is `kvCache.bytesPerElement`: 2 for the engines' default f16 cache, about 1 or 0.56 when a model is set
    /// to a quantized one (ADR D-057). Not read from model metadata: it's a setting, not a model property.
    static func ramNeeded(
        model: ModelShape,
        contextSize: Int,
        kvCache: KVCacheSetting = .full,
        overheadBytes: Int64
    ) -> Int64 {
        model.weightBytes + kvBytes(model, contextSize: contextSize, kvCache: kvCache) + overheadBytes
    }

    /// The keys and values held for `contextSize` tokens, summed over the layers that keep them (ADR D-071).
    /// A layer with a window holds at most that many tokens, and stays at full precision under a quantized
    /// setting, as MLX leaves its rotating caches (ADR D-057).
    static func kvBytes(_ model: ModelShape, contextSize: Int, kvCache: KVCacheSetting) -> Int64 {
        let layers = model.kvLayers
            ?? [ModelShape.KVLayers(
                count: model.layerCount,
                kvHeads: model.kvHeadCount,
                keyValueDim: 2 * model.headDim
            )]
        return layers.reduce(0) { total, group in
            let tokens = group.window.map { min($0, contextSize) } ?? contextSize
            let bytes = group.window == nil ? kvCache.bytesPerElement : KVCacheSetting.full.bytesPerElement
            let perToken = Int64(Double(group.count) * Double(group.kvHeads) * Double(group.keyValueDim) * bytes)
            return total + perToken * Int64(tokens)
        }
    }

    /// The largest context up to `limit` whose cache fits in `budget` bytes; 0 if none does.
    static func largestContext(_ model: ModelShape, fitting budget: Int64, kvCache: KVCacheSetting, limit: Int) -> Int {
        guard budget >= 0 else { return 0 }
        guard kvBytes(model, contextSize: limit, kvCache: kvCache) > budget else { return limit }
        // KV grows with the context, so the largest that fits is found by halving the range.
        var low = 0, high = limit
        while low < high {
            let middle = (low + high + 1) / 2
            if kvBytes(model, contextSize: middle, kvCache: kvCache) <= budget {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// The verdict, RAM figure, and (when the chip is recognized) speed
    /// estimate for running `model` on `device` under `runtime`, at
    /// `requestedContextSize` (default 8,192, per ARCHITECTURE.md §7).
    ///
    /// `bandwidthTable` is a chip-name → GB/s lookup, ordinarily loaded
    /// from `Resources/catalog.json`'s `chipBandwidthGBps` key via
    /// `ChipBandwidthTable.loadFromBundle()` — passed in explicitly here
    /// so this stays a pure function for testing.
    ///
    /// Returns `nil` if `device.gpuWorkingSetCeilingBytes` is unavailable
    /// — nothing in the formula works without a ceiling to compare
    /// against.
    static func estimate(
        model: ModelShape,
        device: DeviceInfo,
        runtime: RuntimeID,
        requestedContextSize: Int = FitEstimator.defaultContextSize,
        kvCache: KVCacheSetting = .full,
        bandwidthTable: [String: Double] = [:]
    ) -> FitEstimate? {
        guard let ceiling = device.gpuWorkingSetCeilingBytes else { return nil }
        let overhead = overheadBytes(for: runtime)

        let verdict: FitVerdict
        let contextForRAMFigure: Int

        // "Won't fit" is defined by ARCHITECTURE.md §7 specifically as
        // weights alone exceeding the ceiling — not weights plus overhead
        // plus KV cache. A model whose weights just barely fit but whose
        // overhead pushes it over ends up as `.tight` with a
        // `reducedContextSize` of 0 instead: still unusable in practice,
        // but that's a distinct (and much rarer) edge case from "the
        // weights themselves don't fit", which is what this verdict is
        // for.
        if model.weightBytes > ceiling {
            verdict = .wontFit
            contextForRAMFigure = 0
        } else {
            let neededAtRequested = ramNeeded(
                model: model, contextSize: requestedContextSize, kvCache: kvCache, overheadBytes: overhead
            )
            let comfortableCeiling = Int64(Double(ceiling) * comfortableFraction)

            if neededAtRequested <= comfortableCeiling {
                verdict = .comfortable
                contextForRAMFigure = requestedContextSize
            } else {
                // The largest context that fits under the full
                // (not comfortable-fraction) ceiling: ceiling >= W + O + KV(C).
                let reduced = largestContext(
                    model, fitting: ceiling - model.weightBytes - overhead, kvCache: kvCache,
                    limit: max(0, requestedContextSize)
                )
                verdict = .tight(reducedContextSize: reduced)
                contextForRAMFigure = reduced
            }
        }

        let ramNeededBytes = ramNeeded(
            model: model, contextSize: contextForRAMFigure, kvCache: kvCache, overheadBytes: overhead
        )

        let tokPerSec = device.chipName
            .flatMap { bandwidthTable[$0] }
            .map { speedEstimate(model: model, bandwidthGBps: $0) }

        var result = FitEstimate(verdict: verdict, ramNeededBytes: ramNeededBytes, estimatedTokensPerSecond: tokPerSec)
        if case let .tight(reduced) = verdict, kvCache == .full,
           let quantized = estimate(
               model: model, device: device, runtime: runtime, requestedContextSize: requestedContextSize, kvCache: .q4
           )
        {
            let fitting = switch quantized.verdict {
            case .comfortable: requestedContextSize
            case let .tight(context): context
            case .wontFit: 0
            }
            if fitting > reduced {
                result.contextWith4BitKV = fitting
            }
        }
        return result
    }

    /// tok/s ≈ 0.7 × bandwidth / active_bytes_per_token, per
    /// ARCHITECTURE.md §7. `active_bytes_per_token` is
    /// `model.activeWeightBytes` when set (MoE), else the full
    /// `model.weightBytes` (dense).
    static func speedEstimate(model: ModelShape, bandwidthGBps: Double) -> Double {
        let activeBytes = Double(model.activeWeightBytes ?? model.weightBytes)
        guard activeBytes > 0 else { return 0 }
        let bandwidthBytesPerSecond = bandwidthGBps * 1_000_000_000
        return 0.7 * bandwidthBytesPerSecond / activeBytes
    }
}

/// Loads the chip → GB/s bandwidth lookup from the curated catalog
/// resource (`Resources/catalog.json`'s `chipBandwidthGBps` key) — the
/// only piece of that file this phase needs. The full curated-models
/// schema (`families`, `ramTiersGB`, ...) is Phase 2 step 6's `Catalog.swift`
/// to parse; this deliberately only decodes the one key it needs, so
/// fields added there later can't break this loader.
enum ChipBandwidthTable {
    private struct RawCatalog: Decodable {
        var chipBandwidthGBps: [String: Double]
    }

    /// Returns an empty table (never throws) if the resource is missing
    /// or malformed — an unrecognized chip already means "no speed
    /// estimate" per `FitEstimator.estimate`, so a totally empty table
    /// degrades the same way a partially-missing one would.
    static func loadFromBundle(_ bundle: Bundle = .main) -> [String: Double] {
        guard let url = bundle.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(RawCatalog.self, from: data)
        else {
            return [:]
        }
        return raw.chipBandwidthGBps
    }
}

extension DeviceInfo {
    /// "Apple M4 Pro · 64 GB · comfortable up to ~55B" — from the measured GPU ceiling (see
    /// `FitEstimator.approxMaxParamsB`), never the catalog tier's open-ended upper bound, which once rendered as
    /// "showing 35–999B models". The Add Model sheet's header and the Models page's first line.
    var summaryLine: String {
        var parts: [String] = []
        if let chipName {
            parts.append(chipName)
        }
        if let unifiedMemoryBytes {
            parts.append("\(Int(Double(unifiedMemoryBytes) / 1_073_741_824)) GB")
        }
        if let gpuWorkingSetCeilingBytes {
            let maxParams = FitEstimator.approxMaxParamsB(gpuCeilingBytes: gpuWorkingSetCeilingBytes, comfortable: true)
            parts.append("comfortable up to ~\(maxParams)B")
        }
        return parts.joined(separator: " · ")
    }
}
