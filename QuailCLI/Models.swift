import ArgumentParser
import Darwin
import Foundation

// CLI v2 (docs/IMPLEMENTATION_PLAN.md Phase 2b step 5): pull, rm, default,
// ctx, config — each asks the app to do what its Settings UI does.

struct Pull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download a model into Quail's store.",
        discussion: """
        Takes a catalog name (`quail pull --list`) or any Hugging Face GGUF repo, \
        with an optional quant: qwen3-8b, qwen3-8b:Q8_0, unsloth/gemma-4-12b-it-GGUF:Q5_K_M. \
        Interrupted downloads resume where they stopped.
        """
    )

    @Argument(help: "A catalog name or owner/repo, optionally :QUANT.")
    var model: String?

    @Flag(name: .shortAndLong, help: "List the catalog: what's recommended for this Mac and what's installed.")
    var list = false

    func validate() throws {
        if !list, model == nil {
            throw ValidationError("Name a model to pull, or use --list.")
        }
    }

    func run() async throws {
        if list {
            let response = try await AppLink.request(ControlRequest(command: .catalog))
            try AppLink.check(response)
            let entries = (response.catalog ?? []).sorted { ($0.recommended ? 0 : 1, $0.id) < (
                $1.recommended ? 0 : 1,
                $1.id
            ) }
            Output.printTable(["NAME", "PARAMS", "QUANTS", "", ""], entries.map { entry in
                [
                    entry.id,
                    entry.paramsB.map { $0 < 1 ? String(format: "%.1fB", $0) : String(format: "%.0fB", $0) } ?? "—",
                    entry.quants.map { $0 == entry.defaultQuant ? "\($0)*" : $0 }.joined(separator: " "),
                    entry.recommended ? "recommended" : "",
                    entry.installed.isEmpty ? "" : "installed: \(entry.installed.joined(separator: " "))",
                ]
            })
            print(Output.dim("* default quant. Pull with: quail pull <name>[:quant]"))
            return
        }
        guard let model else { return }

        let cancel = Self.cancelOnInterrupt()
        let progress = Task { await Self.showProgress() }
        let response = try await AppLink.request(ControlRequest(command: .pull, model: model))
        progress.cancel()
        _ = await progress.value
        cancel.cancel()
        Output.clearStatusLine()
        try AppLink.check(response)
        print(response.message ?? "Done.")
    }

    /// Ctrl-C cancels the download in the app (it resumes on the next pull),
    /// then exits.
    private static func cancelOnInterrupt() -> DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            Task {
                _ = try? await AppLink.request(ControlRequest(command: .pullCancel), launchIfNeeded: false)
                Output.clearStatusLine()
                FileHandle.standardError.write(Data("Cancelled — `quail pull` again to resume.\n".utf8))
                Darwin.exit(130)
            }
        }
        source.resume()
        return source
    }

    private static func showProgress() async {
        guard isatty(STDERR_FILENO) != 0 else { return }
        // Measured from the first reading, not from zero — a resumed
        // download starts with bytes already on disk.
        var lastBytes: Int64?
        var lastTime = Date()
        var rate = 0.0
        while !Task.isCancelled {
            if let progress = try? await AppLink.request(ControlRequest(command: .pullProgress), launchIfNeeded: false)
                .pullProgress, progress.running, progress.totalBytes > 0
            {
                let now = Date()
                if let previous = lastBytes {
                    let elapsed = now.timeIntervalSince(lastTime)
                    if elapsed >= 1 {
                        let instant = Double(progress.bytesWritten - previous) / elapsed
                        rate = rate == 0 ? instant : rate * 0.7 + instant * 0.3
                        lastBytes = progress.bytesWritten
                        lastTime = now
                    }
                } else {
                    lastBytes = progress.bytesWritten
                    lastTime = now
                }
                let fraction = Double(progress.bytesWritten) / Double(progress.totalBytes)
                let width = 24
                let filled = Int(fraction * Double(width))
                let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
                var line = "\(progress.repo ?? "")\(progress.quant.map { ":\($0)" } ?? "")  \(bar) \(Int(fraction * 100))%  "
                line += "\(Output.bytes(progress.bytesWritten)) / \(Output.bytes(progress.totalBytes))"
                if rate > 0 {
                    line += "  \(Output.bytes(Int64(rate)))/s"
                }
                FileHandle.standardError.write(Data("\r\u{1B}[2K\(line)".utf8))
            }
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
    }
}

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Delete an installed model (its file(s) and catalog entry)."
    )

    @Argument(help: "Model name (see `quail list`); a unique prefix is enough.")
    var model: String

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.") var yes = false

    func run() async throws {
        if !yes, isatty(STDIN_FILENO) != 0 {
            print("Delete \(model)? [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine()?.lowercased(), ["y", "yes"].contains(answer) else {
                print("Kept.")
                return
            }
        }
        let response = try await AppLink.request(ControlRequest(command: .remove, model: model))
        try AppLink.check(response)
        print(response.message ?? "Deleted.")
    }
}

