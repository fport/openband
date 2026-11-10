import Foundation

/// OpenAI's Responses API, called straight from the phone with the user's own key. Images go
/// as data URLs: a Files upload would be a second round trip and would leave an object sitting
/// on the user's account for the app to clean up afterwards.
struct OpenAIClient: AIProviderClient {
    var endpoint = URL(string: "https://api.openai.com/v1/responses")!
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func complete(_ request: AIRequest, model: String, key: String) async throws -> String {
        var content: [[String: Any]] = [["type": "input_text", "text": request.user]]
        content += request.images.map { data in
            ["type": "input_image",
             "image_url": "data:image/jpeg;base64,\(data.base64EncodedString())",
             "detail": "high"]
        }

        let body: [String: Any] = [
            "model": model,
            "instructions": request.system,
            "input": [["role": "user", "content": content]],
            "max_output_tokens": request.maxTokens,
        ]

        var http = URLRequest(url: endpoint)
        http.httpMethod = "POST"
        http.timeoutInterval = 120
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        http.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: http)
        try AIHTTP.check(response, data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.badResponse("")
        }
        if let status = json["status"] as? String, status == "incomplete" {
            throw AIError.badResponse(String(localized: "The answer was cut short."))
        }
        let text = Self.text(in: json)
        guard !text.isEmpty else {
            if let refusal = Self.refusal(in: json) { throw AIError.refused(refusal) }
            throw AIError.badResponse("")
        }
        return text
    }

    /// The Responses API returns a list of output items; the answer is the text inside the
    /// message item. `output_text` is the SDKs' convenience field and is not always present.
    private static func text(in json: [String: Any]) -> String {
        if let flat = json["output_text"] as? String, !flat.isEmpty { return flat }
        let output = json["output"] as? [[String: Any]] ?? []
        return output
            .compactMap { $0["content"] as? [[String: Any]] }
            .flatMap { $0 }
            .filter { $0["type"] as? String == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    private static func refusal(in json: [String: Any]) -> String? {
        let output = json["output"] as? [[String: Any]] ?? []
        return output
            .compactMap { $0["content"] as? [[String: Any]] }
            .flatMap { $0 }
            .first { $0["type"] as? String == "refusal" }
            .flatMap { $0["refusal"] as? String }
    }
}
