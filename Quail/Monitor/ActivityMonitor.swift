import Foundation
import Observation

/// What quail-server says it's doing (`GET /slots`, ADR D-060), and who's asking (D-067).
struct ServerActivity: Equatable, Sendable, Decodable {
    /// Who sent a request: the app (its `User-Agent`'s first product, and the whole header) and the machine ("local"
    /// for this Mac, else an IP address).
    struct Client: Equatable, Sendable, Decodable {
        var agent: String
        var userAgent: String
        var address: String?

        var key: ClientKey {
            ClientKey(agent: agent, address: address)
        }

        enum CodingKeys: String, CodingKey {
            case agent, address
            case userAgent = "user_agent"
        }
    }

    /// A client's work since the server started.
    struct ClientTotals: Equatable, Sendable, Decodable {
        var agent: String
        var userAgent: String
        var address: String?
        var requests: Int
        var promptTokens: Int
        var generatedTokens: Int
        var busySeconds: Double
        var active: Int

        var key: ClientKey {
            ClientKey(agent: agent, address: address)
        }

        var counters: ClientCounters {
            ClientCounters(
                requests: requests, promptTokens: promptTokens, generated: generatedTokens, busySeconds: busySeconds
            )
        }

        enum CodingKeys: String, CodingKey {
            case agent, address, requests, active
            case userAgent = "user_agent"
            case promptTokens = "prompt_tokens"
            case generatedTokens = "generated_tokens"
            case busySeconds = "busy_seconds"
        }
    }

    struct Model: Equatable, Sendable, Decodable {
        var id: String
        var state: String
        var loadingSeconds: Double?
        var leases: Int
        var memoryBytes: Int?

        enum CodingKeys: String, CodingKey {
            case id, state, leases
            case loadingSeconds = "loading_seconds"
            case memoryBytes = "memory_bytes"
        }
    }

    struct Request: Equatable, Sendable, Decodable, Identifiable {
        enum Phase: String, Sendable, Decodable {
            case waitingForModel = "waiting_for_model"
            case queued
            case readingPrompt = "reading_prompt"
            case generating
        }

        var id: Int
        var model: String
        var phase: Phase
        var promptTotal: Int
        var promptDone: Int
        var cached: Int
        var generated: Int
        var promptPerSecond: Double?
        var predictedPerSecond: Double?
        var seconds: Double
        /// Nil from a server older than 0.62.
        var client: Client?

        enum CodingKeys: String, CodingKey {
            case id, model, phase, cached, generated, seconds, client
            case promptTotal = "prompt_total"
            case promptDone = "prompt_done"
            case promptPerSecond = "prompt_per_second"
            case predictedPerSecond = "predicted_per_second"
        }

        /// How much of the prompt is read, 0–1.
        var promptFraction: Double {
            promptTotal > 0 ? min(1, Double(promptDone) / Double(promptTotal)) : 0
        }
    }

    var models: [Model] = []
    var requests: [Request] = []
    /// Every client since the server started; empty from a server older than 0.62.
    var clients: [ClientTotals] = []
    var uptimeSeconds: Double?

    var isBusy: Bool {
        !requests.isEmpty || models.contains { $0.state == "loading" }
    }

    /// A few words for the menu bar while something is happening; nil when idle. Loading comes first (nothing
    /// else moves until it's done), then a prompt being read, then the combined writing speed.
    var busyLabel: String? {
        if models.contains(where: { $0.state == "loading" })
            || requests.contains(where: { $0.phase == .waitingForModel })
        {
            return "Loading…"
        }
        let others = requests.count - 1
        let more = others > 0 ? " +\(others)" : ""
        if let reading = requests.filter({ $0.phase == .readingPrompt }).max(by: { $0.promptTotal < $1.promptTotal }) {
            return "Reading \(Int((reading.promptFraction * 100).rounded(.down)))%\(more)"
        }
        let writing = requests.filter { $0.phase == .generating }
        if !writing.isEmpty {
            let speed = writing.compactMap(\.predictedPerSecond).reduce(0, +)
            return speed > 0 ? "\(Int(speed.rounded())) tok/s" : "Writing…"
        }
        if !requests.isEmpty {
            return "Queued"
        }
        return nil
    }
}

