import Foundation

/// A piece of a chat reply: the answer, or the model's reasoning before it.
enum ChatDelta: Equatable, Sendable {
    case content(String)
    case reasoning(String)
}

/// Separates `<think>…</think>` reasoning from the answer as text streams in, like llama-server's
/// default (`reasoning_format` "auto"): the reasoning goes to `reasoning_content`, the tags and the
/// whitespace right after each are dropped, and nothing that could still be half a tag is emitted.
///
/// A model may open the tag itself, or its chat template may have opened it already (Qwen3's
/// generation prompt ends with `<think>` when thinking is on), in which case generation starts
/// inside the reasoning (`startsInReasoning`).
struct ReasoningSplitter: Sendable {
    static let open = "<think>"
    static let close = "</think>"

    private enum Mode {
        /// Before any answer text: the opening tag may still come.
        case start
        case reasoning
        case answer
    }

    private var mode: Mode
    private var pending = ""
    /// After a tag, whitespace is dropped until the first real character.
    private var skippingWhitespace: Bool

    init(startsInReasoning: Bool) {
        mode = startsInReasoning ? .reasoning : .start
        skippingWhitespace = startsInReasoning
    }

    mutating func push(_ text: String) -> [ChatDelta] {
        pending += text
        return drain(final: false)
    }

    /// The end of generation: whatever was being held back was never a tag.
    mutating func flush() -> [ChatDelta] {
        drain(final: true)
    }

    private mutating func drain(final: Bool) -> [ChatDelta] {
        var out: [ChatDelta] = []
        func emit(_ delta: ChatDelta) {
            switch delta {
            case let .content(text) where text.isEmpty: return
            case let .reasoning(text) where text.isEmpty: return
            default: break
            }
            // Merge neighbours of the same kind so a chunk is one delta.
            if let last = out.last {
                switch (last, delta) {
                case let (.content(a), .content(b)): out[out.count - 1] = .content(a + b); return
                case let (.reasoning(a), .reasoning(b)): out[out.count - 1] = .reasoning(a + b); return
                default: break
                }
            }
            out.append(delta)
        }

        while true {
            if skippingWhitespace {
                let trimmed = String(pending.drop(while: { $0.isWhitespace }))
                pending = trimmed
                if pending.isEmpty {
                    break
                }
                skippingWhitespace = false
            }
            switch mode {
            case .start:
                // Leading whitespace before an opening tag is skipped along with the tag; keep it
                // aside until we know which it is.
                let body = pending.drop(while: { $0.isWhitespace })
                if body.hasPrefix(Self.open) {
                    pending = String(body.dropFirst(Self.open.count))
                    mode = .reasoning
                    skippingWhitespace = true
                    continue
                }
                if !final, Self.open.hasPrefix(String(body)) {
                    return out // the start of a tag, or only whitespace so far: wait
                }
                mode = .answer
                continue
            case .reasoning:
                if let range = pending.range(of: Self.close) {
                    emit(.reasoning(String(pending[..<range.lowerBound])))
                    pending = String(pending[range.upperBound...])
                    mode = .answer
                    skippingWhitespace = true
                    continue
                }
                let hold = final ? 0 : Self.partialSuffixLength(of: pending, for: Self.close)
                emit(.reasoning(String(pending.dropLast(hold))))
                pending = String(pending.suffix(hold))
                return out
            case .answer:
                emit(.content(pending))
                pending = ""
                return out
            }
        }
        // Only reached with everything consumed as skipped whitespace.
        return out
    }

    /// How many trailing characters of `text` are a proper prefix of `tag`.
    private static func partialSuffixLength(of text: String, for tag: String) -> Int {
        var length = min(tag.count - 1, text.count)
        while length > 0 {
            if text.suffix(length) == tag.prefix(length) {
                return length
            }
            length -= 1
        }
        return 0
    }
}
