import AppKit
import SwiftUI

/// The Quail window's Server page (ADR D-061): whether the server is running and what to do about it, the
/// addresses and key a client uses, who can reach it, which runtime runs it, and how it starts and keeps the Mac
/// awake — everything that was spread over Settings' General and Endpoint tabs, with no Start or Stop anywhere.
///
/// Written over one server's state and settings, so Phase 5's multiple endpoints can list several of these.
struct ServerPane: View {
    let appState: AppState

    @Environment(\.openWindow) private var openWindow

    /// The key as typed while it's shown, decoupled from `appState.apiKey`: a two-way binding would fight the
    /// user mid-edit (a replacement key passes through an empty string, which `AppState.setAPIKey` ignores
    /// rather than clearing the key). Saved on Return.
    @State private var apiKeyText = ""
    @State private var showKey = false
    @State private var confirmRegenerate = false
    /// Custom chosen, before an address has been typed and saved (until then the host is unchanged).
    @State private var customReach = false
    @State private var hostDraft = ""

    private var phase: ServerController.Phase {
        appState.serverController.phase
    }

    var body: some View {
        Form {
            statusSection
            addressSection
            networkSection
            engineSection
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
        .onAppear {
            apiKeyText = appState.apiKey ?? ""
            hostDraft = appState.config.host
            customReach = EndpointAddress.reach(of: appState.config.host) == .custom
        }
        .onChange(of: appState.apiKey) { _, newValue in
            apiKeyText = newValue ?? ""
        }
        .alert("Make a new API key?", isPresented: $confirmRegenerate) {
            Button("New Key") { appState.regenerateAPIKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Tools set up with the current key stop working until you give them the new one. A running server keeps the old key until it restarts."
            )
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        // `hasServableModel` reads the disk, which Observation can't see: reading these stored properties makes a
        // finished download or a change in Finder re-render the page (as in `MenuView`).
        let _ = appState.installs.phase
        let _ = appState.storeRevision
        return Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(appState.statusColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.statusLabel)
                        .font(.headline)
                    Text(appState.hasServableModel ? appState.modelStatusLine : "No model installed")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                statusButtons
            }
            .padding(.vertical, 4)

            if case let .failed(reason) = phase {
                HStack(alignment: .firstTextBaseline) {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Show Logs") {
                        bringToFront(id: "logs") { openWindow(id: "logs") }
                    }
                }
            }

            if let reason = appState.restartReason {
                HStack {
                    Label(reason, systemImage: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button("Restart") {
                        Task { await appState.restart() }
                    }
                }
            }
        }
    }

    @ViewBuilder private var statusButtons: some View {
        if !appState.hasServableModel {
            Button("Add Model…") {
                appState.addModelRequested = true
                appState.mainPage = .models
            }
            .buttonStyle(.borderedProminent)
        } else if appState.canStart {
            Button("Start") { ServerActions.start(appState) }
                .buttonStyle(.borderedProminent)
        } else {
            if phase == .ready {
                Button("Test…") {
                    bringToFront(id: "ping") { openWindow(id: "ping") }
                }
                .help("Checks the server is up, a model loads and it answers")
            }
            Button("Stop") {
                Task { await appState.stop() }
            }
            .disabled(!appState.canStop)
        }
    }

    // MARK: - Address and key

