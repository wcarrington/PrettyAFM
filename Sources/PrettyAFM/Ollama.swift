import Foundation

enum Ollama {
    static let base = URL(string: ProcessInfo.processInfo.environment["OLLAMA_HOST_URL"] ?? "http://127.0.0.1:11434")!

    static func installedModels() async -> [String]? {
        var req = URLRequest(url: base.appending(path: "api/tags"))
        req.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["name"] as? String }
    }

    /// POSTs JSON and yields each NDJSON line from Ollama's streaming response.
    static func streamLines(path: String, body: [String: Any],
                            onLine: ([String: Any]) async throws -> Void) async throws {
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 600

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line }
            let msg = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["error"] as? String
            throw NSError(domain: "Ollama", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg ?? "Ollama returned HTTP \(http.statusCode)"])
        }
        for try await line in bytes.lines {
            guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let err = obj["error"] as? String {
                throw NSError(domain: "Ollama", code: 1, userInfo: [NSLocalizedDescriptionKey: err])
            }
            try await onLine(obj)
        }
    }

    struct Stats { var promptTokens = 0; var outputTokens = 0; var tokensPerSecond: Double = 0 }

    static func chat(profile: QwenProfile, messages: [ChatMessage], think: Bool,
                     onThinking: (String) async throws -> Void,
                     onDelta: (String) async throws -> Void) async throws -> Stats {
        var msgs: [[String: Any]] = []
        if !messages.contains(where: { $0.role == "system" }) {
            msgs.append(["role": "system", "content": "You are a helpful, precise assistant running locally on the user's Mac. Use Markdown for formatting. Only use LaTeX ($...$) for genuine math expressions."])
        }
        for m in messages {
            var o: [String: Any] = ["role": m.role, "content": m.fullContent]
            if !m.images.isEmpty { o["images"] = m.images }
            msgs.append(o)
        }
        let body: [String: Any] = [
            "model": profile.model,
            "messages": msgs,
            "stream": true,
            "think": think,
            "options": ["num_ctx": profile.contextTokens],
        ]
        var stats = Stats()
        try await streamLines(path: "api/chat", body: body) { obj in
            if let message = obj["message"] as? [String: Any] {
                if let t = message["thinking"] as? String, !t.isEmpty { try await onThinking(t) }
                if let c = message["content"] as? String, !c.isEmpty { try await onDelta(c) }
            }
            if obj["done"] as? Bool == true {
                stats.promptTokens = obj["prompt_eval_count"] as? Int ?? 0
                stats.outputTokens = obj["eval_count"] as? Int ?? 0
                let ns = obj["eval_duration"] as? Double ?? 0
                if ns > 0 { stats.tokensPerSecond = Double(stats.outputTokens) / (ns / 1e9) }
            }
        }
        return stats
    }
}
