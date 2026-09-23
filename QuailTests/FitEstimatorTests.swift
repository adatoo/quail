import Foundation
import Testing
@testable import Quail

@Suite("FitEstimator")
struct FitEstimatorTests {
    /// A 16 GB Mac's GPU ceiling: roughly 75% of 16 GiB (17,179,869,184
    /// bytes), matching ARCHITECTURE.md §7's "about 75% of RAM by default"
    /// for MTLDevice.recommendedMaxWorkingSetSize.
    private static let sixteenGB = DeviceInfo(
        chipName: "Apple M2",
        performanceCoreCount: 4,
        efficiencyCoreCount: 4,
        unifiedMemoryBytes: 17_179_869_184,
        gpuWorkingSetCeilingBytes: 12_884_901_888,
        freeMemoryBytes: 10_000_000_000
    )

    /// An 8B model at Q4_K_M: file size close to real-world (Llama 3.1 8B
    /// Q4_K_M is ~4.9 GB on disk), llama-family shape (32 layers, 8 KV
    /// heads, head dim 128 — hidden 4096 / 32 heads).
    private static let eightBQ4KM = ModelShape(
        weightBytes: 4_900_000_000,
        layerCount: 32,
        kvHeadCount: 8,
        headDim: 128
    )

    /// A 32B model at Q4_K_M: file size close to real-world (Qwen 32B
    /// Q4_K_M is ~19 GB on disk) — deliberately larger than the 16 GB
    /// machine's entire GPU ceiling.
    private static let thirtyTwoBQ4KM = ModelShape(
        weightBytes: 19_000_000_000,
        layerCount: 64,
        kvHeadCount: 8,
        headDim: 128
    )

    // MARK: - The plan's own two canonical scenarios

