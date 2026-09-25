import Foundation

/// What `quail pull <spec>` names, ollama-style: a catalog model
/// (`qwen3-8b`, `qwen3-8b:Q8_0`) or any Hugging Face GGUF repo
/// (`owner/repo`, `owner/repo:Q5_K_M`, or its huggingface.co URL).
struct PullSpec: Equatable {
    var family: Catalog.Family?
    var repo: String
    /// As typed; matched case-insensitively against the repo's files.
    var quant: String?

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unknownModel(String, suggestions: [String])
        case mlxOnly(String)

        var description: String {
            switch self {
            case .empty:
                "Name a model: a catalog name (see `quail pull --list`) or a Hugging Face repo (owner/repo)."
            case let .unknownModel(name, suggestions):
                "No catalog model called '\(name)'."
                    + (suggestions.isEmpty ? "" : " Did you mean: \(suggestions.joined(separator: ", "))?")
                    + " See `quail pull --list`, or pass a Hugging Face repo as owner/repo."
            case let .mlxOnly(name):
                "\(name) is only available as MLX; `quail pull` fetches GGUF models. Add it from the app's Models pane."
            }
        }
    }

    static func parse(_ raw: String, catalog: Catalog) throws -> PullSpec {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://huggingface.co/", "http://huggingface.co/", "huggingface.co/", "hf.co/"]
            where text.lowercased().hasPrefix(prefix)
        {
            text = String(text.dropFirst(prefix.count))
        }
        guard !text.isEmpty else { throw ParseError.empty }

        var name = text
        var quant: String?
        if let colon = text.lastIndex(of: ":") {
            let tail = String(text[text.index(after: colon)...])
            if !tail.isEmpty, !tail.contains("/") {
                name = String(text[..<colon])
                quant = tail
            }
        }

        if name.contains("/") {
            let parts = name.split(separator: "/").prefix(2)
            let repo = parts.joined(separator: "/")
            // A curated repo pasted as owner/repo still gets its family
            // (mmproj companion, default quant).
            let family = catalog.families.first { $0.gguf?.repo.caseInsensitiveCompare(repo) == .orderedSame }
            return PullSpec(family: family, repo: family?.gguf?.repo ?? repo, quant: quant)
        }

        let key = normalized(name)
        guard let family = catalog.families.first(where: { normalized($0.id) == key || normalized($0.name) == key })
        else {
            let suggestions = catalog.families
                .filter { normalized($0.id).contains(key) || key.contains(normalized($0.id)) }
                .map(\.id)
            throw ParseError.unknownModel(name, suggestions: Array(suggestions.prefix(5)))
        }
        guard let gguf = family.gguf else { throw ParseError.mlxOnly(family.name) }
        return PullSpec(family: family, repo: gguf.repo, quant: quant)
    }

    /// The quant to download: the one asked for (if the repo has it), else
    /// the family's default, else Q4_K_M, else the first available.
    static func chooseQuant(requested: String?, available: [String], familyDefault: String?) -> String? {
        if let requested {
            return available.first { $0.caseInsensitiveCompare(requested) == .orderedSame }
        }
        if let familyDefault, available.contains(familyDefault) {
            return familyDefault
        }
        return available.first { $0.caseInsensitiveCompare("Q4_K_M") == .orderedSame } ?? available.first
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}
