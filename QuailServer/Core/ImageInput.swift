import Foundation
import Jinja

/// Images a request carries, as bytes the engine can decode (ADR D-047). An image arrives as a `data:` URL
/// with base64 content; a URL that would have to be fetched is refused, because fetching whatever address a
/// request names is a network and privacy decision the server doesn't make on a client's behalf.
public enum ImageInput {
    /// What stands for an image in the prompt text, which the engine replaces with the image's embedding:
    /// libmtmd's default marker, checked against the library when the engine loads a projector.
    public static let marker = "<__media__>"

    /// The most one image may weigh once decoded (the request body has its own, larger limit).
    static let maxBytes = 32 << 20

    static func decode(url: String) throws -> Data {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard lowered.hasPrefix("data:") else {
            if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("file:") {
                throw RequestError.invalid(
                    "quail-server doesn't fetch image URLs; send the image as a base64 data: URL"
                )
            }
            throw RequestError.invalid("an image must be a base64 data: URL")
        }
        guard let comma = trimmed.firstIndex(of: ",") else {
            throw RequestError.invalid("the image's data: URL has no data")
        }
        let header = trimmed[trimmed.startIndex ..< comma].lowercased()
        guard header.hasSuffix(";base64") else {
            throw RequestError.invalid("the image's data: URL must be base64 encoded")
        }
        let payload = trimmed[trimmed.index(after: comma)...]
        guard let data = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters), !data.isEmpty else {
            throw RequestError.invalid("the image's base64 data is empty or malformed")
        }
        guard data.count <= maxBytes else {
            throw RequestError.invalid("the image is larger than \(maxBytes >> 20) MB")
        }
        return data
    }

    /// The URL of a chat completions `image_url` part, which is `{"url": …}` or the URL itself.
    static func url(ofPart part: Value) throws -> String {
        guard let url = part["image_url"]?["url"]?.stringValue ?? part["image_url"]?.stringValue else {
            throw RequestError.invalid("an image_url part needs a \"url\"")
        }
        return url
    }

    /// A chat completions image part for a data: URL (how the other APIs' image blocks are handed on).
    static func part(url: String) -> Value {
        .record([("type", .string("image_url")), ("image_url", .record([("url", .string(url))]))])
    }
}