extension ServerActivity {
    enum CodingKeys: String, CodingKey {
        case models, requests, clients
        case uptimeSeconds = "uptime_seconds"
    }

    /// Reads an older server's reply too, which has no clients.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decode([Model].self, forKey: .models)
        requests = try container.decode([Request].self, forKey: .requests)
        clients = try container.decodeIfPresent([ClientTotals].self, forKey: .clients) ?? []
        uptimeSeconds = try container.decodeIfPresent(Double.self, forKey: .uptimeSeconds)
    }
}

/// One client: an app on a machine (ADR D-067).
struct ClientKey: Hashable, Sendable {
    var agent: String
    var address: String?
}

/// A client's running totals, as the server counts them from its start.
struct ClientCounters: Equatable, Sendable {
    var requests = 0
    var promptTokens = 0
    var generated = 0
    var busySeconds: Double = 0

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(
            requests: lhs.requests - rhs.requests, promptTokens: lhs.promptTokens - rhs.promptTokens,
            generated: lhs.generated - rhs.generated, busySeconds: lhs.busySeconds - rhs.busySeconds
        )
    }

    /// Whether any figure is below `other`'s: the server restarted in between.
    func fellBelow(_ other: Self) -> Bool {
        requests < other.requests || promptTokens < other.promptTokens || generated < other.generated
            || busySeconds < other.busySeconds - 0.001
    }
}

/// Every client's totals at one `/slots` poll, kept so the Activity window can total the window it shows.
struct ClientReading: Equatable, Sendable {
    var date: Date
    var counters: [ClientKey: ClientCounters]
}

/// One client's load over the Activity window's chosen stretch of time, and right now.
struct ClientLoad: Equatable, Sendable, Identifiable {
    /// How much of the window the client had a request in progress: under 25%, up to 75%, or more.
    enum Level: Equatable, Sendable {
        case light, moderate, heavy

        init(busyFraction: Double) {
            self = busyFraction > 0.75 ? .heavy : busyFraction >= 0.25 ? .moderate : .light
        }
    }

    var key: ClientKey
    var userAgent: String
    /// Its requests in progress now, and their combined writing speed.
    var running: Int
    var tokensPerSecond: Double?
    /// Over the window.
    var totals: ClientCounters
    /// 0–1.
    var busyFraction: Double

    var level: Level {
        Level(busyFraction: busyFraction)
    }

    var id: ClientKey {
        key
    }
}

/// One reading kept for the Activity window's charts: the Mac's CPU, GPU and memory, and the server's memory while
/// it runs.
struct ActivityPoint: Equatable, Sendable {
    var date: Date
    /// 0–100.
    var cpu: Double?
    /// 0–100.
    var gpu: Double?
    var memoryUsed: Int64?
    var memoryTotal: Int64?
    var serverMemory: Int64?
}

/// A point on a chart: `x` from 0 (the window's start) to 1 (now), `y` from 0 to 1. A nil `y` breaks the line (no
/// reading, or a gap in sampling).
struct ChartPoint: Equatable, Sendable {
    var x: Double
    var y: Double?
}

/// Samples the Mac, and polls the server's activity while it runs (ADR D-060): every second while something is
/// happening, every two seconds otherwise. The Mac is sampled while the server runs *or* the Activity window is open,
/// so the window shows CPU, GPU and memory with the server stopped too; nothing runs when neither is true. Keeps 15
/// minutes of readings for the window's charts, which show the last 1, 5 or 15 of them.
@MainActor
@Observable
final class ActivityMonitor {
    private(set) var system = SystemSample()
    private(set) var server = ServerActivity()
    /// Readings, oldest first, trimmed to `historySpan`.
    private(set) var history: [ActivityPoint] = []
    /// Each client's totals at each `/slots` poll, oldest first, trimmed to `historySpan` (ADR D-067).
    private(set) var clientReadings: [ClientReading] = []
    /// Whether the runtime answers `GET /slots` (quail-server does; llama-server's router doesn't).
    private(set) var hasActivity = false
    /// Whether it's polling the server (the server is running).
    private(set) var running = false

