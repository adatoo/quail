import Foundation
import Testing
@testable import Quail

@Suite("Benchmark", .timeLimit(.minutes(1)))
struct BenchmarkTests {
    // MARK: - Suite and stats

    @Test("Stat.of gives median, min and max; nil for no samples")
    func stats() throws {
        let odd = try #require(BenchmarkResult.Stat.of([30, 10, 20]))
        #expect(odd == .init(median: 20, min: 10, max: 30, samples: 3))
        let even = try #require(BenchmarkResult.Stat.of([4, 1, 3, 2]))
        #expect(even.median == 2.5)
        #expect(BenchmarkResult.Stat.of([]) == nil)
    }

    @Test("prompt tokens repeat the passage and are cut to exactly the size asked")
    func promptSizing() {
        let tokens = BenchmarkSuite.promptTokens(from: [1, 2, 3], count: 7)
        #expect(tokens == [1, 2, 3, 1, 2, 3, 1])
        #expect(BenchmarkSuite.promptTokens(from: Array(0 ..< 100), count: 512).count == 512)
        #expect(BenchmarkSuite.promptTokens(from: [], count: 5).isEmpty)
    }

    @Test("a prompt size fits only with room for one generated token")
    func fits() {
        #expect(BenchmarkSuite.fits(4096, contextSize: 4097))
        #expect(!BenchmarkSuite.fits(4096, contextSize: 4096))
        #expect(BenchmarkSuite.fits(4096, contextSize: nil))
    }

    // MARK: - Runner

    @Test("measures every step, excludes the warm-up, and unloads a model that wasn't loaded before")
    func fullRun() async throws {
        let client = FakeBenchmarkClient(states: ["Target": "unloaded"], contextSize: 32768)
        let output = try await BenchmarkRunner(client: client, pollInterval: .milliseconds(1))
            .run(model: "Target") { _, _ in }

        let measured = output.measurements
        // The fake's warm-up answers 9999 tok/s; measured runs 100, 110, 120.
        #expect(measured.generation256?.median == 110)
        #expect(measured.generation256?.max == 120)
        #expect(measured.prompt512?.samples == BenchmarkSuite.measuredRuns)
        #expect(measured.prompt4096 != nil)
        #expect(measured.timeToFirstTokenMs != nil)
        #expect(measured.loadSeconds != nil)
        #expect(measured.skipped.isEmpty)
        #expect(output.properties.build == "b-test")
        #expect(output.otherModelsLoaded.isEmpty)

        let prompts = await client.promptLengths
        // 1 warm-up + 3×512 + 3×4096 + 3 generation runs, in that order.
        #expect(prompts.count == 10)
        #expect(prompts.filter { $0 == 512 }.count == 3)
        #expect(prompts.filter { $0 == 4096 }.count == 3)
        #expect(await client.states["Target"] == "unloaded")
    }

    @Test("skips prompt 4096 when the context is too small, and reloads what was loaded before")
    func smallContextAndRestore() async throws {
        let client = FakeBenchmarkClient(states: ["Target": "unloaded", "Other": "loaded"], contextSize: 2048)
        let output = try await BenchmarkRunner(client: client, pollInterval: .milliseconds(1))
            .run(model: "Target") { _, _ in }

        #expect(output.measurements.prompt4096 == nil)
        #expect(output.measurements.skipped.count == 1)
        #expect(output.otherModelsLoaded == ["Other"])
        #expect(await client.states["Other"] == "loaded")
        #expect(await client.states["Target"] == "unloaded")
    }

    @Test("a model that was loaded before stays loaded")
    func keepsLoadedTarget() async throws {
        let client = FakeBenchmarkClient(states: ["Target": "loaded"], contextSize: 32768)
        _ = try await BenchmarkRunner(client: client, pollInterval: .milliseconds(1)).run(model: "Target") { _, _ in }
        #expect(await client.states["Target"] == "loaded")
    }

