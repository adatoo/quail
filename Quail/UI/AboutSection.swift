import AppKit
import SwiftUI

/// Settings → General → About: which Quail this is and what's inside it.
/// Everything lives here rather than in an About window or menu item — Quail
/// is a menu-bar agent with no app menu to hold one (ADR D-029). Rows that
/// don't exist yet (the `quail-server` version, runtime pins) join this list
/// when they do.
struct AboutSection: View {
    let appState: AppState

    @State private var showLicences = false
    @State private var copied = false

    var body: some View {
        let facts = AboutFacts.current(catalog: appState.catalog)
        Section {
            LabeledContent("Version") { Text(facts.versionLine).textSelection(.enabled) }
            LabeledContent("Distribution") { Text(facts.distribution).textSelection(.enabled) }
            LabeledContent("llama.cpp") { Text(facts.llamaCppLine).textSelection(.enabled) }
            LabeledContent("Model catalog") { Text(facts.catalogLine).textSelection(.enabled) }
            LabeledContent("macOS") { Text(facts.macOS).textSelection(.enabled) }
            LabeledContent("Bug reports") {
                Button(copied ? "Copied" : "Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(facts.summary, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
            }
            LabeledContent("Open-source licences") {
                Button("Show…") { showLicences = true }
                    .sheet(isPresented: $showLicences) { LicencesSheet() }
            }
        } header: {
            Text("About")
        }
    }
}

/// The licence texts that must ship with the app: llama.cpp's (MIT, bundled
/// by `task embed:llama`) and a line for Quail's own.
struct LicencesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Licences").font(.title3.bold())
            Text("Quail © 2026 Arif Datoo, released under the MIT Licence. It runs llama.cpp:")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(AppInfo.llamaCppLicence() ?? "The llama.cpp licence file isn't part of this build.")
                    // The licence file is hard-wrapped at ~72 columns; at a larger size
                    // every line would wrap a second time and read raggedly.
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 260)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
