import Foundation

/// Identifies one of the three runtimes Quail can drive. Raw values are also
/// used as log file stems (`Paths.logFile(for:)`) and config values.
enum RuntimeID: String, Sendable, CaseIterable, Codable {
    case llamaCpp
    case omlx
    case rapidMLX
}

/// GGUF (llama.cpp) or MLX safetensors (oMLX, Rapid-MLX).
enum ModelFormat: String, Sendable, CaseIterable, Codable {
    case gguf
    case mlxSafetensors
}

/// Whether a runtime's supporting software (for the two uv-installed
/// runtimes) is present, and at what version. llama.cpp is always `.bundled`.
enum InstallState: Sendable, Equatable {
    case bundled
    case installed(version: String)
    case missing
    case updateAvailable(String)
}

/// A model as a runtime's API identifies it — e.g. the router's model id
/// from `GET /models`. `ModelStore` (PR 7) owns the richer catalog entry
/// this is derived from; this is deliberately minimal until then.
struct ModelRef: Sendable, Equatable, Codable {
    let id: String
}

/// Exe/args/env/cwd for `ProcessSupervisor` to launch. `environment` is
/// always used as-is — never merged with the app's own environment — per
/// AGENTS.md ("never inherit the user's shell environment").
struct LaunchSpec: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryURL: URL?
}

/// Server-configurable bits that don't yet warrant the full `Config.swift`
/// (PR 6): host/port/API key/models directory/how many models a router-mode
/// runtime may hold loaded at once.
struct EndpointConfig: Sendable, Equatable {
    var host: String = "127.0.0.1"
    var port: Int = 8080
    var apiKey: String?
    var modelsDirectory: URL
    var modelsMax: Int = 1
}

/// Result of `Runtime.health(base:apiKey:)`. `status` is kept as the raw string
/// llama-server returns (`"ok"`) rather than an enum, since it's the only
/// value observed and other runtimes may report differently.
struct Health: Sendable, Equatable, Decodable {
    let status: String
    var isUp: Bool {
        status == "ok"
    }
}

/// One row from `GET /models` (router mode). Only the fields Quail currently
/// uses are decoded; extra JSON fields (`path`, `architecture`, `meta`, …)
/// are ignored by `Decodable` rather than modeled, so a future llama-server
/// response with more fields doesn't require a code change.
struct ServedModel: Sendable, Equatable, Identifiable, Decodable {
    let id: String
    let status: Status

    struct Status: Sendable, Equatable, Decodable {
        /// One of "unloaded" | "loading" | "loaded" | "downloading" |
        /// "sleeping" per the llama-server router-mode README — kept as a
        /// raw string (not an enum) since the API is still evolving
        /// upstream and an unrecognised value shouldn't fail to decode.
        let value: String
        let failed: Bool?
        let exitCode: Int?

        private enum CodingKeys: String, CodingKey {
            case value
            case failed
            case exitCode = "exit_code"
        }
    }
}

/// Result of `Runtime.select(model:base:apiKey:)`.
enum SelectAction: Sendable, Equatable {
    /// The runtime swapped models without restarting (llama.cpp router
    /// mode's `POST /models/load`).
    case hotSwapped
    /// The runtime needs a full process restart to switch models
    /// (Rapid-MLX, one model per instance).
    case needsRestart
}

/// Errors from the HTTP calls a `Runtime` makes to its own server.
enum RuntimeError: Error, Sendable, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case decoding(String)
}

/// One of the three servers Quail can start: llama.cpp (bundled), oMLX or
/// Rapid-MLX (installed on demand, later phases). Every adapter is a thin,
/// honest view of what the runtime already exposes — see
/// docs/ARCHITECTURE.md §1 and §4.
protocol Runtime: Sendable {
    var id: RuntimeID { get }
    var supportedFormats: Set<ModelFormat> { get }
    var installState: InstallState { get async }

    func launchSpec(config: EndpointConfig, model: ModelRef?) -> LaunchSpec

    /// `apiKey` is whatever `--api-key` the runtime was launched with, or
    /// `nil`. Confirmed empirically against a real b11081 build: `/health`
    /// is exempt from auth, but `/models`, `/v1/models` and
    /// `/v1/chat/completions` all 401 without it once `--api-key` is set —
    /// so every call here takes it, even though `health` doesn't strictly
    /// need it today, for one consistent rule callers don't have to
    /// special-case.
    func health(base: URL, apiKey: String?) async throws -> Health
    func listModels(base: URL, apiKey: String?) async throws -> [ServedModel]
    func select(model: ModelRef, base: URL, apiKey: String?) async throws -> SelectAction

    /// The runtime's own web UI at this base URL, if it has one (llama.cpp's
    /// built-in chat/model UI, oMLX's `/admin`). `nil` for Rapid-MLX.
    func webUIURL(base: URL) -> URL?
}
