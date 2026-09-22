import CryptoKit
import Foundation
import Testing
@testable import Quail

@Suite("HFDownloader")
struct HFDownloaderTests {
    private static let hub = URL(string: "http://hub.test")!

    private static func makeSession(handler: @escaping @Sendable (URLRequest) -> StubResponse) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = handler
        return URLSession(configuration: config)
    }

    private static func scratchRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-hf-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func shaHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func collect(_ stream: AsyncStream<HFDownloadEvent>) async -> [HFDownloadEvent] {
        var events: [HFDownloadEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    // MARK: - Fixtures: real captured Hub payloads (trimmed to relevant fields)

    /// Real shape from Qwen/Qwen3-0.6B-GGUF?blobs=true, trimmed — keeps
    /// one LFS weight, one plain file, and the size/lfs keys intact.
    private static let ggufListingJSON = """
    {"siblings":[
      {"rfilename":"Qwen3-0.6B-Q8_0.gguf","size":639446688,
       "lfs":{"sha256":"9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031","size":639446688,"pointerSize":134}},
      {"rfilename":"README.md","size":6236},
      {"rfilename":".gitattributes","size":1808}
    ]}
    """.data(using: .utf8)!

    /// Real shape from mlx-community/Qwen2.5-7B-Instruct-4bit?blobs=true,
    /// trimmed — only model.safetensors is LFS.
    private static let mlxListingJSON = """
    {"siblings":[
      {"rfilename":"config.json","size":787},
      {"rfilename":"model.safetensors","size":4284346255,
       "lfs":{"sha256":"86110f368236b53cf4c2336f991a85703b17bcc60bb75f292b4002ec0219f071"}},
      {"rfilename":"tokenizer.json","size":7031673}
    ]}
    """.data(using: .utf8)!

    // MARK: - listFiles

    @Test("listFiles decodes a GGUF repo listing with LFS sha256")
    func listFilesDecodesGGUF() async throws {
        let session = Self.makeSession { _ in StubResponse(statusCode: 200, body: Self.ggufListingJSON) }
        let downloader = HFDownloader(urlSession: session, hubBaseURL: Self.hub)

        let repo = try await downloader.listFiles(repo: "Qwen/Qwen3-0.6B-GGUF")

        #expect(repo.id == "Qwen/Qwen3-0.6B-GGUF")
        #expect(repo.files.count == 3)
        let weight = try #require(repo.files.first { $0.remotePath == "Qwen3-0.6B-Q8_0.gguf" })
        #expect(weight.sizeBytes == 639_446_688)
        #expect(weight.sha256 == "9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031")
        let readme = try #require(repo.files.first { $0.remotePath == "README.md" })
        #expect(readme.sha256 == nil)
    }

    @Test("listFiles decodes an MLX repo: only safetensors has sha256")
    func listFilesDecodesMLX() async throws {
        let session = Self.makeSession { _ in StubResponse(statusCode: 200, body: Self.mlxListingJSON) }
        let downloader = HFDownloader(urlSession: session, hubBaseURL: Self.hub)

        let repo = try await downloader.listFiles(repo: "mlx-community/Qwen2.5-7B-Instruct-4bit")

        let weights = try #require(repo.files.first { $0.remotePath == "model.safetensors" })
        #expect(weights.sha256 != nil)
        let config = try #require(repo.files.first { $0.remotePath == "config.json" })
        #expect(config.sha256 == nil)
    }

    @Test("listFiles rejects implausible repo IDs without hitting network")
    func listFilesRejectsBadRepoID() async throws {
        let session = Self.makeSession { _ in StubResponse(statusCode: 200, body: Data()) }
        let downloader = HFDownloader(urlSession: session, hubBaseURL: Self.hub)

        await #expect(throws: HFDownloadError.invalidRepoID) {
            _ = try await downloader.listFiles(repo: "../etc/passwd")
        }
        await #expect(throws: HFDownloadError.invalidRepoID) {
            _ = try await downloader.listFiles(repo: "")
        }
    }

    @Test("listFiles sends Authorization when a token is given")
    func listFilesSendsBearerToken() async throws {
        let captured = CapturedValue<String?>()
        let session = Self.makeSession { request in
            captured.set(request.value(forHTTPHeaderField: "Authorization"))
            return StubResponse(statusCode: 200, body: Self.ggufListingJSON)
        }
        let downloader = HFDownloader(urlSession: session, hubBaseURL: Self.hub)

        _ = try await downloader.listFiles(repo: "Qwen/Qwen3-0.6B-GGUF", token: "hf_test_123")

        #expect(captured.value == "Bearer hf_test_123")
    }

    // MARK: - install: happy path

    @Test("install downloads one file, verifies sha256, moves it into place")
    func installSingleFileHappyPath() async throws {
        let content = Data("hello-gguf-bytes".utf8)
        let file = HFFile(remotePath: "tiny-Q8_0.gguf", sizeBytes: Int64(content.count), sha256: Self.shaHex(content))
        let session = Self.makeSession { request in
            guard request.url?.path.contains("/resolve/") == true else {
                return StubResponse(statusCode: 404)
            }
            #expect(request.value(forHTTPHeaderField: "Range") == nil)
            return StubResponse(statusCode: 200, body: content)
        }
        let downloader = HFDownloader(urlSession: session, hubBaseURL: Self.hub)
        let root = Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("gguf", isDirectory: true)
        let partial = root.appendingPathComponent(".partial", isDirectory: true)

        let stream = await downloader.install(
            repo: "Qwen/Qwen3-0.6B-GGUF", files: [file],
            destinationDirectory: dest, partialDirectory: partial
        )
        let events = await Self.collect(stream)

        #expect(events.contains(.fileCompleted(file)))
        #expect(events.contains(.finished(destinationDirectory: dest)))
        let finalData = try Data(contentsOf: dest.appendingPathComponent("tiny-Q8_0.gguf"))
        #expect(finalData == content)
        // Partial dir cleaned up on success.
        #expect(!FileManager.default.fileExists(atPath: partial.appendingPathComponent("Qwen--Qwen3-0.6B-GGUF").path))
    }

    @Test("install verifies by size when no sha256 is available")
    func installSizeOnlyWhenNoChecksum() async {
        let content = Data("fake-config-json".utf8)
        let file = HFFile(remotePath: "config.json", sizeBytes: Int64(content.count), sha256: nil)
        let session = Self.makeSession { _ in StubResponse(statusCode: 200, body: content) }
        let downloader = HFDownloader(urlSession: session, hubBaseURL: Self.hub)
        let root = Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let stream = await downloader.install(
            repo: "mlx-community/Qwen2.5-7B-Instruct-4bit", files: [file],
            destinationDirectory: root.appendingPathComponent("mlx", isDirectory: true),
            partialDirectory: root.appendingPathComponent(".partial", isDirectory: true)
        )
        let events = await Self.collect(stream)

        #expect(events.contains(where: {
            if case .finished = $0 {
                true
            } else {
                false
            }
        }))
    }

    @Test("install flattens a subdirectory remotePath to its basename")
    func installFlattensSubdirectory() async {
        let content = Data("sharded-bytes".utf8)
        let file = HFFile(
            remotePath: "BF16/gemma-3-27b-it-BF16-00001-of-00002.gguf",
            sizeBytes: Int64(content.count), sha256: Self.shaHex(content)
        )
        let session = Self.makeSession { _ in StubResponse(statusCode: 200, body: content) }
        let downloader = HFDownloader(urlSession: session, hubBaseURL: Self.hub)
        let root = Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("gguf", isDirectory: true)

        let stream = await downloader.install(
            repo: "unsloth/gemma-3-27b-it-GGUF", files: [file],
            destinationDirectory: dest,
            partialDirectory: root.appendingPathComponent(".partial", isDirectory: true)
        )
        _ = await Self.collect(stream)

        #expect(FileManager.default
            .fileExists(atPath: dest.appendingPathComponent("gemma-3-27b-it-BF16-00001-of-00002.gguf").path))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("BF16").path))
    }

    // MARK: - resume

    @Test("install resumes from existing partial bytes with a Range request")
    func installResumesWithRange() async throws {
        let full = Data("0123456789ABCDEFGHIJ".utf8) // 20 bytes
        let firstHalf = full.prefix(8)
        let secondHalf = full.suffix(from: 8)
        let file = HFFile(remotePath: "tiny.gguf", sizeBytes: Int64(full.count), sha256: Self.shaHex(full))
        let capturedRange = CapturedValue<String?>()
        let session = Self.makeSession { request in
            capturedRange.set(request.value(forHTTPHeaderField: "Range"))
            guard request.value(forHTTPHeaderField: "Range") == "bytes=8-" else {
                return StubResponse(statusCode: 200, body: full)
            }
            return StubResponse(
                statusCode: 206,
                headers: ["Content-Range": "bytes 8-19/20"],
                body: Data(secondHalf)
            )
        }
        let downloader = HFDownloader(urlSession: session, hubBaseURL: Self.hub)
        let root = Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("gguf", isDirectory: true)
        let partial = root.appendingPathComponent(".partial", isDirectory: true)
        // Simulate a previous interrupted run: first 8 bytes already on disk.
        let repoPartial = partial.appendingPathComponent("Qwen--Qwen3-0.6B-GGUF", isDirectory: true)
        try FileManager.default.createDirectory(at: repoPartial, withIntermediateDirectories: true)
        try firstHalf.write(to: repoPartial.appendingPathComponent("tiny.gguf.partial"))

        let stream = await downloader.install(
            repo: "Qwen/Qwen3-0.6B-GGUF", files: [file],
            destinationDirectory: dest, partialDirectory: partial
        )
        let events = await Self.collect(stream)

        #expect(capturedRange.value == "bytes=8-")
        #expect(events.contains(.finished(destinationDirectory: dest)))
        #expect(try Data(contentsOf: dest.appendingPathComponent("tiny.gguf")) == full)
    }

    @Test("install restarts from zero when the server ignores Range")
    func installRestartsWhenRangeIgnored() async throws {
        let full = Data("0123456789ABCDEFGHIJ".utf8)
        let file = HFFile(remotePath: "tiny.gguf", sizeBytes: Int64(full.count), sha256: Self.shaHex(full))
        let session = Self.makeSession { request in
            // Server ignores Range: returns 200 + full body regardless.
            #expect(request.value(forHTTPHeaderField: "Range") != nil)
            return StubResponse(statusCode: 200, body: full)
        }
        let downloader = HFDownloader(urlSession: session, hubBaseURL: Self.hub)
        let root = Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("gguf", isDirectory: true)
        let partial = root.appendingPathComponent(".partial", isDirectory: true)
        let repoPartial = partial.appendingPathComponent("Qwen--Qwen3-0.6B-GGUF", isDirectory: true)
        try FileManager.default.createDirectory(at: repoPartial, withIntermediateDirectories: true)
        try Data("STALE-PREFIX".utf8).write(to: repoPartial.appendingPathComponent("tiny.gguf.partial"))

        let stream = await downloader.install(
            repo: "Qwen/Qwen3-0.6B-GGUF", files: [file],
            destinationDirectory: dest, partialDirectory: partial
        )
        let events = await Self.collect(stream)

        #expect(events.contains(.finished(destinationDirectory: dest)))
        #expect(try Data(contentsOf: dest.appendingPathComponent("tiny.gguf")) == full)
    }

    // MARK: - failures

    @Test("install emits checksumMismatch and deletes the corrupt partial")
    func installChecksumMismatchDeletesPartial() async {
        let content = Data("corrupt-bytes".utf8)
        let file = HFFile(
            remotePath: "tiny.gguf",
            sizeBytes: Int64(content.count),
            sha256: String(repeating: "0", count: 64)
        )
        let session = Self.makeSession { _ in StubResponse(statusCode: 200, body: content) }
        let downloader = HFDownloader(urlSession: session, hubBaseURL: Self.hub)
        let root = Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent(".partial", isDirectory: true)
        let repoPartial = partial.appendingPathComponent("Qwen--Qwen3-0.6B-GGUF", isDirectory: true)

        let stream = await downloader.install(
            repo: "Qwen/Qwen3-0.6B-GGUF", files: [file],
            destinationDirectory: root.appendingPathComponent("gguf", isDirectory: true),
            partialDirectory: partial
        )
        let events = await Self.collect(stream)

        let failed = events.compactMap { event -> HFDownloadError? in
            if case let .failed(error) = event {
                error
            } else {
                nil
            }
        }
        #expect(failed.count == 1)
        if case let .checksumMismatch(name, _, _) = failed[0] {
            #expect(name == "tiny.gguf")
        } else {
            Issue.record("expected checksumMismatch, got \(failed[0])")
        }
        #expect(!FileManager.default.fileExists(atPath: repoPartial.appendingPathComponent("tiny.gguf.partial").path))
    }

    @Test("install maps 401 on resolve to gatedRepoRequiresToken")
    func install401IsGated() async {
        let content = Data("x".utf8)
        let file = HFFile(remotePath: "config.json", sizeBytes: Int64(content.count), sha256: nil)
        let session = Self.makeSession { request in
            if request.url?.path.contains("/resolve/") == true {
                return StubResponse(statusCode: 401, body: Data("restricted".utf8))
            }
            return StubResponse(statusCode: 404)
        }
        let downloader = HFDownloader(urlSession: session, hubBaseURL: Self.hub)
        let root = Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let stream = await downloader.install(
            repo: "meta-llama/Llama-3.1-8B-Instruct", files: [file],
            destinationDirectory: root.appendingPathComponent("mlx", isDirectory: true),
            partialDirectory: root.appendingPathComponent(".partial", isDirectory: true)
        )
        let events = await Self.collect(stream)

        #expect(events.contains(.failed(.gatedRepoRequiresToken)))
    }

    @Test("install sends the bearer token on resolve when given")
    func installSendsBearerToken() async {
        let content = Data("secret-weights".utf8)
        let file = HFFile(
            remotePath: "model.safetensors",
            sizeBytes: Int64(content.count),
            sha256: Self.shaHex(content)
        )
        let captured = CapturedValue<String?>()
        let session = Self.makeSession { request in
            if request.url?.path.contains("/resolve/") == true {
                captured.set(request.value(forHTTPHeaderField: "Authorization"))
            }
            return StubResponse(statusCode: 200, body: content)
        }
        let downloader = HFDownloader(urlSession: session, hubBaseURL: Self.hub)
        let root = Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let stream = await downloader.install(
            repo: "meta-llama/Llama-3.1-8B-Instruct", files: [file],
            destinationDirectory: root.appendingPathComponent("mlx", isDirectory: true),
            partialDirectory: root.appendingPathComponent(".partial", isDirectory: true),
            token: "hf_secret"
        )
        _ = await Self.collect(stream)

        #expect(captured.value == "Bearer hf_secret")
    }

    // MARK: - multi-file atomicity + progress

    @Test("destination stays empty until every file verifies")
    func destinationEmptyUntilAllVerified() async {
        let good = Data("good-file".utf8)
        let goodFile = HFFile(remotePath: "config.json", sizeBytes: Int64(good.count), sha256: Self.shaHex(good))
        let badContent = Data("bad-file".utf8)
        let badFile = HFFile(
            remotePath: "model.safetensors",
            sizeBytes: Int64(badContent.count),
            sha256: String(repeating: "f", count: 64)
        )
        let session = Self.makeSession { request in
            if request.url?.path.contains("config.json") == true {
                return StubResponse(statusCode: 200, body: good)
            }
            return StubResponse(statusCode: 200, body: badContent)
        }
        let downloader = HFDownloader(urlSession: session, hubBaseURL: Self.hub)
        let root = Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("mlx", isDirectory: true)

        let stream = await downloader.install(
            repo: "mlx-community/Qwen2.5-7B-Instruct-4bit", files: [goodFile, badFile],
            destinationDirectory: dest,
            partialDirectory: root.appendingPathComponent(".partial", isDirectory: true)
        )
        let events = await Self.collect(stream)

        #expect(events.contains(where: {
            if case .failed = $0 {
                true
            } else {
                false
            }
        }))
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []
        #expect(contents.isEmpty)
    }

    @Test("progress events are monotonic and end at the total")
    func progressIsMonotonic() async {
        // 3 MiB so the 1 MiB chunk buffer yields multiple progress events.
        let content = Data(repeating: 0xAB, count: 3 * 1024 * 1024)
        let file = HFFile(remotePath: "big.gguf", sizeBytes: Int64(content.count), sha256: Self.shaHex(content))
        let session = Self.makeSession { _ in StubResponse(statusCode: 200, body: content) }
        let downloader = HFDownloader(urlSession: session, hubBaseURL: Self.hub)
        let root = Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let stream = await downloader.install(
            repo: "Qwen/Qwen3-0.6B-GGUF", files: [file],
            destinationDirectory: root.appendingPathComponent("gguf", isDirectory: true),
            partialDirectory: root.appendingPathComponent(".partial", isDirectory: true)
        )
        let events = await Self.collect(stream)
        let progresses = events.compactMap { event -> HFDownloadProgress? in
            if case let .progress(p) = event {
                p
            } else {
                nil
            }
        }

        #expect(!progresses.isEmpty)
        var last: Int64 = -1
        for p in progresses {
            #expect(p.bytesWritten >= last)
            #expect(p.totalBytes == Int64(content.count))
            last = p.bytesWritten
        }
        #expect(last == Int64(content.count))
    }

    @Test("redirect to a CDN preserves the Range header on the second leg")
    func redirectPreservesRange() async throws {
        let full = Data("0123456789ABCDEFGHIJ".utf8)
        let secondHalf = Data(full.suffix(from: 8))
        let file = HFFile(remotePath: "tiny.gguf", sizeBytes: Int64(full.count), sha256: Self.shaHex(full))
        let secondLegRange = CapturedValue<String?>()
        let cdn = try #require(URL(string: "http://cdn.test/file-bytes"))
        let session = Self.makeSession { request in
            if request.url?.host == "cdn.test" {
                secondLegRange.set(request.value(forHTTPHeaderField: "Range"))
                return StubResponse(statusCode: 206, body: secondHalf)
            }
            // First leg: resolve → 302 to the CDN.
            return StubResponse(statusCode: 302, headers: ["Location": cdn.absoluteString])
        }
        let downloader = HFDownloader(urlSession: session, hubBaseURL: Self.hub)
        let root = Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("gguf", isDirectory: true)
        let partial = root.appendingPathComponent(".partial", isDirectory: true)
        let repoPartial = partial.appendingPathComponent("Qwen--Qwen3-0.6B-GGUF", isDirectory: true)
        try FileManager.default.createDirectory(at: repoPartial, withIntermediateDirectories: true)
        try full.prefix(8).write(to: repoPartial.appendingPathComponent("tiny.gguf.partial"))

        let stream = await downloader.install(
            repo: "Qwen/Qwen3-0.6B-GGUF", files: [file],
            destinationDirectory: dest, partialDirectory: partial
        )
        let events = await Self.collect(stream)

        #expect(secondLegRange.value == "bytes=8-")
        #expect(events.contains(.finished(destinationDirectory: dest)))
        #expect(try Data(contentsOf: dest.appendingPathComponent("tiny.gguf")) == full)
    }
}

/// `StubURLProtocol.handler` runs synchronously before the mocked call
/// completes, so single-request-per-test captures need no synchronization;
/// multi-leg redirect tests may read from another thread, so this uses a
/// lock.
private final class CapturedValue<T: Sendable>: @unchecked Sendable {
    private var stored: T?
    private let lock = NSLock()
    var value: T? {
        lock.withLock { stored }
    }

    func set(_ newValue: T) {
        lock.withLock { stored = newValue }
    }
}
