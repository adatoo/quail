import Foundation

/// How a typed model name resolves against the installed model ids: an
/// exact id, then a case-insensitive id, then a unique case-insensitive
/// prefix (`quail rm qwen3-0.6b`). Pure, and shared by the app (which
/// resolves `rm`, `ctx`, `default`) and the CLI (which has to tell a model
/// name from a prompt in `quail chat`).
enum ModelNameMatch: Equatable {
    case one(String)
    case none
    case ambiguous([String])

    static func match(_ name: String, in ids: [String]) -> ModelNameMatch {
        if let exact = ids.first(where: { $0 == name }) {
            return .one(exact)
        }
        if let loose = ids.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return .one(loose)
        }
        let prefixes = ids.filter { $0.lowercased().hasPrefix(name.lowercased()) }
        switch prefixes.count {
        case 0: return .none
        case 1: return .one(prefixes[0])
        default: return .ambiguous(prefixes)
        }
    }
}

/// What `quail chat [model] [prompt…]` means (ADR D-025). The first word is
/// a model only if it names exactly one installed model; otherwise every
/// word is the prompt and the default model answers. `-m` names the model
/// outright, so nothing is guessed.
enum ChatTarget {
    struct Resolved: Equatable {
        /// `nil`: use the default model.
        var model: String?
        var prompt: [String]
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownModel(String)
        case ambiguous(String, [String], guessed: Bool)

        var description: String {
            switch self {
            case let .unknownModel(name):
                "No installed model named '\(name)'. See `quail list`."
            case let .ambiguous(name, matches, guessed):
                "'\(name)' matches \(matches.joined(separator: ", ")) — "
                    + (guessed ? "name one, use -m, or quote the whole prompt." : "be more specific.")
            }
        }
    }

    static func resolve(words: [String], explicitModel: String?, installed: [String]) throws -> Resolved {
        if let explicitModel {
            switch ModelNameMatch.match(explicitModel, in: installed) {
            case let .one(id): return Resolved(model: id, prompt: words)
            case .none: throw Failure.unknownModel(explicitModel)
            case let .ambiguous(matches): throw Failure.ambiguous(explicitModel, matches, guessed: false)
            }
        }
        // A quoted prompt arrives as one word with spaces — never a model.
        guard let first = words.first, !first.contains(where: \.isWhitespace) else {
            return Resolved(model: nil, prompt: words)
        }
        switch ModelNameMatch.match(first, in: installed) {
        case let .one(id): return Resolved(model: id, prompt: Array(words.dropFirst()))
        case .none: return Resolved(model: nil, prompt: words)
        case let .ambiguous(matches): throw Failure.ambiguous(first, matches, guessed: true)
        }
    }
}
