import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Benchmark tab of Settings (Phase 2b step 4): run the fixed suite on
/// an installed model, and browse, compare, copy and export saved results.
struct BenchmarkPane: View {
    let appState: AppState

    @State private var model = ""
    @State private var selection: Set<BenchmarkResult.ID> = []
    /// The run the other is measured against; the older of the two until
    /// the user says otherwise.
    @State private var baselineID: BenchmarkResult.ID?

    private var benchmarks: BenchmarkController {
        appState.benchmarks
    }

    private var serverReady: Bool {
        appState.serverController.phase == .ready
    }

    var body: some View {
        VStack(spacing: 0) {
            runBar
                .padding()
            Divider()
            resultsTable
            if let pair = comparison {
                Divider()
                ComparisonStrip(baseline: pair.baseline, other: pair.other, swap: swapBaseline)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
            }
            Divider()
            actionBar
                .padding(.horizontal)
                .padding(.vertical, 10)
        }
        // Settings sizes to its tab (`fixedSize`), and a Table scrolls, so
        // its ideal height is tiny — same reason as `ModelsPane`.
        .frame(minHeight: 520)
        .onAppear(perform: pickModel)
        .onChange(of: benchmarks.requestedModel) { _, _ in pickModel() }
    }

    private func pickModel() {
        let models = appState.benchmarkableModels
        if let requested = benchmarks.requestedModel, models.contains(requested) {
            model = requested
            benchmarks.requestedModel = nil
        } else if model.isEmpty || !models.contains(model) {
            model = appState.config.defaultModelID.flatMap { models.contains($0) ? $0 : nil } ?? models.first ?? ""
        }
    }

    private func swapBaseline() {
        baselineID = comparison?.other.id
    }

    // MARK: - Run

    private var runBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if appState.benchmarkableModels.isEmpty {
                    Text("No GGUF models installed — add one in Settings → Models.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: $model) {
                        ForEach(appState.benchmarkableModels, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 340)
                    .disabled(benchmarks.isRunning)
                }
                Spacer()
                Button {
                    Task { try? await appState.runBenchmark(model: model) }
                } label: {
                    Label("Run Benchmark", systemImage: "gauge.with.dots.needle.67percent")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!serverReady || benchmarks.isRunning || model.isEmpty)
                .help(serverReady ? "About a minute for a small model" : "Start the server first")
            }

