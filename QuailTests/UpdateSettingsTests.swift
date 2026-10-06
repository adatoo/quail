import Foundation
import Testing
@testable import Quail

/// A stand-in for Sparkle's updater that records what was written to it.
@MainActor
private final class FakeUpdateBackend: UpdateBackend {
    var automaticallyChecksForUpdates: Bool {
        didSet { writes += 1 }
    }

    var updateCheckInterval: TimeInterval {
        didSet { writes += 1 }
    }

    var automaticallyDownloadsUpdates: Bool {
        didSet { writes += 1 }
    }

    var lastUpdateCheckDate: Date?
    var canCheckForUpdates = true
    private(set) var checks = 0
    private(set) var writes = 0

    init(checks: Bool = true, interval: TimeInterval = 86400, downloads: Bool = false, last: Date? = nil) {
        automaticallyChecksForUpdates = checks
        updateCheckInterval = interval
        automaticallyDownloadsUpdates = downloads
        lastUpdateCheckDate = last
        writes = 0
    }

    func checkForUpdates() {
        checks += 1
    }
}

@Suite("UpdateSettings")
@MainActor
struct UpdateSettingsTests {
    @Test(
        "a stored Sparkle state reads back as the nearest choice, never checking more often than asked",
        arguments: [
            (true, 3600.0, UpdateFrequency.daily),
            (true, 86400.0, .daily),
            (true, 86401.0, .weekly),
            (true, 604_800.0, .weekly),
            (true, 604_801.0, .monthly),
            (true, 2_592_000.0, .monthly),
            (false, 86400.0, .never),
            (false, 999_999_999.0, .never),
        ]
    )
    func readsBack(automatic: Bool, interval: TimeInterval, expected: UpdateFrequency) {
        #expect(UpdateFrequency(automaticallyChecks: automatic, interval: interval) == expected)
        let settings = UpdateSettings(backend: FakeUpdateBackend(checks: automatic, interval: interval))
        #expect(settings.frequency == expected)
    }

    @Test("each choice has the interval Sparkle is given")
    func intervals() {
        #expect(UpdateFrequency.daily.interval == 86400)
        #expect(UpdateFrequency.weekly.interval == 604_800)
        #expect(UpdateFrequency.monthly.interval == 2_592_000)
        #expect(UpdateFrequency.never.interval == nil)
        #expect(UpdateFrequency.allCases.map(\.label) == ["Daily", "Weekly", "Monthly", "Never"])
    }

    @Test("choosing a frequency writes its interval and turns scheduled checks on")
    func choosingWrites() {
        let backend = FakeUpdateBackend(checks: false, interval: 86400)
        let settings = UpdateSettings(backend: backend)
        #expect(settings.frequency == .never)

        settings.frequency = .weekly
        #expect(backend.automaticallyChecksForUpdates)
        #expect(backend.updateCheckInterval == 604_800)

        settings.frequency = .monthly
        #expect(backend.updateCheckInterval == 2_592_000)
    }

    @Test("Never turns scheduled checks off and remembers nothing else; choosing again restores them")
    func never() {
        let backend = FakeUpdateBackend(checks: true, interval: 604_800)
        let settings = UpdateSettings(backend: backend)
        settings.frequency = .never
        #expect(!backend.automaticallyChecksForUpdates)

        settings.frequency = .daily
        #expect(backend.automaticallyChecksForUpdates)
        #expect(backend.updateCheckInterval == 86400)
    }

    @Test("the automatic-install toggle writes through, and reads the stored value at start")
    func installToggle() {
        let backend = FakeUpdateBackend(downloads: true)
        let settings = UpdateSettings(backend: backend)
        #expect(settings.installsAutomatically)

        settings.installsAutomatically = false
        #expect(!backend.automaticallyDownloadsUpdates)
    }

    @Test("setting what's already set writes nothing")
    func noRedundantWrites() {
        let backend = FakeUpdateBackend(checks: true, interval: 86400, downloads: false)
        let settings = UpdateSettings(backend: backend)
        settings.frequency = .daily
        settings.installsAutomatically = false
        #expect(backend.writes == 0)
    }