    @Test("a failed load is reported, not waited out, and loaded models are still restored")
    func failedLoad() async throws {
        let client = FakeBenchmarkClient(states: ["Target": "unloaded", "Other": "loaded"], contextSize: 32768)
        await client.failLoads(of: "Target")
        await #expect(throws: BenchmarkError.loadFailed("Target")) {
            _ = try await BenchmarkRunner(client: client, pollInterval: .milliseconds(1))
                .run(model: "Target") { _, _ in }
        }
        #expect(await client.states["Other"] == "loaded")
    }

    @Test("a cancelled run still puts the loaded models back")
    func cancelledRunRestores() async throws {
        let client = FakeBenchmarkClient(states: ["Target": "unloaded", "Other": "loaded"], contextSize: 32768)
        await client.hangOnComplete()
        let run = Task {
            try await BenchmarkRunner(client: client, pollInterval: .milliseconds(1)).run(model: "Target") { _, _ in }
        }
        while await !client.isHanging {
            try await Task.sleep(for: .milliseconds(1))
        }
        run.cancel()
        await #expect(throws: (any Error).self) { _ = try await run.value }
        #expect(await client.states["Other"] == "loaded")
        #expect(await client.states["Target"] == "unloaded")
    }

    @Test("an unknown model is rejected before anything runs")
    func unknownModel() async {
        let client = FakeBenchmarkClient(states: ["Target": "unloaded"], contextSize: 32768)
        await #expect(throws: BenchmarkError.unknownModel("Nope")) {
            _ = try await BenchmarkRunner(client: client).run(model: "Nope") { _, _ in }
        }
    }

    // MARK: - Controller

    @MainActor
    @Test("a run claims the controller at once, refuses a second, and a cancel saves nothing")
    func controllerClaimsAndCancels() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let controller = BenchmarkController(store: BenchmarkStore(fileURL: file))
        let run = Task {
            try await controller.execute(model: "M") { _ in
                try await Task.sleep(for: .seconds(60))
                return Self.sampleResult(model: "M", chip: "Apple M4 Pro", speed: 1)
            }
        }
        while !controller.isRunning {
            await Task.yield()
        }
        #expect(controller.step == "Preparing…")
        #expect(controller.startedAt != nil)
        await #expect(throws: BenchmarkError.alreadyRunning) {
            _ = try await controller.execute(model: "N") { _ in Self.sampleResult(model: "N", chip: "x", speed: 1) }
        }

        controller.cancel()
        await #expect(throws: (any Error).self) { _ = try await run.value }
        #expect(!controller.isRunning)
        #expect(controller.results.isEmpty)
        #expect(controller.lastError?.hasPrefix("Cancelled") == true)
    }

    @Test("elapsed time reads as minutes and seconds")
    func elapsed() {
        #expect(BenchmarkController.elapsedText(0) == "0:00")
        #expect(BenchmarkController.elapsedText(72.9) == "1:12")
        #expect(BenchmarkController.elapsedText(-3) == "0:00")
    }

    // MARK: - Comparison

    @Test("a change is worded against the baseline: faster as a ratio, slower as a percentage")
    func comparisonWording() throws {
        #expect(BenchmarkComparison.change(baseline: 100, other: 123) == .init(direction: .faster, text: "1.23× faster"))
        #expect(BenchmarkComparison.change(baseline: 100, other: 81) == .init(direction: .slower, text: "19% slower"))
        #expect(BenchmarkComparison.change(baseline: 100, other: 100.5)?.direction == .same)
        #expect(BenchmarkComparison.change(baseline: 0, other: 50) == nil)
    }

    @Test("the baseline is the one asked for if it's in the pair, else the older run")
    func baselineChoice() throws {
        var older = Self.sampleResult(model: "M", chip: "c", speed: 1)
        older.date = Date(timeIntervalSince1970: 1000)
        let newer = Self.sampleResult(model: "M", chip: "c", speed: 2)
        let pair = [newer, older]
        #expect(BenchmarkComparison.baseline(of: pair, preferred: nil)?.id == older.id)
        #expect(BenchmarkComparison.baseline(of: pair, preferred: newer.id)?.id == newer.id)
        #expect(BenchmarkComparison.baseline(of: pair, preferred: UUID())?.id == older.id)
        #expect(BenchmarkComparison.baseline(of: [older], preferred: nil) == nil)
    }

    // MARK: - Chat entry

    @Test("a runtime with a web UI opens it; one without hands off to quail run")
    func chatEntry() throws {
        let url = try #require(URL(string: "http://127.0.0.1:8080"))
        #expect(ChatEntry.resolve(webUI: url, model: "M") == .browser(url))
        #expect(ChatEntry.resolve(webUI: nil, model: "Qwen3-8B-Q4_K_M") == .terminal(command: "quail run Qwen3-8B-Q4_K_M"))
        #expect(ChatEntry.resolve(webUI: nil, model: nil) == .terminal(command: "quail run"))
        #expect(ChatEntry.command(model: "my model's") == "quail run 'my model'\\''s'")
    }

    // MARK: - Result format and storage

    @Test("a result round-trips through JSON and the control protocol")
    func roundTrip() throws {
        let result = Self.sampleResult(model: "M", chip: "Apple M4 Pro", speed: 42)
        let data = try BenchmarkResult.encoder().encode(result)
        #expect(try BenchmarkResult.decoder().decode(BenchmarkResult.self, from: data) == result)

        let response = ControlResponse(ok: true, benchmark: result)
        let line = try ControlCoding.encodeLine(response)
        #expect(try ControlCoding.decode(ControlResponse.self, line: line.dropLast()) == response)
    }

    @Test("the store saves and loads results; measured speed is the newest on this chip")
    func store() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = BenchmarkStore(fileURL: file)
        var old = Self.sampleResult(model: "M", chip: "Apple M4 Pro", speed: 40)
        old.date = Date(timeIntervalSince1970: 1000)
        let new = Self.sampleResult(model: "M", chip: "Apple M4 Pro", speed: 50)
        let otherChip = Self.sampleResult(model: "M", chip: "Apple M1", speed: 10)
        try store.save([old, new, otherChip])

        let loaded = store.load()
        #expect(loaded.count == 3)
        #expect(loaded.first?.date == new.date)
        #expect(BenchmarkStore.latestGenerationSpeed(in: loaded, chip: "Apple M4 Pro") == ["M": 50])
    }

    @Test("markdown names the model, the Mac and each measurement")
    func markdown() {
        let text = Self.sampleResult(model: "Qwen3-8B-Q4_K_M", chip: "Apple M4 Pro", speed: 42).markdown
        #expect(text.contains("Qwen3-8B-Q4_K_M"))
        #expect(text.contains("Apple M4 Pro"))
        #expect(text.contains("| Generate 256 | 42.0 tok/s"))
    }

    static func sampleResult(model: String, chip: String, speed: Double) -> BenchmarkResult {
        BenchmarkResult(
            suite: BenchmarkSuite.id,
            date: Date(timeIntervalSince1970: 1_790_000_000),
            quailVersion: "0.1.0",
            hardware: .init(chip: chip, gpuCores: 20, memoryBytes: 64 << 30),
            model: .init(id: model, format: "gguf", quant: "Q4_K_M", bytes: 5 << 30),
            engine: .init(runtime: "llama.cpp", build: "b11081", contextSize: 32768, slots: 4),
            conditions: .init(thermalState: "nominal", lowPowerMode: false, onBattery: false, otherModelsLoaded: []),
            measurements: .init(
                loadSeconds: .of([1.2]),
                prompt512: .of([900, 950, 1000]),
                prompt4096: .of([800]),
                generation256: .of([speed]),
                timeToFirstTokenMs: .of([120])
            ),
            estimatedTokensPerSecond: 45
        )
    }
}

