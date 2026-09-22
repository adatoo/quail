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
