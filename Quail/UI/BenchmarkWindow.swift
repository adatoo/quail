import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Benchmark window (Phase 2b step 4): run the fixed suite on an
/// installed model, and browse, compare, copy and export saved results.
struct BenchmarkWindow: View {
    let appState: AppState

    @State private var model = ""
    @State private var selection: Set<BenchmarkResult.ID> = []

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
            if selected.count == 2 {
                Divider()
                ComparisonStrip(first: selected[0], second: selected[1])
                    .padding(.horizontal)
                    .padding(.vertical, 10)
            }
            Divider()
            actionBar
                .padding(.horizontal)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 860, minHeight: 440)
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
                    Text(benchmarks.step)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                    Text(Self.timestamp(result.date))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help(result.date.formatted(date: .complete, time: .complete))
                }
                .width(min: 125, ideal: 135)
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
                .width(min: 140, ideal: 180)
                TableColumn("Prompt 512") { Text(Self.speed($0.measurements.prompt512)).monospacedDigit() }
                    .width(min: 90, ideal: 100)
                TableColumn("Prompt 4096") { Text(Self.speed($0.measurements.prompt4096)).monospacedDigit() }
                    .width(min: 90, ideal: 100)
                TableColumn("Generate") { result in
                    Text(Self.speed(result.measurements.generation256))
                        .monospacedDigit()
                        .help(result.estimatedTokensPerSecond.map { String(format: "Estimated: %.0f tok/s", $0) } ?? "")
                }
                .width(min: 85, ideal: 95)
                TableColumn("First token") { result in
                    Text(result.measurements.timeToFirstTokenMs.map { String(format: "%.0f ms", $0.median) } ?? "—")
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 80)
                TableColumn("Load") { result in
                    Text(result.measurements.loadSeconds.map { String(format: "%.1f s", $0.median) } ?? "—")
                        .monospacedDigit()
                }
                .width(min: 50, ideal: 60)
            }
            .contextMenu(forSelectionType: BenchmarkResult.ID.self) { ids in
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
                ? "Select results to copy, export or compare (two)."
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

/// Two results side by side: how much faster the second is on each test.
private struct ComparisonStrip: View {
    let first: BenchmarkResult
    let second: BenchmarkResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text("\(label(first)) vs \(label(second))")
                .font(.callout.bold())
                .lineLimit(1)
                .truncationMode(.middle)
            cell("Prompt 512", first.measurements.prompt512, second.measurements.prompt512)
            cell("Prompt 4096", first.measurements.prompt4096, second.measurements.prompt4096)
            cell("Generate", first.measurements.generation256, second.measurements.generation256)
            Spacer()
        }
    }

    /// The model, plus the run's time when both are the same model.
    private func label(_ result: BenchmarkResult) -> String {
        first.model.id == second.model.id
            ? "\(result.model.id) (\(BenchmarkWindow.timestamp(result.date)))"
            : result.model.id
    }

    @ViewBuilder
    private func cell(_ title: String, _ a: BenchmarkResult.Stat?, _ b: BenchmarkResult.Stat?) -> some View {
        if let a, let b, a.median > 0 {
            let ratio = b.median / a.median
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.2f×", ratio))
                    .monospacedDigit()
                    .foregroundStyle(ratio >= 1 ? .green : .orange)
                    .help("\(label(second)) relative to \(label(first))")
            }
        }
    }
}
