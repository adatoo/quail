import SwiftUI

/// What helps you choose a catalog family (ADR D-070): what it's for, when it came out, its maker's page and the
/// files, how it ranks publicly, what replaced it, and what else to consider on this Mac. The same card in the
/// Add Model sheet and behind a Models row's info button.
struct ModelFactsCard: View {
    let family: Catalog.Family
    /// The repo Quail downloads from, linked as "Files".
    let filesRepo: String?
    /// A newer family from the same line, when the catalog has one.
    let newer: Catalog.Family?
    /// Other families worth a look on this Mac (`ModelAlternatives`).
    var alternatives: [ModelAlternatives.Alternative] = []
    /// Shows `newer` or an alternative in the Add Model sheet; `nil` hides the buttons.
    var onShow: ((Catalog.Family) -> Void)?

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
            quailScores
            ranking
            if let newer {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle").foregroundStyle(.orange)
                    Text("Newer from the same line: \(newer.name)")
                    if let onShow {
                        Button("Show") { onShow(newer) }
                            .controlSize(.small)
                    }
                }
                .font(.callout)
            }
            alternativesList
        }
    }

    @ViewBuilder private var alternativesList: some View {
        if !alternatives.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Alternatives on this Mac").font(.callout.weight(.semibold))
                ForEach(alternatives, id: \.family.id) { alternative in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: Self.symbol(alternative.reason))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(alternative.family.name).font(.callout)
                            Text("\(Self.label(alternative.reason)): \(alternative.detail)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        if let onShow {
                            Button("Show") { onShow(alternative.family) }
                                .controlSize(.small)
                        }
                    }
                }
                Text("From Quail's own tests, and the memory and speed estimated for this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    private static func label(_ reason: ModelAlternatives.Reason) -> String {
        switch reason {
        case .scoresHigher: "Scores higher"
        case .smaller: "Smaller"
        case .faster: "Faster"
        }
    }

    private static func symbol(_ reason: ModelAlternatives.Reason) -> String {
        switch reason {
        case .scoresHigher: "arrow.up.right"
        case .smaller: "arrow.down.right.and.arrow.up.left"
        case .faster: "hare"
        }
    }

    @ViewBuilder private var quailScores: some View {
        if let scores = family.quailScores {
            VStack(alignment: .leading, spacing: 3) {
                Label {
                    Text(ModelFacts.quailText(scores)).monospacedDigit()
                } icon: {
                    Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                }
                .font(.callout)
                .help(ModelFacts.quailMethod(scores))
                Text(ModelFacts.quailMethod(scores) + (family.quailNote.map { " " + $0 } ?? ""))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("How Quail tests", destination: ModelFacts.quailMethodURL)
            }
            .font(.caption)
        } else if let note = family.quailNote {
            Label(note, systemImage: "checkmark.seal")
                .font(.callout)
                .foregroundStyle(.secondary)
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
