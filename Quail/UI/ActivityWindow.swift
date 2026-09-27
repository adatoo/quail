import AppKit
import SwiftUI

/// Live CPU, GPU and memory, and what the server is doing, request by request (ADR D-060). A small window that
/// can stay above other windows while a long prompt is read.
struct ActivityWindow: View {
    let appState: AppState
    @AppStorage("activityWindowOnTop") private var onTop = true

    private var monitor: ActivityMonitor {
        appState.activity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Meter(title: "GPU", percent: monitor.system.gpuPercent, history: monitor.gpuHistory, tint: .purple)
                Meter(title: "CPU", percent: monitor.system.cpuPercent, history: monitor.cpuHistory, tint: .blue)
            }
            memoryLine
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
        .frame(minHeight: 300, alignment: .top)
        .background(WindowLevel(floating: onTop).frame(width: 0, height: 0))
    }

    @ViewBuilder private var memoryLine: some View {
        let system = monitor.system
        if let used = system.memoryUsedBytes, let total = system.memoryTotalBytes {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Memory").font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(Self.gigabytes(used)) of \(Self.gigabytes(total))")
                        .font(.caption.monospacedDigit())
                }
                ProgressView(value: Double(used), total: Double(max(total, 1)))
                    .tint(Double(used) / Double(max(total, 1)) > 0.9 ? .red : .green)
                if let server = system.serverMemoryBytes {
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
        }
    }

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

/// A percentage with a minute's history under it.
private struct Meter: View {
    let title: String
    let percent: Double?
    let history: [Double?]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "—").font(.caption.monospacedDigit())
            }
            Sparkline(values: history, tint: tint)
                .frame(height: 34)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
        }
        .frame(maxWidth: .infinity)
    }
}

/// The last minute of a 0–100 figure, oldest on the left.
private struct Sparkline: View {
    let values: [Double?]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let slots = ActivityMonitor.historyLength
            let step = size.width / CGFloat(max(1, slots - 1))
            let offset = slots - values.count
            var line = Path()
            var area = Path()
            var started = false
            for (index, value) in values.enumerated() {
                guard let value else { continue }
                let point = CGPoint(
                    x: CGFloat(offset + index) * step, y: size.height * (1 - CGFloat(min(100, max(0, value)) / 100))
                )
                if started {
                    line.addLine(to: point)
                    area.addLine(to: point)
                } else {
                    line.move(to: point)
                    area.move(to: CGPoint(x: point.x, y: size.height))
                    area.addLine(to: point)
                    started = true
                }
            }
            guard started, let last = line.currentPoint else { return }
            area.addLine(to: CGPoint(x: last.x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(tint.opacity(0.25)))
            context.stroke(line, with: .color(tint), lineWidth: 1.5)
        }
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

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: appState.menuBarIcon)
            if let label = appState.menuBarActivityLabel {
                Text(label).monospacedDigit()
            }
        }
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