    @Test("Check Now asks Sparkle to check, and the last-checked time follows it")
    func checkNow() {
        let backend = FakeUpdateBackend(last: nil)
        let settings = UpdateSettings(backend: backend)
        #expect(settings.lastCheck == nil)

        settings.checkNow()
        #expect(backend.checks == 1)

        let when = Date(timeIntervalSince1970: 1_800_000_000)
        backend.lastUpdateCheckDate = when
        #expect(settings.lastCheck == nil) // not until Sparkle says it finished
        settings.refreshLastCheck()
        #expect(settings.lastCheck == when)
    }

    @Test("Check Now brings Quail forward first, then shows Checking until the cycle ends")
    func checkNowActivatesAndShowsChecking() {
        let backend = FakeUpdateBackend()
        let settings = UpdateSettings(backend: backend)
        var order: [String] = []
        settings.activate = { order.append("activate \(backend.checks)") }

        settings.checkNow()
        #expect(order == ["activate 0"])
        #expect(backend.checks == 1)
        #expect(settings.status == .checking)
        #expect(!settings.canCheckNow) // a second press while checking does nothing

        settings.checkNow()
        #expect(backend.checks == 1)

        settings.cycleFinished()
        #expect(settings.status == .idle)
        #expect(settings.canCheckNow)
    }

    @Test("while Sparkle is busy in the background the button is disabled and pressing it does nothing")
    func busyBackground() {
        let backend = FakeUpdateBackend()
        backend.canCheckForUpdates = false
        let settings = UpdateSettings(backend: backend)
        #expect(!settings.canCheckNow)

        settings.checkNow()
        #expect(backend.checks == 0)
        #expect(settings.status == .idle)

        settings.canCheckChanged(true)
        #expect(settings.canCheckNow)
    }

    @Test("a check that finds nothing says up to date; one that fails says why")
    func upToDateAndFailed() {
        let settings = UpdateSettings(backend: FakeUpdateBackend())
        settings.checkNow()
        settings.noUpdateFound()
        settings.cycleFinished()
        #expect(settings.status == .upToDate)

        settings.checkNow()
        #expect(settings.status == .checking)
        settings.failed("The network connection was lost.")
        settings.cycleFinished()
        #expect(settings.status == .failed("The network connection was lost."))
    }

    @Test("found, then downloading, then ready: Restart Now runs Sparkle's install")
    func downloadToInstall() {
        let settings = UpdateSettings(backend: FakeUpdateBackend())
        settings.found(version: "1.0.2")
        #expect(settings.status == .available(version: "1.0.2"))
        #expect(settings.installNow == nil)

        settings.downloading(version: "1.0.2")
        #expect(settings.status == .downloading(version: "1.0.2"))

        var installed = 0
        settings.readyToInstall(version: "1.0.2") { installed += 1 }
        #expect(settings.status == .readyToInstall(version: "1.0.2"))
        settings.installNow?()
        #expect(installed == 1)
    }

    @Test("a later check's result doesn't hide an update that's downloaded and waiting")
    func readyStaysReady() {
        let settings = UpdateSettings(backend: FakeUpdateBackend())
        settings.readyToInstall(version: "1.0.2") {}
        settings.checkNow()
        #expect(settings.status == .readyToInstall(version: "1.0.2"))
        settings.noUpdateFound()
        settings.failed("offline")
        settings.found(version: "1.0.2")
        settings.cycleFinished()
        #expect(settings.status == .readyToInstall(version: "1.0.2"))
        #expect(settings.installNow != nil)
    }

    @Test("a failed download ends it; skipping a found version clears it")
    func downloadFailedAndSkipped() {
        let settings = UpdateSettings(backend: FakeUpdateBackend())
        settings.downloading(version: "1.0.2")
        settings.downloadFailed("The file couldn't be saved.")
        #expect(settings.status == .failed("The file couldn't be saved."))

        settings.found(version: "1.0.3")
        settings.skipped()
        #expect(settings.status == .idle)
    }
}
