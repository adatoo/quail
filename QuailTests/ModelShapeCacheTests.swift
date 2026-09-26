import Foundation
import Testing
@testable import Quail

@Suite("Model shape cache")
struct ModelShapeCacheTests {
    private static let shape = ModelShape(
        weightBytes: 5_000_000_000, layerCount: 36, kvHeadCount: 8, headDim: 128, activeWeightBytes: nil,
        trainedContext: 40960
    )

    private final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000_000)
    }

    @Test("a stored shape comes back, survives a reload from disk, and expires after 30 days")
    func storeReloadExpire() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("shapes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let clock = Clock()
        let key = ModelShapeCache.key(repo: "org/m", format: .gguf, file: "m.gguf")
        let cache = ModelShapeCache(url: file, now: { clock.date })
        #expect(cache.shape(for: key) == nil)
        cache.store(Self.shape, for: key)
        #expect(cache.shape(for: key) == Self.shape)

        let reopened = ModelShapeCache(url: file, now: { clock.date })
        #expect(reopened.shape(for: key) == Self.shape)
        clock.date += ModelShapeCache.lifetime + 1
        #expect(reopened.shape(for: key) == nil)
    }

    @Test("a cached catalog family gets its verdict without asking Hugging Face")
    func catalogFitUsesTheCache() async throws {
        let cache = ModelShapeCache(url: nil)
        let family = Catalog.Family(
            id: "m", name: "M", paramsB: 8,
            gguf: .init(repo: "org/M-GGUF", quants: ["Q4_K_M"], defaultQuant: "Q4_K_M"),
            isCurated: true
        )
        cache.store(Self.shape, for: ModelShapeCache.key(repo: "org/M-GGUF", format: .gguf, file: "quant:Q4_K_M"))
        // A downloader pointed at nowhere: any request would fail and show "Couldn't reach Hugging Face".
        let downloader = try HFDownloader(hubBaseURL: #require(URL(string: "http://127.0.0.1:9")))
        let fit = await ModelPreview.catalogFit(
            family: family, downloader: downloader, device: DeviceInfo.current(), ggufRuntime: .llamaCpp,
            bandwidthTable: [:], token: nil, cache: cache
        )
        if case .estimate = fit {} else {
            Issue.record("expected an estimate from the cache, got \(fit)")
        }
    }
}
