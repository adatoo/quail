import ArgumentParser
import Darwin
import Foundation

/// `quail bench [model]` — run the fixed benchmark suite in the app and
/// print the result (ADR D-023). `--history` lists saved results.
struct Bench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Benchmark a model: prompt processing, generation speed, time to first token, load time.",
        discussion: """
        Runs the fixed quail-bench-1 suite on the running server (about a minute \
        for a small model) and saves the result in Quail. Whatever models were \
        loaded before are loaded again afterwards.
        """
    )

    @Argument(help: "Model name (see `quail list`). Defaults to the default model.")
    var model: String?

    @Flag(help: "Print the full result as JSON.") var json = false
    @Flag(help: "List saved results instead of running.") var history = false

    func run() async throws {
        if history {
            let response = try await AppLink.request(ControlRequest(command: .benchHistory))
            try AppLink.check(response)
            let results = response.benchmarks ?? []
            if json {
                return try print(String(decoding: BenchmarkResult.encoder().encode(results), as: UTF8.self))
            }
            guard !results.isEmpty else {
                return print("No benchmarks yet. Run `quail bench <model>`.")
            }
            Output.printTable(
                ["RUN", "MODEL", "PROMPT 512", "PROMPT 4096", "GENERATE", "TTFT", "LOAD"],
                results.map(Self.row)
            )
            return
        }

        try await AppLink.ensureRunning()
        let target = model
        let spinner = Task { await Self.showProgress() }
        let response = try await AppLink.request(ControlRequest(command: .bench, model: target))
        spinner.cancel()
        _ = await spinner.value
        Self.clearLine()
        try AppLink.check(response)
        guard let result = response.benchmark else { throw CLIError("No result from Quail.") }

        if json {
            return try print(String(decoding: BenchmarkResult.encoder().encode(result), as: UTF8.self))
        }
        print(Self.summary(result))
    }

    // MARK: - Output

    static func row(_ result: BenchmarkResult) -> [String] {
        let measured = result.measurements
        return [
            result.date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().second()),
            result.model.id,
            speed(measured.prompt512),
            speed(measured.prompt4096),
            speed(measured.generation256),
            measured.timeToFirstTokenMs.map { String(format: "%.0f ms", $0.median) } ?? "—",
            measured.loadSeconds.map { String(format: "%.1f s", $0.median) } ?? "—",
        ]
    }

    static func speed(_ stat: BenchmarkResult.Stat?) -> String {
        stat.map { String(format: "%.1f tok/s", $0.median) } ?? "—"
    }

    static func summary(_ result: BenchmarkResult) -> String {
        let measured = result.measurements
        func line(_ label: String, _ stat: BenchmarkResult.Stat?, _ unit: String, _ digits: Int = 1) -> String {
            let name = label.padding(toLength: 22, withPad: " ", startingAt: 0)
            guard let stat else { return "\(name)—" }
            let value = String(format: "%.\(digits)f \(unit)", stat.median)
            let range = String(format: "(%.\(digits)f–%.\(digits)f)", stat.min, stat.max)
            return "\(name)\(value.padding(toLength: 16, withPad: " ", startingAt: 0))\(Output.dim(range))"
        }
        var lines = [
            "\(result.model.id) on \(result.hardware.marketingName ?? result.hardware.chip ?? "this Mac")",
            Output
                .dim(
                    "\(result.suite) · \(result.engine.runtime) \(result.engine.build ?? "") · \(result.engine.contextSize.map { "\($0) ctx" } ?? "")"
                ),
            "",
            line("Prompt, 512 tokens", measured.prompt512, "tok/s"),
            line("Prompt, 4096 tokens", measured.prompt4096, "tok/s"),
            line("Generate, 256 tokens", measured.generation256, "tok/s"),
            line("Time to first token", measured.timeToFirstTokenMs, "ms", 0),
            line("Load", measured.loadSeconds, "s", 2),
        ]
        if let estimate = result.estimatedTokensPerSecond, let measuredSpeed = measured.generation256?.median {
            lines.append(Output.dim(String(
                format: "Quail estimated %.0f tok/s for generation; measured %.0f.",
                estimate,
                measuredSpeed
            )))
        }
        for note in result.conditions.warnings + measured.skipped {
            lines.append("Note: \(note)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Progress

    /// Redraws one status line from the app's progress until cancelled.
    private static func showProgress() async {
        guard isatty(STDERR_FILENO) != 0 else { return }
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        var tick = 0
        while !Task.isCancelled {
            if let progress = try? await AppLink.request(ControlRequest(command: .benchProgress), launchIfNeeded: false)
                .benchProgress, progress.running
            {
                let percent = Int((progress.fraction * 100).rounded())
                let text = "\(frames[tick % frames.count]) \(percent)%  \(progress.step)"
                FileHandle.standardError.write(Data("\r\u{1B}[2K\(text)".utf8))
            }
            tick += 1
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
        }
    }

    private static func clearLine() {
        guard isatty(STDERR_FILENO) != 0 else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
    }
}
