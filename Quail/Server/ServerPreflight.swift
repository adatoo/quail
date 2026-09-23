import Darwin
import Foundation
import os

/// What `ServerController.start` checks before it launches anything:
/// clean up any `llama-server` a previous Quail run left behind, then make
/// sure nothing else is already listening on the endpoint's port.
///
/// Found by live testing: stopping Quail from Xcode (or any `SIGKILL`)
/// can't be intercepted, so its `llama-server` child survives as an
/// orphan still bound to the port. Every later Start then launched a new
/// server that couldn't bind and exited — but the health check polled the
/// same host:port, the *orphan* answered `ok`, and the menu went green for
/// a server that wasn't Quail's. Test then failed with 401 (the orphan had
/// an older API key) and the icon went red once the new process's restarts
/// ran out.
struct PreflightResult: Sendable, Equatable {
    /// Non-nil means "don't launch" — shown as the failure reason.
    var failure: String?
    /// Lines for the Logs window (what was cleaned up), so the reaping is
    /// visible rather than silent.
    var notes: [String] = []
}

enum ServerPreflight {
    /// The production preflight: reap Quail's own orphans (matched by the
    /// presets file every Quail-launched router is given), then refuse to
    /// start if the port is still taken — naming whoever holds it.
    static let live: @Sendable (EndpointConfig) async -> PreflightResult = { config in
        var notes: [String] = []
        // llama-server truncates its --log-file on every launch, so a
        // failed Start used to erase the only record of the run before it.
        // (llama.cpp is the only runtime ServerController launches today.)
        rotateLog(Paths.logFile(for: .llamaCpp))
        if let signature = config.presetsFile?.path {
            let reaped = await OrphanReaper.reap(signature: signature)
            if !reaped.isEmpty {
                notes.append(
                    "Stopped \(reaped.count) llama-server process(es) left behind by an earlier Quail run: pid \(reaped.map(String.init).joined(separator: ", "))"
                )
            }
        }

        let probeHost = config.host == "0.0.0.0" ? "127.0.0.1" : config.host
        if PortCheck.isListening(host: probeHost, port: config.port) {
            let owner = PortCheck.listenerDescription(port: config.port) ?? "another process"
            return PreflightResult(
                failure: "Port \(config.port) is already in use by \(owner). Quit it, or choose a different port in Settings → Endpoint.",
                notes: notes
            )
        }
        return PreflightResult(failure: nil, notes: notes)
    }

    /// Moves `log` to `<name>.previous.log`, replacing any older one, so
    /// exactly one prior run survives. A missing `log` is a no-op.
    static func rotateLog(_ log: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: log.path) else { return }
        let previous = log.deletingPathExtension().appendingPathExtension("previous.log")
        try? fileManager.removeItem(at: previous)
        try? fileManager.moveItem(at: log, to: previous)
    }
}

/// Finds and stops `llama-server` processes a previous Quail run launched
/// and then lost track of (parent gone, so reparented to launchd, pid 1).
enum OrphanReaper {
    struct ProcessRow: Sendable, Equatable {
        var pid: Int32
        var ppid: Int32
        var command: String
    }

    private static let logger = Logger(subsystem: "com.datoos.quail", category: "OrphanReaper")

    /// Parses `ps -axww -o pid=,ppid=,command=` output. Pure, so the
    /// selection logic below is unit-testable without real processes.
    static func parse(psOutput: String) -> [ProcessRow] {
        psOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { return nil }
            return ProcessRow(pid: pid, ppid: ppid, command: String(fields[2]))
        }
    }

    /// Orphaned Quail routers: a `llama-server` whose parent is launchd
    /// (pid 1) and whose arguments include `signature` (this store's
    /// presets file — every router Quail launches gets it, and nothing
    /// else does). A live Quail's own child has Quail as its parent, so
    /// it's never selected; neither is some other app's `llama-server`
    /// (different arguments). Returns the routers plus their children
    /// (the per-model instances router mode forks), children last.
    static func orphans(matching signature: String, in rows: [ProcessRow]) -> (routers: [Int32], children: [Int32]) {
        let routers = rows.filter {
            $0.ppid == 1 && $0.command.contains("llama-server") && $0.command.contains(signature)
        }.map(\.pid)
        let routerSet = Set(routers)
        let children = rows.filter { routerSet.contains($0.ppid) }.map(\.pid)
        return (routers, children)
    }

    /// Stops every orphan `orphans(matching:in:)` finds: `SIGTERM` the
    /// router (llama-server's own shutdown stops its model children — see
    /// D-009), wait up to `timeout` for it to exit, then `SIGKILL`
    /// anything still alive. Returns the pids it signalled.
    @discardableResult
    static func reap(signature: String, timeout: TimeInterval = 5) async -> [Int32] {
        let found = orphans(matching: signature, in: parse(psOutput: runPS()))
        guard !found.routers.isEmpty else { return [] }
        logger.notice("reaping orphaned llama-server(s): \(found.routers, privacy: .public)")

        for pid in found.routers {
            kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, (found.routers + found.children).contains(where: isAlive) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        for pid in found.children + found.routers where isAlive(pid) {
            kill(pid, SIGKILL)
        }
        return found.routers + found.children
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private static func runPS() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Is something already accepting connections on a port — and if so, who.
enum PortCheck {
    /// A plain TCP connect to `host:port`. Succeeds only if something is
    /// listening; a closed port is refused immediately on loopback.
    static func isListening(host: String, port: Int) -> Bool {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(result) }

        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                let connected = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
                close(fd)
                if connected {
                    return true
                }
            }
            cursor = info.pointee.ai_next
        }
        return false
    }

    /// "llama-server (pid 83828)" for whoever is listening on `port`, via
    /// `lsof`; `nil` if that can't be determined (e.g. sandboxed build).
    static func listenerDescription(port: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var pid: String?
        var command: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil {
                pid = String(line.dropFirst())
            } else if line.hasPrefix("c"), command == nil {
                command = String(line.dropFirst())
            }
        }
        guard let pid else { return nil }
        return "\(command ?? "a process") (pid \(pid))"
    }
}
