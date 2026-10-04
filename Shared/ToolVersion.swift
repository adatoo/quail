import Foundation

/// A tool's version, read from what `<tool> --version` prints ("1.18.34", "opencode v2.0.19"), so `quail launch`
/// passes a flag only to versions that have it: opencode's `--standalone` exists from 2.0 on, and opencode 1 stops
/// with its usage text when given it.
struct ToolVersion: Comparable, Sendable, Equatable {
    var parts: [Int]

    /// The first dotted number in the text, or nil if there's none.
    init?(parsing text: String) {
        guard let range = text.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) else { return nil }
        parts = text[range].split(separator: ".").compactMap { Int($0) }
    }

    /// Missing numbers count as zero, so 2 and 2.0.0 are the same version.
    static func == (lhs: ToolVersion, rhs: ToolVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: ToolVersion, rhs: ToolVersion) -> Bool {
        for index in 0 ..< max(lhs.parts.count, rhs.parts.count) {
            let (l, r) = (lhs.parts[safe: index] ?? 0, rhs.parts[safe: index] ?? 0)
            if l != r {
                return l < r
            }
        }
        return false
    }

    /// Whether the trailing arguments go on: yes unless the installed version is known and older than `minimum`.
    /// A tool whose version can't be read gets them, as before this check existed.
    static func allows(installed: String?, minimum: String?) -> Bool {
        guard let minimum, let required = ToolVersion(parsing: minimum),
              let installed, let found = ToolVersion(parsing: installed)
        else { return true }
        return found >= required
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
