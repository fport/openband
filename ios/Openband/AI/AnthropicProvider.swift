import Foundation

/// Anthropic's Messages API, called straight from the phone with the user's own key.
struct AnthropicClient: AIProviderClient {
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// The API version the request shape below is written against.
    var version = "2026-10-21"
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func complete(_ request: AIRequest, model: String, key: String) async throws -> String {
        // Images before the text, which is the order Anthropic's own examples use.
        var content: [[String: Any]] = request.images.map { data in
            ["type": "image",
             "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]]
        }
        content.append(["type": "text", "text": request.user])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens,
            "system": request.system,
            "messages": [["role": "user", "content": content]],
        ]

        var http = URLRequest(url: endpoint)
        http.httpMethod = "POST"
        http.timeoutInterval = 120
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `x-api-key` still works but is the legacy fallback; bearer auth is the current one.
        http.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        http.setValue(version, forHTTPHeaderField: "anthropic-version")
        http.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: http)
        try AIHTTP.check(response, data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]] else {
            throw AIError.badResponse("")
        }
        let text = blocks.compactMap { $0["text"] as? String }.joined()
        // A refusal comes back as a 200 that is not the JSON that was asked for, so it has to
        // be caught before the answer is parsed.
        switch json["stop_reason"] as? String {
        case "refusal": throw AIError.refused(String(text.prefix(200)))
        case "max_tokens": throw AIError.badResponse(String(localized: "The answer was cut short."))
        default: break
        }
        guard !text.isEmpty else { throw AIError.badResponse("") }
        return text
    }
}

enum AIHTTP {
    /// Turns a status code into something the screen can say out loud.
    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200 ..< 300).contains(http.statusCode) else { return }
        switch http.statusCode {
        case 401, 403: throw AIError.unauthorized
        case 413: throw AIError.tooLarge
        case 429: throw AIError.rateLimited
        default: throw AIError.server(http.statusCode, message(data))
        }
    }

    /// Both providers nest the human-readable reason under `error.message`.
    private static func message(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return "" }
        return message
    }
}
