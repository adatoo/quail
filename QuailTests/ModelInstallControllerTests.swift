import CryptoKit
import Foundation
import Testing
@testable import Quail

@Suite("ModelInstallController")
@MainActor
struct ModelInstallControllerTests {
    private static func shaHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeSession(handler: @escaping @Sendable (URLRequest) -> StubResponse) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = handler
        return URLSession(configuration: config)
    }

    private static func makeController(
        handler: @escaping @Sendable (URLRequest) -> StubResponse
    ) -> (ModelInstallController, ModelStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-install-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ModelStore(rootURL: dir)
        let downloader = HFDownloader(
            urlSession: makeSession(handler: handler),
            hubBaseURL: URL(string: "http://hub.test")!
        )
        return (ModelInstallController(downloader: downloader, modelStore: store), store)
    }

    @Test("a successful GGUF install writes the file, stamps the catalog row, and regenerates presets")
    func ggufInstallCompletes() async throws {
        let content = Data("real-gguf-bytes".utf8)
        let file = HFFile(remotePath: "Tiny-Q8_0.gguf", sizeBytes: Int64(content.count), sha256: Self.shaHex(content))
        let (controller, store) = Self.makeController { _ in StubResponse(statusCode: 200, body: content) }
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        let task = try #require(controller.install(
            repo: "org/Tiny-GGUF", files: [file], format: .gguf, quant: "Q8_0", family: "tiny"
        ))
        await task.value

        let onDisk = store.ggufDirectory.appendingPathComponent("Tiny-Q8_0.gguf")
        #expect(try Data(contentsOf: onDisk) == content)

        let row = try #require(store.loadCatalog().entries.first)
        #expect(row.id == "Tiny-Q8_0")
        #expect(row.sourceRepo == "org/Tiny-GGUF")
        #expect(row.quant == "Q8_0")
        #expect(row.family == "tiny")
        #expect(row.format == .gguf)

        // Presets regenerated as part of install, not only at Start:
        let ini = try String(contentsOf: store.presetsFile, encoding: .utf8)
        #expect(ini.contains("[Tiny-Q8_0]"))

        #expect(controller.phase == .installed(modelID: "Tiny-Q8_0"))
        // Size is left for refreshedCatalog's disk measurement — install
        // records provenance only.
        #expect(row.bytes == 0)
    }

    @Test("an MLX install lands in a per-repo directory under mlx/")
    func mlxInstallCompletes() async throws {
        let configBytes = Data(#"{"model_type":"llama"}"#.utf8)
        let weights = Data("weights".utf8)
        let files = [
            HFFile(remotePath: "config.json", sizeBytes: Int64(configBytes.count), sha256: nil),
            HFFile(remotePath: "model.safetensors", sizeBytes: Int64(weights.count), sha256: Self.shaHex(weights)),
        ]
        let (controller, store) = Self.makeController { request in
            if request.url?.path.hasSuffix("config.json") == true {
                return StubResponse(statusCode: 200, body: configBytes)
            }
            return StubResponse(statusCode: 200, body: weights)
        }
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        let task = try #require(controller.install(
            repo: "mlx-community/Tiny-4bit", files: files, format: .mlxSafetensors, family: "tiny-mlx"
        ))
        await task.value

        let dir = store.mlxDirectory.appendingPathComponent("mlx-community--Tiny-4bit")
        #expect(try Data(contentsOf: dir.appendingPathComponent("config.json")) == configBytes)
        #expect(try Data(contentsOf: dir.appendingPathComponent("model.safetensors")) == weights)
        let row = try #require(store.loadCatalog().entries.first)
        #expect(row.id == "mlx-community--Tiny-4bit")
        #expect(row.format == .mlxSafetensors)
        #expect(controller.phase == .installed(modelID: "mlx-community--Tiny-4bit"))
        // GGUF-only side effect: an MLX install must not touch presets.ini.
        #expect(!FileManager.default.fileExists(atPath: store.presetsFile.path))
    }

    @Test("progress accounting is cumulative across files, and completes")
    func progressIsCumulative() async throws {
        let one = Data("aaaa".utf8)
        let two = Data("bb".utf8)
        let files = [
            HFFile(remotePath: "a.bin", sizeBytes: 4, sha256: nil),
            HFFile(remotePath: "b.bin", sizeBytes: 2, sha256: nil),
        ]
        // The arithmetic itself, as a pure function: the second file's
        // per-file progress must carry the first file's full size — a
        // progress bar that reset at every file boundary would read as
        // a stalled download.
        #expect(ModelInstallController
            .cumulativeBytesWritten(files: files, current: files[0], writtenForCurrent: 2) == 2)
        #expect(ModelInstallController
            .cumulativeBytesWritten(files: files, current: files[1], writtenForCurrent: 2) == 6)

        let (controller, store) = Self.makeController { request in
            request.url?.path.hasSuffix("a.bin") == true
                ? StubResponse(statusCode: 200, body: one)
                : StubResponse(statusCode: 200, body: two)
        }
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        let task = try #require(controller.install(repo: "org/x", files: files, format: .mlxSafetensors))
        await task.value
        #expect(controller.phase == .installed(modelID: "org--x"))
    }

    @Test("a gated failure surfaces a described message, not a crash")
    func gatedFailureDescribes() async throws {
        let file = HFFile(remotePath: "config.json", sizeBytes: 1, sha256: nil)
        let (controller, store) = Self.makeController { _ in StubResponse(statusCode: 401) }
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        let task = try #require(controller.install(repo: "meta-llama/Gated", files: [file], format: .mlxSafetensors))
        await task.value

        guard case let .failed(message) = controller.phase else {
            Issue.record("expected .failed, got \(controller.phase)")
            return
        }
        #expect(message.contains("gated"))
    }

    @Test("cancel stops the download, leaves phase idle, and keeps partial bytes for resume")
    func cancelKeepsPartialForResume() async throws {
        // 3 chunks of 1 MiB spaced out, so the 20ms cancel deterministically
        // lands mid-stream rather than after an instant whole-body delivery.
        let chunk = Data(repeating: 0x7, count: 1024 * 1024)
        let full = chunk + chunk + chunk
        let file = HFFile(remotePath: "big.gguf", sizeBytes: Int64(full.count), sha256: Self.shaHex(full))
        let (controller, store) = Self.makeController { _ in
            StubResponse(statusCode: 200, chunks: [chunk, chunk, chunk], interChunkDelay: 0.03)
        }
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        let task = try #require(controller.install(repo: "org/big", files: [file], format: .gguf))
        // Let some bytes land, then cancel mid-stream.
        try await Task.sleep(nanoseconds: 20_000_000)
        controller.cancel()
        await task.value

        #expect(controller.phase == .idle)
        #expect(controller.target == nil)
        let repoPartial = store.partialDirectory.appendingPathComponent("org--big", isDirectory: true)
        let partialURL = repoPartial.appendingPathComponent("big.gguf.partial")
        // Whether bytes landed depends on timing — assert consistency for
        // whatever did: the row must not have been written either way.
        #expect(store.loadCatalog().entries.isEmpty)
        if FileManager.default.fileExists(atPath: partialURL.path) {
            let size = try (Data(contentsOf: partialURL)).count
            #expect(size < full.count, "cancelled download must not have completed")
        }
    }

    @Test("a second install while one is running is a no-op")
    func secondInstallRejectedWhileActive() async throws {
        let content = Data("x".utf8)
        let file = HFFile(remotePath: "one.gguf", sizeBytes: 1, sha256: nil)
        let (controller, store) = Self.makeController { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return StubResponse(statusCode: 200, body: content)
        }
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        let first = try #require(controller.install(repo: "org/a", files: [file], format: .gguf))
        let second = controller.install(repo: "org/b", files: [file], format: .gguf)
        #expect(second == nil)
        await first.value
        #expect(controller.target?.repo == "org/a")
    }

    @Test("acknowledgeFinished clears installed back to idle")
    func acknowledgeFinished() async throws {
        let content = Data("gguf".utf8)
        let file = HFFile(remotePath: "M-Q8_0.gguf", sizeBytes: Int64(content.count), sha256: Self.shaHex(content))
        let (controller, store) = Self.makeController { _ in StubResponse(statusCode: 200, body: content) }
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        controller.acknowledgeFinished() // idle: no-op
        #expect(controller.phase == .idle)

        let task = try #require(controller.install(repo: "org/M-GGUF", files: [file], format: .gguf))
        await task.value
        #expect(controller.phase == .installed(modelID: "M-Q8_0"))

        // Used to persist, leaving the next Add-model sheet stuck on "Installed · Done".
        controller.acknowledgeFinished()
        #expect(controller.phase == .idle)
    }

    @Test("describe() covers every HFDownloadError case")
    func describeCoverage() {
        #expect(ModelInstallController.describe(.invalidRepoID) == "invalid repo id")
        #expect(ModelInstallController.describe(.httpStatus(404)) == "HTTP 404")
        #expect(ModelInstallController.describe(.invalidResponse) == "invalid response")
        #expect(ModelInstallController.describe(.checksumMismatch(file: "f.gguf", expected: "a", actual: "b"))
            == "checksum mismatch for f.gguf")
    }
}
