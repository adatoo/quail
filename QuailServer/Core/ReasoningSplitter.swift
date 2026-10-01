import Foundation

/// A piece of a chat reply: the answer, or the model's reasoning before it.
enum ChatDelta: Equatable, Sendable {
    case content(String)
    case reasoning(String)
    /// A complete tool call.
    case toolCall(ParsedToolCall)
}

/// The tags a model family wraps its reasoning in.
struct ReasoningTags: Equatable, Sendable {
    var open: String
    var close: String
    /// Whether a reasoning block can also come after answer text, not only at the start of a reply.
    var anywhere = false
    /// For a grammar (`JSONSchemaGrammar`): text the reasoning block's close is always followed by, and text the
    /// answer always starts with, in a family whose reply is a run of messages (Muse Glimmer's headers).
    var afterClose = ""
    var answerPrefix = ""

    /// `<think>…</think>`: Qwen3 and most reasoning models.
    static let think = ReasoningTags(open: "<think>", close: "</think>")
    /// Gemma 4's thought channel. It writes an empty one after a tool result even with thinking off, and
    /// can end a reply with another or with a stray `<channel|>`, as llama.cpp's own parser notes.
    static let gemma4 = ReasoningTags(open: "<|channel>thought", close: "<channel|>", anywhere: true)
    /// Muse Glimmer's reasoning message and its answer's header, after the generation prompt's
    /// `<|start|>assistant` (`MuseGlimmerParser` reads its replies; these shape a grammar for them).
    static let museGlimmer = ReasoningTags(
        open: " to=self<|message|>", close: "<|eom|>", afterClose: "<|start|>assistant",
        answerPrefix: " to=user<|message|>"
    )
}

extension ToolCallFormat {
    /// How this family marks its reasoning (Harmony's channels have their own parser).
    var reasoningTags: ReasoningTags {
        switch self {
        case .gemma4: .gemma4
        case .museGlimmer: .museGlimmer
        default: .think
        }
    }
}

/// Separates reasoning (`<think>…</think>`, or the family's own `tags`) from the answer as text streams
/// in, like llama-server's default (`reasoning_format` "auto"): the reasoning goes to
/// `reasoning_content`, the tags and the whitespace right after each are dropped, and nothing that could
/// still be half a tag is emitted.
///
/// A model may open the tag itself, or its chat template may have opened it already (Qwen3's
/// generation prompt ends with `<think>` when thinking is on), in which case generation starts
/// inside the reasoning (`startsInReasoning`).
struct ReasoningSplitter: Sendable {
    private let tags: ReasoningTags

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

    init(startsInReasoning: Bool, tags: ReasoningTags = .think) {
        self.tags = tags
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
                if body.hasPrefix(tags.open) {
                    pending = String(body.dropFirst(tags.open.count))
                    mode = .reasoning
                    skippingWhitespace = true
                    continue
                }
                if !final, tags.open.hasPrefix(String(body)) {
                    return out // the start of a tag, or only whitespace so far: wait
                }
                mode = .answer
                continue
            case .reasoning:
                if let range = pending.range(of: tags.close) {
                    emit(.reasoning(String(pending[..<range.lowerBound])))
                    pending = String(pending[range.upperBound...])
                    mode = .answer
                    skippingWhitespace = true
                    continue
                }
                let hold = final ? 0 : Self.partialSuffixLength(of: pending, for: tags.close)
                emit(.reasoning(String(pending.dropLast(hold))))
                pending = String(pending.suffix(hold))
                return out
            case .answer:
                guard tags.anywhere else {
                    emit(.content(pending))
                    pending = ""
                    return out
                }
                // A later reasoning block opens as the first one did; a closing tag with nothing open is dropped.
                let open = pending.range(of: tags.open)
                let close = pending.range(of: tags.close)
                if let tag = [open, close].compactMap(\.self).min(by: { $0.lowerBound < $1.lowerBound }) {
                    emit(.content(String(pending[..<tag.lowerBound])))
                    pending = String(pending[tag.upperBound...])
                    if tag == open {
                        mode = .reasoning
                        skippingWhitespace = true
                    }
                    continue
                }
                let hold = final ? 0 : max(
                    Self.partialSuffixLength(of: pending, for: tags.open),
                    Self.partialSuffixLength(of: pending, for: tags.close)
                )
                emit(.content(String(pending.dropLast(hold))))
                pending = String(pending.suffix(hold))
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
