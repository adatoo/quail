import Foundation
import Observation

/// What quail-server says it's doing (`GET /slots`, ADR D-060).
struct ServerActivity: Equatable, Sendable, Decodable {
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

        enum CodingKeys: String, CodingKey {
            case id, model, phase, cached, generated, seconds
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

/// Polls the server's activity and samples the Mac while the server runs (ADR D-060): every second while
/// something is happening, every two seconds otherwise. Keeps a minute of CPU and GPU history for the Activity
/// window's graphs.
@MainActor
@Observable
final class ActivityMonitor {
    private(set) var system = SystemSample()
    private(set) var server = ServerActivity()
    /// The last minute of readings, oldest first (nil where there was no figure).
    private(set) var cpuHistory: [Double?] = []
    private(set) var gpuHistory: [Double?] = []
    /// Whether the runtime answers `GET /slots` (quail-server does; llama-server's router doesn't).
    private(set) var hasActivity = false
    /// Whether it's polling (the server is running).
    private(set) var running = false

    static let historyLength = 60

    @ObservationIgnored private let sampler = SystemMonitor()
    @ObservationIgnored private var task: Task<Void, Never>?

    var busyLabel: String? {
        server.busyLabel
    }

    /// Starts polling `base`, reading the server's processes from `processIDs`; `fallbackLoading` says whether a
    /// model is loading when the runtime has no `/slots`.
    func start(
        base: URL, apiKey: String?, processIDs: @escaping @Sendable () async -> [Int32],
        fallbackLoading: @escaping @MainActor () -> Bool
    ) {
        stop()
        hasActivity = true
        running = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pids = await processIDs()
                let reading = await Task.detached(priority: .utility) { [sampler] in
                    sampler.sample(serverPIDs: pids)
                }.value
                record(reading)
                switch hasActivity ? await Self.fetch(base: base, apiKey: apiKey) : .unsupported {
                case let .activity(activity):
                    server = activity
                case .unsupported:
                    // No `/slots` (llama-server): loading is all that can be told.
                    hasActivity = false
                    server = ServerActivity(
                        models: fallbackLoading() ? [.init(id: "", state: "loading", leases: 0)] : []
                    )
                case .failed:
                    break // a busy moment; the next poll tries again
                }
                do {
                    try await Task.sleep(for: server.isBusy ? .seconds(1) : .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
        server = ServerActivity()
        system = SystemSample()
        cpuHistory = []
        gpuHistory = []
    }

    private func record(_ reading: SystemSample) {
        system = reading
        cpuHistory = Array((cpuHistory + [reading.cpuPercent]).suffix(Self.historyLength))
        gpuHistory = Array((gpuHistory + [reading.gpuPercent]).suffix(Self.historyLength))
    }

    /// For previews and snapshot tests.
    func show(system: SystemSample, server: ServerActivity, cpuHistory: [Double?], gpuHistory: [Double?]) {
        self.system = system
        self.server = server
        self.cpuHistory = cpuHistory
        self.gpuHistory = gpuHistory
        hasActivity = true
        running = true
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
