import SwiftUI

/// The General page's Updates section: how often Quail looks for a new version, whether it
/// installs one without asking, what the updater is doing now, and a button to look now. Shown in
/// the direct build (`UpdateSettings` is `nil` only where no updater runs, as in previews and tests).
struct UpdatesSection: View {
    @Bindable var settings: UpdateSettings

    var body: some View {
        Section {
            Picker("Check for updates", selection: $settings.frequency) {
                ForEach(UpdateFrequency.allCases) { frequency in
                    Text(frequency.label).tag(frequency)
                }
            }
            Toggle(isOn: $settings.installsAutomatically) {
                Text("Download and install updates automatically")
                Text(
                    settings.installsAutomatically
                        ? "New versions download in the background and install the next time Quail quits. Check for Updates still shows you what it finds."
                        : "Quail tells you when there's a new version, and downloads it only if you choose Install."
                )
            }
            .disabled(settings.frequency == .never)
            LabeledContent("Status") {
                UpdateStatusView(settings: settings)
            }
            LabeledContent("Check now") {
                Button("Check for Updates…") { settings.checkNow() }
                    .disabled(!settings.canCheckNow)
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

/// One line on where the updater is: the last check, a check or download under way, or an
/// update waiting to install, with the button that installs it now.
private struct UpdateStatusView: View {
    let settings: UpdateSettings

    var body: some View {
        switch settings.status {
        case .idle:
            Text(lastChecked).foregroundStyle(.secondary)
        case .checking:
            busy("Checking…")
        case .upToDate:
            Text("Quail \(AppInfo.version) is up to date · \(lastChecked)").foregroundStyle(.secondary)
        case let .available(version):
            Text("Quail \(version) is available").foregroundStyle(.secondary)
        case let .downloading(version):
            busy("Downloading Quail \(version)…")
        case let .readyToInstall(version):
            HStack {
                Text("Quail \(version) is downloaded and installs when Quail quits.")
                if let installNow = settings.installNow {
                    Button("Restart Now", action: installNow)
                }
            }
        case let .failed(message):
            Text("Couldn't check for updates: \(message)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var lastChecked: String {
        let when = settings.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never"
        return "Last checked \(when)"
    }

    private func busy(_ label: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(label).foregroundStyle(.secondary)
        }
    }
}
