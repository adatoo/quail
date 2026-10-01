import SwiftUI

/// What helps you choose a catalog family (ADR D-070): what it's for, when it came out, its maker's page and the
/// files, how it ranks publicly, and what replaced it. The same card in the Add Model sheet and behind a Models
/// row's info button.
struct ModelFactsCard: View {
    let family: Catalog.Family
    /// The repo Quail downloads from, linked as "Files".
    let filesRepo: String?
    /// A newer family from the same line, when the catalog has one.
    let newer: Catalog.Family?
    /// Shows `newer` in the Add Model sheet; `nil` hides the button.
    var onShowNewer: ((Catalog.Family) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = family.summary {
                Text(summary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if let released = family.released {
                    HStack(spacing: 4) {
                        Text("Released \(ModelFacts.dayText(released))")
                        if ModelFacts.isNew(family) {
                            Badge(text: "New", color: .accentColor)
                        }
                    }
                }
                if let url = ModelFacts.modelCardURL(family) {
                    Link("Model card", destination: url)
                        .help("The maker's page for it on Hugging Face: \(family.modelCard ?? "")")
                }
                if let filesRepo, let url = URL(string: "https://huggingface.co/\(filesRepo)") {
                    Link("Files", destination: url)
                        .help("Where Quail downloads it from: \(filesRepo)")
                }
            }
            .font(.callout)
            ranking
            if let newer {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle").foregroundStyle(.orange)
                    Text("Newer from the same line: \(newer.name)")
                    if let onShowNewer {
                        Button("Show") { onShowNewer(newer) }
                            .controlSize(.small)
                    }
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder private var ranking: some View {
        if let arena = family.arena {
            VStack(alignment: .leading, spacing: 3) {
                Label {
                    Text("Arena rating \(ModelFacts.arenaText(arena))").monospacedDigit()
                } icon: {
                    Image(systemName: "chart.bar.fill").foregroundStyle(.secondary)
                }
                .font(.callout)
                .help(ModelFacts.arenaCaveat)
                Text(ModelFacts.arenaCaveat + " " + ModelFacts.arenaCredit(arena))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Link("Leaderboard", destination: ModelFacts.arenaLeaderboardURL)
                    Link("Data", destination: ModelFacts.arenaDatasetURL)
                    Link("CC BY 4.0", destination: ModelFacts.ccByURL)
                        .help("The licence Arena publishes its ratings under")
                }
            }
            .font(.caption)
        } else if ModelFacts.expectsRanking(family) {
            Label("Not publicly ranked: Arena's text leaderboard doesn't list it.", systemImage: "chart.bar")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