    @Test("8B Q4_K_M on 16 GB is Comfortable at the default 8K context")
    func eightBOnSixteenGBIsComfortable() throws {
        let estimate = try #require(FitEstimator.estimate(
            model: Self.eightBQ4KM, device: Self.sixteenGB, runtime: .llamaCpp
        ))

        #expect(estimate.verdict == .comfortable)
        // Sanity-check the actual RAM figure independently of the verdict
        // logic: weights (4.9e9) + KV cache (2*32*8*128*2*8192 =
        // 1,073,741,824) + llama.cpp overhead (1.5e9).
        #expect(estimate.ramNeededBytes == 4_900_000_000 + 1_073_741_824 + 1_500_000_000)
    }

    @Test("32B Q4_K_M on 16 GB is Won't fit")
    func thirtyTwoBOnSixteenGBWontFit() throws {
        let estimate = try #require(FitEstimator.estimate(
            model: Self.thirtyTwoBQ4KM, device: Self.sixteenGB, runtime: .llamaCpp
        ))

        #expect(estimate.verdict == .wontFit)
        // Weights alone (19 GB) already exceed the ceiling (12,884,901,888
        // bytes ≈ 12 GB). The RAM figure still includes the runtime's
        // fixed overhead (always incurred) but no KV cache (context 0) —
        // no context helps once weights alone don't fit.
        let expectedRAMNeeded: Int64 = 19_000_000_000 + 1_500_000_000
        #expect(estimate.ramNeededBytes == expectedRAMNeeded)
    }

    // MARK: - Tight

    @Test("a model that clears the ceiling but not the comfortable threshold is Tight with a reduced context")
    func tightVerdictReducesContext() throws {
        // 11 GB weights + 1.5 GB llama.cpp overhead already leaves only
        // ~384.9 MB of the 16 GB machine's ceiling for KV cache — well
        // past the comfortable threshold (70% of ceiling ≈ 9.02 GB) at the
        // default 8K context, but the weights themselves are still under
        // the full ceiling.
        let model = ModelShape(weightBytes: 11_000_000_000, layerCount: 32, kvHeadCount: 8, headDim: 128)

        let estimate = try #require(FitEstimator.estimate(model: model, device: Self.sixteenGB, runtime: .llamaCpp))

        guard case let .tight(reducedContextSize) = estimate.verdict else {
            Issue.record("expected .tight, got \(estimate.verdict)")
            return
        }
        // perTokenBytes = 2*32*8*128*2 = 131,072; budget = ceiling -
        // weights - overhead = 12,884,901,888 - 11,000,000,000 -
        // 1,500,000,000 = 384,901,888; 384,901,888 / 131,072 = 2936
        // (integer division).
        #expect(reducedContextSize == 2936)
        #expect(reducedContextSize < FitEstimator.defaultContextSize)
    }

    // MARK: - Per-runtime overhead changes the verdict

    @Test("the same model can be Comfortable under llama.cpp but Tight under a Python runtime's higher overhead")
    func perRuntimeOverheadChangesVerdict() throws {
        // Sized so llama.cpp's 1.5 GB overhead keeps it comfortable but a
        // Python runtime's 2.5 GB overhead (1 GB more) pushes it over the
        // comfortable threshold (70% of the 16 GB machine's ceiling ≈
        // 9.02 GB): needed = 6 GB weights + ~1.07 GB KV cache + overhead.
        let model = ModelShape(weightBytes: 6_000_000_000, layerCount: 32, kvHeadCount: 8, headDim: 128)

        let underLlamaCpp = try #require(FitEstimator.estimate(
            model: model,
            device: Self.sixteenGB,
            runtime: .llamaCpp
        ))
        let underOMLX = try #require(FitEstimator.estimate(model: model, device: Self.sixteenGB, runtime: .omlx))

        #expect(underLlamaCpp.verdict == .comfortable)
        #expect(underOMLX.verdict != .comfortable)
    }

    @Test("overheadBytes matches ARCHITECTURE.md §7's ~1.5 GB llama.cpp / ~2.5 GB Python runtime figures")
    func overheadBytesPerRuntime() {
        #expect(FitEstimator.overheadBytes(for: .llamaCpp) == 1_500_000_000)
        #expect(FitEstimator.overheadBytes(for: .omlx) == 2_500_000_000)
        #expect(FitEstimator.overheadBytes(for: .rapidMLX) == 2_500_000_000)
    }

    // MARK: - No GPU ceiling means no estimate

    @Test("estimate returns nil when the device has no GPU working set ceiling")
    func nilCeilingReturnsNilEstimate() {
        let device = DeviceInfo(chipName: "Apple M2", gpuWorkingSetCeilingBytes: nil)

        let estimate = FitEstimator.estimate(model: Self.eightBQ4KM, device: device, runtime: .llamaCpp)

        #expect(estimate == nil)
    }

    // MARK: - Speed estimate

    @Test("speedEstimate for a dense model uses the full weight size")
    func denseSpeedEstimate() {
        // 0.7 * (273 GB/s in bytes) / 4.9e9 bytes.
        let tokPerSec = FitEstimator.speedEstimate(model: Self.eightBQ4KM, bandwidthGBps: 273)

        let expected = 0.7 * 273_000_000_000 / 4_900_000_000
        #expect(abs(tokPerSec - expected) < 0.001)
        // Sanity: a plausible real-world figure (community-reported 8B
        // Q4_K_M speeds on M-series chips are roughly in this range).
        #expect(tokPerSec > 20 && tokPerSec < 60)
    }

    @Test("speedEstimate for a MoE model uses activeWeightBytes, not the full weight size, and is faster")
    func moeSpeedEstimateUsesActiveBytesOnly() {
        // Same total file size as a dense model, but only ~1/6th active
        // per token (e.g. 8 of 48 experts) — decode should be much faster
        // than a dense model of the same total size.
        let moeModel = ModelShape(
            weightBytes: 19_000_000_000,
            layerCount: 48,
            kvHeadCount: 8,
            headDim: 128,
            activeWeightBytes: 19_000_000_000 / 6
        )
        let denseModelSameSize = ModelShape(weightBytes: 19_000_000_000, layerCount: 48, kvHeadCount: 8, headDim: 128)

        let moeTokPerSec = FitEstimator.speedEstimate(model: moeModel, bandwidthGBps: 273)
        let denseTokPerSec = FitEstimator.speedEstimate(model: denseModelSameSize, bandwidthGBps: 273)

        #expect(moeTokPerSec > denseTokPerSec)
        #expect(abs(moeTokPerSec - denseTokPerSec * 6) < 0.01)
    }

    @Test("estimate has no speed figure for a chip missing from the bandwidth table")
    func unknownChipHasNoSpeedEstimate() throws {
        let device = DeviceInfo(chipName: "Apple M97 Ultra Extreme", gpuWorkingSetCeilingBytes: 12_884_901_888)

        let estimate = try #require(FitEstimator.estimate(
            model: Self.eightBQ4KM, device: device, runtime: .llamaCpp,
            bandwidthTable: ["Apple M4 Pro": 273]
        ))

        #expect(estimate.estimatedTokensPerSecond == nil)
    }

    @Test("estimate includes a speed figure for a chip present in the bandwidth table")
    func knownChipHasSpeedEstimate() throws {
        let device = DeviceInfo(chipName: "Apple M4 Pro", gpuWorkingSetCeilingBytes: 12_884_901_888)

        let estimate = try #require(FitEstimator.estimate(
            model: Self.eightBQ4KM, device: device, runtime: .llamaCpp,
            bandwidthTable: ["Apple M4 Pro": 273]
        ))

        #expect(estimate.estimatedTokensPerSecond != nil)
    }

    // MARK: - ModelShape adapters

    @Test("ModelShape.from(gguf:) prefers keyLength over the computed embeddingLength/headCount fallback")
    func modelShapeFromGGUFPrefersKeyLength() throws {
        var metadata = GGUFMetadata()
        metadata.blockCount = 42
        metadata.headCountKV = 8
        metadata.embeddingLength = 3584
        metadata.headCount = 16 // 3584/16 = 224, but keyLength below disagrees
        metadata.keyLength = 256

        let shape = try #require(ModelShape.from(gguf: metadata, weightBytes: 5_000_000_000))

        #expect(shape.headDim == 256)
        #expect(shape.layerCount == 42)
        #expect(shape.kvHeadCount == 8)
        #expect(shape.weightBytes == 5_000_000_000)
        #expect(shape.activeWeightBytes == nil)
    }

    @Test("ModelShape.from(gguf:) falls back to embeddingLength/headCount when keyLength is absent")
    func modelShapeFromGGUFFallsBackToComputedHeadDim() throws {
        var metadata = GGUFMetadata()
        metadata.blockCount = 32
        metadata.headCountKV = 8
        metadata.embeddingLength = 4096
        metadata.headCount = 32

        let shape = try #require(ModelShape.from(gguf: metadata, weightBytes: 4_900_000_000))

        #expect(shape.headDim == 128)
    }

    @Test("ModelShape.from(gguf:) computes activeWeightBytes from expert fields")
    func modelShapeFromGGUFComputesActiveWeightBytes() throws {
        var metadata = GGUFMetadata()
        metadata.blockCount = 48
        metadata.headCountKV = 8
        metadata.keyLength = 128
        metadata.expertCount = 128
        metadata.expertUsedCount = 8

        let shape = try #require(ModelShape.from(gguf: metadata, weightBytes: 18_000_000_000))

        // 8/128 = 1/16. Pre-typed as Int64, rather than inlining the
        // division directly in #expect — Swift Testing's macro
        // mis-evaluates an Optional<Int64> == <untyped literal division>
        // comparison inline (confirmed: the same comparison as a plain
        // `if` statement outside the macro returns the correct `true`).
        let expected: Int64 = 18_000_000_000 / 16
        #expect(shape.activeWeightBytes == expected)
    }

    @Test("ModelShape.from(gguf:) returns nil when a required field is missing")
    func modelShapeFromGGUFReturnsNilWhenIncomplete() {
        var metadata = GGUFMetadata()
        metadata.blockCount = 32
        // headCountKV missing entirely.

        #expect(ModelShape.from(gguf: metadata, weightBytes: 1_000_000_000) == nil)
    }

    @Test("ModelShape.from(mlx:) uses the config's fields directly")
    func modelShapeFromMLX() throws {
        var metadata = MLXMetadata()
        metadata.hiddenLayers = 28
        metadata.headCountKV = 4
        metadata.headDim = 128
        metadata.numLocalExperts = 8
        metadata.numExpertsPerToken = 2

        let shape = try #require(ModelShape.from(mlx: metadata, weightBytes: 4_500_000_000))

        #expect(shape.layerCount == 28)
        #expect(shape.kvHeadCount == 4)
        #expect(shape.headDim == 128)
        // 2/8 = 1/4. Pre-typed, same reason as the GGUF equivalent test
        // above.
        let expectedActiveWeightBytes: Int64 = 4_500_000_000 / 4
        #expect(shape.activeWeightBytes == expectedActiveWeightBytes)
    }

    @Test("ModelShape.from(mlx:) returns nil when headDim is missing")
    func modelShapeFromMLXReturnsNilWhenIncomplete() {
        var metadata = MLXMetadata()
        metadata.hiddenLayers = 28
        metadata.headCountKV = 4
        // headDim missing entirely (neither explicit nor computable, since
        // MLXMetadata.read is what would have computed it — a hand-built
        // MLXMetadata with nothing set has no headDim at all).

        #expect(ModelShape.from(mlx: metadata, weightBytes: 1_000_000_000) == nil)
    }

    // MARK: - ChipBandwidthTable

    @Test("ChipBandwidthTable.loadFromBundle decodes a real catalog.json's chipBandwidthGBps table")
    func loadsBandwidthTableFromABundle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-catalog-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let json = """
        { "chipBandwidthGBps": { "Apple M4 Pro": 273, "Apple M1": 68.25 } }
        """
        try json.write(to: directory.appendingPathComponent("catalog.json"), atomically: true, encoding: .utf8)

        let bundle = try #require(Bundle(url: directory))
        let table = ChipBandwidthTable.loadFromBundle(bundle)

        #expect(table["Apple M4 Pro"] == 273)
        #expect(table["Apple M1"] == 68.25)
    }

    @Test("ChipBandwidthTable.loadFromBundle returns an empty table when catalog.json is missing")
    func loadsEmptyTableWhenResourceMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-empty-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = try #require(Bundle(url: directory))
        let table = ChipBandwidthTable.loadFromBundle(bundle)

        #expect(table.isEmpty)
    }

    @Test("the real shipped Resources/catalog.json decodes and matches this machine's chip if known")
    func realShippedCatalogDecodes() throws {
        // Bypasses Bundle entirely (QuailTests isn't hosted inside Quail.app,
        // so Bundle.main here is the xctest runner, not Quail's own bundle —
        // see ChipBandwidthTable's doc comment) to guard the real file's
        // schema directly against whatever this repo actually ships.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // QuailTests/
            .deletingLastPathComponent() // repo root
        let catalogURL = repoRoot.appendingPathComponent("Quail/Resources/catalog.json")
        let data = try Data(contentsOf: catalogURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let bandwidthTable = try #require(json?["chipBandwidthGBps"] as? [String: Any])

        #expect((bandwidthTable["Apple M4 Pro"] as? Double) == 273)
        #expect(bandwidthTable.count >= 10)
    }

    @Test("approxMaxParamsB: a 64 GB Mac's real ceiling gives ~55B comfortable, ~85B max — never a sentinel like 999")
    func approxMaxParams() {
        let ceiling: Int64 = 55_662_805_000 // 51.84 GB, as measured on a 64 GB M4 Pro
        #expect(FitEstimator.approxMaxParamsB(gpuCeilingBytes: ceiling, comfortable: true) == 55)
        #expect(FitEstimator.approxMaxParamsB(gpuCeilingBytes: ceiling, comfortable: false) == 85)
        #expect(FitEstimator.approxMaxParamsB(gpuCeilingBytes: 16_000_000_000, comfortable: true) == 13)
        #expect(FitEstimator.approxMaxParamsB(gpuCeilingBytes: 1_000_000_000, comfortable: true) == 0)
    }

    @Test("a GGUF without head_count_kv (BERT-style) uses head_count, as llama.cpp does")
    func missingKVHeadsFallsBackToHeadCount() throws {
        var metadata = GGUFMetadata()
        metadata.architecture = "nomic-bert"
        metadata.blockCount = 12
        metadata.headCount = 12
        metadata.embeddingLength = 768
        let shape = try #require(ModelShape.from(gguf: metadata, weightBytes: 140_000_000))
        #expect(shape.kvHeadCount == 12)
        #expect(shape.headDim == 64)
    }

    @Test("contextLabel renders token counts as K")
    func contextLabel() {
        #expect(RemoteFitBadge.contextLabel(4096) == "4K")
        #expect(RemoteFitBadge.contextLabel(1536) == "1.5K")
    }

    // MARK: - Context size (ADR D-020)

    @Test("automaticContextSize: largest comfortable of 32K/16K/8K — 16K for 8B Q4_K_M on a 16 GB Mac")
    func automaticContext() {
        #expect(FitEstimator
            .automaticContextSize(model: Self.eightBQ4KM, device: Self.sixteenGB, runtime: .llamaCpp) == 16384)
        var small = Self.eightBQ4KM
        small.weightBytes = 700_000_000
        #expect(FitEstimator.automaticContextSize(model: small, device: Self.sixteenGB, runtime: .llamaCpp) == 32768)
        small.trainedContext = 8192 // never above what the model was trained for
        #expect(FitEstimator.automaticContextSize(model: small, device: Self.sixteenGB, runtime: .llamaCpp) == 8192)
        #expect(FitEstimator.automaticContextSize(
            model: Self.thirtyTwoBQ4KM,
            device: Self.sixteenGB,
            runtime: .llamaCpp
        ) == nil)
    }

    @Test("contextOptions: 4K–128K, capped at the trained context, which is itself offered")
    func contextOptions() {
        #expect(FitEstimator.contextOptions(trainedContext: nil) == [4096, 8192, 16384, 32768, 65536, 131_072])
        #expect(FitEstimator.contextOptions(trainedContext: 40960) == [4096, 8192, 16384, 32768, 40960])
        #expect(FitEstimator.contextOptions(trainedContext: 2048) == [2048])
    }
}
