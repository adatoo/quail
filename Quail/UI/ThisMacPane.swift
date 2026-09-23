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
            LabeledContent("Mac", value: device.marketingName ?? "Unknown")
            LabeledContent("Identifier", value: device.modelIdentifier ?? "—")
            LabeledContent("Chip", value: device.chipName ?? "—")
            LabeledContent("CPU cores", value: coreCountLine)
            LabeledContent("GPU cores", value: device.gpuCoreCount.map(String.init) ?? "—")

            Divider()

            LabeledContent("Unified memory", value: byteCount(device.unifiedMemoryBytes))
            LabeledContent("GPU working-set ceiling", value: byteCount(device.gpuWorkingSetCeilingBytes))
            LabeledContent("Free right now", value: byteCount(device.freeMemoryBytes))
            LabeledContent("Memory bandwidth", value: bandwidthLine)
            LabeledContent("RAM tier", value: tierLine)

            Divider()

            LabeledContent("macOS", value: device.osVersion ?? "—")

            HStack {
                Spacer()
                Button("Copy Details") { copyDetails() }
            }
        }
        .padding()
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

    private var tierLine: String {
        guard let bytes = device.unifiedMemoryBytes,
              let (name, tier) = appState.catalog.tier(forMemoryBytes: bytes)
        else {
            return "—"
        }
        let label = name.prefix(1).uppercased() + name.dropFirst()
        guard let range = tier.recommendedRange else { return label }
        return "\(label) · comfortable with ~\(formatParams(range.lowerBound))–\(formatParams(range.upperBound))B models"
    }

    private func formatParams(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.1f", value)
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
            "GPU working-set ceiling: \(byteCount(device.gpuWorkingSetCeilingBytes))",
            "Free right now: \(byteCount(device.freeMemoryBytes))",
            "Memory bandwidth: \(bandwidthLine)",
            "RAM tier: \(tierLine)",
            "macOS: \(device.osVersion ?? "—")",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
