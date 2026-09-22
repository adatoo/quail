import Foundation
@testable import Quail

/// A `Runtime` whose HTTP-facing methods are fully controllable, so
/// `ServerController` and `HealthProbe` tests never make a real network
/// call or need a real llama-server process — only `ProcessSupervisor`
/// spawns anything, and tests point it at a trivial system binary (e.g.
/// `/bin/sleep`) via `launchSpec`.
actor FakeRuntime: Runtime {
    nonisolated let id: RuntimeID = .llamaCpp
    nonisolated let supportedFormats: Set<ModelFormat> = [.gguf]
    var installState: InstallState {
        .bundled
    }

    private let fixedLaunchSpec: LaunchSpec
    private var healthResults: [Result<Health, Error>]
    private var healthCallIndex = 0
    private var listModelsResult: Result<[ServedModel], Error> = .success([])
    private var selectResult: Result<SelectAction, Error> = .success(.hotSwapped)

    /// - Parameters:
    ///   - launchSpec: returned unconditionally from `launchSpec(config:model:)`.
    ///     Point this at a real, trivial, fast-exiting-or-not binary
    ///     depending on what the test needs `ProcessSupervisor` to do.
    ///   - healthResults: consumed in order by successive `health(base:)`
    ///     calls; the last element repeats once exhausted. Defaults to
    ///     always-healthy.
    init(launchSpec: LaunchSpec, healthResults: [Result<Health, Error>] = [.success(Health(status: "ok"))]) {
        fixedLaunchSpec = launchSpec
        self.healthResults = healthResults
    }

    nonisolated func launchSpec(config _: EndpointConfig, model _: ModelRef?) -> LaunchSpec {
        fixedLaunchSpec
    }

    func health(base _: URL, apiKey _: String?) async throws -> Health {
        let result = healthResults[min(healthCallIndex, healthResults.count - 1)]
        if healthCallIndex < healthResults.count - 1 {
            healthCallIndex += 1
        }
        return try result.get()
    }

    func listModels(base _: URL, apiKey _: String?) async throws -> [ServedModel] {
        try listModelsResult.get()
    }

    func select(model _: ModelRef, base _: URL, apiKey _: String?) async throws -> SelectAction {
        try selectResult.get()
    }

    nonisolated func webUIURL(base: URL) -> URL? {
        base
    }

    // MARK: - Test configuration (actor-isolated; call with `await` from tests)

    func setHealthResults(_ results: [Result<Health, Error>]) {
        healthResults = results
        healthCallIndex = 0
    }

    func setListModelsResult(_ result: Result<[ServedModel], Error>) {
        listModelsResult = result
    }

    func setSelectResult(_ result: Result<SelectAction, Error>) {
        selectResult = result
    }
}
