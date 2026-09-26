import SwiftUI

/// A family's `ModelStrength`s as small capsules — each with its explanation as a tooltip (ADR D-052).
/// Strengths Quail can't use yet (audio) are left to `StrengthList`, which says so.
struct StrengthChips: View {
    let strengths: [ModelStrength]
    /// Labelled chips at most; the rest collapse into "+N" (its tooltip names them).
    var limit = 4

    private var usable: [ModelStrength] {
        strengths.filter(\.isUsableInQuail)
    }

    /// Never wider than the row offers: as many labelled chips as fit (down to one), then icons
    /// only. A fixed-width row of chips once pushed the row's name, size and fit badge out of the
    /// way (2026-09-26 screenshots).
    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(Set([limit, 3, 2, 1].map { min($0, usable.count) })).sorted(by: >), id: \.self) { count in
                chips(labelled: count)
            }
            icons
        }
        .font(.caption2)
        .imageScale(.small)
        .lineLimit(1)
    }

    private func chips(labelled count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(usable.prefix(count)) { strength in
                Label(strength.label, systemImage: strength.systemImage)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help(strength.explanation)
            }
            more(after: count)
        }
        .fixedSize()
    }

    private var icons: some View {
        HStack(spacing: 5) {
            ForEach(usable) { strength in
                Image(systemName: strength.systemImage)
                    .help("\(strength.label): \(strength.explanation)")
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func more(after count: Int) -> some View {
        let rest = usable.dropFirst(count)
        if !rest.isEmpty {
            Text("+\(rest.count)")
                .foregroundStyle(.secondary)
                .help(rest.map(\.label).joined(separator: ", "))
        }
    }
}

/// The detail pane's "Good for" block: every strength with its explanation, and a note for what the
/// model can do that Quail can't pass it yet.
struct StrengthList: View {
    let strengths: [ModelStrength]

    var body: some View {
        if !strengths.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Good for").font(.headline)
                ForEach(strengths.filter(\.isUsableInQuail)) { strength in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(strength.label)
                            Text(strength.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: strength.systemImage).foregroundStyle(.secondary)
                    }
                }
                let unusable = strengths.filter { !$0.isUsableInQuail }
                if !unusable.isEmpty {
                    Text(
                        "The model also understands \(unusable.map { $0.label.lowercased() }.joined(separator: " and ")); Quail can't pass that to it yet."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
