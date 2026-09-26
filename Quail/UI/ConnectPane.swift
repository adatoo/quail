import AppKit
import SwiftUI

/// Settings → Connect (Phase 2b step 1): copy-ready config for coding
/// tools, editors, chat apps and SDKs, filled in with this endpoint's
/// address, API key and a chosen model — plus a Test that makes the same
/// kind of request the tool will. Copy-only: Quail never edits other apps'
/// config files.
struct ConnectPane: View {
    let appState: AppState

    private static let integrations = Integration.bundled()

    @State private var selectedID: Integration.ID?
    @State private var model = ""
    @State private var fromAnotherDevice = false
    @State private var testOutcome: ConnectionTester.Outcome?
    @State private var testing = false

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(Integration.Category.allCases, id: \.self) { category in
                    let items = Self.integrations.filter { $0.category == category }
                    if !items.isEmpty {
                        Section(category.title) {
                            ForEach(items) { Text($0.name).tag($0.id) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            if let integration = selected {
                detail(for: integration)
            } else {
                Text("Choose a tool.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Fixed, not min: the Settings window sizes to its tab, and a
        // grouped Form's ideal height is all of its content — a long
        // snippet plus notes made the window taller than the screen.
        // The Form scrolls within this.
        .frame(height: 600)
        .onAppear {
            if selectedID == nil {
                selectedID = Self.integrations.first?.id
            }
            if model.isEmpty {
                model = appState.config.defaultModelID ?? installedModels.first ?? ""
            }
        }
        .onChange(of: selectedID) { _, _ in testOutcome = nil }
        .onChange(of: model) { _, _ in testOutcome = nil }
    }

    private var selected: Integration? {
        Self.integrations.first { $0.id == selectedID }
    }

    private var installedModels: [String] {
        _ = appState.storeRevision // re-read when the store changes
        // The store's catalog, not a GGUF scan, so MLX models are offered too.
        return appState.modelStore.loadCatalog().entries
            .filter { appState.canServe($0.format) }
            .map(\.id)
    }

    /// The context `model` will run at (what presets.ini says).
    private func contextSize(of model: String) -> Int? {
        _ = appState.storeRevision // re-read when the store changes
        return appState.modelStore.loadCatalog().entries.first { $0.id == model }?.effectiveContextSize
    }

    // MARK: - Values

    private var localBase: URL? {
        EndpointAddress.localBase(host: appState.config.host, port: appState.config.port)
    }

    private var networkBase: URL? {
        EndpointAddress.networkBase(host: appState.config.host, port: appState.config.port)
    }

    private var values: SnippetRenderer.Values? {
        guard let base = fromAnotherDevice ? networkBase : localBase else { return nil }
        return SnippetRenderer.Values(
            baseURL: base,
            apiKey: appState.config.apiKeyEnabled ? appState.apiKey : nil,
            model: model.isEmpty ? "your-model-id" : model,
            contextSize: model.isEmpty ? nil : contextSize(of: model)
        )
    }

    // MARK: - Detail

    private func detail(for integration: Integration) -> some View {
        Form {
            Section {
                if installedModels.isEmpty {
                    LabeledContent("Model") {
                        Text("No models installed — add one in Models.").foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Model", selection: $model) {
                        ForEach(installedModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                Picker("Used from", selection: $fromAnotherDevice) {
                    Text("This Mac").tag(false)
                    Text("Another device").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            } header: {
                header(for: integration)
            }

            warnings(for: integration)

            if let values {
                let rendered = SnippetRenderer.render(integration.snippet, with: values)
                Section {
                    ScrollView(.horizontal) {
                        Text(rendered)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.vertical, 4)
                    }
                    HStack(spacing: 10) {
                        CopyButton(text: rendered)
                            .keyboardShortcut("c", modifiers: [.command, .shift])
                        Button("Test") { Task { await runTest(integration, values: values) } }
                            .disabled(testing || appState.serverController.phase != .ready || model.isEmpty)
                            .help(appState.serverController.phase == .ready
                                ? "Send one tiny request exactly as this tool would"
                                : "Start the server to test")
                        testStatus
                        Spacer()
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Configuration")
                        Text("Goes in: \(integration.where)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fontWeight(.regular)
                            .textSelection(.enabled)
                    }
                    .textCase(nil)
                } footer: {
                    if appState.serverController.phase != .ready {
                        Text("Start the server to test the connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                #if !APPSTORE
                    if let launch = integration.launch {
                        let command = "quail launch \(launch.aliases?.first ?? integration.id) -m \(model)"
                        Section {
                            LabeledContent {
                                CopyButton(text: command)
                            } label: {
                                Text(command)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        } header: {
                            Text("Or let Quail start it")
                        } footer: {
                            Text(
                                "Runs \(integration.name) pointed at Quail for that session only — your own config is untouched."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                #endif

                if let notes = integration.notes {
                    Section("Notes") {
                        Text(SnippetRenderer.render(notes, with: values))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func header(for integration: Integration) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(integration.name)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Text("\(integration.category.singular) · speaks \(integration.api.title)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Link(destination: integration.docsURL) {
                Label("Setup docs", systemImage: "arrow.up.right.square")
            }
            .font(.callout)
        }
        .textCase(nil)
        .padding(.bottom, 6)
    }

    @ViewBuilder private func warnings(for integration: Integration) -> some View {
        let contextShort: (needed: Int, running: Int)? = {
            guard let needed = integration.minContext, let running = contextSize(of: model), running < needed
            else { return nil }
            return (needed, running)
        }()
        let networkWarning = fromAnotherDevice && (networkBase == nil || !appState.config.apiKeyEnabled)
        if networkWarning || contextShort != nil {
            Section {
                if networkWarning {
                    networkNote
                }
                if let contextShort {
                    Label(
                        "\(integration.name) needs at least \(RemoteFitBadge.contextLabel(contextShort.needed)) of context; \(model) runs at \(RemoteFitBadge.contextLabel(contextShort.running)). Raise it in Models (the “ctx” menu on its row), then restart the server.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var networkNote: some View {
        if networkBase == nil {
            Label(
                EndpointAddress.isWildcard(appState.config.host)
                    ? "Couldn't find this Mac's network address."
                    :
                    "The server only listens on this Mac. Set Host to 0.0.0.0 in Endpoint to reach it from other devices.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        } else if !appState.config.apiKeyEnabled {
            Label(
                "Anyone on your network can use this endpoint — consider turning on the API key in Endpoint.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var testStatus: some View {
        if testing {
            ProgressView().controlSize(.small)
            Text("Testing…").foregroundStyle(.secondary)
        } else if let testOutcome {
            switch testOutcome {
            case let .passed(ms):
                Label("Works (\(ms) ms)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case let .failed(message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private func runTest(_ integration: Integration, values: SnippetRenderer.Values) async {
        testing = true
        testOutcome = nil
        // Test from this Mac even for "Another device": the request goes
        // to the same server either way, and the LAN address only proves
        // reachability from here.
        var local = values
        if let localBase {
            local.baseURL = localBase
        }
        testOutcome = await ConnectionTester.test(api: integration.api, values: local)
        testing = false
    }
}

/// A Copy button that briefly reads "Copied".
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
    }
}

private extension Integration.Category {
    var singular: String {
        switch self {
        case .codingAgent: "Coding agent"
        case .editor: "Editor"
        case .chatApp: "Chat app"
        case .sdk: "Code"
        }
    }
}

private extension Integration.API {
    var title: String {
        switch self {
        case .openAIChat: "OpenAI Chat Completions"
        case .openAIResponses: "OpenAI Responses"
        case .anthropic: "Anthropic Messages"
        }
    }
}
