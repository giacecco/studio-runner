import Foundation

/// DeepSeek's Anthropic-compatible Messages endpoint. Mirrors the bun client:
/// `x-api-key`, `anthropic-version: 2023-06-01`, `{ system, messages,
/// max_tokens }`. The full system prompt is composed of three layers:
///   1. `Config.baseRole` (hardcoded studio-runner persona)
///   2. `.studiorunner.d/system.md` (per-project context, user-edited)
///   3. The call-specific prompt passed in by the caller
enum DeepSeek {
    struct APIError: Error, CustomStringConvertible {
        let status: Int
        let body: String
        var description: String { "DeepSeek HTTP \(status): \(body)" }
    }

    static func call(systemPrompt: String, userPrompt: String) async throws -> String {
        guard let key = Config.apiKey else {
            throw NSError(domain: "StudioRunner", code: 100,
                          userInfo: [NSLocalizedDescriptionKey: "STUDIORUNNER_AI_API_KEY not set"])
        }

        let projectContext: String = (try? String(contentsOf: Config.systemFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let fullSystem = [Config.baseRole, projectContext, systemPrompt]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n---\n\n")

        var req = URLRequest(url: URL(string: "https://api.deepseek.com/anthropic/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": Config.deepseekModel,
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
        let text = content.compactMap { $0["text"] as? String }.joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
