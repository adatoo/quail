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
            trainedContext: metadata.contextLength
        )
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
            trainedContext: metadata.trainedContext
        )
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

    /// RAM_needed = W + 2 · L · H_kv · d · b · C + O
    ///
    /// `b` is `kvCache.bytesPerElement`: 2 for the engines' default f16 cache, about 1 or 0.56 when a model is set
    /// to a quantized one (ADR D-057). Not read from model metadata: it's a setting, not a model property.
    static func ramNeeded(
        model: ModelShape,
        contextSize: Int,
        kvCache: KVCacheSetting = .full,
        overheadBytes: Int64
    ) -> Int64 {
        model.weightBytes + kvBytesPerToken(model, kvCache) * Int64(contextSize) + overheadBytes
    }

    /// 2 · L · H_kv · d · b: one token's keys and values across the layers.
    static func kvBytesPerToken(_ model: ModelShape, _ kvCache: KVCacheSetting) -> Int64 {
        Int64(2 * Double(model.layerCount) * Double(model.kvHeadCount) * Double(model.headDim) * kvCache
            .bytesPerElement)
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
                // Solve for the largest context that fits under the full
                // (not comfortable-fraction) ceiling:
                // ceiling >= W + O + 2*L*Hkv*d*b*C
                let perTokenBytes = kvBytesPerToken(model, kvCache)
                let budget = ceiling - model.weightBytes - overhead
                let fittingContext = perTokenBytes > 0 ? Int(budget / perTokenBytes) : requestedContextSize
                let reduced = max(0, min(fittingContext, requestedContextSize))
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
