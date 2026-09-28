import SwiftUI

/// The Quail window's General page: Quail itself rather than its server — opening at login, the menu bar, the
/// `quail` command and updates. The server's own start-up and power settings are on the Server page (ADR D-061).
struct GeneralPage: View {
    let appState: AppState
    let updateSettings: UpdateSettings?

    /// The outcome of the last Install/Uninstall; `nil` shows the installed state instead.
    @State private var cliMessage: String?
    @State private var cliInstalled = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Open Quail at login",
                    isOn: Binding(
                        get: { appState.config.openAtLogin },
                        set: { appState.setOpenAtLogin($0) }
                    )
                )
                Toggle(
                    "Show activity in the menu bar",
                    isOn: Binding(
                        get: { appState.config.menuBarActivity },
                        set: { appState.setMenuBarActivity($0) }
                    )
                )
                .help(
                    "While the server works: \"Loading…\", \"Reading 41%\", \"52 tok/s\" beside the icon. Activity… in the menu shows more."
                )
            }

            Section {
                LabeledContent("quail command") {
                    HStack {
                        Button(cliInstalled ? "Reinstall" : "Install") {
                            cliMessage = CommandLineTool.install()
                            cliInstalled = CommandLineTool.isInstalled
                        }
                        .disabled(CommandLineTool.bundledURL == nil)
                        Button("Uninstall") {
                            cliMessage = CommandLineTool.uninstall()
                            cliInstalled = CommandLineTool.isInstalled
                        }
                        .disabled(!cliInstalled)
                    }
                }
                Text(cliMessage ?? (cliInstalled
                        ? "Installed at ~/.local/bin/quail."
                        : "Not installed."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Command line")
            } footer: {
                Text("quail start · quail chat · quail launch claude — like ollama.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let updateSettings {
                UpdatesSection(settings: updateSettings)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            cliInstalled = CommandLineTool.isInstalled
        }
    }
}