            if benchmarks.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: benchmarks.fraction)
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(benchmarks.step)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let startedAt = benchmarks.startedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                Text(BenchmarkController.elapsedText(timeline.date.timeIntervalSince(startedAt)))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Cancel") { benchmarks.cancel() }
                            .controlSize(.small)
                    }
                }
            } else if benchmarks.wasCancelled {
                Label("Cancelled — nothing was saved.", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else if let error = benchmarks.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            } else {
                Text(
                    "Runs \(BenchmarkSuite.id): prompt processing at 512 and 4096 tokens, generation of 256 tokens, time to first token and load time — \(BenchmarkSuite.measuredRuns) runs each after a warm-up. What's loaded now is loaded again afterwards."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Results

    private var selected: [BenchmarkResult] {
        benchmarks.results.filter { selection.contains($0.id) }
    }

    /// With exactly two runs selected: which is the baseline, and the other.
    private var comparison: (baseline: BenchmarkResult, other: BenchmarkResult)? {
        let pair = selected
        guard let baseline = BenchmarkComparison.baseline(of: pair, preferred: baselineID),
              let other = pair.first(where: { $0.id != baseline.id })
        else { return nil }
        return (baseline, other)
    }

    @ViewBuilder private var resultsTable: some View {
        if benchmarks.results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No results yet.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(benchmarks.results, selection: $selection) {
                // First, so runs of the same model are told apart at a
                // glance; seconds, because two runs can share a minute.
                TableColumn("Run") { result in
                    HStack(spacing: 6) {
                        Text(Self.timestamp(result.date))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .help(result.date.formatted(date: .complete, time: .complete))
                        if comparison?.baseline.id == result.id {
                            // Grey with white text: readable on a plain row and
                            // on the selection's blue, which a blue tag isn't.
                            Text("Baseline")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.gray.opacity(0.65), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
                .width(min: 170, ideal: 175)
                TableColumn("Model") { result in
                    HStack(spacing: 4) {
                        Text(result.model.id).lineLimit(1).truncationMode(.middle)
                        let notes = result.conditions.warnings + result.measurements.skipped
                        if !notes.isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(notes.joined(separator: "\n"))
                        }
                    }
                }
                .width(min: 215, ideal: 220)
                TableColumn("Prompt 512") { Text(Self.speed($0.measurements.prompt512)).monospacedDigit() }
                    .width(min: 85, ideal: 90)
                TableColumn("Prompt 4096") { Text(Self.speed($0.measurements.prompt4096)).monospacedDigit() }
                    .width(min: 85, ideal: 90)
                TableColumn("Generate") { result in
                    Text(Self.speed(result.measurements.generation256))
                        .monospacedDigit()
                        .help(result.estimatedTokensPerSecond.map { String(format: "Estimated: %.0f tok/s", $0) } ?? "")
                }
                .width(min: 80, ideal: 85)
                TableColumn("First token") { result in
                    Text(result.measurements.timeToFirstTokenMs.map { String(format: "%.0f ms", $0.median) } ?? "—")
                        .monospacedDigit()
                }
                .width(min: 65, ideal: 70)
                TableColumn("Load") { result in
                    Text(result.measurements.loadSeconds.map { String(format: "%.1f s", $0.median) } ?? "—")
                        .monospacedDigit()
                }
                .width(min: 45, ideal: 50)
            }
            .contextMenu(forSelectionType: BenchmarkResult.ID.self) { ids in
                // Right-clicking inside a selection hands over the whole
                // selection, so with a pair the choice is to swap it.
                if ids.count == 1, let only = ids.first {
                    Button("Set as Baseline") { baselineID = only }
                } else if ids.count == 2, comparison != nil {
                    Button("Swap Baseline") { swapBaseline() }
                }
                Button("Copy as Markdown") { copyMarkdown(ids) }
                Button("Export JSON…") { exportJSON(ids) }
                Divider()
                Button("Delete", role: .destructive) { benchmarks.delete(ids) }
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Text(selection.isEmpty
                ? "Select results to copy or export. Select two to compare them against a baseline."
                : "\(selection.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy as Markdown") { copyMarkdown(selection) }
                .disabled(selection.isEmpty)
            Button("Export JSON…") { exportJSON(selection) }
                .disabled(selection.isEmpty)
            Button("Delete") { benchmarks.delete(selection); selection = [] }
                .disabled(selection.isEmpty || benchmarks.isRunning)
        }
    }

    /// "23 Sep, 18:43:07" — this year's runs; older ones get the year.
    static func timestamp(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        let day = sameYear
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(day), \(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()))"
    }

    static func speed(_ stat: BenchmarkResult.Stat?) -> String {
        stat.map { String(format: "%.1f tok/s", $0.median) } ?? "—"
    }

    // MARK: - Copy / export

    private func results(_ ids: Set<BenchmarkResult.ID>) -> [BenchmarkResult] {
        benchmarks.results.filter { ids.contains($0.id) }
    }

    private func copyMarkdown(_ ids: Set<BenchmarkResult.ID>) {
        let text = results(ids).map(\.markdown).joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportJSON(_ ids: Set<BenchmarkResult.ID>) {
        let chosen = results(ids)
        guard !chosen.isEmpty, let data = try? BenchmarkResult.encoder().encode(chosen) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = chosen.count == 1
            ? "\(chosen[0].model.id)-\(BenchmarkSuite.id).json"
            : "quail-benchmarks.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// One result measured against another: the baseline is the reference,
/// every cell says how the other run compares to it.
private struct ComparisonStrip: View {
    let baseline: BenchmarkResult
    let other: BenchmarkResult
    let swap: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(label(other))")
                    .font(.callout.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text("against baseline \(label(baseline))")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(action: swap) {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Swap: make \(label(other)) the baseline")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            cell("Prompt 512", baseline.measurements.prompt512, other.measurements.prompt512)
            cell("Prompt 4096", baseline.measurements.prompt4096, other.measurements.prompt4096)
            cell("Generate", baseline.measurements.generation256, other.measurements.generation256)
            Spacer()
        }
    }

    /// The model, plus the run's time when both are the same model.
    private func label(_ result: BenchmarkResult) -> String {
        baseline.model.id == other.model.id
            ? "\(result.model.id) (\(BenchmarkPane.timestamp(result.date)))"
            : result.model.id
    }

    @ViewBuilder
    private func cell(_ title: String, _ base: BenchmarkResult.Stat?, _ other: BenchmarkResult.Stat?) -> some View {
        if let base, let other, let change = BenchmarkComparison.change(baseline: base.median, other: other.median) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(change.text)
                    .monospacedDigit()
                    .foregroundStyle(color(change.direction))
                    .help(String(format: "%.1f tok/s against a baseline of %.1f tok/s", other.median, base.median))
            }
        }
    }

    private func color(_ direction: BenchmarkComparison.Change.Direction) -> Color {
        switch direction {
        case .faster: .green
        case .slower: .orange
        case .same: .secondary
        }
    }
}
