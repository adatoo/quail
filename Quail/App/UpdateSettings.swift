import Foundation

/// How often Quail checks for a new version (Settings → General → Updates).
/// The four choices Sparkle's scheduler can express: it checks on a timer, or not at all.
enum UpdateFrequency: String, CaseIterable, Identifiable, Sendable {
    case daily
    case weekly
    case monthly
    case never

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .never: "Never"
        }
    }

    /// Seconds between scheduled checks; `nil` for `never`.
    var interval: TimeInterval? {
        switch self {
        case .daily: 86400
        case .weekly: 7 * 86400
        case .monthly: 30 * 86400
        case .never: nil
        }
    }

    /// The choice that a stored Sparkle state amounts to. An interval that isn't
    /// one of ours (a hand-edited default, or the plist's) rounds up to the next
    /// choice, so nothing checks *more* often than the person asked.
    init(automaticallyChecks: Bool, interval: TimeInterval) {
        if !automaticallyChecks {
            self = .never
        } else if interval <= 86400 {
            self = .daily
        } else if interval <= 7 * 86400 {
            self = .weekly
        } else {
            self = .monthly
        }
    }
}

/// Where the updater is, so Settings and the menu can say it instead of working out of sight.
/// Sparkle's own windows still do the asking; this is what Quail shows between them.
enum UpdateStatus: Equatable, Sendable {
    /// Nothing to say beyond the last check.
    case idle
    /// A check someone asked for is running.
    case checking
    /// The last check found nothing newer.
    case upToDate
    /// A newer version was found and is waiting on the person (automatic install off).
    case available(version: String)
    /// Downloading in the background (automatic install on, or after Install).
    case downloading(version: String)
    /// Downloaded; installs the next time Quail quits, or now through `installNow`.
    case readyToInstall(version: String)
    case failed(String)
}

/// The part of Sparkle's `SPUUpdater` the settings use, so the mapping below can
/// be tested with a fake.
@MainActor
protocol UpdateBackend: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var updateCheckInterval: TimeInterval { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    /// False while Sparkle is busy in the background (fetching the feed or downloading an
    /// update), when `checkForUpdates()` is ignored.
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

/// What Settings → Updates shows and changes. Sparkle keeps these in `UserDefaults`
/// itself, so nothing here goes in `config.json`; this only translates between
/// Sparkle's separate on/off and interval settings and the single choice a person sees.
@MainActor
@Observable
final class UpdateSettings {
    private let backend: any UpdateBackend

    var frequency: UpdateFrequency {
        didSet {
            guard frequency != oldValue else { return }
            if let interval = frequency.interval {
                backend.updateCheckInterval = interval
                backend.automaticallyChecksForUpdates = true
            } else {
                backend.automaticallyChecksForUpdates = false
            }
        }
    }

    /// Download and install without asking (on the next quit). Off means Sparkle
    /// finds an update and asks first.
    var installsAutomatically: Bool {
        didSet {
            guard installsAutomatically != oldValue else { return }
            backend.automaticallyDownloadsUpdates = installsAutomatically
        }
    }

    private(set) var lastCheck: Date?

    private(set) var status: UpdateStatus = .idle

    /// Installs a downloaded update now: Sparkle quits Quail (through `applicationShouldTerminate`,
    /// so the server stops first), swaps the app and relaunches it. Set only while `readyToInstall`.
    private(set) var installNow: (() -> Void)?

    private var backendCanCheck: Bool

    /// Whether Check for Updates would do anything. Sparkle ignores it during a background
    /// download, so the button is disabled then rather than silently doing nothing.
    var canCheckNow: Bool {
        backendCanCheck && status != .checking
    }

    /// Brings Quail forward before Sparkle opens a window: Quail has no Dock icon, so
    /// otherwise the window can open behind whatever app is in front.
    var activate: () -> Void = {}

    init(backend: any UpdateBackend) {
        self.backend = backend
        frequency = UpdateFrequency(
            automaticallyChecks: backend.automaticallyChecksForUpdates,
            interval: backend.updateCheckInterval
        )
        installsAutomatically = backend.automaticallyDownloadsUpdates
        lastCheck = backend.lastUpdateCheckDate
        backendCanCheck = backend.canCheckForUpdates
    }

    func checkNow() {
        guard canCheckNow else { return }
        activate()
        switch status {
        case .idle, .upToDate, .failed:
            status = .checking
        case .checking, .available, .downloading, .readyToInstall:
            // Sparkle shows the update it already has rather than checking again.
            break
        }
        backend.checkForUpdates()
    }

    /// Called when Sparkle finishes a check, so "Last checked" moves on its own.
    func refreshLastCheck() {
        lastCheck = backend.lastUpdateCheckDate
    }

    // MARK: What Sparkle reports (from `Updater`'s delegate)

    func canCheckChanged(_ canCheck: Bool) {
        backendCanCheck = canCheck
    }

    func found(version: String) {
        guard !isPastAvailable else { return }
        status = .available(version: version)
    }

    func downloading(version: String) {
        status = .downloading(version: version)
    }

    func readyToInstall(version: String, install: @escaping () -> Void) {
        status = .readyToInstall(version: version)
        installNow = install
    }

    func noUpdateFound() {
        guard !isPastAvailable else { return }
        status = .upToDate
    }

    func failed(_ message: String) {
        guard !isPastAvailable else { return }
        status = .failed(message)
    }

    /// A download that failed ends it, whatever came before.
    func downloadFailed(_ message: String) {
        status = .failed(message)
        installNow = nil
    }

    /// The person chose Skip This Version: there's nothing to point at until the next check.
    func skipped() {
        guard case .available = status else { return }
        status = .idle
    }

    /// The end of every check, found or not.
    func cycleFinished() {
        refreshLastCheck()
        if status == .checking {
            status = .idle
        }
    }

    /// Once an update is downloading or downloaded, a later check's result doesn't replace it:
    /// the download still installs when Quail quits.
    private var isPastAvailable: Bool {
        switch status {
        case .downloading, .readyToInstall: true
        default: false
        }
    }
}
