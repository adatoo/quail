import ArgumentParser
import Darwin
import Foundation

/// `quail launch <tool>` — start a coding tool already pointed at Quail,
/// like `ollama launch`: the recipe comes from the app (integrations.json,
/// the same verified configs as the Connect tab), applied as environment
/// variables, arguments and temp files — never by editing the tool's own
/// config files.
struct Launch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start a coding tool pointed at Quail (claude, codex, opencode, qwen, aider, goose).",
        discussion: """
        Arguments after -- are passed to the tool, e.g. `quail launch opencode -- run "fix the tests"`. \
        Nothing in the tool's own config files changes; the settings apply to this run only.
        """
    )

    @Argument(help: "claude, codex, opencode, qwen, aider or goose.") var tool: String?
    @Option(name: .shortAndLong, help: "Model to use (default: the default model).") var model: String?
    @Argument(parsing: .postTerminator, help: "Passed through to the tool.") var passthrough: [String] = []

    func run() async throws {
        try await AppLink.ensureRunning()
        let response = try await AppLink.request(ControlRequest(command: .launch, tool: tool ?? "", model: model))
        try AppLink.check(response)
        guard let launch = response.launch else { throw CLIError("No launch recipe from Quail.") }
        for warning in launch.warnings {
            FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
        }

        var tempDir = ""
        if !launch.files.isEmpty {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("quail-launch-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, contents) in launch.files {
                let file = dir.appendingPathComponent(name)
                try contents.write(to: file, atomically: true, encoding: .utf8)
                chmod(file.path, 0o600) // may contain the API key
            }
            tempDir = dir.path
        }
        func fill(_ text: String) -> String {
            text.replacingOccurrences(of: "{{tempDir}}", with: tempDir)
        }

        for (key, value) in launch.env {
            setenv(key, fill(value), 1)
        }
        // A flag newer versions need and older ones refuse (opencode's --standalone) goes only to a version that has
        // it.
        let installed = launch.trailingArgsMinVersion == nil ? nil : Self.version(of: launch.command)
        let trailing = ToolVersion.allows(installed: installed, minimum: launch.trailingArgsMinVersion)
            ? (launch.trailingArgs ?? []).map(fill) : []
        let arguments = [launch.command] + launch.args.map(fill) + passthrough + trailing
        let cArgs = arguments.map { strdup($0) } + [nil]
        execvp(launch.command, cArgs) // only returns on failure
        throw CLIError(
            "Couldn't run '\(launch.command)' — is it installed and on your PATH? (\(String(cString: strerror(errno))))"
        )
    }

    /// What `<command> --version` prints, found on the PATH as `execvp` will find it; nil if it can't be run.
    static func version(of command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command, "--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
