import Foundation

/// The Connect tab's Test button: one tiny real request over the API the
/// tool will actually use — `/v1/chat/completions`, `/v1/responses` or the
/// Anthropic-style `/v1/messages` — with the exact base URL, key and model
/// the snippet shows. A pass means the snippet's values work, not just that
/// the server is up.
enum ConnectionTester {
    enum Outcome: Sendable, Equatable {
        case passed(milliseconds: Int)
        case failed(String)
    }

    static func test(
        api: Integration.API,
        values: SnippetRenderer.Values,
        urlSession: URLSession = .shared
    ) async -> Outcome {
        var request: URLRequest
        let body: [String: Any]
        switch api {
        case .openAIChat:
            request = URLRequest(url: values.baseURL.appending(path: "v1/chat/completions"))
            body = ["model": values.model, "max_tokens": 1, "messages": [["role": "user", "content": "Hi"]]]
        case .openAIResponses:
            request = URLRequest(url: values.baseURL.appending(path: "v1/responses"))
            body = ["model": values.model, "max_output_tokens": 16, "input": "Hi"]
        case .anthropic:
            request = URLRequest(url: values.baseURL.appending(path: "v1/messages"))
            body = ["model": values.model, "max_tokens": 1, "messages": [["role": "user", "content": "Hi"]]]
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 120 // a first request may load the model
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = values.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let start = Date()
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("No HTTP response") }
            guard (200 ..< 300).contains(http.statusCode) else {
                return .failed("HTTP \(http.statusCode)\(Self.errorMessage(in: data).map { ": \($0)" } ?? "")")
            }
            return .passed(milliseconds: Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The `error.message` llama-server (and OpenAI/Anthropic-shaped APIs)
    /// put in an error body.
    static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return object["message"] as? String
    }
}
