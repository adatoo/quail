import Foundation

/// What `quail-server` was asked to do.
enum ServerCommand: Equatable, Sendable {
    case run(ServerArguments)
    case help
    case version
}

struct ServerArgumentsError: Error, Equatable, LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

/// `quail-server`'s command line. The flags `LlamaCppRuntime.launchSpec`
/// passes to `llama-server` keep their names, so the adapter that launches
/// this server (Phase 3 step 6) is close to a copy of that one.
struct ServerArguments: Equatable, Sendable {
    /// Which engine serves models. `auto` is the real engines; `echo` is the
    /// deterministic test engine, available in Debug builds only.
    enum EngineChoice: String, Equatable, Sendable {
        case auto
        case echo
    }

    var host = "127.0.0.1"
    var port = 8080
    var apiKey: String?
    /// The store's `gguf/` folder (one `.gguf` per model).
    var modelsDirectory: URL?
    /// The store's `mlx/` folder (one directory per model, with a `config.json`).
    var mlxDirectory: URL?
    var presetsFile: URL?
    var modelsMax = 1
    var logFile: URL?
    var engine = EngineChoice.auto

    static let usage = """
    usage: quail-server [options]

      --host <addr>          address to bind (default 127.0.0.1)
      --port <n>             port to bind (default 8080)
      --api-key <key>        require this key (Authorization: Bearer / x-api-key); /health stays open
      --models-dir <dir>     folder of .gguf models
      --mlx-dir <dir>        folder of MLX model directories
      --models-preset <ini>  per-model settings (llama-server preset format)
      --models-max <n>       models kept loaded at once (default 1)
      --log-file <path>      also append the log to this file
      --version, --help
    """

    static func parse(_ arguments: [String]) throws -> ServerCommand {
        var result = ServerArguments()
        var index = 0

        func value(for flag: String, inline: String?) throws -> String {
            if let inline {
                return inline
            }
            index += 1
            guard index < arguments.count else { throw ServerArgumentsError(message: "\(flag) needs a value") }
            return arguments[index]
        }

        while index < arguments.count {
            let raw = arguments[index]
            var flag = raw
            var inline: String?
            if raw.hasPrefix("--"), let equals = raw.firstIndex(of: "=") {
                flag = String(raw[..<equals])
                inline = String(raw[raw.index(after: equals)...])
            }
            switch flag {
            case "--help", "-h":
                return .help
            case "--version":
                return .version
            case "--host":
                result.host = try value(for: flag, inline: inline)
            case "--port":
                let text = try value(for: flag, inline: inline)
                guard let port = Int(text), (0 ... 65535).contains(port) else {
                    throw ServerArgumentsError(message: "--port must be 0–65535, not \"\(text)\"")
                }
                result.port = port
            case "--api-key":
                let key = try value(for: flag, inline: inline)
                result.apiKey = key.isEmpty ? nil : key
            case "--models-dir":
                result.modelsDirectory = try URL(fileURLWithPath: value(for: flag, inline: inline))
            case "--mlx-dir":
                result.mlxDirectory = try URL(fileURLWithPath: value(for: flag, inline: inline))
            case "--models-preset":
                result.presetsFile = try URL(fileURLWithPath: value(for: flag, inline: inline))
            case "--models-max":
                let text = try value(for: flag, inline: inline)
                guard let count = Int(text), count >= 1 else {
                    throw ServerArgumentsError(message: "--models-max must be at least 1, not \"\(text)\"")
                }
                result.modelsMax = count
            case "--log-file":
                result.logFile = try URL(fileURLWithPath: value(for: flag, inline: inline))
            #if DEBUG
                case "--engine":
                    let text = try value(for: flag, inline: inline)
                    guard let choice = EngineChoice(rawValue: text) else {
                        throw ServerArgumentsError(message: "--engine must be auto or echo, not \"\(text)\"")
                    }
                    result.engine = choice
            #endif
            default:
                throw ServerArgumentsError(message: "unknown option \(raw)")
            }
            index += 1
        }

        if result.modelsDirectory == nil, result.mlxDirectory == nil {
            throw ServerArgumentsError(message: "give at least one of --models-dir or --mlx-dir")
        }
        return .run(result)
    }
}
