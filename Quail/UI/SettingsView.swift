import SwiftUI

/// Which tab of `SettingsView` is showing — see `AppState.settingsTab`'s
/// doc comment for why this is steerable from outside the view.
enum SettingsTab: Hashable {
    case general
    case endpoint
    case models
    case benchmark
    case connect
    case thisMac
}

/// Root of the Settings window: `General` (open at login), `Endpoint`
/// (runtime, host, port, API key), `Models` (store, catalog, downloads),
/// `Benchmark` (fixed suite, saved results) and `This Mac` (device-fit facts). `Runtimes`, `Logs` and `About` land
/// in later phases per docs/IMPLEMENTATION_PLAN.md.
struct SettingsView: View {
    let appState: AppState

    var body: some View {
        TabView(selection: Binding(
            get: { appState.settingsTab },
            set: { appState.settingsTab = $0 }
        )) {
            GeneralSettingsView(appState: appState)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            EndpointSettingsView(appState: appState)
                .tabItem { Label("Endpoint", systemImage: "network") }
                .tag(SettingsTab.endpoint)

            ModelsPane(appState: appState)
                .tabItem { Label("Models", systemImage: "shippingbox") }
                .tag(SettingsTab.models)

            BenchmarkPane(appState: appState)
                .tabItem { Label("Benchmark", systemImage: "gauge.with.dots.needle.67percent") }
                .tag(SettingsTab.benchmark)

            ConnectPane(appState: appState)
                .tabItem { Label("Connect", systemImage: "cable.connector") }
                .tag(SettingsTab.connect)

            ThisMacPane(appState: appState)
                .tabItem { Label("This Mac", systemImage: "memorychip") }
                .tag(SettingsTab.thisMac)
        }
        // 900 (was 680, 560 before): Benchmark's seven-column results table
        // needs it, and every tab shares one width so the window doesn't
        // resize as you switch. Also room for the 820-wide Add Model sheet,
        // which used to overhang. Content wider than the frame is drawn
        // centered and clipped both edges, which no amount of internal
        // wrapping fixes once a row's minimum genuinely exceeds it.
        .frame(width: 900)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettingsView: View {
    let appState: AppState

    /// The outcome of the last Install/Uninstall; `nil` shows the
    /// installed state instead. Either way it's one caption line with
    /// room reserved for three, so the window — which sizes to this tab
    /// (`fixedSize` in `SettingsView`) — doesn't jump as it changes
    /// (user-reported).
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
                    "Start the server when Quail opens",
                    isOn: Binding(
                        get: { appState.config.autoStartServer },
                        set: { appState.setAutoStartServer($0) }
                    )
                )
            }

            #if !APPSTORE
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
                        .lineLimit(3, reservesSpace: true)
                } header: {
                    Text("Command line")
                } footer: {
                    Text("quail start · quail run <model> · quail launch claude — like ollama.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            #endif
        }
        .formStyle(.grouped)
        .onAppear {
            #if !APPSTORE
                cliInstalled = CommandLineTool.isInstalled
            #endif
        }
    }
}

#if !APPSTORE
    /// "Install quail Command": a symlink from `~/.local/bin/quail` to the
    /// CLI inside this app (`Contents/Helpers/quail`) — no admin password,
    /// unlike /usr/local/bin. The symlink follows the app, so updating
    /// Quail updates the command.
    enum CommandLineTool {
        static var linkURL: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/quail")
        }

        static var bundledURL: URL? {
            let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/quail")
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        static var isInstalled: Bool {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)) != nil
        }

        static func install() -> String {
            guard let target = bundledURL else { return "This build of Quail doesn't include the quail command." }
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? fm.destinationOfSymbolicLink(atPath: linkURL.path)) != nil || fm
                    .fileExists(atPath: linkURL.path)
                {
                    try fm.removeItem(at: linkURL)
                }
                try fm.createSymbolicLink(at: linkURL, withDestinationURL: target)
            } catch {
                return "Couldn't install: \(error.localizedDescription)"
            }
            return "Installed at ~/.local/bin/quail. If your shell can't find it, add ~/.local/bin to your PATH."
        }

        static func uninstall() -> String {
            do {
                try FileManager.default.removeItem(at: linkURL)
                return "Removed ~/.local/bin/quail."
            } catch {
                return "Couldn't remove it: \(error.localizedDescription)"
            }
        }
    }
#endif

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

    private var baseURL: String {
        "http://\(appState.config.host):\(appState.config.port)"
    }

    var body: some View {
        Form {
            Section {
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
                    LabeledContent("Max loaded models", value: "\(appState.config.modelsMax)")
                }
            } header: {
                Text("Models")
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
                Text("Clients send it as a Bearer token (or x-api-key). Press Return to save an edited key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