struct Default: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or set the default model (loaded when the server starts)."
    )

    @Argument(help: "Model to make the default. Omit to show the current one.")
    var model: String?

    @Flag(help: "Clear the default — models load on first request.") var clear = false

    func run() async throws {
        let response = try await AppLink.request(ControlRequest(command: .setDefault, model: model, clear: clear))
        try AppLink.check(response)
        print(response.message ?? "")
    }
}

struct Ctx: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or set a model's context size.",
        discussion: "Sizes: 4k 8k 16k 32k 64k 128k (or a token count), or auto. Applies on the next start."
    )

    @Argument(help: "Model name (see `quail list`).")
    var model: String

    @Argument(help: "New size, or auto. Omit to see the options and how each fits.")
    var size: String?

    func run() async throws {
        var request = ControlRequest(command: .context, model: model)
        if let size {
            if size.lowercased() == "auto" {
                request.automatic = true
            } else if let tokens = Self.tokens(size) {
                request.contextSize = tokens
            } else {
                throw ValidationError("'\(size)' isn't a size — try 32k, 32768 or auto.")
            }
        }
        let response = try await AppLink.request(request)
        try AppLink.check(response)
        if let options = response.contextOptions {
            let label = { (tokens: Int) in tokens % 1024 == 0 ? "\(tokens / 1024)K" : "\(tokens)" }
            print("\(options.model): \(label(options.current))\(options.isAutomatic ? " (automatic)" : "")")
            Output.printTable(["SIZE", "FIT", ""], options.options.map { option in
                [
                    label(option.tokens),
                    option.fit ?? "unknown",
                    option.tokens == options.current ? "← current" : "",
                ]
            })
            if let automatic = options.automatic {
                print(Output.dim("auto = \(label(automatic)) on this Mac."))
            }
            return
        }
        print(response.message ?? "")
    }

    /// "32k" → 32768, "32768" → 32768.
    static func tokens(_ text: String) -> Int? {
        let lower = text.lowercased()
        if lower.hasSuffix("k"), let value = Int(lower.dropLast()) {
            return value * 1024
        }
        return Int(lower)
    }
}

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show where things are: endpoint, API key, model store, logs and settings."
    )

    @Flag(help: "Show the API key in full.") var showKey = false
    @Flag(help: "Print as JSON.") var json = false

    func run() async throws {
        let response = try await AppLink.request(ControlRequest(command: .config))
        try AppLink.check(response)
        guard var config = response.config else { throw CLIError("No config from Quail.") }
        if !showKey, let key = config.apiKey {
            config.apiKey = key.count > 4 ? String(repeating: "•", count: 8) + key.suffix(4) : "••••"
        }
        if json {
            return try Output.printJSON(config)
        }
        let rows: [(String, String)] = [
            ("Version", config.version),
            ("Server", config.running ? "running" : "stopped"),
            ("Endpoint", config.baseURL),
            ("API key", config.apiKeyEnabled ? (config.apiKey ?? "—") : "off"),
            ("Runtime", config.runtime),
            ("Host / port", "\(config.host):\(config.port)"),
            ("Max loaded models", "\(config.modelsMax)"),
            ("Default model", config.defaultModel ?? "none"),
            ("Models folder", config.modelsDirectory),
            ("Server log", config.logFile),
            ("Settings file", config.configFile),
            ("Open at login", config.openAtLogin ? "yes" : "no"),
            ("Start server on open", config.autoStartServer ? "yes" : "no"),
        ]
        let width = rows.map(\.0.count).max() ?? 0
        for (label, value) in rows {
            print("\(label.padding(toLength: width, withPad: " ", startingAt: 0))   \(value)")
        }
        if !showKey, config.apiKeyEnabled {
            print(Output.dim("--show-key prints the key in full."))
        }
    }
}
