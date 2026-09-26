import Foundation
import os

extension AppState {
    /// Installed models the chosen runtime can serve, so can benchmark: GGUF under llama.cpp, GGUF and MLX
    /// under the Quail server.
    var benchmarkableModels: [String] {
        _ = storeRevision // re-read when the store changes
        return modelStore.loadCatalog().entries.filter { canServe($0.format) }.map(\.id).sorted()
    }

    /// "GGUF" or "MLX", for labelling a model in the Benchmark pane.
    func formatLabel(ofModel id: String) -> String? {
        modelStore.loadCatalog().entries.first { $0.id == id }.map { $0.format == .gguf ? "GGUF" : "MLX" }
    }

    /// Benchmarks `id` on the running server and saves the result.
    func runBenchmark(model id: String) async throws -> BenchmarkResult {
        guard serverController.phase == .ready, let base = serverController.baseURL else {
            throw BenchmarkError.serverNotRunning
        }
        guard let entry = modelStore.loadCatalog().entries.first(where: { $0.id == id }) else {
            throw BenchmarkError.unknownModel(id)
        }
        guard canServe(entry.format) else { throw BenchmarkError.notGGUF(id) }

        let store = modelStore
        let runtime = config.runtimeID
        let runtimeName = self.runtime.id.displayName
        let apiKey = serverController.apiKey
        return try await benchmarks.execute(model: id) { [self] controller in
            let context = await Task.detached(priority: .userInitiated) {
                Self.benchmarkContext(for: entry, store: store, runtime: runtime, runtimeName: runtimeName)
            }.value
            try Task.checkCancellation()
            await benchmarkLog("benchmark of \(id) started")
            do {
                let result = try await controller.run(
                    model: id,
                    client: LlamaCppBenchmarkClient(base: base, apiKey: apiKey),
                    context: context
                )
                let speed = result.measurements.generation256?.median
                let generation = speed.map { String(format: "%.1f tok/s", $0) } ?? "—"
                await benchmarkLog("benchmark of \(id) finished — generation \(generation)")
                return result
            } catch {
                await benchmarkLog("benchmark of \(id) failed — \(error)")
                throw error
            }
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
        runtime: RuntimeID,
        runtimeName: String = RuntimeID.llamaCpp.displayName
    ) -> BenchmarkContext {
        let device = DeviceInfo.current()
        let architecture: String? = switch entry.format {
        case .gguf:
            (try? GGUFMetadata.read(from: store.ggufDirectory.appendingPathComponent("\(entry.id).gguf")))?.architecture
        case .mlxSafetensors:
            (try? MLXMetadata.read(from: store.mlxDirectory.appendingPathComponent(entry.id)
                    .appendingPathComponent("config.json")))?.modelType
        }
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
                format: entry.format == .gguf ? "gguf" : "mlx",
                sourceRepo: entry.sourceRepo,
                quant: entry.quant,
                params: entry.params,
                bytes: entry.bytes,
                sha256: entry.sha256,
                architecture: architecture,
                trainedContext: entry.trainedContext
            ),
            estimatedTokensPerSecond: estimate?.estimatedTokensPerSecond,
            runtimeName: runtimeName
        )
    }
}
