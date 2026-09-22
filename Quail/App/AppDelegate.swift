import AppKit
import Dispatch

/// Owns the app's `AppState` and makes sure the bundled runtime's child
/// process is actually stopped before Quail itself goes away, through
/// either path something can end the app:
///
/// - "Quit Quail", Cmd+Q, Dock "Quit", or a macOS logout/restart/shutdown
///   all go through `applicationShouldTerminate`.
/// - A raw `kill <pid>`/`SIGTERM` sent directly to Quail's own process
///   (not through any of the above) bypasses AppKit's termination
///   machinery entirely, so it's also handled explicitly with a
///   `DispatchSourceSignal`.
///
/// Without either, `NSApplication.terminate()` — or the process simply
/// being killed — does not itself send anything to a spawned `Process`:
/// confirmed by testing it, the bundled `llama-server` is left running as
/// an orphan. See AGENTS.md and docs/IMPLEMENTATION_PLAN.md Phase 1 step 4
/// ("Kill the child on app termination"), and `ServerController.stop()`'s
/// doc comment for why waiting for it to actually exit (not just sending
/// the signal) is what makes this a real guarantee.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.appState.stop()
                exit(0)
            }
        }
        source.resume()
        sigtermSource = source

        // Weekly catalog refresh (docs/ARCHITECTURE.md §6) — no-ops
        // until a `QuailCatalogURL` exists in Info.plist; see
        // `AppState.refreshCatalog` for the cadence rationale.
        Task { await appState.refreshCatalog() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard appState.canStop else { return .terminateNow }
        Task {
            await appState.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
