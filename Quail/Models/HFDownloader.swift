import CryptoKit
import Foundation

/// Downloads model files from the Hugging Face Hub into the store, per
/// docs/ARCHITECTURE.md §6's "Downloads" section — one file at a time,
/// resumable both within a single run (cancel) and across app restarts,
/// via HTTP `Range`, with the LFS sha256 verified once a file is
/// complete.
///
/// In-process streaming (`URLSession.bytes(for:)`), not a true background
/// `URLSession` — see ADR D-015 for why: background sessions are
/// delegate-only (no streaming, so sha256 needs a second full read),
/// their resume mechanism is Apple's own opaque, sometimes-unreliable
/// `resumeData` rather than an HTTP `Range` we control, and critically
/// `URLProtocol` stubbing — the mechanism this whole test suite depends
/// on — does not work with them at all. A menu-bar agent that's meant to
/// always be running trades "survives quitting the app" for "resumes
/// instantly on next launch, from a plain resumable file, fully tested."
actor HFDownloader {
    private let urlSession: URLSession
    private let hubBaseURL: URL
    private let fileManager: FileManager

    /// Bytes buffered before a write + progress callback. Large enough
    /// that per-chunk overhead is negligible against a multi-GB download,
    /// small enough that progress still updates several times a second.
    private static let chunkSize = 1 << 20 // 1 MiB

    /// How long a request may go without receiving a byte (ADR D-051). URLSession's default is 60 s,
    /// which on a network that looks connected but goes nowhere (a captive portal, a dead proxy)
    /// left the Add Model sheet waiting minutes. Metadata is small; a download keeps its partial
    /// bytes and resumes, so failing sooner costs nothing.
    static let metadataTimeout: TimeInterval = 15
    static let downloadTimeout: TimeInterval = 30

    /// `.offline` for the URL errors that mean "no connection" rather than "Hugging Face said no";
    /// anything else unchanged.
    static func offline(_ error: Error) -> Error {
        // A firewall, or a sandbox, refusing the connection surfaces as a bare POSIX error.
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           [EPERM, ENETDOWN, ENETUNREACH, EHOSTUNREACH, ETIMEDOUT].contains(Int32(nsError.code))
        {
            return HFDownloadError.offline
        }
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .timedOut, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            return HFDownloadError.offline
        default:
            return error
        }
    }

    init(
        urlSession: URLSession = .shared,
        hubBaseURL: URL = URL(string: "https://huggingface.co")!,
        fileManager: FileManager = .default
    ) {
        self.urlSession = urlSession
        self.hubBaseURL = hubBaseURL
        self.fileManager = fileManager
    }

    // MARK: - Listing

    /// `GET /api/models/{repo}?blobs=true` — every file in the repo, with
    /// size and (for LFS-tracked files) sha256. Succeeds even for a gated
    /// repo the caller has no access to — confirmed against a real one —
    /// so `gatedRepoRequiresToken` is only ever thrown by `install`, not
    /// here.
    func listFiles(repo: String, token: String? = nil) async throws -> HFRepo {
        guard Self.isPlausibleRepoID(repo) else { throw HFDownloadError.invalidRepoID }

        var components = URLComponents(
            url: hubBaseURL.appendingPathComponent("api/models/\(repo)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        guard let url = components.url else { throw HFDownloadError.invalidRepoID }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.metadataTimeout
        Self.authorize(&request, token: token)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw Self.offline(error)
        }
        try Self.checkStatus(response)

        struct RawResponse: Decodable {
            struct Sibling: Decodable {
                var rfilename: String
                var size: Int64?
                var lfs: LFS?
                struct LFS: Decodable { var sha256: String }
            }

            var siblings: [Sibling]
        }

        let raw: RawResponse
        do {
            raw = try JSONDecoder().decode(RawResponse.self, from: data)
        } catch {
            throw HFDownloadError.decoding(String(describing: error))
        }

        let files = raw.siblings.map { sibling in
            HFFile(remotePath: sibling.rfilename, sizeBytes: sibling.size ?? 0, sha256: sibling.lfs?.sha256)
        }
        return HFRepo(id: repo, files: files)
    }

    private static func isPlausibleRepoID(_ repo: String) -> Bool {
        !repo.isEmpty && !repo.hasPrefix("/") && !repo.hasSuffix("/") && !repo.contains("..")
    }

    /// Fetches only a file's first `maxBytes` (one `Range` request —
    /// confirmed a real 206 comes back through the CDN redirect) so the
    /// Models pane can run `GGUFMetadata.parse` for a *pre-download* fit
    /// verdict, per docs/ARCHITECTURE.md §7: "Both are read from the Hub
    /// file listing before download, so the verdict shows in the picker"
    /// (with the listing supplying the size and this supplying the
    /// shape). 8 MiB covers the metadata section of every model checked
    /// — vocabularies make it larger than it sounds (Qwen3's 151,936-
    /// token vocab ≈ 2 MB) — and a header that outgrows the budget
    /// throws `.truncated` from `GGUFMetadata.parse`, which callers
    /// treat as "no verdict", not an error.
    func fetchHeader(
        repo: String,
        file: HFFile,
        maxBytes: Int = 8 * 1024 * 1024,
        token: String? = nil
    ) async throws -> Data {
        let resolveURL = hubBaseURL.appendingPathComponent("\(repo)/resolve/main/\(file.remotePath)")
        var request = URLRequest(url: resolveURL)
        Self.authorize(&request, token: token)
        request.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = Self.metadataTimeout
        let delegate = RangePreservingRedirectDelegate()
        let data: Data, response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request, delegate: delegate)
        } catch {
            throw Self.offline(error)
        }
        try Self.checkStatus(response)
        return data
    }

    // MARK: - Install (download + verify + move into place)

    /// Downloads every file in `files` from `repo` into `destinationDirectory`,
    /// resuming any bytes already on disk under `partialDirectory` from a
    /// previous attempt — whether that attempt was cancelled or the app
    /// itself was quit or crashed mid-download. Nothing appears in
    /// `destinationDirectory` for a file until that file is verified;
    /// `.finished` isn't emitted until every file in the call is.
    ///
    /// A GGUF download is typically one file with `destinationDirectory`
    /// = `ModelStore.ggufDirectory` directly; an MLX download is several
    /// files with `destinationDirectory` = a per-repo subdirectory of
    /// `ModelStore.mlxDirectory` the caller names (ARCHITECTURE.md §6:
    /// `mlx-community--Qwen3-30B-A3B-4bit/`).
    ///
    /// One file at a time (docs/IMPLEMENTATION_PLAN.md step 5), in the
    /// order given. A `.checksumMismatch` on one file deletes just that
    /// file's partial bytes (a corrupt download should never masquerade
    /// as a resumable one) but leaves every other file's progress intact,
    /// then ends the stream with `.failed` — the caller decides whether
    /// to retry.
    func install(
        repo: String,
        files: [HFFile],
        destinationDirectory: URL,
        partialDirectory: URL,
        token: String? = nil
    ) -> AsyncStream<HFDownloadEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                    let repoPartialDir = partialDirectory.appendingPathComponent(Self.sanitize(repo), isDirectory: true)
                    try fileManager.createDirectory(at: repoPartialDir, withIntermediateDirectories: true)

                    for file in files {
                        try Task.checkCancellation()
                        do {
                            try await downloadOneFile(
                                repo: repo,
                                file: file,
                                repoPartialDir: repoPartialDir,
                                token: token
                            ) { written, total in
                                continuation.yield(.progress(HFDownloadProgress(
                                    file: file,
                                    bytesWritten: written,
                                    totalBytes: total
                                )))
                            }
                        } catch let error as HFDownloadError {
                            if case .checksumMismatch = error {
                                // A corrupt download must never look resumable.
                                try? fileManager.removeItem(at: Self.partialFileURL(
                                    repoPartialDir: repoPartialDir,
                                    file: file
                                ))
                                try? fileManager.removeItem(at: Self.sidecarURL(
                                    repoPartialDir: repoPartialDir,
                                    file: file
                                ))
                            }
                            throw error
                        }
                        continuation.yield(.fileCompleted(file))
                    }

                    // Every file verified — move each into place. Not one
                    // atomic filesystem operation, but each individual
                    // move is atomic (same-volume rename), the loop does
                    // no other I/O in between, and — the property that
                    // actually matters — nothing under `destinationDirectory`
                    // exists at all until every file has already passed
                    // verification above.
                    for file in files {
                        let partialURL = Self.partialFileURL(repoPartialDir: repoPartialDir, file: file)
                        let finalURL = destinationDirectory.appendingPathComponent(file.localFilename)
                        try? fileManager.removeItem(at: finalURL)
                        try fileManager.moveItem(at: partialURL, to: finalURL)
                        try? fileManager.removeItem(at: Self.sidecarURL(repoPartialDir: repoPartialDir, file: file))
                    }
                    try? fileManager.removeItem(at: repoPartialDir)

                    continuation.yield(.finished(destinationDirectory: destinationDirectory))
                } catch is CancellationError {
                    // Partial bytes + sidecar deliberately left in place —
                    // that's the resume state for next time.
                } catch let error as HFDownloadError {
                    continuation.yield(.failed(error))
                } catch {
                    // A connection dropped mid-file surfaces here, from the byte stream.
                    if Self.offline(error) as? HFDownloadError == .offline {
                        continuation.yield(.failed(.offline))
                    } else {
                        continuation.yield(.failed(.decoding(String(describing: error))))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func partialFileURL(repoPartialDir: URL, file: HFFile) -> URL {
        repoPartialDir.appendingPathComponent(file.localFilename + ".partial")
    }

    private static func sidecarURL(repoPartialDir: URL, file: HFFile) -> URL {
        repoPartialDir.appendingPathComponent(file.localFilename + ".json")
    }

    /// Repo ids are `owner/name`; `.partial/` needs one path component per
    /// repo, so `/` becomes `--` — the same convention ARCHITECTURE.md §6
    /// already uses for MLX model directory names.
    private static func sanitize(_ repo: String) -> String {
        repo.replacingOccurrences(of: "/", with: "--")
    }

    // MARK: - One file

    private func downloadOneFile(
        repo: String,
        file: HFFile,
        repoPartialDir: URL,
        token: String?,
        onProgress: @Sendable (Int64, Int64) -> Void
    ) async throws {
        let partialURL = Self.partialFileURL(repoPartialDir: repoPartialDir, file: file)
        let sidecarURL = Self.sidecarURL(repoPartialDir: repoPartialDir, file: file)

        // Refreshed on every attempt (not just the first) so a sidecar
        // left over from an interrupted run always matches what we're
        // about to verify against — sizes/checksums could differ if the
        // caller is re-installing a since-updated repo.
        let sidecar = HFPartialSidecar(
            repo: repo,
            remotePath: file.remotePath,
            expectedSizeBytes: file.sizeBytes,
            expectedSHA256: file.sha256
        )
        try? JSONEncoder().encode(sidecar).write(to: sidecarURL)

        var existingBytes = Self.fileSize(at: partialURL, fileManager: fileManager)
        var hasher = SHA256()
        if file.sha256 != nil, existingBytes > 0 {
            Self.hashExistingContents(of: partialURL, into: &hasher, fileManager: fileManager)
        }

        if existingBytes < file.sizeBytes || file.sizeBytes == 0 {
            let resolveURL = hubBaseURL.appendingPathComponent("\(repo)/resolve/main/\(file.remotePath)")
            var request = URLRequest(url: resolveURL)
            Self.authorize(&request, token: token)
            let requestedRange = existingBytes > 0
            if requestedRange {
                request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
            }

            request.timeoutInterval = Self.downloadTimeout
            let delegate = RangePreservingRedirectDelegate()
            let asyncBytes: URLSession.AsyncBytes, response: URLResponse
            do {
                (asyncBytes, response) = try await urlSession.bytes(for: request, delegate: delegate)
            } catch {
                throw Self.offline(error)
            }
            let honoredRange = try Self.checkStatus(response)

            if requestedRange, !honoredRange {
                // The server ignored our Range and is about to send the
                // whole file from byte 0 — appending that to what's
                // already on disk would corrupt it. Start clean.
                try? fileManager.removeItem(at: partialURL)
                existingBytes = 0
                hasher = SHA256()
            }

            if !fileManager.fileExists(atPath: partialURL.path) {
                fileManager.createFile(atPath: partialURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partialURL)
            defer { try? handle.close() }
            try handle.seekToEnd()

            var written = existingBytes
            var buffer = Data()
            buffer.reserveCapacity(Self.chunkSize)
            let shouldHash = file.sha256 != nil

            func flush() {
                guard !buffer.isEmpty else { return }
                handle.write(buffer)
                if shouldHash {
                    hasher.update(data: buffer)
                }
                written += Int64(buffer.count)
                onProgress(written, file.sizeBytes)
                buffer.removeAll(keepingCapacity: true)
            }

            for try await byte in asyncBytes {
                buffer.append(byte)
                if buffer.count >= Self.chunkSize {
                    try Task.checkCancellation()
                    flush()
                }
            }
            flush()
        }

        try Self.verify(partialURL: partialURL, file: file, hasher: hasher, fileManager: fileManager)
    }

    private static func verify(partialURL: URL, file: HFFile, hasher: SHA256, fileManager: FileManager) throws {
        if let expectedSHA256 = file.sha256 {
            let digest = hasher.finalize()
            let actualHex = digest.map { String(format: "%02x", $0) }.joined()
            guard actualHex == expectedSHA256 else {
                throw HFDownloadError.checksumMismatch(
                    file: file.localFilename,
                    expected: expectedSHA256,
                    actual: actualHex
                )
            }
        } else if file.sizeBytes > 0 {
            // No checksum available (confirmed real for most files in an
            // MLX repo) — the best verification available is size.
            let actualSize = fileSize(at: partialURL, fileManager: fileManager)
            guard actualSize == file.sizeBytes else {
                throw HFDownloadError.checksumMismatch(
                    file: file.localFilename,
                    expected: "size=\(file.sizeBytes)",
                    actual: "size=\(actualSize)"
                )
            }
        }
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> Int64 {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func hashExistingContents(of url: URL, into hasher: inout SHA256, fileManager _: FileManager) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
    }

    // MARK: - HTTP helpers

    private static func authorize(_ request: inout URLRequest, token: String?) {
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Returns whether the response was `206 Partial Content` (i.e. the
    /// server honored a `Range` request), throwing for anything outside
    /// 200–299, with `401` mapped to `gatedRepoRequiresToken` — confirmed
    /// that's specifically what a real gated repo's `resolve/main/...`
    /// returns without a valid token.
    @discardableResult
    private static func checkStatus(_ response: URLResponse) throws -> Bool {
        guard let http = response as? HTTPURLResponse else { throw HFDownloadError.invalidResponse }
        if http.statusCode == 401 {
            throw HFDownloadError.gatedRepoRequiresToken
        }
        guard (200 ..< 300).contains(http.statusCode) else { throw HFDownloadError.httpStatus(http.statusCode) }
        return http.statusCode == 206
    }
}

/// Metadata for one in-progress download, written alongside its partial
/// bytes under `ModelStore.partialDirectory` so a later launch of Quail
/// can resume without re-fetching the file listing first. The signed CDN
/// URL a `resolve/main/...` redirect returns is deliberately never
/// persisted here — confirmed it's a short-lived, expiring signed URL —
/// resume always re-requests `resolve/main/...` fresh and lets it
/// redirect again.
struct HFPartialSidecar: Sendable, Equatable, Codable {
    var repo: String
    var remotePath: String
    var expectedSizeBytes: Int64
    var expectedSHA256: String?
}

/// Re-attaches `Range` to a redirected request. Confirmed necessary
/// because Hugging Face's `resolve/main/...` endpoint 302s to a
/// different host (its CDN) for the actual file bytes, and URLSession's
/// default redirect handling doesn't reliably carry a custom `Range`
/// header across a cross-host redirect. Deliberately does *not* forward
/// `Authorization`: the initial request to `resolve/main/...` is what
/// needs the bearer token (to get a correctly-scoped signed CDN URL in
/// the first place, for a gated repo); the CDN URL itself is already
/// signed and forwarding a Hugging Face user token to a third-party CDN
/// host would be sending a credential somewhere it isn't needed — the
/// same reasoning URLSession's own default cross-host redirect handling
/// already applies to `Authorization` specifically.
private final class RangePreservingRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            redirected.setValue(range, forHTTPHeaderField: "Range")
        }
        completionHandler(redirected)
    }
}
