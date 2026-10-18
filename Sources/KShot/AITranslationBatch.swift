import Foundation

/// 布局始终由客户端持有；请求只包含需要翻译的正文及块内编号。
struct AITranslationBatch {
    struct Part {
        let layout: TranslationTextLayout
        let needsTranslation: Bool
    }

    let parts: [Part]
    let chunks: [[Int]]

    init(lines: [(text: String, protected: Bool)], maxLines: Int = 32, maxBytes: Int = 6_000) {
        precondition(maxLines > 0 && maxBytes > 0)
        parts = lines.map { line in
            let layout = TranslationTextLayout(line.text)
            return Part(layout: layout, needsTranslation: !line.protected && !layout.isLiteral
                && !TranslationLanguageDetector.sample(layout.content).isEmpty)
        }
        var chunks: [[Int]] = []
        var chunk: [Int] = []
        var bytes = 0
        for index in parts.indices where parts[index].needsTranslation {
            let size = parts[index].layout.content.utf8.count
            if !chunk.isEmpty && (chunk.count >= maxLines || bytes + size > maxBytes) {
                chunks.append(chunk)
                chunk = []
                bytes = 0
            }
            // 单行不拆分，防止切断句子；超长行单独请求。
            chunk.append(index)
            bytes += size
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        self.chunks = chunks
    }

    func input(for indices: [Int]) throws -> String {
        let records = indices.enumerated().map { AITranslationRecord(id: $0.offset, text: parts[$0.element].layout.content) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try records.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n")
    }

    /// 仅展示连续完成的前缀及当前行正文，未完成的行不提前添加尾部空格或下一行。
    func render(_ translations: [Int: String], partial: (index: Int, text: String)? = nil) -> String {
        var output = ""
        for index in parts.indices {
            let part = parts[index]
            if !part.needsTranslation { output += part.layout.original }
            else if let translation = translations[index] { output += part.layout.render(translation) }
            else {
                if let partial, partial.index == index, !partial.text.isEmpty {
                    output += part.layout.prefix + part.layout.translatedContent(partial.text)
                }
                break
            }
        }
        return output
    }
}

struct AITranslationRecord: Codable {
    let id: Int
    let text: String
}

/// JSON Lines 允许完整行立即还原，当前 JSON 字符串尚未闭合时也能展示正文。
struct AITranslationBatchResponse {
    enum FormatError: Error { case invalidRecords }
    let translations: [String]
    let partial: String?

    private static let textPrefix = try! NSRegularExpression(pattern: #"^\s*\{\s*"id"\s*:\s*([0-9]+)\s*,\s*"text"\s*:\s*(".*)$"#)

    init(_ text: String, count: Int, finished: Bool = false) throws {
        var lines = text.components(separatedBy: "\n")
        let pending = finished ? "" : lines.removeLast()
        var translations: [String] = []
        for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let record = Self.record(line), record.id == translations.count, record.id < count else {
                throw FormatError.invalidRecords
            }
            translations.append(record.text)
        }
        var partial: String?
        if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let record = Self.record(pending), record.id == translations.count, record.id < count {
                translations.append(record.text)
            } else if translations.count < count {
                partial = Self.partialText(pending, id: translations.count)
            }
        }
        if finished && translations.count != count { throw FormatError.invalidRecords }
        self.translations = translations
        self.partial = partial
    }

    private static func record(_ line: String) -> AITranslationRecord? {
        guard let record = try? JSONDecoder().decode(AITranslationRecord.self, from: Data(line.utf8)),
              !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return record
    }

    private static func partialText(_ line: String, id: Int) -> String? {
        guard let match = textPrefix.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              Int((line as NSString).substring(with: match.range(at: 1))) == id else { return nil }
        let value = (line as NSString).substring(with: match.range(at: 2))
        var escaped = false
        for index in value.indices.dropFirst() {
            let character = value[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" {
                return try? JSONDecoder().decode(String.self, from: Data(value[...index].utf8))
            }
        }
        // 网络分片可能停在转义符、\uXXXX 或 UTF-16 代理对中间。
        // 最多回退一个代理对的 12 个 ASCII 字符，绝不展示未解码的 JSON。
        var prefix = value
        for _ in 0...12 {
            if let text = try? JSONDecoder().decode(String.self, from: Data((prefix + "\"").utf8)) { return text }
            guard prefix.count > 1 else { break }
            prefix.removeLast()
        }
        return nil
    }
}
