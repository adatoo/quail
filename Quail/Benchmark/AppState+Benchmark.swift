import Foundation
import os

extension AppState {
    /// Installed GGUF models — the ones the running server can benchmark.
    var benchmarkableModels: [String] {
        _ = storeRevision // re-read when the store changes
        return modelStore.loadCatalog().entries.filter { $0.format == .gguf }.map(\.id).sorted()
    }

    /// Benchmarks `id` on the running server and saves the result.
    func runBenchmark(model id: String) async throws -> BenchmarkResult {
        guard serverController.phase == .ready, let base = serverController.baseURL else {
            throw BenchmarkError.serverNotRunning
        }
        guard let entry = modelStore.loadCatalog().entries.first(where: { $0.id == id }) else {
            throw BenchmarkError.unknownModel(id)
        }
        guard entry.format == .gguf else { throw BenchmarkError.notGGUF(id) }

        let store = modelStore
        let runtime = config.runtimeID
        let context = await Task.detached(priority: .userInitiated) {
            Self.benchmarkContext(for: entry, store: store, runtime: runtime)
        }.value
        await benchmarkLog("benchmark of \(id) started")
        do {
            let result = try await benchmarks.run(
                model: id,
                client: LlamaCppBenchmarkClient(base: base, apiKey: serverController.apiKey),
                context: context
            )
            let generation = result.measurements.generation256.map { String(format: "%.1f tok/s", $0.median) } ?? "—"
            await benchmarkLog("benchmark of \(id) finished — generation \(generation)")
            return result
        } catch {
            await benchmarkLog("benchmark of \(id) failed — \(error)")
            throw error
        }
    }

    /// To the Logs window and the unified log, like the store audit.
    private func benchmarkLog(_ text: String) async {
        Logger(subsystem: "com.datoos.quail", category: "Benchmark").notice("\(text, privacy: .public)")
        await logStore.append(stream: .stderr, text: "quail: \(text)")
    }

    nonisolated static func benchmarkContext(
        for entry: InstalledModel,
        store: ModelStore,
        runtime: RuntimeID
    ) -> BenchmarkContext {
        let device = DeviceInfo.current()
        let metadata = try? GGUFMetadata.read(from: store.ggufDirectory.appendingPathComponent("\(entry.id).gguf"))
        let estimate = ModelPreview.installed(
            entry: entry, store: store, device: device,
            ggufRuntime: runtime, bandwidthTable: ChipBandwidthTable.loadFromBundle()
        )
        return BenchmarkContext(
            quailVersion: AppInfo.version,
            hardware: BenchmarkResult.Hardware(
                chip: device.chipName,
                marketingName: device.marketingName,
                modelIdentifier: device.modelIdentifier,
                performanceCores: device.performanceCoreCount,
                efficiencyCores: device.efficiencyCoreCount,
                gpuCores: device.gpuCoreCount,
                memoryBytes: device.unifiedMemoryBytes,
                gpuWorkingSetBytes: device.gpuWorkingSetCeilingBytes,
                osVersion: device.osVersion
            ),
            model: BenchmarkResult.Model(
                id: entry.id,
                format: "gguf",
                sourceRepo: entry.sourceRepo,
                quant: entry.quant,
                params: entry.params,
                bytes: entry.bytes,
                sha256: entry.sha256,
                architecture: metadata?.architecture,
                trainedContext: entry.trainedContext
            ),
            estimatedTokensPerSecond: estimate?.estimatedTokensPerSecond
        )
    }
}
