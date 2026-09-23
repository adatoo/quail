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
    @State private var copied = false

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

            ScrollView {
                if let integration = selected {
                    detail(for: integration)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                } else {
                    Text("Choose a tool.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
        }
        .frame(minHeight: 520)
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
        return appState.modelStore.installedGGUFFiles().map { $0.deletingPathExtension().lastPathComponent }
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
            model: model.isEmpty ? "your-model-id" : model
        )
    }

    // MARK: - Detail

    private func detail(for integration: Integration) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(integration.name).font(.title2.bold())
                Link("Official setup docs", destination: integration.docsURL).font(.callout)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Model").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    if installedModels.isEmpty {
                        Text("No models installed — add one in Models.").foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: $model) {
                            ForEach(installedModels, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }
                }
                GridRow {
                    Text("Used from").foregroundStyle(.secondary)
                    Picker("Used from", selection: $fromAnotherDevice) {
                        Text("This Mac").tag(false)
                        Text("Another device").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }
                GridRow {
                    Text("Goes in").foregroundStyle(.secondary)
                    Text(integration.where).textSelection(.enabled)
                }
            }

            if fromAnotherDevice {
                networkNote
            }

            if let values {
                let rendered = SnippetRenderer.render(integration.snippet, with: values)
                ScrollView(.horizontal) {
                    Text(rendered)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 10) {
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(rendered, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    Button("Test") { Task { await runTest(integration, values: values) } }
                        .disabled(testing || appState.serverController.phase != .ready || model.isEmpty)
                        .help(appState.serverController.phase == .ready
                            ? "Send one tiny request exactly as this tool would"
                            : "Start the server to test")
                    testStatus
                }
            }

            if let notes = integration.notes, let values {
                Text(SnippetRenderer.render(notes, with: values))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
