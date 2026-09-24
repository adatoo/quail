import Foundation
import Testing
@testable import Quail

/// Real end-to-end smoke test: the actual vendored `llama-server` binary,
/// a real GGUF, driven through `ServerController` → `ProcessSupervisor` →
/// `LlamaCppRuntime` exactly as production code would — no fakes anywhere
/// in this one.
///
/// **Not run as part of `xcodebuild test`** (and therefore not in CI):
/// it needs `Vendor/llama.cpp` populated (`task vendor:llama`) and a
/// real GGUF placed by hand, and the first launch of a freshly-signed
/// binary can take up to ~16s (see docs/DECISIONS.md D-009). Per AGENTS.md
/// ("Smoke test after any change to Server/ or Runtimes/"), run this
/// manually before merging such a change by placing a small GGUF at
/// `modelsDir` below (an environment variable would be more flexible, but
/// `xcodebuild test` does not forward the invoking shell's environment into
/// the test runner process without scheme-level configuration):
///
/// ```
/// task vendor:llama
/// mkdir -p /tmp/quail-smoke-models/gguf
/// curl -L -o /tmp/quail-smoke-models/gguf/Qwen3-0.6B-Q8_0.gguf \
///   https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf
/// xcodebuild -scheme Quail -configuration Debug test \
///   -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
/// ```
@Suite("LlamaCppIntegrationSmokeTest (manual only — see file header)", .timeLimit(.minutes(2)))
@MainActor
struct LlamaCppIntegrationSmokeTest {
    @Test("real llama-server: start, list a real model, stop — router and child both gone")
    func realRouterStartsListsAndStops() async throws {
        let modelsDir = "/tmp/quail-smoke-models/gguf"
        guard FileManager.default.fileExists(atPath: modelsDir) else {
            print("\(modelsDir) not found; skipping. See this file's header to run manually.")
            return
        }

        let vendorURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // QuailTests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Vendor/llama.cpp/llama-server")
        try #require(
            FileManager.default.fileExists(atPath: vendorURL.path),
            "Vendor/llama.cpp/llama-server not found — run `task vendor:llama` first"
        )

        let runtime = LlamaCppRuntime(
            executableURL: vendorURL,
            logFile: FileManager.default.temporaryDirectory.appendingPathComponent("quail-smoke-llama.log")
        )
        let controller = ServerController(runtime: runtime, logStore: LogStore(), healthTimeout: 30)
        let config = EndpointConfig(
            host: "127.0.0.1",
            port: 18199,
            apiKey: nil,
            modelsDirectory: URL(fileURLWithPath: modelsDir)
        )

        await controller.start(config: config)
        #expect(controller.phase == .ready)

        let base = try #require(controller.baseURL)
        let models = try await runtime.listModels(base: base, apiKey: nil)
        #expect(!models.isEmpty, "expected the real GGUF at \(modelsDir) to be listed")

        await controller.stop()
        #expect(controller.phase == .stopped)
    }

    @Test("real llama-server with --api-key: /health is exempt, /models needs the header")
    func realRouterEnforcesAPIKeyExceptOnHealth() async throws {
        let modelsDir = "/tmp/quail-smoke-models/gguf"
        guard FileManager.default.fileExists(atPath: modelsDir) else {
            print("\(modelsDir) not found; skipping. See this file's header to run manually.")
            return
        }

        let vendorURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Vendor/llama.cpp/llama-server")
        try #require(FileManager.default.fileExists(atPath: vendorURL.path))

        let runtime = LlamaCppRuntime(
            executableURL: vendorURL,
            logFile: FileManager.default.temporaryDirectory.appendingPathComponent("quail-smoke-llama.log")
        )
        let controller = ServerController(runtime: runtime, logStore: LogStore(), healthTimeout: 30)
        let config = EndpointConfig(
            host: "127.0.0.1",
            port: 18200,
            apiKey: "quail-smoke-test-key",
            modelsDirectory: URL(fileURLWithPath: modelsDir)
        )

        // start() itself relies on health being exempt from auth — if it
        // weren't, HealthProbe would time out here even with the right key
        // wired through (see ServerController.start's HealthProbe.
        // waitUntilHealthy call and Runtime.swift's doc comment).
        await controller.start(config: config)
        #expect(controller.phase == .ready)

        let base = try #require(controller.baseURL)

        await #expect(throws: RuntimeError.httpStatus(401)) {
            _ = try await runtime.listModels(base: base, apiKey: nil)
        }

        let models = try await runtime.listModels(base: base, apiKey: "quail-smoke-test-key")
        #expect(!models.isEmpty)

        await controller.stop()
        #expect(controller.phase == .stopped)
    }

    @Test("ModelStore.refreshedCatalog parses the real multi-GB GGUF's header cheaply")
    func refreshAgainstRealGGUF() throws {
        // GGUFMetadata's fixtures are synthetic; this proves the
        // memory-mapped header read against a real 639 MB file with its
        // full tensor-info section and ~150k-entry vocab after the
        // metadata — the skip-past-what-we-don't-read path at real scale,
        // and refreshedCatalog's end-to-end fit wiring on it.
        let modelsDir = URL(fileURLWithPath: "/tmp/quail-smoke-models", isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelsDir.appendingPathComponent("gguf").path) else {
            print("smoke model store not found; skipping. See this file's header to run manually.")
            return
        }
        let store = ModelStore(rootURL: modelsDir)

        let catalog = store.refreshedCatalog(
            device: DeviceInfo.current(),
            ggufRuntime: .llamaCpp,
            bandwidthTable: ChipBandwidthTable.loadFromBundle()
        )

        let row = try #require(catalog.entries.first { $0.id == "Qwen3-0.6B-Q8_0" })
        #expect(row.bytes == 639_446_688)
        // A 0.6B model is comfortable at 32K on any real Mac; its trained
        // context (40,960) doesn't cap that — Automatic picks 32K (D-020).
        #expect(row.contextSize == 32768)
        #expect(row.trainedContext == 40960)
    }
}
