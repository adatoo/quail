import SwiftUI

/// A family's `ModelStrength`s as small capsules — each with its explanation as a tooltip (ADR D-052).
/// Strengths Quail can't use yet (audio) are left to `StrengthList`, which says so.
struct StrengthChips: View {
    let strengths: [ModelStrength]
    /// Past this many, the rest collapse into "+N" (its tooltip names them).
    var limit = 4

    private var usable: [ModelStrength] {
        strengths.filter(\.isUsableInQuail)
    }

    var body: some View {
        let shown = usable.prefix(limit)
        let rest = usable.dropFirst(limit)
        HStack(spacing: 4) {
            ForEach(Array(shown)) { strength in
                Label(strength.label, systemImage: strength.systemImage)
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help(strength.explanation)
            }
            if !rest.isEmpty {
                Text("+\(rest.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(rest.map(\.label).joined(separator: ", "))
            }
        }
        .lineLimit(1)
        .fixedSize()
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