    /// How much history is kept: the longest window the Activity window offers.
    static let historySpan: TimeInterval = 15 * 60
    /// The windows the Activity window offers, in minutes.
    static let windowMinutes = [1, 5, 15]
    /// Readings further apart than this are drawn with a break between them (sampling stopped for a while).
    static let maxGap: TimeInterval = 10

    @ObservationIgnored private let sampler = SystemMonitor()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var source: Source?
    /// Set by `show(...)`: the figures are fixed, so opening the window doesn't start real sampling.
    @ObservationIgnored private var frozen = false

    /// What polling the server needs.
    private struct Source {
        let base: URL
        let apiKey: String?
        let processIDs: @Sendable () async -> [Int32]
        let fallbackLoading: @MainActor () -> Bool
    }

    var busyLabel: String? {
        server.busyLabel
    }

    /// Whether the Mac is being sampled now.
    var sampling: Bool {
        task != nil
    }

    /// Starts polling `base`, reading the server's processes from `processIDs`; `fallbackLoading` says whether a
    /// model is loading when the runtime has no `/slots`.
    func start(
        base: URL, apiKey: String?, processIDs: @escaping @Sendable () async -> [Int32],
        fallbackLoading: @escaping @MainActor () -> Bool
    ) {
        source = Source(base: base, apiKey: apiKey, processIDs: processIDs, fallbackLoading: fallbackLoading)
        hasActivity = true
        running = true
        restartLoop()
    }

    /// Stops polling the server. The Mac's readings carry on while the Activity window is open.
    func stop() {
        source = nil
        running = false
        server = ServerActivity()
        clientReadings = []
        system.serverCPUPercent = nil
        system.serverMemoryBytes = nil
        if watchers == 0 {
            stopLoop()
        }
    }

    /// The Activity window says it's open (`true`) or closed (`false`); the Mac is sampled while any is open.
    func watch(_ on: Bool) {
        guard !frozen else { return }
        watchers = max(0, watchers + (on ? 1 : -1))
        if watchers > 0, task == nil {
            restartLoop()
        } else if watchers == 0, source == nil {
            stopLoop()
        }
    }

    private func stopLoop() {
        task?.cancel()
        task = nil
        system = SystemSample()
    }

