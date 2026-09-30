import Foundation
import Testing
@testable import Quail

@Suite("Activity monitor")
struct ActivityMonitorTests {
    private static func request(
        _ id: Int, _ phase: ServerActivity.Request.Phase, done: Int = 0, total: Int = 1000, speed: Double? = nil
    ) -> ServerActivity.Request {
        .init(
            id: id, model: "m", phase: phase, promptTotal: total, promptDone: done, cached: 0, generated: 10,
            promptPerSecond: nil, predictedPerSecond: speed, seconds: 3
        )
    }

    @Test("the menu bar's words: loading first, then the longest prompt being read, then the total speed")
    func busyLabels() {
        var activity = ServerActivity()
        #expect(activity.busyLabel == nil)
        activity.models = [.init(id: "m", state: "loaded", leases: 0)]
        #expect(activity.busyLabel == nil)
        activity.requests = [Self.request(1, .queued)]
        #expect(activity.busyLabel == "Queued")
        activity.requests = [Self.request(1, .readingPrompt, done: 412, total: 1000)]
        #expect(activity.busyLabel == "Reading 41%")
        activity.requests += [Self.request(2, .generating, speed: 30)]
        #expect(activity.busyLabel == "Reading 41% +1")
        activity.requests = [Self.request(1, .generating, speed: 30.2), Self.request(2, .generating, speed: 22)]
        #expect(activity.busyLabel == "52 tok/s")
        activity.requests = [Self.request(1, .generating)]
        #expect(activity.busyLabel == "Writing…")
        activity.models = [.init(id: "m", state: "loading", loadingSeconds: 3, leases: 0)]
        #expect(activity.busyLabel == "Loading…")
    }

    @Test("decodes what quail-server's GET /slots sends")
    func decodesSlots() throws {
        let json = """
        {"models":[{"id":"Qwen3-8B","state":"loaded","leases":1,"memory_bytes":5000000000}],
         "requests":[{"id":7,"model":"Qwen3-8B","phase":"reading_prompt","prompt_total":13570,"prompt_done":4096,
          "cached":0,"generated":0,"prompt_per_second":332.5,"seconds":12.4}]}
        """
        let activity = try JSONDecoder().decode(ServerActivity.self, from: Data(json.utf8))
        #expect(activity.models.first?.memoryBytes == 5_000_000_000)
        let request = try #require(activity.requests.first)
        #expect(request.phase == .readingPrompt)
        #expect(request.predictedPerSecond == nil)
        #expect(abs(request.promptFraction - 4096.0 / 13570) < 1e-9)
        #expect(activity.isBusy)
    }

