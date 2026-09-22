import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for Settings → General's "Open
/// at login" toggle — see docs/ARCHITECTURE.md's login-item row and
/// https://nilcoalescing.com/blog/LaunchAtLoginSetting/ (docs/IMPLEMENTATION_PLAN.md's
/// reading list) for the API's quirks.
///
/// `register()`/`unregister()` can throw for reasons entirely outside
/// Quail's control (e.g. the user removed the login item from System
/// Settings directly), so `setEnabled` treats a thrown error as
/// non-fatal — the caller should always re-read `isEnabled` afterwards
/// rather than trust the requested value blindly. Not unit-tested: it's a
/// thin wrapper over a real system service with no fake to substitute
/// (same reasoning as `Keychain`).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            // Deliberately swallowed: callers re-read `isEnabled` to learn
            // the actual outcome rather than trusting `enabled`.
        }
    }
}
