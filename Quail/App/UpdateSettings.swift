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

/// The part of Sparkle's `SPUUpdater` the settings use, so the mapping below can
/// be tested with a fake, and this file compiles in the App Store build (which
/// has no updater) too.
@MainActor
protocol UpdateBackend: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var updateCheckInterval: TimeInterval { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
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

    init(backend: any UpdateBackend) {
        self.backend = backend
        frequency = UpdateFrequency(
            automaticallyChecks: backend.automaticallyChecksForUpdates,
            interval: backend.updateCheckInterval
        )
        installsAutomatically = backend.automaticallyDownloadsUpdates
        lastCheck = backend.lastUpdateCheckDate
    }

    func checkNow() {
        backend.checkForUpdates()
    }

    /// Called when Sparkle finishes a check, so "Last checked" moves on its own.
    func refreshLastCheck() {
        lastCheck = backend.lastUpdateCheckDate
    }
}
