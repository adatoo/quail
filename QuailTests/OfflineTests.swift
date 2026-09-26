import Foundation
import Testing
@testable import Quail

/// ADR D-051: with no internet connection, Hugging Face lookups say "offline" in plain words, the
/// Add Model list stops asking after the first one, and what's cached still gets a verdict.
@Suite("Offline", .timeLimit(.minutes(1)))
struct OfflineTests {
    /// Nothing listens on port 9 (discard), so every request is refused at once — as with no network.
    private static func unreachableDownloader() throws -> HFDownloader {
        try HFDownloader(hubBaseURL: #require(URL(string: "http://127.0.0.1:9")))
    }

    private static let shape = ModelShape(
        weightBytes: 5_000_000_000, layerCount: 36, kvHeadCount: 8, headDim: 128, activeWeightBytes: nil,
        trainedContext: 40960
    )

    @Test("connection failures become .offline; a server's refusal doesn't")
    func mapping() {
        for code: URLError.Code in [
            .notConnectedToInternet,
            .cannotConnectToHost,
            .cannotFindHost,
            .timedOut,
            .networkConnectionLost,
            .dnsLookupFailed,
        ] {
            #expect(HFDownloader.offline(URLError(code)) as? HFDownloadError == .offline, "\(code)")
        }
        // What a firewall (or the offline check's sandbox) hands back.
        #expect(HFDownloader.offline(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))) as? HFDownloadError
            == .offline)
        #expect(HFDownloader.offline(URLError(.badServerResponse)) as? URLError == URLError(.badServerResponse))
        #expect(HFDownloader.offline(HFDownloadError.httpStatus(404)) as? HFDownloadError == .httpStatus(404))
        #expect(ModelInstallController.describe(.offline).contains("no internet connection"))
    }

    @Test("listing and fit checks report offline, not a raw URLError")
    func listingAndFit() async throws {
        let downloader = try Self.unreachableDownloader()
        await #expect(throws: HFDownloadError.offline) {
            _ = try await downloader.listFiles(repo: "org/model")
        }
        let family = Catalog.Family(
            id: "m", name: "M", paramsB: 8,
            gguf: .init(repo: "org/M-GGUF", quants: ["Q4_K_M"], defaultQuant: "Q4_K_M"),
            isCurated: true
        )
        let fit = await ModelPreview.catalogFit(
            family: family, downloader: downloader, device: DeviceInfo.current(), ggufRuntime: .llamaCpp,
            bandwidthTable: [:], token: nil, cache: ModelShapeCache(url: nil)
        )
        #expect(fit == .offline)
    }

    @Test("the Add Model list goes offline after the first failure; cached families still get verdicts")
    @MainActor
    func catalogVerdictsOffline() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-offline-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let cache = ModelShapeCache(url: nil)
        let appState = try AppState(
            config: Config(),
            configURL: scratch.appendingPathComponent("config.json"),
            secretStore: FakeSecretStore(),
            runtime: FakeRuntime(launchSpec: LaunchSpec(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
                currentDirectoryURL: nil
            )),
            modelsRootURL: scratch.appendingPathComponent("Models", isDirectory: true),
            catalogLocations: .init(bundle: .main, directory: scratch),
            shapeCache: cache,
            downloader: Self.unreachableDownloader(),
            serverPreflight: nil
        )
        // One family looked up on an earlier, online day.
        let cached = try #require(appState.catalog.families.last { family in
            family.gguf.flatMap { $0.defaultQuant ?? $0.quants.first } != nil
        })
        let gguf = try #require(cached.gguf)
        let quant = try #require(gguf.defaultQuant ?? gguf.quants.first)
        cache.store(Self.shape, for: ModelShapeCache.key(repo: gguf.repo, format: .gguf, file: "quant:\(quant)"))

        await appState.loadCatalogVerdicts()

        #expect(appState.hubOffline)
        if case .estimate = appState.catalogFits[cached.id] {} else {
            Issue
                .record(
                    "the cached family should still have a verdict: \(String(describing: appState.catalogFits[cached.id]))"
                )
        }
        for family in appState.catalog.families where family.id != cached.id {
            #expect(appState.catalogFits[family.id] == .offline, "\(family.id)")
        }
    }
}
