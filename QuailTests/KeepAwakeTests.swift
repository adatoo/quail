import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Quail

@Suite("Keep awake", .timeLimit(.minutes(1)))
@MainActor
struct KeepAwakeTests {
    /// Counts assertions instead of taking real ones.
    final class FakeAssertions: KeepAwake.Assertions, @unchecked Sendable {
        var created = 0
        var released = 0
        var reasons: [String] = []

        func create(reason: String) -> IOPMAssertionID? {
            created += 1
            reasons.append(reason)
            return IOPMAssertionID(created)
        }

        func release(_: IOPMAssertionID) {
            released += 1
        }
    }

    @Test("one assertion while active; asking twice changes nothing; released when inactive")
    func assertionLifecycle() {
        let fake = FakeAssertions()
        let keepAwake = KeepAwake(assertions: fake)
        keepAwake.update(active: true)
        keepAwake.update(active: true)
        #expect(fake.created == 1 && keepAwake.isHolding)
        keepAwake.update(active: false)
        keepAwake.update(active: false)
        #expect(fake.released == 1 && !keepAwake.isHolding)
        #expect(fake.reasons.first?.contains("Quail") == true)
    }

    private func makeAppState(_ fake: FakeAssertions, config: Config) throws -> (AppState, URL) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-keepawake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let appState = AppState(
            config: config,
            configURL: scratch.appendingPathComponent("config.json"),
            secretStore: FakeSecretStore(),
            runtime: FakeRuntime(launchSpec: LaunchSpec(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
                currentDirectoryURL: nil
            )),
            modelsRootURL: scratch.appendingPathComponent("Models", isDirectory: true),
            catalogLocations: .init(bundle: .main, directory: scratch),
            shapeCache: ModelShapeCache(url: nil),
            keepAwake: KeepAwake(assertions: fake),
            serverPreflight: nil
        )
        try appState.modelStore.ensureDirectoriesExist()
        try Data("x".utf8).write(to: appState.modelStore.ggufDirectory.appendingPathComponent("M.gguf"))
        return (appState, scratch)
    }

    @Test("held while the server runs with the setting on; released on Stop and when turned off")
    func followsServerAndSetting() async throws {
        let fake = FakeAssertions()
        var config = Config()
        config.apiKeyEnabled = false
        let (appState, scratch) = try makeAppState(fake, config: config)
        defer { try? FileManager.default.removeItem(at: scratch) }

        await appState.start()
        #expect(!appState.keepAwake.isHolding) // off by default
        appState.setKeepAwake(true)
        #expect(appState.keepAwake.isHolding)
        await appState.stop()
        #expect(!appState.keepAwake.isHolding)

        await appState.start()
        #expect(appState.keepAwake.isHolding)
        appState.setKeepAwake(false)
        #expect(!appState.keepAwake.isHolding)
        await appState.stop()
        #expect(fake.created == fake.released)
        #expect(Config.load(from: scratch.appendingPathComponent("config.json")).keepAwake == false)
    }

    #if !APPSTORE
        @Test("the lid-closed loop: its paths and Quail's process, quoted so nothing escapes")
        func lidLoopScript() {
            let dir = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Quail")
            let script = LidSleepGuard.loopScript(
                enabled: dir.appendingPathComponent("lid-awake.enabled"),
                serving: dir.appendingPathComponent("lid-awake.serving"), processID: 4242
            )
            #expect(script.contains(#"E="/Users/someone/Library/Application Support/Quail/lid-awake.enabled""#))
            #expect(script.contains("P=4242"))
            #expect(script.contains("pmset -a disablesleep $want"))
            #expect(script.hasSuffix(#"/bin/rm -f "$E" "$S""#))
            #expect(script.contains("pmset -a disablesleep 0")) // restored on the way out
            #expect(script.contains("AC Power")) // only while plugged in

            #expect(LidSleepGuard.isSafePath(dir.path))
            for bad in [#"/a"b"#, "/a$HOME", "/a`x`", #"/a\b"#] {
                #expect(!LidSleepGuard.isSafePath(bad), "\(bad)")
            }
            #expect(LidSleepGuard.shellQuoted("it's") == #"'it'\''s'"#)
            #expect(LidSleepGuard.appleScriptString(#"say "hi" \ now"#) == #""say \"hi\" \\ now""#)
        }
    #endif
}
