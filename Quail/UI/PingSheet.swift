import SwiftUI

/// Three rows with timings — server up, model loaded, first token — and
/// nothing else. No chat; see `PingRunner`'s doc comment for what each row
/// actually checks. Opened as its own `Window` scene (see `QuailApp.swift`)
/// rather than a `.sheet` presented from the `MenuBarExtra` content: a
/// `.sheet` there gets dismissed along with the transient menu bar window
/// as soon as its own button is tapped, before the sheet can appear.
struct PingSheet: View {
    let appState: AppState

    @State private var runner: PingRunner?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ping").font(.title2).bold()

            if !isServerReady {
                Text("Start the server first.")
                    .foregroundStyle(.secondary)
            } else if let runner {
                row("Server up", runner.serverUp)
                row("Model loaded", runner.modelLoaded)
                row("First token", runner.firstToken)
            }

            HStack {
                Spacer()
                Button("Run Again") {
                    Task { await run() }
                }
                .disabled(!isServerReady)
            }
        }
        .padding(20)
        .frame(width: 360)
        .task { await run() }
    }

    private var isServerReady: Bool {
        appState.serverController.phase == .ready
    }

    private func run() async {
        guard isServerReady, let base = appState.baseURL else { return }
        let runner = runner ?? PingRunner(runtime: appState.runtime, base: base, apiKey: appState.apiKey)
        self.runner = runner
        await runner.run()
    }

    private func row(_ title: String, _ state: PingStepState) -> some View {
        HStack {
            icon(for: state)
            Text(title)
            Spacer()
            Text(label(for: state))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func icon(for state: PingStepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .running:
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func label(for state: PingStepState) -> String {
        switch state {
        case .pending: "—"
        case .running: "…"
        case let .succeeded(interval): String(format: "%.0f ms", interval * 1000)
        case let .failed(message): message
        }
    }
}
