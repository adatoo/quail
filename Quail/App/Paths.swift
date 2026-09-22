import Foundation

/// Fixed, explicit filesystem locations for everything Quail writes.
///
/// Per AGENTS.md: Quail never writes outside `Application Support/Quail`,
/// `Logs/Quail`, and the user-chosen model store, and runtimes are always
/// given explicit paths rather than relying on their own defaults.
enum Paths {
    /// `~/Library/Application Support/Quail`
    static let applicationSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Quail", isDirectory: true)
    }()

    /// `~/Library/Logs/Quail`
    static let logs: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("Quail", isDirectory: true)
    }()

    /// `~/Library/Application Support/Quail/config.json`
    static var configFile: URL {
        applicationSupport.appendingPathComponent("config.json", isDirectory: false)
    }

    /// `~/Library/Application Support/Quail/Models` — the default model
    /// store. Relocatable via a security-scoped bookmark in a later PR
    /// (docs/ARCHITECTURE.md §6); this is the default before a user moves it.
    static var defaultModelsDirectory: URL {
        applicationSupport.appendingPathComponent("Models", isDirectory: true)
    }

    /// `~/Library/Application Support/Quail/Models/gguf`
    static var defaultGGUFDirectory: URL {
        defaultModelsDirectory.appendingPathComponent("gguf", isDirectory: true)
    }

    /// `~/Library/Logs/Quail/<runtimeID>.log`
    static func logFile(for runtime: RuntimeID) -> URL {
        logs.appendingPathComponent("\(runtime.rawValue).log", isDirectory: false)
    }

    /// Creates every directory this enum points at, if missing. Safe to call
    /// repeatedly (e.g. on every app launch).
    static func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        for url in [applicationSupport, logs, defaultGGUFDirectory] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