    @Test("decodes each request's client and every client's totals, and an older server's reply without them")
    func decodesClients() throws {
        let json = """
        {"models":[],"uptime_seconds":1200.5,
         "requests":[{"id":7,"model":"m","phase":"generating","prompt_total":10,"prompt_done":10,"cached":0,
          "generated":4,"seconds":1,"client":{"agent":"claude-cli","user_agent":"claude-cli/2.1.285","address":"local"}}],
         "clients":[{"agent":"claude-cli","user_agent":"claude-cli/2.1.285","address":"local","requests":3,
          "prompt_tokens":900,"generated_tokens":120,"busy_seconds":41.5,"active":1}]}
        """
        let activity = try JSONDecoder().decode(ServerActivity.self, from: Data(json.utf8))
        #expect(activity.requests.first?.client?.key == ClientKey(agent: "claude-cli", address: "local"))
        #expect(activity.clients.first?.counters == ClientCounters(
            requests: 3, promptTokens: 900, generated: 120, busySeconds: 41.5
        ))
        #expect(activity.uptimeSeconds == 1200.5)
        let older = try JSONDecoder().decode(ServerActivity.self, from: Data(#"{"models":[],"requests":[]}"#.utf8))
        #expect(older.clients.isEmpty)
        #expect(older.uptimeSeconds == nil)
    }

    @Test("a client's name: the tool the Connect list says, else the User-Agent's product; the machine", arguments: [
        ("claude-cli", "claude-cli/2.1.285 (external, sdk-cli)", "local", "Claude Code · this Mac"),
        ("codex_exec", "codex_exec/0.155.0 (Mac OS 26.6.2; arm64)", "local", "OpenAI Codex CLI · this Mac"),
        ("codex_cli_rs", "codex_cli_rs/0.155.0", "192.168.1.20", "OpenAI Codex CLI · 192.168.1.20"),
        ("OpenAI/Python", "OpenAI/Python 3.22.1", "local", "Python · this Mac"),
        ("curl", "curl/8.7.1", "local", "curl · this Mac"),
        ("OpenAI/JS", "OpenAI/JS 4.67.3", "local", "OpenAI/JS · this Mac"),
        ("Quail", "Quail/114 CFNetwork/1568", "local", "Quail · this Mac"),
        ("Mozilla", "Mozilla/5.0 (Macintosh)", "10.0.0.4", "Browser · 10.0.0.4"),
        ("", "", nil, "Unknown app · unknown machine"),
    ] as [(String, String, String?, String)])
    func clientNames(agent: String, userAgent: String, address: String?, expected: String) {
        #expect(!ClientNames.known.isEmpty)
        #expect(ClientNames.label(ClientKey(agent: agent, address: address), userAgent: userAgent) == expected)
    }

    private static func totals(
        _ agent: String, requests: Int, busy: Double, active: Int = 0, generated: Int = 0
    ) -> ServerActivity.ClientTotals {
        .init(
            agent: agent, userAgent: agent, address: "local", requests: requests, promptTokens: requests * 100,
            generatedTokens: generated, busySeconds: busy, active: active
        )
    }

    private static func reading(_ date: Date, _ totals: [ServerActivity.ClientTotals]) -> ClientReading {
        ClientReading(date: date, counters: Dictionary(uniqueKeysWithValues: totals.map { ($0.key, $0.counters) }))
    }

    @Test("a client's load over the window: totals since the window's start, and its busy share, coloured by level")
    func clientLoads() throws {
        let now = Date(timeIntervalSince1970: 10000)
        let window: TimeInterval = 60
        let readings = [
            Self.reading(now.addingTimeInterval(-90), [Self.totals("a", requests: 5, busy: 100)]),
            Self.reading(now.addingTimeInterval(-61), [Self.totals("a", requests: 6, busy: 110)]),
            Self.reading(now.addingTimeInterval(-30), [Self.totals("a", requests: 8, busy: 130)]),
        ]
        var activity = ServerActivity(uptimeSeconds: 5000)
        activity.clients = [
            Self.totals("a", requests: 10, busy: 160, active: 2, generated: 50),
            Self.totals("b", requests: 1, busy: 12), // new inside the window
            Self.totals("c", requests: 0, busy: 0), // seen before the window, nothing since
        ]
        activity.requests = [
            .init(
                id: 1, model: "m", phase: .generating, promptTotal: 1, promptDone: 1, cached: 0, generated: 3,
                promptPerSecond: nil, predictedPerSecond: 40, seconds: 1,
                client: .init(agent: "a", userAgent: "a", address: "local")
            ),
        ]
        let loads = ActivityMonitor.clientLoads(readings: readings, activity: activity, window: window, now: now)
        #expect(loads.map(\.key.agent) == ["a", "b"])
        let a = try #require(loads.first)
        #expect(a.totals.requests == 4) // 10 now, 6 at the window's start
        #expect(abs(a.busyFraction - 50.0 / 60) < 1e-9)
        #expect(a.level == .heavy)
        #expect(a.running == 2)
        #expect(a.tokensPerSecond == 40)
        let b = loads[1]
        #expect(b.totals.requests == 1)
        #expect(abs(b.busyFraction - 0.2) < 1e-9)
        #expect(b.level == .light)
    }

    @Test("a client's load when the server restarted, started inside the window, or polling began inside it")
    func clientLoadsEdges() throws {
        let now = Date(timeIntervalSince1970: 10000)
        let early = [Self.reading(now.addingTimeInterval(-120), [Self.totals("a", requests: 50, busy: 500)])]
        // Restarted: the totals went down, so they count from nothing.
        var restarted = ServerActivity(uptimeSeconds: 5000)
        restarted.clients = [Self.totals("a", requests: 2, busy: 30)]
        let reset = try #require(ActivityMonitor.clientLoads(
            readings: early, activity: restarted, window: 60, now: now
        ).first)
        #expect(reset.totals.requests == 2)
        #expect(reset.level == .moderate)
        // Started 20 s ago, inside a 60 s window: busy 10 s of 20.
        var fresh = ServerActivity(uptimeSeconds: 20)
        fresh.clients = [Self.totals("a", requests: 1, busy: 10)]
        let young = try #require(ActivityMonitor.clientLoads(readings: [], activity: fresh, window: 60, now: now).first)
        #expect(abs(young.busyFraction - 0.5) < 1e-9)
        // Polling began 30 s ago in a 5 minute window: what it saw since.
        var long = ServerActivity(uptimeSeconds: 5000)
        long.clients = [Self.totals("a", requests: 3, busy: 30)]
        let seen = [Self.reading(now.addingTimeInterval(-30), [Self.totals("a", requests: 1, busy: 6)])]
        let partial = try #require(ActivityMonitor.clientLoads(
            readings: seen, activity: long, window: 300, now: now
        ).first)
        #expect(partial.totals.requests == 2)
        #expect(abs(partial.busyFraction - 24.0 / 30) < 1e-9)
        #expect(ClientLoad.Level(busyFraction: 0.249) == .light)
        #expect(ClientLoad.Level(busyFraction: 0.25) == .moderate)
        #expect(ClientLoad.Level(busyFraction: 0.75) == .moderate)
        #expect(ClientLoad.Level(busyFraction: 0.751) == .heavy)
    }

    @Test("client readings are kept for 15 minutes, and cleared when the server stops")
    @MainActor
    func clientReadingsKept() {
        let monitor = ActivityMonitor()
        let start = Date(timeIntervalSince1970: 1_000_000)
        var activity = ServerActivity()
        activity.clients = [Self.totals("a", requests: 1, busy: 1)]
        for second in stride(from: 0, through: 20 * 60, by: 10) {
            monitor.recordClients(activity, at: start.addingTimeInterval(Double(second)))
        }
        #expect(monitor.clientReadings.first?.date == start.addingTimeInterval(5 * 60))
        monitor.stop()
        #expect(monitor.clientReadings.isEmpty)
    }

    @Test("history: kept for 15 minutes, placed by time in the chosen window, broken where sampling paused")
    @MainActor
    func historyWindows() {
        let monitor = ActivityMonitor()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for second in stride(from: 0, through: 20 * 60, by: 2) {
            monitor.record(SystemSample(cpuPercent: 50, gpuPercent: 10), at: start.addingTimeInterval(Double(second)))
        }
        let end = start.addingTimeInterval(20 * 60)
        #expect(monitor.history.first?.date == end.addingTimeInterval(-ActivityMonitor.historySpan))
        #expect(monitor.history.last?.date == end)

        let minute = ActivityMonitor.series(monitor.history, window: 60, now: end) { $0.cpu.map { $0 / 100 } }
        #expect(minute.count == 31) // one every 2 s over 60 s, both ends included
        #expect(minute.first?.x == 0 && minute.last?.x == 1)
        #expect(minute.allSatisfy { $0.y == 0.5 })
        let fifteen = ActivityMonitor.series(monitor.history, window: 900, now: end) { $0.cpu.map { $0 / 100 } }
        #expect(fifteen.count == 451)

        // A pause longer than `maxGap` breaks the line; a missing figure is a break too.
        let paused = [
            ActivityPoint(date: end.addingTimeInterval(-50), cpu: 20),
            ActivityPoint(date: end.addingTimeInterval(-48), cpu: 30),
            ActivityPoint(date: end.addingTimeInterval(-10), cpu: 40),
            ActivityPoint(date: end.addingTimeInterval(-8), cpu: nil),
            ActivityPoint(date: end, cpu: 60),
        ]
        let series = ActivityMonitor.series(paused, window: 60, now: end) { $0.cpu.map { $0 / 100 } }
        #expect(series.map(\.y) == [0.2, 0.3, nil, 0.4, nil, 0.6])
        #expect(HistoryChart.runs(series).map(\.count) == [2, 1, 1])
    }

    @Test("the Mac is sampled while the window watches, with the server stopped; stopping the server keeps it")
    @MainActor
    func watchingWhileStopped() async throws {
        let monitor = ActivityMonitor()
        #expect(!monitor.sampling)
        monitor.watch(true)
        #expect(monitor.sampling)
        for _ in 0 ..< 60 where monitor.history.count < 2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(monitor.history.count >= 2)
        #expect(monitor.system.memoryTotalBytes != nil)
        #expect(!monitor.running)

        // A server starting and stopping doesn't end the window's sampling, or its history.
        try monitor.start(
            base: #require(URL(string: "http://127.0.0.1:9")),
            apiKey: nil,
            processIDs: { [] },
            fallbackLoading: { false }
        )
        #expect(monitor.running)
        monitor.stop()
        #expect(!monitor.running && monitor.sampling)
        #expect(monitor.history.count >= 2)
        #expect(monitor.system.serverMemoryBytes == nil)

        monitor.watch(false)
        #expect(!monitor.sampling)
        let count = monitor.history.count
        try await Task.sleep(for: .milliseconds(700))
        #expect(monitor.history.count == count)
    }

    @Test("the Mac's readings: CPU as a share of ticks, memory within the total, this process measurable")
    func systemReadings() throws {
        #expect(SystemMonitor.percent(busy: 25, total: 100) == 25)
        #expect(SystemMonitor.percent(busy: 0, total: 0) == nil)
        #expect(SystemMonitor.cpuTicks() != nil)
        let memory = SystemMonitor.memory()
        let total = try #require(memory.total)
        let used = try #require(memory.used)
        #expect(used > 0 && used <= total)
        let usage = try #require(SystemMonitor.usage(of: getpid()))
        #expect(usage.footprint > 0)
        // Two samples a moment apart give a CPU figure.
        let monitor = SystemMonitor()
        _ = monitor.sample(serverPIDs: [getpid()])
        var spin = 0.0
        for i in 0 ..< 2_000_000 {
            spin += Double(i).squareRoot()
        }
        let second = monitor.sample(serverPIDs: [getpid()])
        #expect(spin > 0)
        #expect(second.cpuPercent != nil)
        #expect(second.serverCPUPercent != nil)
        #expect((second.serverMemoryBytes ?? 0) > 0)
    }
}
