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
            Text("Stops idle sleep, as caffeinate does, so long jobs aren't cut off. The display can still turn off.")
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
            HStack(alignment: .firstTextBaseline) {
                Text("Turns sleep off for the whole Mac while it's plugged in; asks for your password once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                LearnMoreLink(.power, section: "lid")
            }
            .help(
                "macOS sleeps a laptop when its lid closes, whatever an app asks. Sleep comes back when you unplug, stop the server or quit Quail. A closed laptop running a model gets warm: keep it out of a bag."
            )
            if appState.config.keepAwake, appState.config.keepAwakeLidClosed, let status = appState.lidGuardStatus {
                Label(status, systemImage: "moon.zzz")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
