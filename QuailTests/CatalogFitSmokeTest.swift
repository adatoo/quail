import Foundation
import Testing
@testable import Quail

/// Real-network check that every curated GGUF family in the bundled
/// catalog gets an actual fit verdict in the Add-model sheet — not
/// "Fit unknown". Catches a catalog edit pointing at a missing quant, a
/// header too big to preview, or an architecture the estimate can't read.
///
/// **Never runs in CI** (live Hub, ~8 MB per family). Opt in with:
///
/// ```
/// touch /tmp/quail-smoke-catalog-enabled
/// xcodebuild -scheme Quail test -only-testing:QuailTests/CatalogFitSmokeTest
/// rm /tmp/quail-smoke-catalog-enabled
/// ```
@Suite("CatalogFitSmokeTest (manual only — see file header)", .timeLimit(.minutes(10)))
struct CatalogFitSmokeTest {
    @Test("every curated GGUF family resolves to a real verdict against the live Hub")
    func everyFamilyHasAVerdict() async {
        guard FileManager.default.fileExists(atPath: "/tmp/quail-smoke-catalog-enabled") else {
            print("sentinel missing; skipping. See this file's header.")
            return
        }
        let catalog = Catalog.bundled()
        let downloader = HFDownloader()
        let device = DeviceInfo.current()
        let bandwidth = ChipBandwidthTable.loadFromBundle()

        var verdicts: [String: FitEstimate] = [:]
        for family in catalog.families where family.gguf != nil {
            let fit = await ModelPreview.catalogFit(
                family: family, downloader: downloader, device: device,
                ggufRuntime: .llamaCpp, bandwidthTable: bandwidth, token: nil
            )
            print("catalog-fit \(family.id): \(fit)")
            if case let .estimate(estimate) = fit, let repo = family.gguf?.repo {
                verdicts[repo] = estimate
                continue
            }
            Issue.record("\(family.id) (\(family.gguf?.repo ?? "")): \(fit)")
        }
        let recommended = Recommender.finalize(
            candidates: Recommender.candidates(catalog: catalog, device: device), verdicts: verdicts
        )
        print("catalog-fit recommended on this Mac: \(recommended.map(\.id))")
    }
}
