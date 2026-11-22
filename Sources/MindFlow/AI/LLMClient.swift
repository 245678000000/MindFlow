import Foundation

struct LLMMessage {
    var role: String   // "user" | "assistant"
    var content: String
}

enum LLMError: LocalizedError {
    case badURL(String)
    case http(Int, String)
    case api(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "无效的接口地址：\(s)"
        case .http(let code, let msg): return "HTTP \(code)：\(msg.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: code) : msg)"
        case .api(let msg): return msg
        case .empty: return "模型没有返回内容"
        }
    }
}

enum LLMClient {
    static func endpoint(for p: AIProvider) throws -> URL {
        var base = p.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.isEmpty {
            base = p.kind == .anthropic ? "https://api.anthropic.com" : "https://api.openai.com/v1"
        }
        let full: String
        switch p.kind {
        case .anthropic:
            if base.hasSuffix("/messages") { full = base }
            else if base.hasSuffix("/v1") { full = base + "/messages" }
            else { full = base + "/v1/messages" }
        case .openaiChat, .openaiResponses:
            let path = p.kind == .openaiChat ? "/chat/completions" : "/responses"
            if base.hasSuffix(path) { full = base }
            else if let u = URLComponents(string: base), u.path.isEmpty || u.path == "/" { full = base + "/v1" + path }
            else { full = base + path }
        }
        guard let url = URL(string: full), url.scheme?.hasPrefix("http") == true else { throw LLMError.badURL(full) }
        return url
    }

    static func request(provider p: AIProvider, model: String, system: String,
                        messages: [LLMMessage], maxTokens: Int = 8192, stream: Bool = true) throws -> URLRequest {
        var req = URLRequest(url: try endpoint(for: p))
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")

        let msgs = messages.map { ["role": $0.role, "content": $0.content] }
        var body: [String: Any]
        switch p.kind {
        case .anthropic:
            req.setValue(p.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("Bearer \(p.apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": maxTokens, "messages": msgs, "stream": stream]
            if !system.isEmpty { body["system"] = system }
        case .openaiChat:
            req.setValue("Bearer \(p.apiKey)", forHTTPHeaderField: "Authorization")
            var all: [[String: String]] = []
            if !system.isEmpty { all.append(["role": "system", "content": system]) }
            all += msgs
            body = ["model": model, "messages": all, "stream": stream]
        case .openaiResponses:
            req.setValue("Bearer \(p.apiKey)", forHTTPHeaderField: "Authorization")
            body = ["model": model, "input": msgs, "stream": stream, "store": false]
            if !system.isEmpty { body["instructions"] = system }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func stream(provider: AIProvider, model: String, system: String,
                       messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let req = try request(provider: provider, model: model, system: system, messages: messages)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 200

                    if !(200..<300).contains(status) {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line + "\n"
                            if body.count > 6000 { break }
                        }
                        throw LLMError.http(status, errorText(fromBody: body))
                    }

                    var yielded = false
                    var raw = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else {
                            if !line.hasPrefix("event:") && !line.hasPrefix(":") && raw.count < 2_000_000 { raw += line + "\n" }
                            continue
                        }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let d = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                        if let err = streamError(obj) { throw LLMError.api(err) }
                        if let t = delta(obj, kind: provider.kind), !t.isEmpty {
                            yielded = true
                            cont.yield(t)
                        }
                        let type = obj["type"] as? String
                        if type == "message_stop" || type == "response.completed" { break }
                    }

                    // Some gateways ignore `stream: true` and answer with plain JSON.
                    if !yielded {
                        if let d = raw.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                            if let err = streamError(obj) { throw LLMError.api(err) }
                            if let t = fullText(obj), !t.isEmpty { cont.yield(t); yielded = true }
                        }
                        if !yielded { throw LLMError.empty }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Quick connectivity check; returns the first bit of the reply.
    static func test(provider: AIProvider, model: String) async throws -> String {
        var out = ""
        for try await chunk in stream(provider: provider, model: model, system: "",
                                      messages: [LLMMessage(role: "user", content: "回复“你好”两个字即可。")]) {
            out += chunk
            if out.count > 40 { break }
        }
        return out
    }

    // MARK: Parsing

    private static func delta(_ o: [String: Any], kind: APIKind) -> String? {
        switch kind {
        case .anthropic:
            if o["type"] as? String == "content_block_delta", let d = o["delta"] as? [String: Any] {
                return d["text"] as? String
            }
            return nil
        case .openaiChat:
            if let choices = o["choices"] as? [[String: Any]], let first = choices.first {
                if let d = first["delta"] as? [String: Any] { return d["content"] as? String }
                if let m = first["message"] as? [String: Any] { return m["content"] as? String }
            }
            return nil
        case .openaiResponses:
            if o["type"] as? String == "response.output_text.delta" { return o["delta"] as? String }
            return nil
        }
    }

    private static func fullText(_ o: [String: Any]) -> String? {
        if let content = o["content"] as? [[String: Any]] {
            return content.compactMap { $0["text"] as? String }.joined()
        }
        if let choices = o["choices"] as? [[String: Any]], let m = choices.first?["message"] as? [String: Any] {
            return m["content"] as? String
        }
        if let s = o["output_text"] as? String { return s }
        if let output = o["output"] as? [[String: Any]] {
            return output.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }

    private static func streamError(_ o: [String: Any]) -> String? {
        if let e = o["error"] as? [String: Any] { return (e["message"] as? String) ?? "\(e)" }
        if let e = o["error"] as? String { return e }
        if o["type"] as? String == "response.failed",
           let r = o["response"] as? [String: Any], let e = r["error"] as? [String: Any] {
            return (e["message"] as? String) ?? "请求失败"
        }
        return nil
    }

    private static func errorText(fromBody body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = trimmed.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let e = streamError(o) { return e }
            if let m = o["message"] as? String { return m }
        }
        return String(trimmed.prefix(300))
    }
}
