import Foundation
import Testing
@testable import Quail

@Suite("CatalogRefresher")
struct CatalogRefresherTests {
    private static let remoteURL = URL(string: "https://updates.test/catalog.json")!

    private static func scratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-catalogrefresh-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func documentJSON(revision: Int, familyID: String = "gamma") -> Data {
        """
        {
          "revision": \(revision),
          "asOf": "2026-09-20",
          "ramTiersGB": {},
          "chipBandwidthGBps": { "Apple M99": 999 },
          "families": [
            { "id": "\(familyID)", "name": "Gamma", "paramsB": 7,
              "variants": { "gguf": { "repo": "org/Gamma-GGUF", "quants": ["Q4_K_M"], "default": "Q4_K_M" } } }
          ]
        }
        """.data(using: .utf8)!
    }

    private static func makeRefresher(
        directory: URL,
        seed: String? = nil,
        session: URLSession
    ) -> CatalogRefresher {
        let bundleDir = directory
        if let seed {
            try? seed.write(to: bundleDir.appendingPathComponent("catalog.json"), atomically: true, encoding: .utf8)
        }
        let locations = Catalog.Locations(bundle: Bundle(url: bundleDir)!, directory: directory)
        return CatalogRefresher(locations: locations, urlSession: session, remoteURLOverride: remoteURL)
    }

