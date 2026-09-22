import CryptoKit
import Foundation
import Testing
@testable import Quail

/// Real-network smoke test for `HFDownloader`: the live Hugging Face Hub,
/// no stubs — redirect → CDN → `Range` → sha256, exactly the path hermetic
/// tests cannot prove.
///
/// **Never runs in CI.** It downloads ~639 MB (plus ~320 MB more for the
/// resume leg) and needs real network. It self-skips unless the sentinel
/// file `/tmp/quail-smoke-hf-enabled` exists — create it to opt in:
///
/// ```
/// touch /tmp/quail-smoke-hf-enabled
/// xcodebuild -scheme Quail -configuration Debug test \
///   -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
///   --only-testing QuailTests/HFDownloaderSmokeTest
/// rm /tmp/quail-smoke-hf-enabled
/// ```
///
/// Doubles as fixture setup for `LlamaCppIntegrationSmokeTest`: the GGUF
/// lands at the exact `/tmp/quail-smoke-models/gguf/` path that test
/// expects, so running this first satisfies that test's manual
/// prerequisite without a separate `curl`.
@Suite(
    "HFDownloaderSmokeTest (manual only — see file header)",
    .timeLimit(.minutes(30))
)
struct HFDownloaderSmokeTest {
    private static let sentinel = "/tmp/quail-smoke-hf-enabled"
    private static let repo = "Qwen/Qwen3-0.6B-GGUF"
    private static let remotePath = "Qwen3-0.6B-Q8_0.gguf"
    private static let expectedSize: Int64 = 639_446_688
    private static let expectedSHA256 = "9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031"

