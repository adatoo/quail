import Foundation
import IOKit.ps
import Observation

/// The benchmark the app is running (at most one) and the saved results —
/// observed by the Benchmark window, driven by it and by `quail bench`.
@MainActor
@Observable
final class BenchmarkController {
    private(set) var results: [BenchmarkResult]
    private(set) var runningModel: String?
    private(set) var step = ""
    private(set) var fraction = 0.0
    private(set) var lastError: String?
    /// Set by "Benchmark" on a Models row, read by the window's picker.
    var requestedModel: String?

    private let store: BenchmarkStore

    init(store: BenchmarkStore = .default) {
        self.store = store
        results = store.load()
    }

    var isRunning: Bool {
        runningModel != nil
    }

    /// Newest measured generation speed per model on this Mac's chip.
    func measuredSpeeds(chip: String?) -> [String: Double] {
        BenchmarkStore.latestGenerationSpeed(in: results, chip: chip)
    }

    func delete(_ ids: Set<BenchmarkResult.ID>) {
        results.removeAll { ids.contains($0.id) }
        try? store.save(results)
    }

    /// Runs the suite and saves the result. `context` supplies everything
    /// about the model and machine that isn't measured.
    func run(
        model: String,
        client: any BenchmarkClient,
        context: BenchmarkContext
    ) async throws -> BenchmarkResult {
        guard !isRunning else { throw BenchmarkError.alreadyRunning }
        runningModel = model
        step = "Starting…"
        fraction = 0
        lastError = nil
        defer {
            runningModel = nil
            step = ""
        }
        do {
            let conditionsAtStart = Self.currentConditions()
            let output = try await BenchmarkRunner(client: client).run(model: model) { [weak self] step, fraction in
                await MainActor.run {
                    self?.step = step
                    self?.fraction = fraction
                }
            }
            var conditions = conditionsAtStart
            conditions.otherModelsLoaded = output.otherModelsLoaded
            // The worse thermal state of start and end — a run that heated
            // the Mac into throttling is the one to flag.
            let atEnd = Self.currentConditions()
            if Self.thermalRank(atEnd.thermalState) > Self.thermalRank(conditions.thermalState) {
                conditions.thermalState = atEnd.thermalState
            }
            let result = BenchmarkResult(
                suite: BenchmarkSuite.id,
                date: Date(),
                quailVersion: context.quailVersion,
                hardware: context.hardware,
                model: context.model,
                engine: BenchmarkResult.Engine(
                    runtime: "llama.cpp",
                    build: output.properties.build,
                    contextSize: output.properties.contextSize,
                    slots: output.properties.slots
                ),
                conditions: conditions,
                measurements: output.measurements,
                estimatedTokensPerSecond: context.estimatedTokensPerSecond
            )
            results.insert(result, at: 0)
            try? store.save(results)
            return result
        } catch {
            lastError = (error as? BenchmarkError)?.description ?? error.localizedDescription
            throw error
        }
    }

    // MARK: - Conditions

    static func currentConditions() -> BenchmarkResult.Conditions {
        BenchmarkResult.Conditions(
            thermalState: thermalName(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            onBattery: onBattery(),
            otherModelsLoaded: []
        )
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func thermalRank(_ name: String) -> Int {
        ["nominal", "fair", "serious", "critical"].firstIndex(of: name) ?? 0
    }

    /// `nil` when there's no power-source information (desktop Macs report
    /// AC with no battery, which reads as `false`).
    private static func onBattery() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return nil }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

/// What a result records about the model and machine, gathered by
/// `AppState` before a run.
struct BenchmarkContext: Sendable {
    var quailVersion: String
    var hardware: BenchmarkResult.Hardware
    var model: BenchmarkResult.Model
    var estimatedTokensPerSecond: Double?
}
