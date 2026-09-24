import Foundation

/// Runs `BenchmarkSuite` against one model through a `BenchmarkClient`,
/// and leaves the server as it found it: whatever was loaded before is
/// loaded again afterwards, and a model that wasn't loaded is unloaded.
struct BenchmarkRunner: Sendable {
    let client: any BenchmarkClient
    /// How long to wait for a load before giving up.
    var loadTimeout: Duration = .seconds(600)
    var pollInterval: Duration = .milliseconds(50)

    struct Output: Sendable, Equatable {
        var measurements: BenchmarkResult.Measurements
        var properties: ServerProperties
        var otherModelsLoaded: [String]
    }

    /// `progress` gets a short description of each step and the fraction
    /// done (0…1).
    func run(model: String, progress: @Sendable (String, Double) async -> Void) async throws -> Output {
        let before = try await client.modelStates()
        guard before[model] != nil else { throw BenchmarkError.unknownModel(model) }
        let loadedBefore = before.filter { $0.value == "loaded" }.map(\.key).sorted()
        let others = loadedBefore.filter { $0 != model }

        do {
            let output = try await measure(model: model, others: others, progress: progress)
            await progress("Restoring loaded models…", 0.98)
            try await restore(model: model, loadedBefore: loadedBefore)
            return output
        } catch {
            // In a task of its own: a cancelled benchmark (or its cancelled
            // requests) must still put the server back.
            await Task { try? await restore(model: model, loadedBefore: loadedBefore) }.value
            throw error
        }
    }

    private func measure(
        model: String,
        others: [String],
        progress: @Sendable (String, Double) async -> Void
    ) async throws -> Output {
        var measurements = BenchmarkResult.Measurements()

        // Loaded once untimed first, so the timed load reads the file from
        // the page cache — the repeatable number, not the disk's.
        await progress("Loading \(model)…", 0.02)
        try await loadAndWait(model)
        let properties = try await client.properties(model: model)
        let passage = try await client.tokenize(BenchmarkSuite.passage, model: model)
        guard !passage.isEmpty else { throw BenchmarkError.badResponse("empty tokenization") }

        await progress("Timing a load…", 0.1)
        try await client.unload(model: model)
        try await waitFor(model) { $0 != "loaded" && $0 != "loading" }
        let loadStart = ContinuousClock.now
        try await loadAndWait(model)
        measurements.loadSeconds = .of([Self.seconds(ContinuousClock.now - loadStart)])

        let short = BenchmarkSuite.promptTokens(from: passage, count: BenchmarkSuite.generationPromptTokens)
        for run in 0 ..< BenchmarkSuite.warmupRuns {
            await progress("Warming up (\(run + 1)/\(BenchmarkSuite.warmupRuns))…", 0.2)
            _ = try await client.complete(model: model, prompt: short, maxTokens: 16)
        }

        let sizes = BenchmarkSuite.promptSizes
        let steps = Double(sizes.count + 1) * Double(BenchmarkSuite.measuredRuns)
        var done = 0.0
        func fraction() -> Double {
            0.25 + 0.7 * done / steps
        }

        for size in sizes {
            guard BenchmarkSuite.fits(size, contextSize: properties.contextSize) else {
                measurements.skipped.append(
                    "prompt \(size): the model's context (\(properties.contextSize ?? 0)) is too small"
                )
                done += Double(BenchmarkSuite.measuredRuns)
                continue
            }
            let prompt = BenchmarkSuite.promptTokens(from: passage, count: size)
            var speeds: [Double] = []
            var firstTokens: [Double] = []
            for run in 0 ..< BenchmarkSuite.measuredRuns {
                await progress("Prompt \(size) tokens (\(run + 1)/\(BenchmarkSuite.measuredRuns))…", fraction())
                let timing = try await client.complete(model: model, prompt: prompt, maxTokens: 1)
                speeds.append(timing.promptPerSecond)
                firstTokens.append(timing.timeToFirstTokenMs)
                done += 1
            }
            switch size {
            case 512:
                measurements.prompt512 = .of(speeds)
                measurements.timeToFirstTokenMs = .of(firstTokens)
            case 4096:
                measurements.prompt4096 = .of(speeds)
            default:
                break
            }
        }

        var speeds: [Double] = []
        for run in 0 ..< BenchmarkSuite.measuredRuns {
            await progress(
                "Generating \(BenchmarkSuite.generateTokens) tokens (\(run + 1)/\(BenchmarkSuite.measuredRuns))…",
                fraction()
            )
            let timing = try await client.complete(
                model: model,
                prompt: short,
                maxTokens: BenchmarkSuite.generateTokens
            )
            speeds.append(timing.generatedPerSecond)
            done += 1
        }
        measurements.generation256 = .of(speeds)

        return Output(measurements: measurements, properties: properties, otherModelsLoaded: others)
    }

    /// Back to how it was: unload the benchmarked model unless it was
    /// loaded before, then reload whatever else was (a single-model router
    /// evicted it to load ours). Reloads aren't waited on.
    private func restore(model: String, loadedBefore: [String]) async throws {
        if !loadedBefore.contains(model) {
            try await client.unload(model: model)
            // The router answers before the instance has exited; wait, so
            // whoever looks next (`quail ps`) sees the settled state.
            try await waitFor(model) { $0 != "loaded" && $0 != "loading" }
        }
        for other in loadedBefore where other != model {
            try await client.load(model: other)
        }
    }

    private func loadAndWait(_ model: String) async throws {
        if try await client.modelStates()[model] == "loaded" {
            return
        }
        try await client.load(model: model)
        try await waitFor(model) { $0 == "loaded" }
    }

    private func waitFor(_ model: String, until done: (String?) -> Bool) async throws {
        let deadline = ContinuousClock.now + loadTimeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let state = try await client.modelStates()[model]
            if done(state) {
                return
            }
            if state == nil {
                throw BenchmarkError.unknownModel(model)
            }
            if state == "failed" {
                throw BenchmarkError.loadFailed(model)
            }
            try await Task.sleep(for: pollInterval)
        }
        throw BenchmarkError.loadTimedOut(model)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
