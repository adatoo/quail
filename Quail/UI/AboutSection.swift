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
            LabeledContent("Third-party licences") {
                Button("Show…") { showLicences = true }
            }
        } header: {
            Text("About")
        }
        // On the section, not on the row's button: a sheet attached to a control inside a grouped Form row
        // doesn't always present from a Settings scene.
        .sheet(isPresented: $showLicences) { LicencesSheet() }
    }
}

/// The licence texts that must ship with the app: Quail's own line, then the generated notices file
/// (`task notices`, ADR D-044) with every bundled library's licence, laid out natively (the component table
/// as a grid, each licence as preformatted text); llama.cpp's own file is the fallback for a build without
/// it. The file is about 80 KB, so it is read and laid out off the main thread, lazily, with a spinner
/// meanwhile: as one `Text` it took seconds to appear.
struct LicencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var blocks: [NoticesDocument.Block]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Third-party licences").font(.title3.bold())
            Text(
                "Quail © 2026 Arif Datoo, released under the MIT Licence. It includes the open-source software listed here:"
            )
            .foregroundStyle(.secondary)
            Group {
                if let blocks {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                                NoticesBlockView(block: block)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading the licences…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 440)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Text("Also in the app at Contents/Resources/THIRD_PARTY_NOTICES.md")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720)
        .task {
            blocks = await Task.detached(priority: .userInitiated) {
                if let notices = AppInfo.thirdPartyNotices() {
                    return NoticesDocument.parse(notices)
                }
                return [.preformatted(AppInfo.llamaCppLicence() ?? "The licence files aren't part of this build.")]
            }.value
        }
    }
}

struct NoticesBlockView: View {
    let block: NoticesDocument.Block

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(level <= 1 ? .title3.bold() : .headline)
                .padding(.top, level <= 1 ? 0 : 8)
        case let .paragraph(text):
            // Inline Markdown only (links, code, emphasis); URLs on their own become links too.
            Text(Self.inline(text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case let .table(header, rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(cell).font(.caption.bold())
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(header.indices), id: \.self) { column in
                            Text(column < row.count ? row[column] : "")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .textSelection(.enabled)
        case let .preformatted(text):
            // The licence files are hard-wrapped at ~72 columns; at a larger size every line would wrap a second
            // time and read raggedly.
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    nonisolated static func inline(_ text: String) -> AttributedString {
        let linked = text.replacingOccurrences(
            of: #"(?<![(<])\b(https?://[^\s)>]+)"#, with: "<$1>", options: .regularExpression
        )
        return (try? AttributedString(
            markdown: linked,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