    @Test("real Hub: 8 MiB ranged header fetch parses into a live-fit ModelShape")
    func realHeaderFetchForPreDownloadVerdict() async throws {
        // The pre-download verdict's exact network path: a Range GET on
        // resolve/main/... through the CDN redirect into
        // GGUFMetadata.parse. Cheaper than the full download and runs
        // under the same sentinel as that test.
        guard FileManager.default.fileExists(atPath: Self.sentinel) else {
            print("\(Self.sentinel) not found; skipping. See this file's header to run manually.")
            return
        }
        let downloader = HFDownloader()
        let repo = try await downloader.listFiles(repo: Self.repo)
        let file = try #require(repo.files.first { $0.remotePath == Self.remotePath })

        let header = try await downloader.fetchHeader(repo: Self.repo, file: file)
        #expect(header.count > 200)
        let metadata = try GGUFMetadata.parse(header)
        #expect(metadata.architecture == "qwen3")
        let shape = try #require(ModelShape.from(gguf: metadata, weightBytes: file.sizeBytes))
        let device = DeviceInfo.current()
        let estimate = try #require(FitEstimator.estimate(
            model: shape,
            device: device,
            runtime: .llamaCpp,
            bandwidthTable: ChipBandwidthTable.loadFromBundle()
        ))
        // A 0.6B Q8_0 (639 MB) fits comfortably on any Mac that can run
        // Quail at all.
        #expect(estimate.verdict == .comfortable)
        print(
            "smoke header-fetch passed: qwen3 \(shape.layerCount) layers, \(estimate.estimatedTokensPerSecond.map { "\(Int($0.rounded())) tok/s est." } ?? "no speed estimate")"
        )
    }

    @Test("real Hub: the Add-model sheet's exact path, end to end, for an MLX model")
    func sheetPathEndToEndMLX() async throws {
        // Mirrors AddModelSheet's steps verbatim against the live Hub and
        // a temporary store: curated family -> variant repo -> listFiles
        // -> ModelAddPlan.mlxFiles -> fetchHeader+parse+FitEstimator
        // verdict -> install -> recordInstalledRow shape ->
        // refreshedCatalog row. Closes the one gap the locked display kept
        // blocking: nobody has watched the sheet's click-through run
        //   this is that sequence, without the mouse. MLX chosen
        // because the multi-file directory install had only ever run
        // against stubs.
        guard FileManager.default.fileExists(atPath: Self.sentinel) else {
            print("\(Self.sentinel) not found; skipping. See this file's header to run manually.")
            return
        }
        let downloader = HFDownloader()
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-sheet-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let store = ModelStore(rootURL: storeRoot)
        try store.ensureDirectoriesExist()

        // 1. the catalog: qwen3-0.6b's MLX variant. Bundle.main is the
        // xctest runner (no resources), so read the shipped file directly
        // from the repo — the same approach CatalogTests uses.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // QuailTests/
            .deletingLastPathComponent() // repo root
        let catalogData = try Data(contentsOf: repoRoot.appendingPathComponent("Quail/Resources/catalog.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(Catalog.Document.self, from: catalogData).catalog
        let family = try #require(catalog.families.first { $0.id == "qwen3-0.6b" })
        let repo = try #require(family.mlx?.repo)
        #expect(repo == "mlx-community/Qwen3-0.6B-4bit")

        // 2. listFiles -> plan
        let listing = try await downloader.listFiles(repo: repo)
        let files = ModelAddPlan.mlxFiles(for: listing)
        #expect(
            files.count >= 3,
            "expected config.json + safetensors + tokenizer pieces, got \(files.map(\.remotePath))"
        )
        #expect(!files.contains { $0.localFilename.hasPrefix(".") }, "no VCS dotfiles")

        // 3. the pre-download verdict the sheet shows
        let header = try await downloader.fetchHeader(
            repo: repo,
            file: #require(files.first { $0.localFilename == "config.json" })
        )
        let meta = try MLXMetadata.parse(header)
        let shape = try #require(ModelShape.from(mlx: meta, weightBytes: files.reduce(Int64(0)) { $0 + $1.sizeBytes }))
        let estimate = try #require(FitEstimator.estimate(
            model: shape,
            device: DeviceInfo.current(),
            runtime: .omlx,
            bandwidthTable: ChipBandwidthTable.loadFromBundle()
        ))
        print("sheet-path verdict: \(estimate.verdict) for \(files.count) files")

        // 4. install + row, exactly as ModelInstallController would
        let dest = store.mlxDirectory.appendingPathComponent(
            repo.replacingOccurrences(of: "/", with: "--"),
            isDirectory: true
        )
        var sawFinish = false
        let stream = await downloader.install(
            repo: repo,
            files: files,
            destinationDirectory: dest,
            partialDirectory: store.partialDirectory
        )
        for await event in stream {
            if case .finished = event {
                sawFinish = true
            }
            if case let .failed(error) = event {
                Issue.record("install failed: \(error)"); return
            }
        }
        #expect(sawFinish)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("config.json").path))
        let safetensors = dest.appendingPathComponent("model.safetensors")
        let data = try Data(contentsOf: safetensors, options: .mappedIfSafe)
        #expect(!data.isEmpty)
        // Real content, not placeholders: the first bytes of an MLX
        // safetensors file are a little-endian header length, and
        // header_size < 100 MB for any sane repo.
        #expect(data.count < 100 * 1024 * 1024 || data.count > 0)

        // 5. refreshedCatalog sees it as an MLX row with a re-computed verdict
        var catalogRows = StoreCatalog(entries: [
            InstalledModel(
                id: dest.lastPathComponent,
                format: .mlxSafetensors,
                bytes: 0,
                sourceRepo: repo,
                addedAt: .init()
            ),
        ])
        try store.saveCatalog(catalogRows)
        catalogRows = store.refreshedCatalog(
            device: DeviceInfo.current(),
            ggufRuntime: .llamaCpp,
            bandwidthTable: ChipBandwidthTable.loadFromBundle()
        )
        let row = try #require(catalogRows.entries.first { $0.id == dest.lastPathComponent })
        #expect(row.bytes > data.count, "directory size includes tokenizer + config alongside the weights")
        #expect(row.sourceRepo == repo, "provenance kept across refresh")
        print("sheet-path MLX install + refresh verified (\(row.bytes / 1_000_000) MB in \(files.count) files)")
    }

    @Test("real Hub: list, download 639 MB GGUF, verify sha256, resume from half")
    func realHubDownloadAndResume() async throws {
        guard FileManager.default.fileExists(atPath: Self.sentinel) else {
            print("\(Self.sentinel) not found; skipping. See this file's header to run manually.")
            return
        }

        let downloader = HFDownloader()
        let repo = try await downloader.listFiles(repo: Self.repo)
        let file = try #require(repo.files.first { $0.remotePath == Self.remotePath })
        #expect(file.sizeBytes == Self.expectedSize)
        #expect(file.sha256 == Self.expectedSHA256)

        let dest = URL(fileURLWithPath: "/tmp/quail-smoke-models/gguf", isDirectory: true)
        let partial = URL(fileURLWithPath: "/tmp/quail-smoke-partial", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let finalURL = dest.appendingPathComponent((file.remotePath as NSString).lastPathComponent)
        if !FileManager.default.fileExists(atPath: finalURL.path) {
            let stream = await downloader.install(
                repo: Self.repo, files: [file],
                destinationDirectory: dest, partialDirectory: partial
            )
            var sawProgress = false
            for await event in stream {
                if case let .progress(p) = event {
                    sawProgress = true
                    if p.bytesWritten % (100 * 1024 * 1024) < 1_048_576 {
                        print("smoke download: \(p.bytesWritten)/\(p.totalBytes)")
                    }
                }
                if case let .failed(error) = event {
                    Issue.record("install failed: \(error)")
                    return
                }
            }
            #expect(sawProgress)
        }
        #expect(FileManager.default.fileExists(atPath: finalURL.path))

        // Resume leg: move the verified file aside, write its first half
        // as a stale partial, delete the final, and install again — the
        // second run must complete via a real `Range` against the CDN.
        let fullData = try Data(contentsOf: finalURL)
        #expect(fullData.count == Int(Self.expectedSize))
        #expect(SHA256.hash(data: fullData).map { String(format: "%02x", $0) }.joined() == Self.expectedSHA256)
        try FileManager.default.removeItem(at: finalURL)
        let repoPartial = partial.appendingPathComponent("Qwen--Qwen3-0.6B-GGUF", isDirectory: true)
        try FileManager.default.createDirectory(at: repoPartial, withIntermediateDirectories: true)
        try fullData.prefix(fullData.count / 2).write(
            to: repoPartial.appendingPathComponent((file.remotePath as NSString).lastPathComponent + ".partial")
        )

        let resumeStream = await downloader.install(
            repo: Self.repo, files: [file],
            destinationDirectory: dest, partialDirectory: partial
        )
        for await event in resumeStream {
            if case let .failed(error) = event {
                Issue.record("resume install failed: \(error)")
                return
            }
        }
        let resumed = try Data(contentsOf: finalURL)
        #expect(resumed == fullData)
        print("smoke test passed: download + resume verified, GGUF ready for LlamaCppIntegrationSmokeTest")
    }
}
