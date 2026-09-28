import AppKit
import SwiftUI

/// The Quail window's About page: which Quail this is, what's inside it, and the Mac it runs on — the hardware
/// facts `FitEstimator` reads for every verdict (docs/ARCHITECTURE.md §7), which had a Settings tab of their own
/// until ADR D-061. One Copy Details covers both, for a bug report. (D-029 put About in Settings → General.)
struct AboutPage: View {
    let appState: AppState

    @Environment(\.websiteBase) private var websiteBase
    @State private var device = DeviceInfo.current()
    @State private var showLicences = false
    @State private var copied = false

    var body: some View {
        let facts = AboutFacts.current(catalog: appState.catalog)
        let mac = ThisMacFacts(device: device, catalog: appState.catalog)
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quail").font(.title2.bold())
                        Text("Version \(facts.versionLine)")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button(copied ? "Copied" : "Copy Details") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(facts.summary + "\n" + mac.summary, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                    .help("Copies this page — Quail's versions and this Mac's — to paste into a bug report")
                }
            }

            Section {
                HStack(spacing: 18) {
                    if let websiteBase {
                        Link("Website", destination: websiteBase)
                        Link("Documentation", destination: Website.help(base: websiteBase))
                    }
                    Link("Release Notes", destination: Website.releaseNotes)
                    Link("Report an Issue", destination: Website.newIssue)
                    Link("Source Code", destination: Website.repository)
                    Spacer()
                }
            }

            Section("Quail") {
                LabeledContent("Distribution") { Text(facts.distribution).textSelection(.enabled) }
                LabeledContent("llama.cpp") { Text(facts.llamaCppLine).textSelection(.enabled) }
                LabeledContent("MLX") { Text(facts.mlxLine).textSelection(.enabled) }
                LabeledContent("Model catalog") { Text(facts.catalogLine).textSelection(.enabled) }
                LabeledContent("Third-party licences") {
                    Button("Show…") { showLicences = true }
                }
            }

            Section("This Mac") {
                LabeledContent("Mac", value: mac.marketingName)
                LabeledContent("Chip", value: mac.chip)
                LabeledContent("CPU cores", value: mac.cpuCores)
                LabeledContent("GPU cores", value: mac.gpuCores)
                LabeledContent("Model identifier", value: mac.modelIdentifier)
                LabeledContent("macOS", value: facts.macOS)
            }

            Section("Memory") {
                LabeledContent("Unified memory", value: mac.unifiedMemory)
                LabeledContent("Available to the GPU", value: mac.gpuCeiling)
                LabeledContent("Free right now", value: mac.freeMemory)
                LabeledContent("Memory bandwidth", value: mac.bandwidth)
            }

            Section {
                LabeledContent("Comfortable", value: mac.comfortable)
                LabeledContent("Largest that fits", value: mac.largest)
                LabeledContent("Catalog tier", value: mac.tier)
            } header: {
                Text("Model size")
            } footer: {
                Text(
                    "Estimates for 4-bit (Q4_K_M) models at the default 8K context. Each model's own verdict in Models uses its real size."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // On the form, not on the row's button: a sheet attached to a control inside a grouped Form row
        // doesn't always present.
        .sheet(isPresented: $showLicences) { LicencesSheet() }
        // Free memory in particular changes constantly (DeviceInfo's own doc comment); re-read it every 2 s,
        // only while the page is showing.
        .task {
            while !Task.isCancelled {
                device = DeviceInfo.current()
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }
}

/// This Mac's facts as the About page shows them and Copy Details writes them.
struct ThisMacFacts {
    let device: DeviceInfo
    let catalog: Catalog

    var marketingName: String {
        device.marketingName ?? "Unknown"
    }

    var chip: String {
        device.chipName ?? "—"
    }

    var modelIdentifier: String {
        device.modelIdentifier ?? "—"
    }

    var cpuCores: String {
        switch (device.performanceCoreCount, device.efficiencyCoreCount) {
        case let (.some(p), .some(e)): "\(p + e) (\(p) performance, \(e) efficiency)"
        case let (.some(p), nil): "\(p) performance"
        case let (nil, .some(e)): "\(e) efficiency"
        case (nil, nil): "—"
        }
    }

    var gpuCores: String {
        device.gpuCoreCount.map(String.init) ?? "—"
    }

    var unifiedMemory: String {
        Self.bytes(device.unifiedMemoryBytes)
    }

    var gpuCeiling: String {
        Self.bytes(device.gpuWorkingSetCeilingBytes)
    }

    var freeMemory: String {
        Self.bytes(device.freeMemoryBytes)
    }

    var bandwidth: String {
        guard let chipName = device.chipName,
              let bandwidth = catalog.chipBandwidthGBps[chipName] ?? ChipBandwidthTable.loadFromBundle()[chipName]
        else {
            return "unknown — no speed estimates"
        }
        return "~\(Int(bandwidth)) GB/s"
    }

    /// Just the tier's name. Its upper parameter bound is deliberately not
    /// shown: the top tier's is an open-ended sentinel (999B in
    /// catalog.json), which once displayed as "~35–999B models". The size
    /// lines come from this Mac's measured GPU ceiling instead.
    var tier: String {
        guard let bytes = device.unifiedMemoryBytes,
              let (name, _) = catalog.tier(forMemoryBytes: bytes)
        else {
            return "—"
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    var comfortable: String {
        guard let ceiling = device.gpuWorkingSetCeilingBytes else { return "—" }
        return "up to ~\(FitEstimator.approxMaxParamsB(gpuCeilingBytes: ceiling, comfortable: true))B parameters"
    }

    var largest: String {
        guard let ceiling = device.gpuWorkingSetCeilingBytes else { return "—" }
        return "~\(FitEstimator.approxMaxParamsB(gpuCeilingBytes: ceiling, comfortable: false))B parameters (tight)"
    }

    /// Plain text for a bug report, after `AboutFacts.summary` (which already has macOS).
    var summary: String {
        [
            "Mac: \(marketingName)",
            "Identifier: \(modelIdentifier)",
            "Chip: \(chip)",
            "CPU cores: \(cpuCores)",
            "GPU cores: \(gpuCores)",
            "Unified memory: \(unifiedMemory)",
            "Available to the GPU: \(gpuCeiling)",
            "Free right now: \(freeMemory)",
            "Memory bandwidth: \(bandwidth)",
            "Comfortable (4-bit): \(comfortable)",
            "Largest that fits (4-bit): \(largest)",
            "Catalog tier: \(tier)",
        ].joined(separator: "\n")
    }

    private static func bytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
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
