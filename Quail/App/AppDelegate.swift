import AppKit
import Dispatch
import Foundation

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
    /// True when this process is hosting `QuailTests` — `TEST_HOST`
    /// genuinely launches a live Quail.app to run the test bundle
    /// inside it, so this `AppDelegate` really is constructed and
    /// `applicationDidFinishLaunching` really does run, even though no
    /// test ever looks at its `appState` (every test builds its own
    /// with fakes). See `NullSecretStore`'s doc comment for why this
    /// matters: a real `Keychain()` here was popping a macOS
    /// authorization prompt on every single `xcodebuild test` run.
    private static var isHostingUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    let appState = isHostingUnitTests ? AppState(secretStore: NullSecretStore()) : AppState()

    #if !APPSTORE
        /// The in-app updater. Not started when hosting unit tests (it would check the real feed).
        private let updater = Updater(start: !isHostingUnitTests)
    #endif

    /// What Settings → Updates and the menu's "Check for Updates…" use; `nil` in the App Store build.
    var updateSettings: UpdateSettings? {
        #if APPSTORE
            nil
        #else
            updater.settings
        #endif
    }

    private var sigtermSource: DispatchSourceSignal?
    private var controlServer: ControlServer?

    func applicationDidFinishLaunching(_: Notification) {
        // Nothing below matters for a process only hosting the test
        // bundle — skip the SIGTERM plumbing and, more importantly,
        // the real network call `refreshCatalog()` would otherwise
        // make on every test run.
        guard !Self.isHostingUnitTests else { return }
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

        // A previous run killed without a chance to clean up (Xcode's
        // Stop button, a crash, `kill -9`) leaves its llama-server — and
        // whatever model it had loaded — running as an orphan. Stop it
        // now rather than only at the next Start, so its RAM is freed
        // and the port is clear. See ServerPreflight.swift.
        let presetsPath = appState.modelStore.presetsFile.path
        Task { await OrphanReaper.reap(signature: presetsPath) }

        // Pick up anything changed in the store while Quail wasn't running
        // (a model deleted in Finder), then keep watching for more.
        Task {
            await appState.reconcileStore()
            appState.startWatchingStore()
            // "Always on" (`quail service enable` / Settings): start the
            // server as soon as Quail launches — at login, with openAtLogin.
            if appState.config.autoStartServer, appState.canStart {
                await appState.start()
            }
        }

        // The `quail` command-line tool talks to the app over this socket.
        let state = appState // not named appState: CI's Swift reads the Task above as capturing it before declaration
        controlServer = ControlServer { request in await state.handleControl(request) }
        do {
            try controlServer?.start()
        } catch {
            NSLog("Quail: control socket unavailable: \(error)")
        }
    }

    func applicationWillTerminate(_: Notification) {
        controlServer?.stop()
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
