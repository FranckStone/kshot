import Foundation

/// 由程序保留原文排版，模型只负责单行正文。
struct TranslationTextLayout {
    private static let segments = try! NSRegularExpression(pattern: #"[^\r\n\u000B\u000C\u0085\u2028\u2029]+|\r\n|[\r\n\u000B\u000C\u0085\u2028\u2029]"#)
    private static let markers = try! NSRegularExpression(pattern: #"^(?:(?:>+[ \t]+)|(?:#{1,6}[ \t]+)|(?:[-+*•▪◦‣–—][ \t]+(?:\[[ xX]\][ \t]+)?)|(?:[0-9]+[.)、](?![0-9])[ \t]*)|(?:[（(][0-9一二三四五六七八九十百]+[)）][ \t]*)|(?:[一二三四五六七八九十百]+[、.][ \t]*)|(?:[A-Za-z][.)][ \t]+))+"#)

    static func split(_ text: String) -> [String] {
        segments.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            (text as NSString).substring(with: $0.range)
        }
    }

    let original: String
    let prefix: String
    let content: String
    let suffix: String
    let isLiteral: Bool
    private let hasMarker: Bool

    init(_ text: String) {
        original = text
        let leading = String(text.prefix(while: \.isWhitespace))
        let rest = String(text.dropFirst(leading.count))
        let trailing = String(rest.reversed().prefix(while: \.isWhitespace).reversed())
        let body = String(rest.dropLast(trailing.count))
        let marker = Self.markers.firstMatch(in: body, range: NSRange(body.startIndex..., in: body))
        let markerLength = marker?.range.length ?? 0
        let literalMarker = (body as NSString).substring(to: markerLength)
        prefix = leading + literalMarker
        content = (body as NSString).substring(from: markerLength)
        suffix = trailing
        hasMarker = markerLength > 0
        isLiteral = content.isEmpty || content.hasPrefix("```") || content.hasPrefix("~~~")
    }

    /// 模型额外输出的换行不能改变这一原文行的边界。
    func translatedContent(_ value: String) -> String {
        let line = value.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if hasMarker, let marker = Self.markers.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            return (line as NSString).substring(from: marker.range.length)
        }
        return line
    }

    func render(_ translation: String) -> String { prefix + translatedContent(translation) + suffix }
}
