import SwiftUI

/// A small coloured capsule label — the pill `ModelsPane`'s rows used for
/// format/loaded-state/verdict badges, pulled out so `AddModelSheet` can
/// show the same fit-verdict pill without copying it.
struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// `Badge` for a `FitEstimate`'s verdict — the same three labels/colours
/// `ModelsPane`'s installed rows and `AddModelSheet`'s pre-download
/// verdict line both show.
struct FitVerdictBadge: View {
    let estimate: FitEstimate

    var body: some View {
        switch estimate.verdict {
        case .comfortable:
            Badge(text: "Comfortable", color: .green)
        case let .tight(reduced):
            Badge(text: "Tight · \(RemoteFitBadge.contextLabel(reduced)) ctx", color: .yellow)
                .help("Fits only with a reduced \(RemoteFitBadge.contextLabel(reduced))-token context")
        case .wontFit:
            Badge(text: "Won't fit", color: .red)
        }
    }
}

/// A row's fit badge in every state — including the two that used to
/// render as nothing at all: still checking, and couldn't tell (with the
/// reason on hover).
struct RemoteFitBadge: View {
    /// `nil` = not queued yet; shown the same as checking.
    let fit: RemoteFit?

    var body: some View {
        switch fit {
        case nil, .checking?:
            Badge(text: "Checking…", color: .secondary)
        case let .estimate(estimate)?:
            FitVerdictBadge(estimate: estimate)
        case let .unknown(reason)?:
            Badge(text: "Fit unknown", color: .secondary)
                .help(reason)
        }
    }

    /// 4096 → "4K", 1536 → "1.5K".
    static func contextLabel(_ tokens: Int) -> String {
        let k = Double(tokens) / 1024
        return k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))K" : String(format: "%.1fK", k)
    }
}
