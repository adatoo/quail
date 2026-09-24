import Foundation

// The `quail` CLI ↔ Quail.app control protocol: one JSON object per line
// over a Unix domain socket (`ControlPaths.socketURL`). The app owns the
// server (ADR D-003); the CLI asks it to act and report. Compiled into both
// targets, so the two sides can't drift.

enum ControlPaths {
    /// Debug builds only: `QUAIL_DATA_ROOT=/some/dir` moves everything Quail writes
    /// (`Application Support/Quail`, `Logs/Quail`, the control socket) under that
    /// directory, so a test copy of the app — an update test, say — never touches the
    /// real config, models, logs or socket, or auto-starts the real default model.
    /// `HOME` can't do this: Foundation ignores it. Never compiled into a shipped build
    /// (the `quail` CLI, which isn't a Debug-conditioned target, never honours it).
    static var debugDataRoot: URL? {
        #if DEBUG
            // The environment, or a `QuailDataRoot` preference: an updater relaunches the app
            // without its environment, so an update test sets the preference in its own bundle ID's domain.
            (ProcessInfo.processInfo.environment["QUAIL_DATA_ROOT"] ?? UserDefaults.standard
                .string(forKey: "QuailDataRoot"))
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
            nil
        #endif
    }

    /// `~/Library/Application Support/Quail/control.sock` — the same
    /// directory as `Paths.applicationSupport`. The socket file is created
    /// mode 0600: only this user can connect.
    static var socketURL: URL {
        let base = debugDataRoot?.appendingPathComponent("Application Support", isDirectory: true)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Quail", isDirectory: true).appendingPathComponent("control.sock")
    }
}

enum ControlCommand: String, Codable, Sendable {
    case status, start, stop, restart, list, ps, endpoint, launch, logs, service
    /// Runs the benchmark on `model` and answers when it's done.
    case bench
    /// What a running benchmark is doing — polled while `bench` waits.
    case benchProgress
    /// Saved benchmark results, newest first.
    case benchHistory
    /// Downloads `model` (a catalog name or owner/repo, `:quant` optional)
    /// and answers when it's installed.
    case pull
    /// The running download's progress — polled while `pull` waits.
    case pullProgress
    case pullCancel
    /// The downloadable catalog, with what's recommended and installed.
    case catalog
    /// Deletes the installed model `model`.
    case remove
    /// Sets (`model`), clears (`clear`) or reads the default model.
    case setDefault
    /// Sets `model`'s context (`contextSize`, or `automatic`), or reads
    /// its options when neither is given.
    case context
    /// Where things are: endpoint, key, store, logs, settings.
    case config
}

struct ControlRequest: Codable, Sendable, Equatable {
    var command: ControlCommand
    /// `launch`: the integration id or alias ("claude", "codex", …).
    var tool: String?
    /// `launch`: the model to use (default: the default model).
    var model: String?
    /// `logs`: how many recent lines.
    var lines: Int?
    /// `service`: `nil` reads; true/false sets "always on".
    var enabled: Bool?
    /// `context`: a fixed size in tokens.
    var contextSize: Int?
    /// `context`: back to Automatic.
    var automatic: Bool?
    /// `setDefault`: clear it.
    var clear: Bool?
}

struct ControlResponse: Codable, Sendable, Equatable {
    var ok: Bool
    var error: String?
    var status: StatusInfo?
    var models: [ModelInfo]?
    var endpoint: EndpointInfo?
    var launch: ToolLaunch?
    var logLines: [String]?
    var service: ServiceInfo?
    var benchmark: BenchmarkResult?
    var benchmarks: [BenchmarkResult]?
    var benchProgress: BenchProgress?
    var pullProgress: PullProgress?
    var catalog: [CatalogEntryInfo]?
    var contextOptions: ContextOptionsInfo?
    var config: ConfigInfo?
    /// A one-line outcome for commands that change something.
    var message: String?

    static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}

struct StatusInfo: Codable, Sendable, Equatable {
    /// "stopped" | "starting" | "ready" | "stopping" | "failed"
    var phase: String
    var label: String
    var detail: String
    var baseURL: String?
    var defaultModel: String?
    var modelsChangedSinceStart: Bool
    var failure: String?
}

struct ModelInfo: Codable, Sendable, Equatable {
    var id: String
    var format: String
    var bytes: Int64
    var context: Int
    var contextIsAutomatic: Bool
    /// "Comfortable" | "Tight" | "Won't fit" | nil
    var fit: String?
    var isDefault: Bool
    /// The router's status while running: "loaded" | "loading" | "unloaded".
    var status: String?
}

struct EndpointInfo: Codable, Sendable, Equatable {
    /// Reachable from this Mac (loopback when bound to 0.0.0.0).
    var baseURL: String
    var apiKey: String?
    var defaultModel: String?
    var running: Bool
}

/// How to start a tool pointed at Quail — built by the app from
/// `integrations.json`, executed by the CLI.
struct ToolLaunch: Codable, Sendable, Equatable {
    var command: String
    var args: [String]
    var env: [String: String]
    /// File name → contents, written by the CLI into a fresh temporary
    /// directory; `{{tempDir}}` in `args`/`env` is replaced with its path.
    var files: [String: String]
    var warnings: [String]
}

struct BenchProgress: Codable, Sendable, Equatable {
    var running: Bool
    var model: String?
    var step: String
    var fraction: Double
}

struct PullProgress: Codable, Sendable, Equatable {
    var running: Bool
    var repo: String?
    var quant: String?
    var bytesWritten: Int64
    var totalBytes: Int64
    var currentFile: String?
}

struct CatalogEntryInfo: Codable, Sendable, Equatable {
    /// What `quail pull` takes, e.g. "qwen3-8b".
    var id: String
    var name: String
    var paramsB: Double?
    var role: String?
    var ggufRepo: String?
    var quants: [String]
    var defaultQuant: String?
    /// Among this Mac's recommendations (Recommender).
    var recommended: Bool
    /// Installed quants.
    var installed: [String]
}

struct ContextOptionsInfo: Codable, Sendable, Equatable {
    var model: String
    var current: Int
    var isAutomatic: Bool
    /// What Automatic resolves to on this Mac.
    var automatic: Int?
    var options: [Option]

    struct Option: Codable, Sendable, Equatable {
        var tokens: Int
        /// "Comfortable" | "Tight" | "Won't fit" | nil
        var fit: String?
    }
}

struct ConfigInfo: Codable, Sendable, Equatable {
    var version: String
    var runtime: String
    var host: String
    var port: Int
    var baseURL: String
    var apiKeyEnabled: Bool
    var apiKey: String?
    var modelsMax: Int
    var defaultModel: String?
    var modelsDirectory: String
    var logFile: String
    var configFile: String
    var openAtLogin: Bool
    var autoStartServer: Bool
    var running: Bool
}

struct ServiceInfo: Codable, Sendable, Equatable {
    var openAtLogin: Bool
    var autoStartServer: Bool
}

enum ControlCoding {
    static func encodeLine(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    static func decode<T: Decodable>(_: T.Type, line: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: line)
    }
}
