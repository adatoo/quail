import Foundation

/// What Quail tells you about a catalog family to help you choose it: when it came out, where its maker
/// describes it, what replaced it, and how it ranks publicly (ADR D-070). Worded here so the Add Model
/// sheet and the Models list say the same thing.
enum ModelFacts {
    /// A family released within this many days gets a "New" badge.
    static let newForDays = 30

    static func isNew(_ family: Catalog.Family, now: Date = .now) -> Bool {
        guard let released = family.released else { return false }
        let age = now.timeIntervalSince(released)
        return age >= 0 && age < Double(newForDays) * 86400
    }

    /// "5 Aug 2026". The catalog's dates are calendar days, so they're shown in UTC, never shifted a day.
    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    static func modelCardURL(_ family: Catalog.Family) -> URL? {
        family.modelCard.flatMap { URL(string: "https://huggingface.co/\($0)") }
    }

    /// The newest family that replaces `family`, following the chain (Qwen3 32B → Qwen3.8 27B → …), or
    /// `nil` when nothing does or the catalog doesn't have it.
    static func newer(than family: Catalog.Family, in families: [Catalog.Family]) -> Catalog.Family? {
        var seen: Set<String> = [family.id]
        var latest: Catalog.Family?
        var next = family.supersededBy
        while let id = next, !seen.contains(id), let found = families.first(where: { $0.id == id }) {
            seen.insert(id)
            latest = found
            next = found.supersededBy
        }
        return latest
    }

    /// "Qwen3.5 9B (vision)" → "Qwen3.5 9B": short enough for a badge.
    static func shortName(_ family: Catalog.Family) -> String {
        family.name.components(separatedBy: " (").first ?? family.name
    }

    // MARK: - Arena

    static let arenaLeaderboardURL = URL(string: "https://arena.ai/leaderboard/text")!
    static let arenaDatasetURL = URL(string: "https://huggingface.co/datasets/lmarena-ai/leaderboard-dataset")!
    static let ccByURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!

    /// "1439 ± 5 · #94 of 340".
    static func arenaText(_ arena: Catalog.ArenaRating) -> String {
        "\(arena.rating) ± \(arena.interval) · #\(arena.rank) of \(arena.outOf)"
    }

    /// The CC BY 4.0 credit, with the date the numbers are from (the card links the licence beside it).
    static func arenaCredit(_ arena: Catalog.ArenaRating) -> String {
        "Source: Arena text leaderboard (style control), © Arena, as of \(dayText(arena.asOf)); rounded."
    }

    static let arenaCaveat = "From people's votes between two answers, on the full-precision model: "
        + "a quantized download can do a little worse. Ratings within each other's ± are a tie."

    /// Whether "not publicly ranked" is worth saying: an embedding model or a smoke test isn't a chat model, so
    /// the text leaderboard was never going to list it.
    static func expectsRanking(_ family: Catalog.Family) -> Bool {
        family.isCurated && !["embedding", "smoke-test"].contains(family.role ?? "")
    }
}
