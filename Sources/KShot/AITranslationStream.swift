import Foundation

/// 自己分行以保留 SSE 的空行边界；UTF-8 字符即使跨网络包也只在整行到齐后解码。
struct AITranslationLines {
    private var buffer = Data()
    private var skipLF = false

    mutating func consume(_ byte: UInt8) throws -> String? {
        if byte == 10, skipLF { skipLF = false; return nil }
        skipLF = byte == 13
        if byte == 10 || byte == 13 { return try takeLine() }
        buffer.append(byte)
        return nil
    }

    mutating func finish() throws -> String? { buffer.isEmpty ? nil : try takeLine() }

    private mutating func takeLine() throws -> String {
        guard let line = String(data: buffer, encoding: .utf8) else { throw AITranslationError.invalidResponse }
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}

/// DeepSeek 使用 SSE，Ollama 使用逐行 JSON。只收集译文，不展示 reasoning / thinking 字段。
struct AITranslationStream {
    let provider: TranslationProvider
    private(set) var text = ""
    private(set) var completed = false
    private var eventData: [String] = []

    /// 返回本次新增的文字；空事件、心跳和结束标记不产生更新。
    mutating func consume(line: String) throws -> String? {
        guard !completed else { return nil }
        if provider == .deepseek {
            if line.isEmpty { return try flushEvent() }
            if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                eventData.append(value)
            }
            return nil
        }
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return try consumeJSON(line)
    }

    mutating func finish() throws -> String {
        if !eventData.isEmpty { _ = try flushEvent() }
        guard completed else { throw AITranslationError.interrupted }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AITranslationError.emptyResponse }
        return text
    }

    private mutating func flushEvent() throws -> String? {
        guard !eventData.isEmpty else { return nil }
        let data = eventData.joined(separator: "\n")
        eventData.removeAll(keepingCapacity: true)
        if data == "[DONE]" {
            completed = true
            return nil
        }
        return try consumeJSON(data)
    }

    private mutating func consumeJSON(_ value: String) throws -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
              json["error"] == nil else { throw AITranslationError.invalidResponse }
        let fragment: String?
        if provider == .deepseek {
            guard let choices = json["choices"] as? [[String: Any]] else { throw AITranslationError.invalidResponse }
            guard let choice = choices.first else { return nil } // usage-only event
            if choice["finish_reason"] as? String == "length" { throw AITranslationError.truncated }
            if let reason = choice["finish_reason"] as? String, reason != "stop" { throw AITranslationError.invalidResponse }
            guard let delta = choice["delta"] as? [String: Any] else { throw AITranslationError.invalidResponse }
            fragment = delta["content"] as? String
        } else {
            guard let done = json["done"] as? Bool else { throw AITranslationError.invalidResponse }
            if json["done_reason"] as? String == "length" { throw AITranslationError.truncated }
            fragment = (json["message"] as? [String: Any])?["content"] as? String
            completed = done
        }
        guard let fragment, !fragment.isEmpty else { return nil }
        text += fragment
        return fragment
    }
}
