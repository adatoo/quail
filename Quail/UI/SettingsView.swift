import SwiftUI

/// Root of the Settings window: `General` (open at login) and `Endpoint`
/// (runtime, host, port, API key) for now. `Models`, `Runtimes`, `Logs` and
/// `About` land in later PRs per docs/IMPLEMENTATION_PLAN.md.
struct SettingsView: View {
    let appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView(appState: appState)
                .tabItem { Label("General", systemImage: "gearshape") }

            EndpointSettingsView(appState: appState)
                .tabItem { Label("Endpoint", systemImage: "network") }
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettingsView: View {
    let appState: AppState

    var body: some View {
        Form {
            Toggle(
                "Open Quail at login",
                isOn: Binding(
                    get: { appState.config.openAtLogin },
                    set: { appState.setOpenAtLogin($0) }
                )
            )
        }
        .padding()
    }
}

private struct EndpointSettingsView: View {
    let appState: AppState

    /// A local editing buffer, decoupled from `appState.apiKey` — a
    /// direct two-way binding would fight the user mid-edit (typing a
    /// replacement key means passing through an empty string, which
    /// `AppState.setAPIKey` deliberately treats as a no-op rather than
    /// clearing the key; see its doc comment). Synced from `appState`
    /// on appear and whenever `appState.apiKey` changes elsewhere (e.g.
    /// "Regenerate"); synced back to `appState` on submit.
    @State private var apiKeyText = ""

    var body: some View {
        Form {
            Picker("Runtime", selection: .constant(RuntimeID.llamaCpp)) {
                Text("llama.cpp").tag(RuntimeID.llamaCpp)
            }
            .disabled(true) // oMLX and Rapid-MLX arrive in Phase 3

            TextField(
                "Host",
                text: Binding(
                    get: { appState.config.host },
                    set: { appState.setHost($0) }
                )
            )

            TextField(
                "Port",
                value: Binding(
                    get: { appState.config.port },
                    set: { appState.setPort($0) }
                ),
                format: .number.grouping(.never)
            )

            Toggle(
                "Require API key",
                isOn: Binding(
                    get: { appState.config.apiKeyEnabled },
                    set: { appState.setAPIKeyEnabled($0) }
                )
            )

            if appState.config.apiKeyEnabled {
                HStack {
                    TextField("API Key", text: $apiKeyText)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            appState.setAPIKey(apiKeyText)
                            apiKeyText = appState
                                .apiKey ?? "" // normalize, or snap back if the edit was rejected (e.g. blank)
                        }

                    Button("Copy") {
                        copyToPasteboard(appState.apiKey ?? "")
                    }

                    Button("Regenerate") {
                        appState.regenerateAPIKey()
                    }
                }
                .onAppear { apiKeyText = appState.apiKey ?? "" }
                .onChange(of: appState.apiKey) { _, newValue in
                    apiKeyText = newValue ?? ""
                }
            }

            Button("Copy Base URL") {
                copyToPasteboard("http://\(appState.config.host):\(appState.config.port)")
            }
        }
        .padding()
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
