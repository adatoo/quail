import Foundation
import Testing
@testable import Quail

/// Exercises `ProcessSupervisor` against real, trivial system binaries —
/// no llama-server needed. `/bin/sleep` stands in for a long-running
/// server; a tiny shell script that exits immediately stands in for a
/// crashing one.
@Suite("ProcessSupervisor", .timeLimit(.minutes(1)))
struct ProcessSupervisorTests {
    private static func spec(_ executable: String, _ arguments: [String]) -> LaunchSpec {
        LaunchSpec(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: [:],
            currentDirectoryURL: nil
        )
    }

    @Test("intentional stop reports willRestart = false and no further events")
    func stopDoesNotRestart() async throws {
        let supervisor = ProcessSupervisor()
        let events = await supervisor.start(spec: Self.spec("/bin/sleep", ["30"]))

        // Give it a moment to actually be running before stopping it.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await supervisor.isRunning)

        await supervisor.stop()

        var collected: [ProcessSupervisor.Event] = []
        for await event in events {
            collected.append(event)
        }

        #expect(collected.count == 1)
        if case let .exited(_, willRestart, _) = collected.first {
            #expect(willRestart == false)
        } else {
            Issue.record("expected an .exited event, got \(String(describing: collected.first))")
        }
        #expect(await supervisor.isRunning == false)
    }

    @Test("unexpected exit restarts up to maxRestarts, then gives up")
    func exhaustsRestartsWithBackoff() async {
        // A script that exits immediately with a nonzero status every time,
        // simulating a crash loop. Tiny backoff keeps the test fast.
        let supervisor = ProcessSupervisor(maxRestarts: 3, backoff: [0.01, 0.01, 0.01])
        let events = await supervisor.start(spec: Self.spec("/usr/bin/false", []))

        var collected: [ProcessSupervisor.Event] = []
        for await event in events {
            collected.append(event)
        }

        let exits = collected.compactMap { event -> (status: Int32, willRestart: Bool, attempt: Int)? in
            if case let .exited(status, willRestart, attempt) = event {
                return (status, willRestart, attempt)
            }
            return nil
        }

        // 3 restarts attempted (willRestart = true), then a final terminal
        // exit (willRestart = false).
        #expect(exits.count == 4)
        // Deliberately not \.willRestart: #expect's macro expansion can't
        // prove a KeyPath-as-function argument to the rethrowing
        // allSatisfy is non-throwing here, and fails to compile ("call can
        // throw, but it is not marked with 'try'") even though the
        // equivalent closure literal below compiles fine.
        // swiftformat:disable:next preferKeyPath
        #expect(exits.dropLast().allSatisfy { $0.willRestart })
        #expect(exits.last?.willRestart == false)
        #expect(exits.last?.attempt == 3)
    }

    @Test("a process that runs fine is not restarted")
    func healthyProcessIsNotRestarted() async throws {
        let supervisor = ProcessSupervisor(maxRestarts: 3, backoff: [0.01])
        let events = await supervisor.start(spec: Self.spec("/bin/sleep", ["30"]))

        try await Task.sleep(for: .milliseconds(200))
        #expect(await supervisor.isRunning)
        await supervisor.stop()

        var collected: [ProcessSupervisor.Event] = []
        for await event in events {
            collected.append(event)
        }
        #expect(collected.count == 1)
    }

    @Test("stdout is forwarded as log events")
    func forwardsStdout() async {
        // /bin/sleep, not /bin/echo: echo exits with status 0 almost
        // immediately, which ProcessSupervisor correctly treats as an
        // *unexpected* exit for a long-running server and retries with the
        // real 2/4/8s back-off — turning this into a 14s test for reasons
        // that have nothing to do with what it's checking. A long-lived
        // process plus an explicit stop() once we've seen the line avoids
        // that entirely and matches how a real caller would use this API.
        let supervisor = ProcessSupervisor()
        let events = await supervisor.start(spec: Self.spec("/bin/sh", ["-c", "echo 'hello from the child'; sleep 30"]))

        var sawLine = false
        for await event in events {
            if case let .log(.stdout, text) = event, text.contains("hello from the child") {
                sawLine = true
                break
            }
        }
        await supervisor.stop()

        #expect(sawLine)
    }

    @Test("currentProcessID is available while running and nil once stopped")
    func exposesProcessID() async throws {
        let supervisor = ProcessSupervisor()
        _ = await supervisor.start(spec: Self.spec("/bin/sleep", ["30"]))

        try await Task.sleep(for: .milliseconds(200))
        let pid = await supervisor.currentProcessID
        #expect(pid != nil)
        if let pid {
            #expect(pid > 0)
        }

        await supervisor.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await supervisor.currentProcessID == nil)
    }
}
