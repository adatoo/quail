#if !APPSTORE
    import AppKit
    import Sparkle

    /// Sparkle's own settings *are* the update settings: `SPUUpdater` stores them in
    /// `UserDefaults`, so the app just reads and writes them through `UpdateSettings`.
    extension SPUUpdater: UpdateBackend {}

    /// The in-app updater (ADR D-032): checks the appcast each release attaches, on
    /// the schedule Settings → Updates chooses, and installs with Sparkle's standard UI.
    /// Direct build only — the App Store updates the App Store build.
    ///
    /// Installing quits Quail through the ordinary `applicationShouldTerminate`, so the
    /// server stops cleanly first, then Sparkle swaps the app and relaunches it.
    @MainActor
    final class Updater {
        let settings: UpdateSettings
        private let controller: SPUStandardUpdaterController
        private let delegate = UpdaterDelegate()
        private let userDriverDelegate = UserDriverDelegate()

        /// - Parameter start: `false` under unit tests, which host a real Quail.app —
        ///   starting Sparkle there would check the real feed on every test run.
        init(start: Bool) {
            controller = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: delegate,
                userDriverDelegate: userDriverDelegate
            )
            settings = UpdateSettings(backend: controller.updater)
            delegate.onCycleFinished = { [settings] in settings.refreshLastCheck() }
            guard start else { return }
            controller.startUpdater()
            #if DEBUG
                // For testing an update end to end without waiting for the schedule:
                // `open Quail.app --args -QuailCheckForUpdatesOnLaunch YES`.
                if UserDefaults.standard.bool(forKey: "QuailCheckForUpdatesOnLaunch") {
                    controller.updater.checkForUpdatesInBackground()
                }
                // An update installs when Quail quits; `-QuailQuitAfterSeconds 40` quits the way the
                // menu's Quit does (through applicationShouldTerminate), for a test with nobody clicking.
                // A plain main-queue block, deliberately not a `Task`: `terminate` waits (in a nested run
                // loop) for `applicationShouldTerminate`'s async reply, which needs the main actor, and a
                // Task calling it would be holding that actor — a deadlock. The menu's Quit is a
                // synchronous button action, so it never has this problem.
                let quitAfter = UserDefaults.standard.double(forKey: "QuailQuitAfterSeconds")
                if quitAfter > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) {
                        NSApp.terminate(nil)
                    }
                }
            #endif
        }
    }

    @MainActor
    private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
        var onCycleFinished: (() -> Void)?

        #if DEBUG
            /// Debug builds can point at another appcast (`-QuailUpdateFeed <url>`) to test an
            /// update against a local server. Shipped builds only ever use the Info.plist's.
            func feedURLString(for _: SPUUpdater) -> String? {
                UserDefaults.standard.string(forKey: "QuailUpdateFeed")
            }
        #endif

        func updater(_: SPUUpdater, didFinishUpdateCycleFor _: SPUUpdateCheck, error _: (any Error)?) {
            onCycleFinished?()
        }

        #if DEBUG
            /// `-QuailInstallUpdateAfterSeconds 25`: once an update is downloaded for install-on-quit,
            /// install it after that delay through Sparkle's own path — the one "Install and Relaunch"
            /// takes, in which Sparkle (not Quail) quits the app. For testing an update, with the
            /// server running, and nobody clicking.
            func updater(
                _: SPUUpdater,
                willInstallUpdateOnQuit _: SUAppcastItem,
                immediateInstallationBlock: @escaping () -> Void
            ) -> Bool {
                let delay = UserDefaults.standard.double(forKey: "QuailInstallUpdateAfterSeconds")
                guard delay > 0 else { return false }
                NSLog("Quail: update downloaded; installing in %.0fs (debug flag)", delay)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NSLog("Quail: asking Sparkle to install now")
                    immediateInstallationBlock()
                }
                return true
            }
        #endif
    }

    /// Quail is a menu-bar agent with no Dock icon: a scheduled update's window can open
    /// behind other apps. Sparkle's "gentle reminders" API is how a background app takes
    /// responsibility for being noticed. (Not main-actor annotated by Sparkle, unlike the
    /// updater delegate, so it's its own class; Sparkle calls it on the main thread.)
    private final class UserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
        var supportsGentleScheduledUpdateReminders: Bool {
            true
        }

        func standardUserDriverWillHandleShowingUpdate(
            _ handleShowingUpdate: Bool,
            forUpdate _: SUAppcastItem,
            state _: SPUUserUpdateState
        ) {
            guard handleShowingUpdate else { return }
            MainActor.assumeIsolated { NSApp.activate(ignoringOtherApps: true) }
        }
    }
#endif
