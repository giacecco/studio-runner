import Foundation

/// Anthropic-compatible Messages API client. Works with any endpoint that
/// implements the Anthropic Messages protocol — DeepSeek, Claude, etc.
/// Configured via `Config.aiEndpoint` and `Config.aiModel`.
enum AIClient {
    struct APIError: Error, CustomStringConvertible {
        let status: Int
        let body: String
        var description: String { "HTTP \(status): \(body)" }
    }

    /// `Config.aiEndpoint` comes from a hand-editable JSON file — a malformed
    /// value must surface as an error, not a force-unwrap crash.
    private static func endpointURL() throws -> URL {
        guard let url = URL(string: Config.aiEndpoint), url.scheme != nil else {
            throw NSError(domain: "StudioRunner", code: 101,
                          userInfo: [NSLocalizedDescriptionKey:
                              "Invalid AI endpoint URL: '\(Config.aiEndpoint)'"])
        }
        return url
    }

    /// Minimal auth check: sends a 1-token request and throws on any HTTP error.
    static func ping() async throws {
        guard let key = Config.apiKey else {
            throw NSError(domain: "StudioRunner", code: 100,
                          userInfo: [NSLocalizedDescriptionKey: "No API key set"])
        }
        var req = URLRequest(url: try endpointURL())
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        let payload: [String: Any] = [
            "model": Config.aiModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "Hi"]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(status: -1, body: "no response")
        }
        if http.statusCode < 200 || http.statusCode >= 300 {
            throw APIError(status: http.statusCode,
                           body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    static func call(systemPrompt: String, userPrompt: String) async throws -> String {
        guard let key = Config.apiKey else {
            throw NSError(domain: "StudioRunner", code: 100,
                          userInfo: [NSLocalizedDescriptionKey: "API key not set"])
        }

        let projectContext: String = (try? String(contentsOf: Config.systemFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let fullSystem = [Config.baseRole, projectContext, systemPrompt]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n---\n\n")

        var req = URLRequest(url: try endpointURL())
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Non-streaming: no bytes arrive until the full completion is
        // generated, so a slow 4096-token response can exceed the 60 s
        // URLSession default.
        req.timeoutInterval = 300
        let payload: [String: Any] = [
            "model": Config.aiModel,
            "max_tokens": 4096,
            "system": fullSystem,
            "messages": [["role": "user", "content": userPrompt]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(status: -1, body: "no response")
        }
        if http.statusCode < 200 || http.statusCode >= 300 {
            throw APIError(status: http.statusCode,
                           body: String(data: data, encoding: .utf8) ?? "")
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            return ""
        }
        // A response cut off at max_tokens must not be treated as complete:
        // the consolidator would overwrite studiorunner.md with a truncated
        // document and advance the watermark, losing the tail for good.
        if let stopReason = obj["stop_reason"] as? String, stopReason == "max_tokens" {
            throw APIError(status: -2, body: "response truncated at max_tokens")
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
