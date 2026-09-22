import Foundation

/// Static app metadata surfaced in the About pane (added in a later PR) and
/// used to distinguish the Developer ID build from the Mac App Store build
/// at runtime for anything that can't be resolved purely by `#if APPSTORE`.
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var isAppStoreBuild: Bool {
        #if APPSTORE
            true
        #else
            false
        #endif
    }
}
