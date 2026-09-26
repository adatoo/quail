import Foundation

/// The weekly remote catalog refresh (docs/ARCHITECTURE.md §6: "A remote
/// copy on the update host is fetched weekly so new models don't wait for
/// an app release"), from the URL set in `Info.plist` under
/// `QuailCatalogURL`.
///
/// The URL is the repo's own `catalog.json` on GitHub. It runs in the
/// background at launch and only when the cache is a week old; with no
/// connection it fails quietly, within `timeout`, and the bundled or
/// cached catalog serves as before (ADR D-051).
struct CatalogRefresher: Sendable {
    /// "Weekly", per the plan. A failed refresh does not update
    /// `fetchedAt`, so the next app launch retries rather than waiting
    /// out the week on a transient error.
    static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Idle timeout for the fetch: a background nicety, so it gives up well before URLSession's 60 s.
    static let timeout: TimeInterval = 15

    let locations: Catalog.Locations
    let urlSession: URLSession
    /// Overrides the `Info.plist` lookup when set — production leaves it
    /// `nil` (so `QuailCatalogURL` decides); tests pass an explicit URL
    /// rather than faking a bundle's Info.plist.
    let remoteURLOverride: URL?

    init(locations: Catalog.Locations, urlSession: URLSession = .shared, remoteURLOverride: URL? = nil) {
        self.locations = locations
        self.urlSession = urlSession
        self.remoteURLOverride = remoteURLOverride
    }

    /// `Info.plist`'s `QuailCatalogURL`, if set and a valid URL.
    static func remoteURL(in bundle: Bundle = .main) -> URL? {
        guard let string = bundle.infoDictionary?["QuailCatalogURL"] as? String, !string.isEmpty else {
            return nil
        }
        return URL(string: string)
    }

    enum Outcome: Sendable, Equatable {
        case noRemoteURL
        case notDue
        case updated(revision: Int)
        case failed(Failure)
    }

    enum Failure: Sendable, Equatable {
        case httpStatus(Int)
        /// 2xx but not something decodable as a `Catalog.Document` —
        /// deliberately not treated as "empty catalog", which a naive
        /// decode-then-use would turn a corrupt response into.
        case undecodable
        /// Refused a revision older than anything already in hand — the
        /// only guard against a misconfigured (not hostile — it's HTTPS
        /// from our own host) update host serving a stale file. Same
        /// revision is accepted, so a same-numbered-but-corrected
        /// upload still refreshes the cache.
        case staleRevision(remote: Int, current: Int)
        case transport(String)
    }

    /// Fetches and writes the refresh cache iff the URL is set, the
    /// cache is missing or older than a week, and the response passes
    /// `Document`'s schema and the revision guard. Every failure mode
    /// leaves the existing cache untouched — a bad remote response must
    /// never degrade `Catalog.current()` below the bundled seed.
    @discardableResult
    func refreshIfNeeded(now: Date = .init()) async -> Outcome {
        guard let remoteURL = remoteURLOverride ?? Self.remoteURL(in: locations.bundle) else {
            return .noRemoteURL
        }
        if let fetchedAt = Catalog.fetchedAtOfRefreshCache(at: locations.refreshCacheFile),
           now.timeIntervalSince(fetchedAt) < Self.refreshInterval
        {
            return .notDue
        }

        let currentRevision = max(
            Catalog.bundled(in: locations.bundle).revision,
            Catalog.loadRefreshCache(from: locations.refreshCacheFile)?.revision ?? 0
        )

        let data: Data
        let response: URLResponse
        do {
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = Self.timeout
            (data, response) = try await urlSession.data(for: request)
        } catch {
            return .failed(.transport(String(describing: error)))
        }
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            return .failed(.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1))
        }

        let document: Catalog.Document
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            document = try decoder.decode(Catalog.Document.self, from: data)
        } catch {
            return .failed(.undecodable)
        }
        guard document.revision >= currentRevision else {
            return .failed(.staleRevision(remote: document.revision, current: currentRevision))
        }

        do {
            try Catalog.saveRefreshCache(document, fetchedAt: now, to: locations.refreshCacheFile)
        } catch {
            return .failed(.transport(String(describing: error)))
        }
        return .updated(revision: document.revision)
    }
}
