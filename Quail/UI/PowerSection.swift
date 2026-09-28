import SwiftUI

/// The Server page's Power section (ADR D-054): keep the Mac awake while the server runs, and — in the direct
/// build — with a laptop's lid closed while it's plugged in.
struct PowerSection: View {
    let appState: AppState

    var body: some View {
        Section("Power") {
            Toggle(
                "Keep this Mac awake while the server runs",
                isOn: Binding(get: { appState.config.keepAwake }, set: { appState.setKeepAwake($0) })
            )
            Text(
                "Stops idle sleep, as caffeinate does, so a long download, benchmark or agent session isn't cut off. The display can still turn off."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle(
                "Also with the lid closed, when plugged in",
                isOn: Binding(
                    get: { appState.config.keepAwakeLidClosed },
                    set: { appState.setKeepAwakeLidClosed($0) }
                )
            )
            .disabled(!appState.config.keepAwake)
            Text(
                "macOS sleeps a laptop when its lid closes, whatever an app asks, so this turns sleep off system-wide while the server runs on power. It asks for your password when the server first starts. Sleep comes back when you unplug, stop the server or quit Quail. A closed laptop running a model gets warm: keep it out of a bag."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if appState.config.keepAwake, appState.config.keepAwakeLidClosed, let status = appState.lidGuardStatus {
                Label(status, systemImage: "moon.zzz")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