    private var addressSection: some View {
        Section {
            if let local = appState.localBaseURL?.absoluteString {
                LabeledContent("On this Mac") {
                    address(local)
                }
            }
            if EndpointAddress.reach(of: appState.config.host) != .thisMac || appState.networkBaseURL != nil {
                LabeledContent("From other devices") {
                    if let network = appState.networkBaseURL?.absoluteString {
                        address(network)
                    } else {
                        Text("No network address found")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Toggle(
                "Require API key",
                isOn: Binding(
                    get: { appState.config.apiKeyEnabled },
                    set: { appState.setAPIKeyEnabled($0) }
                )
            )
            if appState.config.apiKeyEnabled {
                LabeledContent("API key") {
                    HStack(spacing: 8) {
                        if showKey {
                            TextField("API key", text: $apiKeyText)
                                .labelsHidden()
                                .font(.system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 240)
                                .onSubmit {
                                    appState.setAPIKey(apiKeyText)
                                    // Normalised, or back to the stored key if the edit was rejected (blank).
                                    apiKeyText = appState.apiKey ?? ""
                                }
                                .help("Type your own and press Return to save it")
                        } else {
                            Text(String(repeating: "•", count: min(appState.apiKey?.count ?? 0, 16)))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                        CopyButton(text: appState.apiKey ?? "")
                        Button("New Key…") { confirmRegenerate = true }
                    }
                }
            }
        } header: {
            Text("Address")
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    appState.config.apiKeyEnabled
                        ? "Clients send the key as a Bearer token or x-api-key. Connect fills in both for you."
                        : "Without a key, any web page you open can use your models."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                LearnMoreLink(.network, section: "key")
            }
        }
    }

    private func address(_ url: String) -> some View {
        HStack(spacing: 8) {
            Text(url)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            CopyButton(text: url)
        }
    }

    // MARK: - Network

    private var reach: EndpointAddress.Reach {
        customReach ? .custom : EndpointAddress.reach(of: appState.config.host)
    }

    private var networkSection: some View {
        Section {
            Picker(
                "Reachable from",
                selection: Binding(
                    get: { reach },
                    set: { choice in
                        if let host = choice.host {
                            customReach = false
                            appState.setHost(host)
                            hostDraft = host
                        } else {
                            customReach = true
                            // Start from a real address: the one typed before, or this Mac's on the network.
                            if EndpointAddress.reach(of: appState.config.host) != .custom {
                                hostDraft = EndpointAddress.currentLANAddress() ?? ""
                            }
                        }
                    }
                )
            ) {
                ForEach(EndpointAddress.Reach.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if reach == .custom {
                LabeledContent("Listen address") {
                    HStack(spacing: 8) {
                        TextField("Listen address", text: $hostDraft, prompt: Text("e.g. 192.168.1.20"))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            // On Return only: saving every keystroke flipped the warnings below as you typed.
                            .onSubmit(saveCustomHost)
                        Button("Save", action: saveCustomHost)
                            .disabled(hostDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                || hostDraft.trimmingCharacters(in: .whitespaces) == appState.config.host)
                    }
                }
            }

            exposureNote

            TextField(
                "Port",
                value: Binding(
                    get: { appState.config.port },
                    set: { appState.setPort($0) }
                ),
                format: .number.grouping(.never)
            )
        } header: {
            Text("Network")
        } footer: {
            HStack {
                Spacer()
                LearnMoreLink(.network, section: "reach")
            }
        }
    }

    private func saveCustomHost() {
        let host = hostDraft.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        appState.setHost(host)
        // A custom address that turns out to be loopback or every interface is shown as that choice instead.
        customReach = EndpointAddress.reach(of: host) == .custom
    }

    @ViewBuilder private var exposureNote: some View {
        switch appState.networkExposure {
        case .keyed:
            Label(
                "Other devices on your network can reach the server. They need the API key to use it.",
                systemImage: "network"
            )
            .font(.callout)
            .foregroundStyle(.orange)
        case .open:
            HStack(alignment: .firstTextBaseline) {
                Label(
                    "Anyone on your network can use this server and your models: the API key is off.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.red)
                Spacer(minLength: 8)
                Button("Require API Key") { appState.setAPIKeyEnabled(true) }
                    .controlSize(.small)
            }
        case nil:
            EmptyView()
        }
    }

    // MARK: - Engine

    private var engineSection: some View {
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
            .help(
                "Which server Quail starts. Quail server is the default; llama.cpp stays available as a fallback and runs GGUF models only."
            )
            if !appState.canChangeRuntime {
                // Stop is at the top of the page.
                Text("Stop the server to change the runtime.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let note = appState.mlxUnavailableNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Stepper(value: Binding(
                get: { appState.config.modelsMax },
                set: { appState.setModelsMax($0) }
            ), in: 1 ... 8) {
                LabeledContent("Models loaded at once", value: "\(appState.config.modelsMax)")
            }
        } header: {
            Text("Engine")
        } footer: {
            Text("Each loaded model keeps its weights in memory. Changes on this page apply when the server restarts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
