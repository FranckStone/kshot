import Foundation
import NaturalLanguage

/// 只清理检测样本，不修改待翻译原文；避免网址、邮箱、密钥和编号主导语言判断。
enum TranslationLanguageDetector {
    private static let noise = [
        #"(?i)\b(?:https?://|www\.)[^\s<>，。！？、；：“”‘’（）【】]+"#,
        #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
        #"\b(?:sk-|ghp_|github_pat_|AKIA)[A-Za-z0-9_-]+\b"#,
        #"\b(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{6,}\b"#,
        #"\b[A-Fa-f0-9]{12,}\b"#,
        #"[0-9]+(?:[./:_-][0-9]+)*"#
    ].map { try! NSRegularExpression(pattern: $0) }

    // 极短界面词缺少统计上下文（例如系统会把 Hi 判成加泰罗尼亚语），只为明确的常用词兜底。
    private static let englishUIWords: Set<String> = [
        "hi", "hello", "ok", "yes", "no", "save", "cancel", "copy", "paste", "cut", "undo", "redo",
        "open", "close", "edit", "view", "file", "help", "search", "settings", "install", "update",
        "download", "upload", "delete", "retry", "done", "next", "back", "continue", "start", "stop",
        "on", "off", "login", "logout", "sign in", "sign out", "new", "error", "warning", "success",
        "loading", "translate", "translation", "language", "auto", "text", "image", "screen", "capture",
        "ui", "api", "api key", "ocr", "url", "id"
    ]
    // 这些拼写也用于其他语言，存在上下文时不能一律判成英语。
    private static let sharedUIWords: Set<String> = ["no", "on", "file", "continue", "auto", "image", "capture", "stop"]

    static func sample(_ text: String) -> String {
        var value = text
        for regex in noise {
            value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: " ")
        }
        return value.unicodeScalars.map { CharacterSet.letters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) ? String($0) : " " }
            .joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// AI 翻译前只保留证据充分的目标语言行；不确定的短词仍交给模型判断。
    static func confidentlyMatches(_ text: String, language: TargetLanguage) -> Bool {
        let clean = sample(text)
        guard clean.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 4 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(clean)
        let ranked = recognizer.languageHypotheses(withMaximum: 2).sorted { $0.value > $1.value }
        guard let first = ranked.first, first.value >= 0.95,
              first.value - (ranked.dropFirst().first?.value ?? 0) >= 0.80 else { return false }
        return TargetLanguage.source(identifier: first.key.rawValue) == language
    }

    static func detect(_ text: String, context: TargetLanguage? = nil) -> TargetLanguage? {
        let clean = sample(text)
        guard !clean.isEmpty else { return nil }
        let word = clean.lowercased()
        if englishUIWords.contains(word), !sharedUIWords.contains(word) { return language("en") }
        let scalars = clean.unicodeScalars
        let kana = scalars.filter { (0x3040...0x30FF).contains($0.value) }.count
        let hangul = scalars.filter { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }.count
        let han = scalars.filter { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x2FA1F).contains($0.value) }.count
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        if kana > 0, kana * 10 >= letters { return language("ja") }
        if hangul > 0, hangul * 10 >= letters { return language("ko") }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(clean)
        let ranked = recognizer.languageHypotheses(withMaximum: 2).sorted { $0.value > $1.value }
        if let context, isCompatible(context, with: clean), letters <= 24,
           clean.split(separator: " ").count <= 3 {
            // 日语的“名前 / 設定 / 確認”单独检测常被判为中文，优先参考附近完整句子。
            if context.identifier == "ja", han == letters, letters <= 8,
               (ranked.first?.value ?? 0) < 0.90 { return context }
            if han == 0, kana == 0, hangul == 0,
               sharedUIWords.contains(word) || (ranked.first?.value ?? 0) < 0.90 {
                return context
            }
        }
        if englishUIWords.contains(word) { return language("en") }
        if han > 0, han * 3 >= letters, kana == 0, hangul == 0 {
            // 纯汉字的短标签也可能是日语；明确的日语证据优先，不能确定时不强行猜中文。
            if let first = ranked.first, first.key == .japanese { return first.value >= 0.75 ? language("ja") : nil }
            // 你好等两种字形相同的短词统一按简体处理，避免凭统计结果额外请求繁体语言包。
            let simplified = clean.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false)
            return language(simplified != nil && simplified != clean ? "zh-Hant" : "zh-Hans")
        }
        guard let first = ranked.first, first.value >= 0.55,
              first.value - (ranked.dropFirst().first?.value ?? 0) >= 0.20 else { return nil }
        return language(first.key.rawValue)
    }

    /// 文档上下文只能补充相同文字体系的短行，不能把俄文或日文强行当成英语。
    static func isCompatible(_ language: TargetLanguage, with text: String) -> Bool {
        let clean = sample(text)
        guard !clean.isEmpty else { return false }
        if Locale.Language(identifier: language.identifier).script?.identifier == "Latn" {
            return clean.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) || (0x0041...0x024F).contains($0.value) }
        }
        if language.identifier.hasPrefix("zh") || language.identifier == "ja" {
            // 有明确中文 / 日文上下文时，可补足“注文番号”这类仅含汉字的短标签。
            return clean.unicodeScalars.allSatisfy {
                CharacterSet.whitespaces.contains($0) || (0x3400...0x9FFF).contains($0.value)
                    || (language.identifier == "ja" && (0x3040...0x30FF).contains($0.value))
            }
        }
        return detect(clean)?.identifier == language.identifier
    }

    private static func language(_ identifier: String) -> TargetLanguage? {
        identifier == "und" ? nil : TargetLanguage.source(identifier: identifier)
    }
}

