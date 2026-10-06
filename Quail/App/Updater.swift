import AppKit
import Sparkle

/// Sparkle's own settings *are* the update settings: `SPUUpdater` stores them in
/// `UserDefaults`, so the app just reads and writes them through `UpdateSettings`.
extension SPUUpdater: UpdateBackend {}

/// The in-app updater (ADR D-032): checks the appcast each release attaches, on
/// the schedule the General page's Updates section chooses, and installs with Sparkle's standard UI.
/// What it's doing in between (checking, downloading, waiting to install) goes to
/// `UpdateSettings.status`, which Settings and the menu show.
///
/// Installing quits Quail through the ordinary `applicationShouldTerminate`, so the
/// server stops cleanly first, then Sparkle swaps the app and relaunches it.
@MainActor
final class Updater {
    let settings: UpdateSettings
    private let controller: SPUStandardUpdaterController
    private let delegate = UpdaterDelegate()
    private let userDriverDelegate = UserDriverDelegate()
    private var canCheckObservation: NSKeyValueObservation?

    /// - Parameter start: `false` under unit tests, which host a real Quail.app —
    ///   starting Sparkle there would check the real feed on every test run.
    init(start: Bool) {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: userDriverDelegate
        )
        settings = UpdateSettings(backend: controller.updater)
        settings.activate = { NSApp.activate(ignoringOtherApps: true) }
        delegate.settings = settings
        guard start else { return }
        controller.startUpdater()
        // Sparkle ignores a check while it's busy in the background; the button follows it.
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [settings] updater, _ in
            // Sparkle changes it on the main thread, and SPUUpdater is main-actor isolated.
            MainActor.assumeIsolated { settings.canCheckChanged(updater.canCheckForUpdates) }
        }
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
    weak var settings: UpdateSettings?

    #if DEBUG
        /// Debug builds can point at another appcast (`-QuailUpdateFeed <url>`) to test an
        /// update against a local server. Shipped builds only ever use the Info.plist's.
        func feedURLString(for _: SPUUpdater) -> String? {
            UserDefaults.standard.string(forKey: "QuailUpdateFeed")
        }
    #endif

    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        settings?.found(version: item.displayVersionString)
    }

    func updater(_: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with _: NSMutableURLRequest) {
        settings?.downloading(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_: SPUUpdater) {
        settings?.noUpdateFound()
    }

    func updater(_: SPUUpdater, failedToDownloadUpdate _: SUAppcastItem, error: any Error) {
        settings?.downloadFailed(error.localizedDescription)
    }

    func updater(_: SPUUpdater, didAbortWithError error: any Error) {
        let error = error as NSError
        // Finding nothing and cancelling the password prompt both arrive as errors, but aren't failures.
        let notFailures = [SUError.noUpdateError.rawValue, SUError.installationCanceledError.rawValue]
        if error.domain == SUSparkleErrorDomain, notFailures.contains(OSStatus(error.code)) {
            return
        }
        settings?.failed(error.localizedDescription)
    }

    func updater(
        _: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate _: SUAppcastItem,
        state _: SPUUserUpdateState
    ) {
        if choice == .skip {
            settings?.skipped()
        }
    }

    func updater(_: SPUUpdater, didFinishUpdateCycleFor _: SPUUpdateCheck, error _: (any Error)?) {
        settings?.cycleFinished()
    }

    /// A background download is ready (automatic install on). Quail takes charge of offering
    /// it — "Restart to Install" in the menu and Settings — instead of Sparkle's reminder
    /// alert; Sparkle still installs it when Quail quits either way. `immediateInstallationBlock`
    /// is Sparkle's own "Install and Relaunch", in which Sparkle (not Quail) quits the app.
    func updater(
        _: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        settings?.readyToInstall(version: item.displayVersionString, install: immediateInstallationBlock)
        #if DEBUG
            // `-QuailInstallUpdateAfterSeconds 25`: install after that delay through the same path,
            // for testing an update with the server running and nobody clicking.
            let delay = UserDefaults.standard.double(forKey: "QuailInstallUpdateAfterSeconds")
            if delay > 0 {
                NSLog("Quail: update downloaded; installing in %.0fs (debug flag)", delay)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NSLog("Quail: asking Sparkle to install now")
                    immediateInstallationBlock()
                }
            }
        #endif
        return true
    }
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
