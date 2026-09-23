import Foundation

enum Output {
    static func statusLine(_ status: StatusInfo) -> String {
        var lines = ["\(status.label) — \(status.detail)"]
        if let base = status.baseURL {
            lines.append("Endpoint: \(base)")
        }
        if let failure = status.failure {
            lines.append("Failed: \(failure)")
        }
        if status.modelsChangedSinceStart {
            lines.append("Models changed since the server started — `quail restart` to apply.")
        }
        return lines.joined(separator: "\n")
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func printTable(_ header: [String], _ rows: [[String]]) {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        for row in all {
            let cells = row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }
            print(cells.joined(separator: "   ").trimmingCharacters(in: .whitespaces))
        }
    }

    static func printJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try print(String(decoding: encoder.encode(value), as: UTF8.self))
    }

    /// Clears a progress line drawn on stderr.
    static func clearStatusLine() {
        guard isatty(STDERR_FILENO) != 0 else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
    }

    /// ANSI dim, only when writing to a terminal.
    static func dim(_ text: String) -> String {
        isatty(STDOUT_FILENO) != 0 ? "\u{1B}[2m\(text)\u{1B}[0m" : text
    }
}