/// 保留换行、纯编号和二维码内容；按原文语言分组，翻译时不再依赖系统重新猜语言。
struct TranslationPlan {
    struct Part {
        let text: String
        let source: TargetLanguage?
    }
    let parts: [Part]
    let languages: [TargetLanguage]

    init(text: String, source: TargetLanguage?, excludedTexts: [String] = []) throws {
        let excluded = Set(excludedTexts)
        let lines = text.components(separatedBy: .newlines).filter { !excluded.contains($0.trimmingCharacters(in: .whitespaces)) }
        let context = TranslationLanguageDetector.detect(lines.joined(separator: "\n"))
        let rawParts = TranslationTextLayout.split(text)
        // 先检测完整句子，再给附近相同文字体系的短行补上下文。
        // 混合中英文时，整篇的中文判断不能盖过英文段落中的短标签。
        let anchors: [(index: Int, language: TargetLanguage)] = rawParts.enumerated().compactMap { index, raw in
            guard !excluded.contains(raw.trimmingCharacters(in: .whitespaces)),
                  TranslationLanguageDetector.sample(raw).unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 12,
                  let language = TranslationLanguageDetector.detect(raw) else { return nil }
            return (index, language)
        }
        var parts: [Part] = []
        var languages: [TargetLanguage] = []
        for (index, raw) in rawParts.enumerated() {
            let sample = TranslationLanguageDetector.sample(raw)
            if excluded.contains(raw.trimmingCharacters(in: .whitespaces)) || sample.isEmpty || TranslationTextLayout(raw).isLiteral {
                parts.append(Part(text: raw, source: nil))
                continue
            }
            let nearby = anchors.filter { TranslationLanguageDetector.isCompatible($0.language, with: raw) }
            let distance = nearby.map { abs($0.index - index) }.min()
            let nearestLanguages = Set(nearby.filter { abs($0.index - index) == distance }.map(\.language))
            let localContext = nearestLanguages.count == 1 ? nearestLanguages.first : nil
            var detected = source ?? TranslationLanguageDetector.detect(raw, context: localContext)
            if source == nil, detected == nil, nearestLanguages.count <= 1, let context,
               TranslationLanguageDetector.isCompatible(context, with: raw) {
                detected = context
            }
            guard let detected else { throw TranslatorError.sourceLanguageRequired }
            if !languages.contains(detected) { languages.append(detected) }
            parts.append(Part(text: raw, source: detected))
        }
        self.parts = parts
        self.languages = languages
    }
}
