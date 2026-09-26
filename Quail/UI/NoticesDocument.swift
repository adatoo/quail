import Foundation

/// The generated `THIRD_PARTY_NOTICES.md` (ADR D-044) as blocks the licences sheet can lay out natively: a
/// component table, one section per component, licence texts as preformatted blocks. It reads the Markdown
/// `task notices` writes (headings, paragraphs, one pipe table, fenced blocks), not Markdown in general;
/// anything else stays a paragraph.
enum NoticesDocument {
    enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case table(header: [String], rows: [[String]])
        case preformatted(String)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var table: [[String]] = []
        var fence: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            let header = table[0]
            // The second row is the `| --- |` rule.
            let rows = table.dropFirst().filter { !$0.allSatisfy { $0.allSatisfy { "-: ".contains($0) } } }
            blocks.append(.table(header: header, rows: Array(rows)))
            table = []
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if var body = fence {
                if line.hasPrefix("```") {
                    blocks.append(.preformatted(body.joined(separator: "\n")))
                    fence = nil
                } else {
                    body.append(line)
                    fence = body
                }
                continue
            }
            if line.hasPrefix("```") {
                flushParagraph()
                flushTable()
                fence = []
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") {
                flushParagraph()
                var cells = trimmed.dropFirst()
                if cells.hasSuffix("|") {
                    cells = cells.dropLast()
                }
                table.append(cells.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) })
                continue
            }
            flushTable()
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let hashes = trimmed.firstIndex(where: { $0 != "#" }), hashes > trimmed.startIndex,
               trimmed[hashes] == " "
            {
                flushParagraph()
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes)
                blocks.append(.heading(
                    level: level,
                    // "## Title ##" closes with hashes too.
                    text: String(trimmed[hashes...])
                        .replacingOccurrences(of: #"\s#+$"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                ))
                continue
            }
            // A line ending in two spaces is a hard break; the lines of one paragraph keep their breaks.
            paragraph.append(line.hasSuffix("  ") ? String(line.dropLast(2)) : trimmed)
        }
        if var body = fence {
            while body.last?.isEmpty == true {
                body.removeLast()
            }
            blocks.append(.preformatted(body.joined(separator: "\n")))
        }
        flushParagraph()
        flushTable()
        return blocks
    }
}
