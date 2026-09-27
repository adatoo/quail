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
