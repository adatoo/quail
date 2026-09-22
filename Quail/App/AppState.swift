import Observation

/// Observable root of the app's UI state.
///
/// This is a placeholder for Phase 1 of docs/IMPLEMENTATION_PLAN.md: the
/// `ServerController` state machine, `Config`, and `ModelStore` land in
/// later PRs and will be composed here.
@MainActor
@Observable
final class AppState {
    var statusLabel: String = "Quail"
}