    private static func makeSession(handler: @escaping @Sendable (URLRequest) -> StubResponse) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = handler
        return URLSession(configuration: config)
    }

    @Test("no remote URL configured anywhere is a no-op that touches nothing")
    func noURLConfigured() async throws {
        let dir = Self.scratchDir()
        let locations = try Catalog.Locations(bundle: #require(Bundle(url: dir)), directory: dir)
        let refresher = CatalogRefresher(locations: locations, urlSession: Self.makeSession { _ in
            Issue.record("must not make a request")
            return StubResponse(statusCode: 500)
        })

        let outcome = await refresher.refreshIfNeeded()

        #expect(outcome == .noRemoteURL)
        #expect(!FileManager.default.fileExists(atPath: locations.refreshCacheFile.path))
    }

    @Test("remoteURL reads QuailCatalogURL from a bundle's Info.plist, and is nil when unset")
    func remoteURLFromInfoPlist() throws {
        // A bare directory works as an empty-Info.plist Bundle
        // (CatalogTests' own trick) — no QuailCatalogURL key at all, so
        // this is a genuinely independent check of the unset case, not
        // a hope that some other bundle happens to have nothing set.
        let dir = Self.scratchDir()
        let emptyBundle = try #require(Bundle(url: dir))
        #expect(CatalogRefresher.remoteURL(in: emptyBundle) == nil)

        // .main is the real, live Quail.app bundle this test process is
        // hosted in (TEST_HOST) — confirms the real, shipped config,
        // project.yml's `info.properties.QuailCatalogURL`: a catalog
        // update ships with a `git push`, not an app release.
        #expect(
            CatalogRefresher.remoteURL(in: .main)?.absoluteString
                == "https://raw.githubusercontent.com/adatoo/quail/main/Quail/Resources/catalog.json"
        )
    }

    @Test("a successful fetch writes the cache and current() picks it up")
    func fetchUpdatesCache() async throws {
        let dir = Self.scratchDir()
        let refresher = Self.makeRefresher(directory: dir, session: Self.makeSession { request in
            #expect(request.url == Self.remoteURL)
            return StubResponse(statusCode: 200, body: Self.documentJSON(revision: 5))
        })

        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let outcome = await refresher.refreshIfNeeded(now: fetchedAt)

        #expect(outcome == .updated(revision: 5))
        let cached = try #require(Catalog.loadRefreshCache(from: refresher.locations.refreshCacheFile))
        #expect(cached.revision == 5)
        #expect(cached.families.map(\.id) == ["gamma"])
        #expect(Catalog.fetchedAtOfRefreshCache(at: refresher.locations.refreshCacheFile) == fetchedAt)
        // And merged: the bundle here has no seed, so current() is the cache.
        #expect(Catalog.current(locations: refresher.locations).revision == 5)
    }

    @Test("a cache fetched less than a week ago is not refreshed")
    func notYetDue() async throws {
        let dir = Self.scratchDir()
        let requests = RequestCounter()
        let refresher = Self.makeRefresher(directory: dir, session: Self.makeSession { _ in
            requests.bump()
            return StubResponse(statusCode: 200, body: Self.documentJSON(revision: 5))
        })
        let document = try JSONDecoder().decode(
            Catalog.Document.self,
            from: Self.documentJSON(revision: 5)
        )
        try Catalog.saveRefreshCache(
            document,
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000),
            to: refresher.locations.refreshCacheFile
        )

        let justBeforeWeek = Date(timeIntervalSince1970: 2_000_000_000) + CatalogRefresher.refreshInterval - 60
        let outcome = await refresher.refreshIfNeeded(now: justBeforeWeek)
        #expect(outcome == .notDue)
        #expect(requests.count == 0)

        // ...and a minute later it retries.
        let afterWeek = Date(timeIntervalSince1970: 2_000_000_000) + CatalogRefresher.refreshInterval + 60
        let outcome2 = await refresher.refreshIfNeeded(now: afterWeek)
        #expect(outcome2 == .updated(revision: 5))
        #expect(requests.count == 1)
    }

    @Test("a revision older than bundled-or-cached is refused, cache untouched")
    func staleRevisionRejected() async {
        let dir = Self.scratchDir()
        // Bundled seed at revision 9 (in a separate file from the cache
        // dir? no — makeRefresher writes catalog.json into dir).
        let seed = """
        { "revision": 9, "ramTiersGB": {}, "chipBandwidthGBps": {},
          "families": [ { "id": "bundled", "name": "B", "paramsB": 1,
                          "variants": { "mlx": { "repo": "org/B-4bit" } } } ] }
        """
        let refresher = Self.makeRefresher(directory: dir, seed: seed, session: Self.makeSession { _ in
            StubResponse(statusCode: 200, body: Self.documentJSON(revision: 8))
        })

        let outcome = await refresher.refreshIfNeeded()

        #expect(outcome == .failed(.staleRevision(remote: 8, current: 9)))
        #expect(!FileManager.default.fileExists(atPath: refresher.locations.refreshCacheFile.path))
        // Equal revision is fine, though — a corrected re-upload of the
        // same-numbered catalog must still refresh.
        let equalOutcome = await CatalogRefresher(
            locations: refresher.locations,
            urlSession: Self.makeSession { _ in StubResponse(statusCode: 200, body: Self.documentJSON(revision: 9)) },
            remoteURLOverride: Self.remoteURL
        ).refreshIfNeeded()
        #expect(equalOutcome == .updated(revision: 9))
    }

    @Test("a failed fetch leaves any existing cache fully intact")
    func failureKeepsCache() async throws {
        let dir = Self.scratchDir()
        let refresher = Self.makeRefresher(directory: dir, session: Self.makeSession { _ in
            StubResponse(statusCode: 200, body: Self.documentJSON(revision: 3, familyID: "good"))
        })
        _ = await refresher.refreshIfNeeded()

        for (name, stub) in [
            ("http", StubResponse(statusCode: 404)),
            ("undecodable", StubResponse(statusCode: 200, body: Data("<html>login wall</html>".utf8))),
        ] {
            let failing = CatalogRefresher(
                locations: refresher.locations,
                urlSession: Self.makeSession { _ in stub },
                remoteURLOverride: Self.remoteURL
            )
            // Backdate fetchedAt so this run is due (the first success
            // set it to "now"), then capture the bytes to compare.
            let staleDate = Date(timeIntervalSince1970: 0)
            let doc = try JSONDecoder().decode(
                Catalog.Document.self,
                from: Self.documentJSON(revision: 3, familyID: "good")
            )
            try Catalog.saveRefreshCache(doc, fetchedAt: staleDate, to: refresher.locations.refreshCacheFile)
            let before = try Data(contentsOf: refresher.locations.refreshCacheFile)
            let outcome = await failing.refreshIfNeeded()
            switch name {
            case "http": #expect(outcome == .failed(.httpStatus(404)))
            default: #expect(outcome == .failed(.undecodable))
            }
            let after = try Data(contentsOf: refresher.locations.refreshCacheFile)
            #expect(after == before, "\(name) failure must not modify the cache file")
        }
    }

    @Test("a failed fetch does not update fetchedAt, so next launch retries")
    func failureRetriesNextLaunch() async {
        let dir = Self.scratchDir()
        let refresher = Self.makeRefresher(directory: dir, session: Self.makeSession { _ in
            StubResponse(statusCode: 500)
        })

        let first = await refresher.refreshIfNeeded()
        #expect(first == .failed(.httpStatus(500)))
        #expect(Catalog.fetchedAtOfRefreshCache(at: refresher.locations.refreshCacheFile) == nil)
        // Immediately retryable (not blocked for a week):
        let second = await refresher.refreshIfNeeded()
        #expect(second == .failed(.httpStatus(500))) // same handler, still failing — but reached the network twice
    }
}

private final class RequestCounter: @unchecked Sendable {
    private var stored = 0
    private let lock = NSLock()
    var count: Int {
        lock.withLock { stored }
    }

    func bump() {
        lock.withLock { stored += 1 }
    }
}