    private func restartLoop() {
        task?.cancel()
        task = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                let source = source
                let pids = await source?.processIDs() ?? []
                let reading = await Task.detached(priority: .utility) { [sampler] in
                    sampler.sample(serverPIDs: pids)
                }.value
                guard !Task.isCancelled else { return }
                record(reading, at: Date())
                if let source {
                    switch hasActivity ? await Self.fetch(base: source.base, apiKey: source.apiKey) : .unsupported {
                    case let .activity(activity):
                        if self.source != nil {
                            server = activity
                            recordClients(activity, at: Date())
                        }
                    case .unsupported:
                        // No `/slots` (llama-server): loading is all that can be told.
                        hasActivity = false
                        server = ServerActivity(
                            models: source.fallbackLoading() ? [.init(id: "", state: "loading", leases: 0)] : []
                        )
                    case .failed:
                        break // a busy moment; the next poll tries again
                    }
                }
                // CPU is a rate between two readings: the second comes quickly, so the meters fill at once.
                let pause: Duration = first ? .milliseconds(500) : server.isBusy ? .seconds(1) : .seconds(2)
                first = false
                do {
                    try await Task.sleep(for: pause)
                } catch {
                    return
                }
            }
        }
    }

    /// Keeps `reading` and drops what's older than `historySpan`.
    func record(_ reading: SystemSample, at date: Date) {
        system = reading
        history.append(ActivityPoint(
            date: date, cpu: reading.cpuPercent, gpu: reading.gpuPercent, memoryUsed: reading.memoryUsedBytes,
            memoryTotal: reading.memoryTotalBytes, serverMemory: reading.serverMemoryBytes
        ))
        let cutoff = date.addingTimeInterval(-Self.historySpan)
        if let first = history.firstIndex(where: { $0.date >= cutoff }), first > 0 {
            history.removeFirst(first)
        }
    }

    /// Keeps the clients' totals from one poll, and drops what's older than `historySpan`.
    func recordClients(_ activity: ServerActivity, at date: Date) {
        guard !activity.clients.isEmpty || !clientReadings.isEmpty else { return }
        clientReadings.append(ClientReading(
            date: date,
            counters: Dictionary(activity.clients.map { ($0.key, $0.counters) }, uniquingKeysWith: { $1 })
        ))
        let cutoff = date.addingTimeInterval(-Self.historySpan)
        if let first = clientReadings.firstIndex(where: { $0.date >= cutoff }), first > 0 {
            clientReadings.removeFirst(first)
        }
    }

    /// Each client's load over the last `window` seconds: its totals now less its totals at the window's start, and
    /// how much of the window it was busy. The start is the newest reading at or before it; failing that, nothing if
    /// the server started inside the window, else the oldest reading (the window reaches back before polling began).
    /// A total that went down means the server restarted, and counts from nothing. Clients with nothing running and
    /// nothing done in the window are left out; the busiest come first.
    nonisolated static func clientLoads(
        readings: [ClientReading], activity: ServerActivity, window: TimeInterval, now: Date
    ) -> [ClientLoad] {
        let start = now.addingTimeInterval(-window)
        let before = readings.last { $0.date <= start }
        let startedInside = activity.uptimeSeconds.map { $0 <= window } ?? false
        let oldest = before == nil && !startedInside ? readings.first : nil
        let covered: TimeInterval = if before != nil {
            window
        } else if startedInside, let uptime = activity.uptimeSeconds {
            uptime
        } else if let oldest {
            now.timeIntervalSince(oldest.date)
        } else {
            0
        }
        var loads: [ClientLoad] = []
        for client in activity.clients {
            let latest = client.counters
            var base = (before ?? oldest)?.counters[client.key] ?? ClientCounters()
            if latest.fellBelow(base) {
                base = ClientCounters()
            }
            let totals = latest - base
            let writing = activity.requests.filter { $0.client?.key == client.key && $0.phase == .generating }
                .compactMap(\.predictedPerSecond)
            guard client.active > 0 || totals.requests > 0 || totals.busySeconds > 0.05 else { continue }
            loads.append(ClientLoad(
                key: client.key, userAgent: client.userAgent, running: client.active,
                tokensPerSecond: writing.isEmpty ? nil : writing.reduce(0, +), totals: totals,
                busyFraction: covered > 0 ? min(1, max(0, totals.busySeconds / covered)) : 0
            ))
        }
        return loads.sorted { ($0.busyFraction, $0.running) > ($1.busyFraction, $1.running) }
    }

    /// The last `window` seconds of one figure, placed by time: x runs from the window's start to `now`, `value`
    /// gives y (0–1, or nil for no reading), and a gap of more than `maxGap` between readings breaks the line.
    static func series(
        _ history: [ActivityPoint], window: TimeInterval, now: Date, value: (ActivityPoint) -> Double?
    ) -> [ChartPoint] {
        let start = now.addingTimeInterval(-window)
        var out: [ChartPoint] = []
        var last: Date?
        for point in history where point.date >= start && point.date <= now {
            if let last, point.date.timeIntervalSince(last) > maxGap {
                out.append(ChartPoint(x: last.timeIntervalSince(start) / window, y: nil))
            }
            out.append(ChartPoint(x: point.date.timeIntervalSince(start) / window, y: value(point).map {
                min(1, max(0, $0))
            }))
            last = point.date
        }
        return out
    }

    /// For previews and snapshot tests.
    func show(
        system: SystemSample, server: ServerActivity, history: [ActivityPoint], clientReadings: [ClientReading] = [],
        running: Bool = true
    ) {
        frozen = true
        task?.cancel()
        task = nil
        self.system = system
        self.server = server
        self.history = history
        self.clientReadings = clientReadings
        hasActivity = running
        self.running = running
    }

    private enum Fetched {
        case activity(ServerActivity)
        /// The runtime has no `/slots`.
        case unsupported
        case failed
    }

    private nonisolated static func fetch(base: URL, apiKey: String?) async -> Fetched {
        var request = URLRequest(url: base.appending(path: "slots"))
        request.timeoutInterval = 2
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return .failed }
        guard status == 200 else { return status == 404 ? .unsupported : .failed }
        return (try? JSONDecoder().decode(ServerActivity.self, from: data)).map(Fetched.activity) ?? .unsupported
    }
}
