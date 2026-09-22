import Foundation
import Testing
@testable import Quail

/// Real end-to-end smoke test: the actual vendored `llama-server` binary,
/// a real GGUF, driven through `ServerController` → `ProcessSupervisor` →
/// `LlamaCppRuntime` exactly as production code would — no fakes anywhere
/// in this one.
///
/// **Not run as part of `xcodebuild test`** (and therefore not in CI):
/// it needs `Vendor/llama.cpp` populated (`scripts/vendor-llama.sh`) and a
/// real GGUF placed by hand, and the first launch of a freshly-signed
/// binary can take up to ~16s (see docs/DECISIONS.md D-009). Per AGENTS.md
/// ("Smoke test after any change to Server/ or Runtimes/"), run this
/// manually before merging such a change by placing a small GGUF at
/// `modelsDir` below (an environment variable would be more flexible, but
/// `xcodebuild test` does not forward the invoking shell's environment into
/// the test runner process without scheme-level configuration):
///
/// ```
/// scripts/vendor-llama.sh
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
            "Vendor/llama.cpp/llama-server not found — run scripts/vendor-llama.sh first"
        )

        let runtime = LlamaCppRuntime(executableURL: vendorURL)
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
        let models = try await runtime.listModels(base: base)
        #expect(!models.isEmpty, "expected the real GGUF at \(modelsDir) to be listed")

        await controller.stop()
        #expect(controller.phase == .stopped)
    }
}