/// A router with models that load and unload instantly. Loading one model
/// evicts the others (like `--models-max 1`). Completions answer 9999 tok/s
/// for the first call (the warm-up) and 100, 110, 120… afterwards.
actor FakeBenchmarkClient: BenchmarkClient {
    private(set) var states: [String: String]
    private(set) var promptLengths: [Int] = []
    private let contextSize: Int
    private var failing: Set<String> = []
    private var hangs = false
    private(set) var isHanging = false

    init(states: [String: String], contextSize: Int) {
        self.states = states
        self.contextSize = contextSize
    }

    /// Makes the next completion wait (until cancelled) instead of answering.
    func hangOnComplete() {
        hangs = true
    }

    func failLoads(of model: String) {
        failing.insert(model)
    }

    func tokenize(_: String, model _: String) async throws -> [Int] {
        Array(1 ... 50)
    }

    func properties(model _: String) async throws -> ServerProperties {
        ServerProperties(build: "b-test", contextSize: contextSize, slots: 4)
    }

    func modelStates() async throws -> [String: String] {
        states
    }

    func load(model: String) async throws {
        if failing.contains(model) {
            states[model] = "failed"
            return
        }
        for key in states.keys where states[key] == "loaded" {
            states[key] = "unloaded"
        }
        states[model] = "loaded"
    }

    func unload(model: String) async throws {
        states[model] = "unloaded"
    }

    func complete(model _: String, prompt: [Int], maxTokens: Int) async throws -> CompletionTiming {
        if hangs {
            isHanging = true
            try await Task.sleep(for: .seconds(60))
        }
        promptLengths.append(prompt.count)
        let call = promptLengths.count
        let speed = call == 1 ? 9999 : Double(100 + 10 * ((call - 2) % 3))
        return CompletionTiming(
            promptTokens: prompt.count, promptPerSecond: speed,
            generatedTokens: maxTokens, generatedPerSecond: speed,
            timeToFirstTokenMs: 50
        )
    }
}
