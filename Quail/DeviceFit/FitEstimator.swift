import Foundation

/// The subset of a model's own shape `FitEstimator`'s formula needs,
/// independent of which format (GGUF or MLX) it came from. `weightBytes`
/// isn't part of either metadata parser's output — it's a file size, not
/// a header field — so every initializer takes it separately.
struct ModelShape: Sendable, Equatable {
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

    /// Builds a `ModelShape` from a GGUF header. `headDim` prefers
    /// `keyLength` (`<arch>.attention.key_length`) when the architecture
    /// writes one explicitly, falling back to `embeddingLength / headCount`
    /// otherwise — see `GGUFMetadata.keyLength`'s doc comment for why that
    /// fallback isn't always correct, but it's the best available when the
    /// explicit key is missing. Returns `nil` if a required field is
    /// missing.
    static func from(gguf metadata: GGUFMetadata, weightBytes: Int64) -> ModelShape? {
        guard let layerCount = metadata.blockCount, let kvHeadCount = metadata.headCountKV else {
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
            )
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
            )
        )
    }

    private static func activeWeightBytes(total: Int64, used: Int?, of experts: Int?) -> Int64? {
        guard let used, let experts, experts > 0 else { return nil }
        return total * Int64(used) / Int64(experts)
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
    /// runtimes".
    static func overheadBytes(for runtime: RuntimeID) -> Int64 {
        switch runtime {
        case .llamaCpp: 1_500_000_000
        case .omlx, .rapidMLX: 2_500_000_000
        }
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
    /// `kvCacheBytesPerElement` is `b` — 2 for an f16 KV cache, 1 for q8.
    /// Not read from model metadata: it's a cache-quantization setting,
    /// not a model property. llama.cpp's own `--cache-type-k` default is
    /// f16 (confirmed against the vendored binary's own `-ctk`/`-ctkd`
    /// flag strings), and nothing in Quail sets it to anything else yet,
    /// so 2 is the only value any real caller passes today.
    static func ramNeeded(
        model: ModelShape,
        contextSize: Int,
        kvCacheBytesPerElement: Int64 = 2,
        overheadBytes: Int64
    ) -> Int64 {
        let kvCacheBytes = 2 * Int64(model.layerCount) * Int64(model.kvHeadCount)
            * Int64(model.headDim) * kvCacheBytesPerElement * Int64(contextSize)
        return model.weightBytes + kvCacheBytes + overheadBytes
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
        kvCacheBytesPerElement: Int64 = 2,
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
                model: model, contextSize: requestedContextSize,
                kvCacheBytesPerElement: kvCacheBytesPerElement, overheadBytes: overhead
            )
            let comfortableCeiling = Int64(Double(ceiling) * comfortableFraction)

            if neededAtRequested <= comfortableCeiling {
                verdict = .comfortable
                contextForRAMFigure = requestedContextSize
            } else {
                // Solve for the largest context that fits under the full
                // (not comfortable-fraction) ceiling:
                // ceiling >= W + O + 2*L*Hkv*d*b*C
                let perTokenBytes = 2 * Int64(model.layerCount) * Int64(model.kvHeadCount)
                    * Int64(model.headDim) * kvCacheBytesPerElement
                let budget = ceiling - model.weightBytes - overhead
                let fittingContext = perTokenBytes > 0 ? Int(budget / perTokenBytes) : requestedContextSize
                let reduced = max(0, min(fittingContext, requestedContextSize))
                verdict = .tight(reducedContextSize: reduced)
                contextForRAMFigure = reduced
            }
        }

        let ramNeededBytes = ramNeeded(
            model: model, contextSize: contextForRAMFigure,
            kvCacheBytesPerElement: kvCacheBytesPerElement, overheadBytes: overhead
        )

        let tokPerSec = device.chipName
            .flatMap { bandwidthTable[$0] }
            .map { speedEstimate(model: model, bandwidthGBps: $0) }

        return FitEstimate(verdict: verdict, ramNeededBytes: ramNeededBytes, estimatedTokensPerSecond: tokPerSec)
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
