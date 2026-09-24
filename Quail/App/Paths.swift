import Foundation

/// Fixed, explicit filesystem locations for everything Quail writes.
///
/// Per AGENTS.md: Quail never writes outside `Application Support/Quail`,
/// `Logs/Quail`, and the user-chosen model store, and runtimes are always
/// given explicit paths rather than relying on their own defaults.
enum Paths {
    /// `~/Library/Application Support/Quail`
    static let applicationSupport: URL = {
        let base = ControlPaths.debugDataRoot?.appendingPathComponent("Application Support", isDirectory: true)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Quail", isDirectory: true)
    }()

    /// `~/Library/Logs/Quail`
    static let logs: URL = {
        let base = ControlPaths.debugDataRoot?.appendingPathComponent("Logs", isDirectory: true)
            ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        return base.appendingPathComponent("Quail", isDirectory: true)
    }()

    /// `~/Library/Application Support/Quail/config.json`
    static var configFile: URL {
        applicationSupport.appendingPathComponent("config.json", isDirectory: false)
    }

    /// `~/Library/Application Support/Quail/Models` — the default model
    /// store, used until a user relocates it. See `ModelStore.swift` for
    /// the folder layout underneath, and `resolveModelsDirectory`/
    /// `makeModelsDirectoryBookmark` below for the relocation mechanism
    /// itself (docs/ARCHITECTURE.md §6: "relocatable; path stored as a
    /// bookmark").
    static var defaultModelsDirectory: URL {
        applicationSupport.appendingPathComponent("Models", isDirectory: true)
    }

    /// `~/Library/Logs/Quail/<runtimeID>.log`
    static func logFile(for runtime: RuntimeID) -> URL {
        logs.appendingPathComponent("\(runtime.rawValue).log", isDirectory: false)
    }

    /// Resolves `Config.modelsDirectoryBookmark` back into a URL, or `nil`
    /// if there isn't one or it can no longer be resolved (e.g. the volume
    /// was unmounted) — callers should fall back to
    /// `defaultModelsDirectory` in that case rather than crash.
    ///
    /// On success, starts accessing the security-scoped resource and never
    /// stops: `ModelStore`'s root is something Quail needs access to for
    /// as long as it's running, not for one bounded operation, so there's
    /// no natural point at which to call
    /// `stopAccessingSecurityScopedResource()` earlier than app exit
    /// (which reclaims it anyway). This matters for the App Store build's
    /// sandbox; the direct build already has full filesystem access and
    /// this call is a harmless no-op there.
    static func resolveModelsDirectory(bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    /// Creates a security-scoped bookmark for a user-chosen models folder.
    /// Nothing calls this yet — it's the mechanism the Models pane
    /// (docs/IMPLEMENTATION_PLAN.md Phase 2 step 7) will use once it lets
    /// someone actually relocate the store via an open panel.
    static func makeModelsDirectoryBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The vendored `llama-server`, embedded as a sibling of Quail's own
    /// executable in `Contents/MacOS` by `task embed:llama` on every
    /// build — see that script and D-009.
    static var llamaServerExecutable: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: "/dev/null"))
            .deletingLastPathComponent()
            .appendingPathComponent("llama-server", isDirectory: false)
    }

    /// Creates the two fixed directories this enum points at, if missing.
    /// Safe to call repeatedly (e.g. on every app launch). The model
    /// store's own subdirectories are `ModelStore.ensureDirectoriesExist`'s
    /// job instead, since that root can move — see `resolveModelsDirectory`
    /// above.
    static func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        for url in [applicationSupport, logs] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
