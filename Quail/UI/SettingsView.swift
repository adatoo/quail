import SwiftUI

/// Root of the Settings window.
///
/// Tabs (General, Endpoint, Models, Runtimes, Logs, About) land in later
/// PRs per docs/IMPLEMENTATION_PLAN.md. This placeholder exists so the
/// `Settings` scene and the menu's "Settings…" action are wired end to end.
struct SettingsView: View {
    var body: some View {
        Text("Settings are coming in a later milestone. See docs/IMPLEMENTATION_PLAN.md.")
            .multilineTextAlignment(.center)
            .padding()
            .frame(width: 420, height: 200)
    }
}
