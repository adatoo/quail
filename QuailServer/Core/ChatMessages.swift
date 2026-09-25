import Foundation
import Jinja

/// Turns a chat request's messages into what a model's template expects.
enum ChatMessages {
    /// How the template wants `content`: a plain string (nearly all do), or the OpenAI list of typed
    /// parts (a few, written for multimodal use, only handle that).
    enum ContentStyle: Equatable, Sendable {
        case string
        case typed
    }

    /// Checks by rendering, as llama.cpp does, rather than guessing from the template's text.
    static func contentStyle(of template: ChatTemplate) -> ContentStyle {
        func renders(_ content: Value) -> Bool {
            let message = Value.object(["role": .string("user"), "content": content])
            guard let text = try? template.render(.init(messages: [message])) else { return false }
            return text.contains("PROBE-TEXT")
        }
        if renders(.string("PROBE-TEXT")) {
            return .string
        }
        let part = Value.object(["type": .string("text"), "text": .string("PROBE-TEXT")])
        return renders(.array([part])) ? .typed : .string
    }

    /// - Parameters:
    ///   - style: how the template wants content.
    ///   - templateKnowsDeveloperRole: gpt-oss's template has a `developer` role; the others don't,
    ///     and get `system` (the OpenAI rename), which is what llama-server sends them.
    ///   - Returns: the messages, with each image part replaced by the marker text, and the images' bytes in
    ///     the order their markers appear.
    static func normalize(
        _ messages: [Value],
        style: ContentStyle,
        templateKnowsDeveloperRole: Bool
    ) throws -> (messages: [Value], media: [Data]) {
        var media: [Data] = []
        let normalized: [Value] = try messages.map { message -> Value in
            guard case var .object(members) = message, let role = members["role"]?.stringValue else {
                throw RequestError.invalid("each message needs a \"role\"")
            }
            if role == "developer", !templateKnowsDeveloperRole {
                members["role"] = .string("system")
            }
            if let content = members["content"], case var .array(parts) = content {
                for (index, part) in parts.enumerated() {
                    let type = part["type"]?.stringValue ?? "text"
                    switch type {
                    case "text", "input_text":
                        break
                    case "image_url":
                        try media.append(ImageInput.decode(url: ImageInput.url(ofPart: part)))
                        parts[index] = .record([("type", .string("text")), ("text", .string(ImageInput.marker))])
                    default:
                        throw RequestError.invalid("\(type) input is not supported")
                    }
                }
                members["content"] = .array(parts)
                if style == .string {
                    // llama-server joins the text parts with a newline.
                    members["content"] = .string(parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n"))
                }
            }
            return .object(members)
        }
        return (normalized, media)
    }

    /// llama.cpp's fallback for a model with no template of its own.
    static let chatMLTemplate = """
    {% for message in messages %}{{ '<|im_start|>' + message['role'] + '\\n' + message['content'] + '<|im_end|>' + '\\n' }}{% endfor %}{% if add_generation_prompt %}{{ '<|im_start|>assistant\\n' }}{% endif %}
    """
}
