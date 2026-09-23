import AppKit
import SwiftUI

/// The "This Mac" Settings tab: the same hardware facts `FitEstimator`
/// already reads for every verdict (docs/ARCHITECTURE.md §7's "What
/// Quail reads from the device" table), made visible for the first time
/// — until this pane, nothing displayed them anywhere.
struct ThisMacPane: View {
    let appState: AppState

    @State private var device = DeviceInfo.current()

    var body: some View {
        Form {
            Section("Hardware") {
                LabeledContent("Mac", value: device.marketingName ?? "Unknown")
                LabeledContent("Chip", value: device.chipName ?? "—")
                LabeledContent("CPU cores", value: coreCountLine)
                LabeledContent("GPU cores", value: device.gpuCoreCount.map(String.init) ?? "—")
                LabeledContent("Model identifier", value: device.modelIdentifier ?? "—")
            }

            Section {
                LabeledContent("Unified memory", value: byteCount(device.unifiedMemoryBytes))
                LabeledContent("Available to the GPU", value: byteCount(device.gpuWorkingSetCeilingBytes))
                LabeledContent("Free right now", value: byteCount(device.freeMemoryBytes))
                LabeledContent("Memory bandwidth", value: bandwidthLine)
            } header: {
                Text("Memory")
            }

            Section {
                LabeledContent("Comfortable", value: comfortableLine)
                LabeledContent("Largest that fits", value: largestLine)
                LabeledContent("Catalog tier", value: tierName)
            } header: {
                Text("Model size")
            } footer: {
                Text(
                    "Estimates for 4-bit (Q4_K_M) models at the default 8K context. Each model's own verdict in Models uses its real size."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Software") {
                LabeledContent("macOS", value: device.osVersion ?? "—")
            }

            HStack {
                Spacer()
                Button("Copy Details") { copyDetails() }
            }
        }
        .formStyle(.grouped)
        // A grouped Form scrolls, so its ideal height is tiny; the Settings
        // window sizes to it (`fixedSize` in SettingsView). Tall enough to
        // show every section without scrolling.
        .frame(minHeight: 660)
        // Free memory in particular changes constantly (DeviceInfo's own
        // doc comment) — re-read on the same 2 s cadence the Models pane
        // polls loaded-state at, only while this tab is actually visible.
        .task {
            while !Task.isCancelled {
                device = DeviceInfo.current()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var coreCountLine: String {
        switch (device.performanceCoreCount, device.efficiencyCoreCount) {
        case let (.some(p), .some(e)): "\(p + e) (\(p) performance, \(e) efficiency)"
        case let (.some(p), nil): "\(p) performance"
        case let (nil, .some(e)): "\(e) efficiency"
        case (nil, nil): "—"
        }
    }

    private var bandwidthLine: String {
        guard let chipName = device.chipName,
              let bandwidth = appState.catalog.chipBandwidthGBps[chipName] ?? ChipBandwidthTable
              .loadFromBundle()[chipName]
        else {
            return "unknown — no speed estimates"
        }
        return "~\(Int(bandwidth)) GB/s"
    }

    /// Just the tier's name. Its upper parameter bound is deliberately not
    /// shown: the top tier's is an open-ended sentinel (999B in
    /// catalog.json), which once displayed as "~35–999B models". The size
    /// lines above come from this Mac's measured GPU ceiling instead.
    private var tierName: String {
        guard let bytes = device.unifiedMemoryBytes,
              let (name, _) = appState.catalog.tier(forMemoryBytes: bytes)
        else {
            return "—"
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private var comfortableLine: String {
        guard let ceiling = device.gpuWorkingSetCeilingBytes else { return "—" }
        return "up to ~\(FitEstimator.approxMaxParamsB(gpuCeilingBytes: ceiling, comfortable: true))B parameters"
    }

    private var largestLine: String {
        guard let ceiling = device.gpuWorkingSetCeilingBytes else { return "—" }
        return "~\(FitEstimator.approxMaxParamsB(gpuCeilingBytes: ceiling, comfortable: false))B parameters (tight)"
    }

    private func byteCount(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private func copyDetails() {
        let lines = [
            "Mac: \(device.marketingName ?? "Unknown")",
            "Identifier: \(device.modelIdentifier ?? "—")",
            "Chip: \(device.chipName ?? "—")",
            "CPU cores: \(coreCountLine)",
            "GPU cores: \(device.gpuCoreCount.map(String.init) ?? "—")",
            "Unified memory: \(byteCount(device.unifiedMemoryBytes))",
            "Available to the GPU: \(byteCount(device.gpuWorkingSetCeilingBytes))",
            "Free right now: \(byteCount(device.freeMemoryBytes))",
            "Memory bandwidth: \(bandwidthLine)",
            "Comfortable (4-bit): \(comfortableLine)",
            "Largest that fits (4-bit): \(largestLine)",
            "Catalog tier: \(tierName)",
            "macOS: \(device.osVersion ?? "—")",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
