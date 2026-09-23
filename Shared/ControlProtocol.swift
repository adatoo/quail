import Foundation

// The `quail` CLI ↔ Quail.app control protocol: one JSON object per line
// over a Unix domain socket (`ControlPaths.socketURL`). The app owns the
// server (ADR D-003); the CLI asks it to act and report. Compiled into both
// targets, so the two sides can't drift.

enum ControlPaths {
    /// `~/Library/Application Support/Quail/control.sock` — the same
    /// directory as `Paths.applicationSupport`. The socket file is created
    /// mode 0600: only this user can connect.
    static var socketURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Quail", isDirectory: true).appendingPathComponent("control.sock")
    }
}

enum ControlCommand: String, Codable, Sendable {
    case status, start, stop, restart, list, ps, endpoint, launch, logs, service
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

struct ServiceInfo: Codable, Sendable, Equatable {
    var openAtLogin: Bool
    var autoStartServer: Bool
}

enum ControlCoding {
    static func encodeLine(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    static func decode<T: Decodable>(_: T.Type, line: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: line)
    }
}
