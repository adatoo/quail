import Darwin
import Foundation

/// Talking to Quail.app: send a control request, launching the app first
/// if its socket isn't there.
enum AppLink {
    static func request(_ request: ControlRequest, launchIfNeeded: Bool = true) async throws -> ControlResponse {
        do {
            return try await send(request)
        } catch let error as LineSocket.SocketError {
            guard case let .system(_, code) = error, code == ENOENT || code == ECONNREFUSED else { throw error }
            guard launchIfNeeded else {
                if request.command == .status {
                    // Not running is a status, not an error.
                    return ControlResponse(ok: true, status: StatusInfo(
                        phase: "not running", label: "Quail isn't running", detail: "Run `quail start`.",
                        modelsChangedSinceStart: false
                    ))
                }
                throw CLIError("Quail isn't running. Run `quail start`.")
            }
            try launchApp()
            for _ in 0 ..< 60 {
                try await Task.sleep(for: .milliseconds(250))
                if let response = try? await send(request) {
                    return response
                }
            }
            throw CLIError("Quail didn't start answering within 15 seconds.")
        }
    }

    private static func send(_ request: ControlRequest) async throws -> ControlResponse {
        try await Task.detached { try LineSocket.request(request) }.value
    }

    static func check(_ response: ControlResponse) throws {
        guard response.ok else { throw CLIError(response.error ?? "Quail reported an error.") }
    }

    /// Makes sure the server is up (starting it if needed) and returns its
    /// status.
    @discardableResult
    static func ensureRunning(announce: Bool = true) async throws -> StatusInfo {
        let status = try await request(ControlRequest(command: .status))
        if status.status?.phase == "ready", let info = status.status {
            return info
        }
        if announce {
            FileHandle.standardError.write(Data("Starting Quail's server…\n".utf8))
        }
        let started = try await request(ControlRequest(command: .start))
        try check(started)
        guard let info = started.status else { throw CLIError("No status from Quail.") }
        return info
    }

    /// Opens the Quail.app this CLI ships inside (resolving the symlink
    /// `Install Command Line Tool` made), in the background; falls back to
    /// whichever Quail Launch Services knows.
    private static func launchApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let app = enclosingApp() {
            process.arguments = ["-g", app.path]
        } else {
            process.arguments = ["-g", "-b", "com.datoos.quail"]
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError("Couldn't open Quail.app — is it installed?")
        }
    }

    static func enclosingApp() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        var url = executable
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" {
                return url
            }
        }
        return nil
    }
}
