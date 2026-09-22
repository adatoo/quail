import Testing
@testable import Quail

@Suite("AppInfo")
struct AppInfoTests {
    @Test("version reads from the bundle without crashing and is never empty")
    func versionIsNonEmpty() {
        #expect(!AppInfo.version.isEmpty)
    }

    @Test("the Quail scheme is not compiled as an App Store build")
    func developerIDSchemeIsNotAppStore() {
        #expect(AppInfo.isAppStoreBuild == false)
    }
}
