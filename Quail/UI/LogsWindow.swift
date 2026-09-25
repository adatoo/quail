import AppKit
import SwiftUI

/// Live tail of `LogStore`'s ring buffer (docs/IMPLEMENTATION_PLAN.md Phase
/// 1 step 9), plus a level filter, "Reveal in Finder" and "Copy Last 200
/// Lines". `LogStore` is an actor with no publisher of its own (AGENTS.md:
/// "No Combine") — `.task` here just polls `recentLines` twice a second,
/// which is simple and plenty fast for a human reading logs; it stops for
/// free when the window closes, since SwiftUI cancels `.task` on disappear.
struct LogsWindow: View {
    let appState: AppState

    @State private var lines: [LogStore.Line] = []
    @State private var levelFilter: Character?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Level", selection: $levelFilter) {
                    Text("All").tag(Character?.none)
                    Text("Info").tag(Character?("I"))
                    Text("Warn").tag(Character?("W"))
                    Text("Error").tag(Character?("E"))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)

                Spacer()

                Button("Reveal in Finder") { revealInFinder() }
                Button("Copy Last 200 Lines") { copyLastLines() }
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(filteredLines.enumerated()), id: \.offset) { _, line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .task { await tail() }
    }

    private var filteredLines: [LogStore.Line] {
        guard let levelFilter else { return lines }
        return lines.filter { $0.level == levelFilter }
    }

    private func tail() async {
        while !Task.isCancelled {
            lines = await appState.logStore.recentLines
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.logFile(for: appState.runtime.id)])
    }

    private func copyLastLines() {
        let text = lines.suffix(200).map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
