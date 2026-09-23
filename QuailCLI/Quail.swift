import ArgumentParser
import Foundation

/// `quail` — the command-line companion to Quail.app, "like ollama"
/// (docs/IMPLEMENTATION_PLAN.md Phase 2b). A thin client: the app owns the
/// server and the model store (ADR D-003); this asks it to act over the
/// control socket (`ControlProtocol`), launching the app first if needed.
@main
struct Quail: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quail",
        abstract: "Run and use local models served by Quail.",
        version: "0.1.0",
        subcommands: [
            Status.self, Start.self, Stop.self, Restart.self,
            List.self, PS.self, Run.self, Launch.self, Logs.self, Service.self,
        ]
    )
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show whether the server is running, and on what.")
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let response = try await AppLink.request(ControlRequest(command: .status), launchIfNeeded: false)
        guard let status = response.status else { throw CLIError(response.error ?? "No status") }
        if json {
            return try Output.printJSON(status)
        }
        print(Output.statusLine(status))
    }
}

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start the server (launching Quail if needed).")
    func run() async throws {
        let status = try await AppLink.ensureRunning(announce: false)
        print(Output.statusLine(status))
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the server.")
    func run() async throws {
        let response = try await AppLink.request(ControlRequest(command: .stop), launchIfNeeded: false)
        try AppLink.check(response)
        print("Stopped.")
    }
}

struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restart the server — applies model and context changes.")
    func run() async throws {
        let response = try await AppLink.request(ControlRequest(command: .restart))
        try AppLink.check(response)
        if let status = response.status {
            print(Output.statusLine(status))
        }
    }
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed models.",
        aliases: ["ls"]
    )
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let response = try await AppLink.request(ControlRequest(command: .list))
        try AppLink.check(response)
        let models = response.models ?? []
        if json {
            return try Output.printJSON(models)
        }
        guard !models.isEmpty else {
            return print("No models installed. Add one in Quail → Settings → Models.")
        }
        Output.printTable(
            ["NAME", "SIZE", "CONTEXT", "FIT", ""],
            models.map { model in
                [
                    model.id,
                    Output.bytes(model.bytes),
                    "\(model.context / 1024)K\(model.contextIsAutomatic ? " (auto)" : "")",
                    model.fit ?? "?",
                    [model.isDefault ? "default" : nil, model.status == "loaded" ? "loaded" : nil]
                        .compactMap(\.self).joined(separator: ", "),
                ]
            }
        )
    }
}

struct PS: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ps", abstract: "List models loaded in memory.")
    func run() async throws {
        let response = try await AppLink.request(ControlRequest(command: .ps), launchIfNeeded: false)
        try AppLink.check(response)
        let models = response.models ?? []
        guard !models.isEmpty else { return print("No models loaded.") }
        Output.printTable(["NAME", "SIZE", "CONTEXT", "STATUS"], models.map {
            [$0.id, Output.bytes($0.bytes), "\($0.context / 1024)K", $0.status ?? ""]
        })
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show recent server and Quail logs.")
    @Option(name: .short, help: "How many lines.") var n = 50
    @Flag(name: .short, help: "Keep printing new lines.") var follow = false

    func run() async throws {
        var last: String?
        repeat {
            let response = try await AppLink.request(ControlRequest(
                command: .logs,
                lines: follow && last != nil ? 500 : n
            ))
            try AppLink.check(response)
            var lines = response.logLines ?? []
            if let last, let index = lines.lastIndex(of: last) {
                lines = Array(lines[lines.index(after: index)...])
            }
            lines.forEach { print($0) }
            last = lines.last ?? last
            if follow {
                try await Task.sleep(for: .seconds(1))
            }
        } while follow
    }
}

struct Service: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep the server always on: open Quail at login and start the server automatically."
    )
    enum Action: String, ExpressibleByArgument, CaseIterable {
        case enable, disable, status
    }

    @Argument(help: "enable, disable, or status.") var action: Action = .status

    func run() async throws {
        let enabled: Bool? = switch action {
        case .enable: true
        case .disable: false
        case .status: nil
        }
        let response = try await AppLink.request(ControlRequest(command: .service, enabled: enabled))
        try AppLink.check(response)
        guard let service = response.service else { return }
        let on = service.openAtLogin && service.autoStartServer
        print(on
            ? "Always on: Quail opens at login and starts the server automatically."
            :
            "Off: \(service.openAtLogin ? "Quail opens at login" : "Quail doesn't open at login"); the server \(service.autoStartServer ? "starts" : "doesn't start") automatically.")
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}
