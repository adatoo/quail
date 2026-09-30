import AppKit
import SwiftUI

/// Live CPU, GPU and memory, and what the server is doing, request by request (ADR D-060). A small window that
/// can stay above other windows while a long prompt is read. The Mac's figures are sampled while it's open, whether
/// or not the server runs, and charted over the last 1, 5 or 15 minutes.
struct ActivityWindow: View {
    let appState: AppState
    @AppStorage("activityWindowOnTop") private var onTop = true
    @AppStorage("activityHistoryMinutes") private var minutes = 1

    private var monitor: ActivityMonitor {
        appState.activity
    }

    private var window: TimeInterval {
        TimeInterval((ActivityMonitor.windowMinutes.contains(minutes) ? minutes : 1) * 60)
    }

    /// The charts end at the latest reading, so they don't creep between readings.
    private var now: Date {
        monitor.history.last?.date ?? Date()
    }

    private func series(_ value: (ActivityPoint) -> Double?) -> [ChartPoint] {
        ActivityMonitor.series(monitor.history, window: window, now: now, value: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("History", selection: $minutes) {
                ForEach(ActivityMonitor.windowMinutes, id: \.self) { Text("\($0) min").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            HStack(spacing: 16) {
                Meter(
                    title: "GPU", percent: monitor.system.gpuPercent,
                    layers: [.init(points: series { $0.gpu.map { $0 / 100 } }, tint: .purple)]
                )
                Meter(
                    title: "CPU", percent: monitor.system.cpuPercent,
                    layers: [.init(points: series { $0.cpu.map { $0 / 100 } }, tint: .blue)]
                )
            }
            memoryChart
            Divider()
            activitySection
            Spacer(minLength: 0)
            Toggle("Keep on top", isOn: $onTop)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 340)
        .frame(minHeight: 340, alignment: .top)
        .background(WindowLevel(floating: onTop).frame(width: 0, height: 0))
        .onAppear { monitor.watch(true) }
        .onDisappear { monitor.watch(false) }
    }

    /// Memory in use against the Mac's total, with the server's share inside it while it runs.
    private var memoryChart: some View {
        let system = monitor.system
        let fraction = system.memoryUsedBytes.flatMap { used in
            system.memoryTotalBytes.map { Double(used) / Double(max($0, 1)) }
        }
        let tint: Color = (fraction ?? 0) > 0.9 ? .red : (fraction ?? 0) > 0.8 ? .orange : .green
        let used = series { point in
            point.memoryUsed.flatMap { used in point.memoryTotal.map { Double(used) / Double(max($0, 1)) } }
        }
        let server = series { point in
            point.serverMemory.flatMap { mine in point.memoryTotal.map { Double(mine) / Double(max($0, 1)) } }
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Memory").font(.caption.weight(.semibold))
                Spacer()
                if let usedBytes = system.memoryUsedBytes, let total = system.memoryTotalBytes {
                    Text("\(Self.gigabytes(usedBytes)) of \(Self.gigabytes(total))")
                        .font(.caption.monospacedDigit())
                } else {
                    Text("—").font(.caption.monospacedDigit())
                }
            }
            HistoryChart(layers: [
                .init(points: used, tint: tint),
                .init(points: server, tint: .indigo, fillOpacity: 0.45),
            ])
            .frame(height: 48)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
            if let server = system.serverMemoryBytes {
                HStack(spacing: 4) {
                    Circle().fill(.indigo).frame(width: 7, height: 7)
                    Text("Server \(Self.gigabytes(server))"
                        + (system.serverCPUPercent.map { " · CPU \(Int($0.rounded()))%" } ?? ""))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var activitySection: some View {
        let server = monitor.server
        if !monitor.running {
            Label(appState.statusLabel, systemImage: "moon.zzz")
                .foregroundStyle(.secondary)
        } else if !monitor.hasActivity {
            Label(
                server.isBusy ? "Loading a model…" : "Idle (llama.cpp doesn't report requests)",
                systemImage: server.isBusy ? "hourglass" : "checkmark.circle"
            )
            .foregroundStyle(.secondary)
        } else {
            let loaded = server.models
            if loaded.isEmpty, server.requests.isEmpty {
                Label("Idle — no model loaded", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            ForEach(loaded, id: \.id) { model in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(model.id).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if model.state == "loading" {
                            Text("Loading \(Int(model.loadingSeconds ?? 0)) s")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.orange)
                        } else if let memory = model.memoryBytes {
                            Text(Self.gigabytes(Int64(memory)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    let requests = server.requests.filter { $0.model == model.id }
                    if requests.isEmpty, model.state == "loaded" {
                        Text("Idle").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(requests) { RequestRow(request: $0) }
                }
            }
            // Requests for a model that isn't loading or loaded yet (waiting for room).
            ForEach(server.requests.filter { request in !loaded.contains { $0.id == request.model } }) {
                RequestRow(request: $0)
            }
            clientsSection
        }
    }

    /// Who's using the server (ADR D-067): each client busy now or in the chosen window, with how much of the window
    /// it kept a request running, coloured by that share.
    @ViewBuilder private var clientsSection: some View {
        let loads = ActivityMonitor.clientLoads(
            readings: monitor.clientReadings, activity: monitor.server, window: window,
            now: monitor.clientReadings.last?.date ?? now
        )
        if !loads.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Clients").font(.caption.weight(.semibold))
                    Spacer()
                    Text("busy in the last \(Int(window / 60)) min").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(loads.prefix(Self.clientRows)) { ClientRow(load: $0) }
                if loads.count > Self.clientRows {
                    Text("and \(loads.count - Self.clientRows) more, less busy")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The most clients listed, busiest first, so the window stays a sensible height.
    static let clientRows = 6

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}

/// One request: what it's doing, how far along, how fast.
private struct RequestRow: View {
    let request: ServerActivity.Request

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.caption)
                Spacer()
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let client = request.client {
                Text(ClientNames.label(client.key, userAgent: client.userAgent))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 13)
                    .help(client.userAgent)
            }
            if request.phase == .readingPrompt {
                ProgressView(value: request.promptFraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
        }
    }

    private var title: String {
        switch request.phase {
        case .waitingForModel: "Waiting for the model"
        case .queued: "Queued"
        case .readingPrompt: "Reading prompt"
        case .generating: "Writing"
        }
    }

    private var detail: String {
        switch request.phase {
        case .waitingForModel, .queued:
            return "\(Int(request.seconds)) s"
        case .readingPrompt:
            let speed = request.promptPerSecond.map { " · \(Self.count($0))/s" } ?? ""
            return "\(Self.count(Double(request.promptDone))) / \(Self.count(Double(request.promptTotal)))\(speed)"
        case .generating:
            let speed = request.predictedPerSecond.map { "\(Int($0.rounded())) tok/s · " } ?? ""
            return "\(speed)\(request.generated)"
        }
    }

    private var color: Color {
        switch request.phase {
        case .waitingForModel: .orange
        case .queued: .secondary
        case .readingPrompt: .blue
        case .generating: .green
        }
    }

    /// "812", "12.4K".
    static func count(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.1fK", value / 1000) : String(Int(value.rounded()))
    }
}

/// One client: who, how much of the window it kept busy (the bar, green under 25%, orange to 75%, red above), what
/// it's running now, and what it did in the window.
private struct ClientRow: View {
    let load: ClientLoad

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(ClientNames.label(load.key, userAgent: load.userAgent))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(Int((load.busyFraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tint)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint).frame(width: max(3, geometry.size.width * load.busyFraction))
                }
            }
            .frame(height: 4)
            Group {
                Text(current)
                Text(done)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.leading, 13)
        }
        .help(load.userAgent.isEmpty ? "No User-Agent" : load.userAgent)
    }

    private var tint: Color {
        switch load.level {
        case .light: .green
        case .moderate: .orange
        case .heavy: .red
        }
    }

    private var current: String {
        guard load.running > 0 else { return "Idle" }
        let speed = load.tokensPerSecond.map { " · \(Int($0.rounded())) tok/s" } ?? ""
        return "\(load.running) running\(speed)"
    }

    private var done: String {
        let totals = load.totals
        let requests = totals.requests == 1 ? "1 request" : "\(totals.requests) requests"
        return "\(requests) · \(RequestRow.count(Double(totals.promptTokens))) read · "
            + "\(RequestRow.count(Double(totals.generated))) written"
    }
}

/// A percentage with its history under it.
private struct Meter: View {
    let title: String
    let percent: Double?
    let layers: [HistoryChart.Layer]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "—").font(.caption.monospacedDigit())
            }
            HistoryChart(layers: layers)
                .frame(height: 34)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Figures over time, 0–1 on the y-axis and the chosen window on the x-axis, oldest on the left. Each layer is an
/// area under a line; a nil point breaks it (no reading, or sampling paused).
struct HistoryChart: View {
    struct Layer {
        var points: [ChartPoint]
        var tint: Color
        var fillOpacity = 0.25
    }

    let layers: [Layer]

    var body: some View {
        Canvas { context, size in
            for layer in layers {
                for run in Self.runs(layer.points) where !run.isEmpty {
                    let points = run.map { CGPoint(x: $0.x * size.width, y: size.height * (1 - $0.y)) }
                    var line = Path()
                    line.addLines(points)
                    var area = line
                    area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
                    area.addLine(to: CGPoint(x: points[0].x, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .color(layer.tint.opacity(layer.fillOpacity)))
                    context.stroke(line, with: .color(layer.tint), lineWidth: 1.5)
                }
            }
        }
    }

    /// The unbroken stretches of `points`: split wherever y is nil.
    static func runs(_ points: [ChartPoint]) -> [[(x: Double, y: Double)]] {
        var runs: [[(x: Double, y: Double)]] = [[]]
        for point in points {
            if let y = point.y {
                runs[runs.count - 1].append((point.x, y))
            } else if !runs[runs.count - 1].isEmpty {
                runs.append([])
            }
        }
        return runs.filter { !$0.isEmpty }
    }
}

/// Floats the hosting window above others, or not.
private struct WindowLevel: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context _: Context) {
        DispatchQueue.main.async {
            view.window?.level = floating ? .floating : .normal
        }
    }
}

/// The menu bar's label: the bird, and a few words while the server is busy.
struct MenuBarLabel: View {
    let appState: AppState

    #if DEBUG
        @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: appState.menuBarIcon)
            if let label = appState.menuBarActivityLabel {
                Text(label).monospacedDigit()
            }
        }
        #if DEBUG
        // Debug builds only: `-QuailOpenPage server` (any `MainPage`) opens the Quail window at launch, so a
        // development copy (with `QUAIL_DATA_ROOT`) can be looked at and screenshotted without clicking the menu.
        .task {
            if let raw = UserDefaults.standard.string(forKey: "QuailOpenPage"), let page = MainPage(rawValue: raw) {
                appState.mainPage = page
                bringToFront(id: MainWindow.id) { openWindow(id: MainWindow.id) }
            }
        }
        #endif
    }
}

/// The menu bar label's look, on its own, for the snapshot tests.
struct MenuBarActivityPreview: View {
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bird.fill").foregroundStyle(.green)
            Text(label).monospacedDigit()
        }
        .padding(.horizontal, 6)
    }
}
