import Darwin
import Foundation
import Testing
@testable import Quail

/// The orphan-selection logic is pure (parsed `ps` output in, pids out) so
/// it's tested without spawning or killing anything real. `PortCheck` is
/// tested against a real listening socket on an ephemeral port.
@Suite("ServerPreflight", .timeLimit(.minutes(1)))
struct ServerPreflightTests {
    private static let presets = "/Users/me/Library/Application Support/Quail/Models/presets.ini"

    /// Shaped like the live case that motivated this: an orphaned router
    /// (ppid 1) with a model child, a live Quail's own router (ppid = Quail),
    /// and some other app's llama-server that's also an orphan.
    private static let psOutput = """
      1     0 /sbin/launchd
    83828     1 /Applications/Quail.app/Contents/Resources/llama-server --models-preset \(presets) --port 8080
    53139 83828 /Applications/Quail.app/Contents/Resources/llama-server --model /x/Qwen3-0.6B-Q8_0.gguf --port 50123
    27478     1 /Applications/Quail.app/Contents/MacOS/Quail
    40000 27478 /Applications/Quail.app/Contents/Resources/llama-server --models-preset \(presets) --port 8080
    61000     1 /opt/hermes/llama-server --model /opt/hermes/m.gguf --port 18434
    garbage line
    """

    @Test("parse reads pid, ppid and the full command, skipping malformed lines")
    func parse() {
        let rows = OrphanReaper.parse(psOutput: Self.psOutput)
        #expect(rows.count == 6)
        #expect(rows[1] == .init(
            pid: 83828,
            ppid: 1,
            command: "/Applications/Quail.app/Contents/Resources/llama-server --models-preset \(Self.presets) --port 8080"
        ))
    }

    @Test("selects only orphaned routers carrying our presets path, plus their children")
    func selectsOnlyOurOrphans() {
        let rows = OrphanReaper.parse(psOutput: Self.psOutput)
        let found = OrphanReaper.orphans(matching: Self.presets, in: rows)
        #expect(found.routers == [83828])
        #expect(found.children == [53139])
    }

    @Test("an orphaned quail-server is reaped like an orphaned llama-server")
    func quailServerOrphans() {
        let rows = OrphanReaper.parse(psOutput: """
        70000     1 /Applications/Quail.app/Contents/MacOS/quail-server --models-preset \(Self.presets) --port 8080
        70001     1 /usr/local/bin/quail-server --models-dir /elsewhere --port 9000
        """)
        #expect(OrphanReaper.orphans(matching: Self.presets, in: rows).routers == [70000])
    }

    @Test("a live Quail's own router is never selected")
    func liveChildIsSafe() {
        let rows = OrphanReaper.parse(psOutput: Self.psOutput).filter { $0.pid != 83828 && $0.pid != 53139 }
        let found = OrphanReaper.orphans(matching: Self.presets, in: rows)
        #expect(found.routers.isEmpty)
        #expect(found.children.isEmpty)
    }

    @Test("rotateLog keeps exactly one previous run's log")
    func rotateLog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("llamaCpp.log")
        let previous = dir.appendingPathComponent("llamaCpp.previous.log")

        ServerPreflight.rotateLog(log) // nothing there yet: no-op
        #expect(!FileManager.default.fileExists(atPath: previous.path))

        try "run 1".write(to: log, atomically: true, encoding: .utf8)
        ServerPreflight.rotateLog(log)
        try "run 2".write(to: log, atomically: true, encoding: .utf8)
        ServerPreflight.rotateLog(log)

        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(try String(contentsOf: previous, encoding: .utf8) == "run 2")
    }

    @Test("isListening is true for a bound port and false once it's closed")
    func portCheck() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))

        #expect(PortCheck.isListening(host: "127.0.0.1", port: port))
        close(fd)
        #expect(!PortCheck.isListening(host: "127.0.0.1", port: port))
    }
}
