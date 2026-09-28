import AppKit
import SwiftUI

/// The Quail window's Server page: which server Quail runs, where it listens, who may use it, and how it starts
/// and keeps the Mac awake — everything that was spread over Settings' General and Endpoint tabs (ADR D-061).
struct ServerPane: View {
    let appState: AppState

    /// A local editing buffer, decoupled from `appState.apiKey` — a
    /// direct two-way binding would fight the user mid-edit (typing a
    /// replacement key means passing through an empty string, which
    /// `AppState.setAPIKey` deliberately treats as a no-op rather than
    /// clearing the key; see its doc comment). Synced from `appState`
    /// on appear and whenever `appState.apiKey` changes elsewhere (e.g.
    /// "Regenerate"); synced back to `appState` on submit.
    @State private var apiKeyText = ""

    private var baseURL: String {
        "http://\(appState.config.host):\(appState.config.port)"
    }

    var body: some View {
        Form {
            Section {
                Picker(
                    "Runtime",
                    selection: Binding(get: { appState.runtime.id }, set: { appState.setRuntime($0) })
                ) {
                    ForEach(RuntimeID.available, id: \.self) { id in
                        Text(id == .quail ? "Quail server (GGUF and MLX)" : "\(id.displayName) (GGUF only)").tag(id)
                    }
                }
                .disabled(!appState.canChangeRuntime || RuntimeID.available.count < 2)
                .help(appState.canChangeRuntime
                    ? "Which server Quail starts. Quail server is the default; llama.cpp stays available as a fallback and runs GGUF models only."
                    : "Stop the server to change the runtime.")
                if let note = appState.mlxUnavailableNote {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                TextField(
                    "Host",
                    text: Binding(
                        get: { appState.config.host },
                        set: { appState.setHost($0) }
                    )
                )
                .help("127.0.0.1 keeps the server to this Mac; 0.0.0.0 lets other devices on your network reach it.")
                switch appState.networkExposure {
                case .keyed:
                    Label(
                        "Other devices on your network can reach this server. They need the API key to use it.",
                        systemImage: "network"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                case .open:
                    HStack(alignment: .firstTextBaseline) {
                        Label(
                            "Anyone on your network can use this server and your models: the API key is off.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                        Spacer(minLength: 8)
                        Button("Require API Key") { appState.setAPIKeyEnabled(true) }
                            .controlSize(.small)
                    }
                case nil:
                    EmptyView()
                }

                TextField(
                    "Port",
                    value: Binding(
                        get: { appState.config.port },
                        set: { appState.setPort($0) }
                    ),
                    format: .number.grouping(.never)
                )

                LabeledContent("Base URL") {
                    HStack(spacing: 8) {
                        Text(baseURL)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy") { copyToPasteboard(baseURL) }
                    }
                }
            } header: {
                Text("Server")
            }

            Section {
                Stepper(value: Binding(
                    get: { appState.config.modelsMax },
                    set: { appState.setModelsMax($0) }
                ), in: 1 ... 8) {
                    LabeledContent("Models loaded at once", value: "\(appState.config.modelsMax)")
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("Applies next time the server starts. Each loaded model keeps its weights in RAM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Require API key",
                    isOn: Binding(
                        get: { appState.config.apiKeyEnabled },
                        set: { appState.setAPIKeyEnabled($0) }
                    )
                )

                // Always present (disabled when off) so the tab keeps its
                // size as the toggle flips — the window sizes to its content.
                LabeledContent("API key") {
                    HStack(spacing: 8) {
                        TextField("API key", text: $apiKeyText, prompt: Text("Off"))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1)
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
                    .disabled(!appState.config.apiKeyEnabled)
                }
                .onAppear { apiKeyText = appState.apiKey ?? "" }
                .onChange(of: appState.apiKey) { _, newValue in
                    apiKeyText = newValue ?? ""
                }
            } header: {
                Text("Access")
            } footer: {
                Text(
                    "Clients send it as a Bearer token (or x-api-key); Connect fills it in for you. Press Return to save an edited key. Leave it on: without one, any web page you open can use your models."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle(
                    "Start the server when Quail opens",
                    isOn: Binding(
                        get: { appState.config.autoStartServer },
                        set: { appState.setAutoStartServer($0) }
                    )
                )
            }

            PowerSection(appState: appState)
        }
        .formStyle(.grouped)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
