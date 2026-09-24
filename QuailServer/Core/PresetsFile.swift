import Foundation

/// One section of a `--models-preset` INI file: the model's id and the flag
/// names (dashes, as `ModelStore.regeneratePresets` writes them) with values.
struct ModelPreset: Equatable, Sendable {
    var id: String
    var values: [String: String]

    func string(_ key: String) -> String? {
        values[key]
    }

    func int(_ key: String) -> Int? {
        values[key].flatMap { Int($0) }
    }

    func bool(_ key: String) -> Bool? {
        guard let raw = values[key]?.lowercased() else { return nil }
        switch raw {
        case "true", "1", "on", "yes": return true
        case "false", "0", "off", "no": return false
        default: return nil
        }
    }
}

/// Reads the INI format `ModelStore.regeneratePresets` writes and
/// llama-server's router accepts: `[id]` sections of `key = value` lines,
/// `;`/`#` comments, and an optional `[*]` section whose keys are defaults
/// for every model.
enum PresetsFile {
    static let globalSection = "*"

    static func load(_ url: URL) -> [ModelPreset] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [ModelPreset] {
        var sections: [(id: String, values: [String: String])] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let id = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                sections.append((id, [:]))
            } else if let equals = line.firstIndex(of: "="), !sections.isEmpty {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    sections[sections.count - 1].values[key] = value
                }
            }
        }
        let defaults = sections.first { $0.id == globalSection }?.values ?? [:]
        return sections
            .filter { $0.id != globalSection && !$0.id.isEmpty }
            .map { ModelPreset(id: $0.id, values: defaults.merging($0.values) { _, own in own }) }
    }
}
