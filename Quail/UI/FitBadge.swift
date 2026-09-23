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
            Badge(text: "Tight · \(reduced)", color: .yellow)
        case .wontFit:
            Badge(text: "Won't fit", color: .red)
        }
    }
}
