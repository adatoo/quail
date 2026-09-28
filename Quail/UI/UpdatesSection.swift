import SwiftUI

/// The General page's Updates section: how often Quail looks for a new version, whether it
/// installs one without asking, and a button to look now. Shown in the direct build
/// (`UpdateSettings` is `nil` only where no updater runs, as in previews and tests).
struct UpdatesSection: View {
    @Bindable var settings: UpdateSettings

    var body: some View {
        Section {
            Picker("Check for updates", selection: $settings.frequency) {
                ForEach(UpdateFrequency.allCases) { frequency in
                    Text(frequency.label).tag(frequency)
                }
            }
            Toggle("Download and install updates automatically", isOn: $settings.installsAutomatically)
                .disabled(settings.frequency == .never)
            LabeledContent("Last checked") {
                Text(settings.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Check now") {
                Button("Check for Updates…") { settings.checkNow() }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Installing restarts Quail, stopping the server cleanly first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
