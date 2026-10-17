import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// 翻译目标语言
struct TargetLanguage: Hashable {
    let title: String
    let identifier: String

    init(title: String, identifier: String) {
        self.title = title
        self.identifier = Self.canonicalIdentifier(identifier)
    }

    // NaturalLanguage 和 Translation 会分别返回 en / en-US、zh-Hant / zh-TW。
    // 地区不同不应额外增加语言选项，也不应触发同语言翻译。
    private static func canonicalIdentifier(_ identifier: String) -> String {
        let language = Locale.Language(identifier: identifier)
        guard let code = language.languageCode?.identifier else { return identifier }
        if code == "zh" { return language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans" }
        let script = language.script.map { "-\($0.identifier)" } ?? ""
        return Locale.Language(identifier: code + script).minimalIdentifier
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identifier == rhs.identifier }
    func hash(into hasher: inout Hasher) { hasher.combine(identifier) }

    static let all: [TargetLanguage] = [
        .init(title: "中文", identifier: "zh-Hans"),
        .init(title: "繁體中文", identifier: "zh-Hant"),
        .init(title: "English", identifier: "en"),
        .init(title: "日本語", identifier: "ja"),
        .init(title: "한국어", identifier: "ko"),
        .init(title: "Français", identifier: "fr"),
        .init(title: "Deutsch", identifier: "de"),
        .init(title: "Español", identifier: "es"),
    ]

    /// 中文译英，其他译中
    static func guess(for text: String) -> TargetLanguage {
        let source = TranslationLanguageDetector.detect(text)
        return source?.identifier.hasPrefix("zh") == true ? all[2] : all[0]
    }

    static func defaultTarget(for text: String) -> TargetLanguage {
        Settings.translationTarget ?? guess(for: text)
    }

    static func source(identifier: String) -> TargetLanguage {
        let identifier = canonicalIdentifier(identifier)
        if let known = all.first(where: { $0.identifier == identifier }) { return known }
        return TargetLanguage(title: Locale(identifier: "zh_CN").localizedString(forLanguageCode: identifier) ?? identifier,
                              identifier: identifier)
    }
}

enum TranslationAvailability {
    case installed, supported, unsupported
}

struct TranslationOutput {
    let text: String
    let sourceLanguages: [TargetLanguage]
    let didTranslate: Bool
    var provider: TranslationProvider = .system
}

enum TranslatorError: LocalizedError {
    case unavailable, sourceLanguageRequired, incompleteResponse, unsupportedSource(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "翻译需要 macOS 15 或更高版本"
        case .sourceLanguageRequired: return "无法自动识别原文语言，请在原文顶部选择语言后重试"
        case .incompleteResponse: return "译文不完整，请重试"
        case .unsupportedSource(let title): return "当前系统不支持将\(title)翻译为所选语言"
        }
    }
}

/// 基于系统 Translation 框架的翻译器。需要把 hostView 加进某个窗口后才能工作（语言包下载提示会挂在该窗口上）。
@MainActor
final class Translator {
    let hostView: NSView
    fileprivate var impl: AnyObject?
    private var activeTask: Task<Void, Never>?
    private let aiTranslator: AITranslator

    static var isAvailable: Bool {
        Settings.translationProvider != .system || isSystemAvailable
    }

    static var isSystemAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    init(aiTranslator: AITranslator = AITranslator()) {
        self.aiTranslator = aiTranslator
        if #available(macOS 15.0, *) {
            let model = TranslatorModel()
            let host = NSHostingView(rootView: TranslatorHostView(model: model))
            host.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            hostView = host
            impl = model
        } else {
            hostView = NSView(frame: .zero)
        }
    }

    func translate(_ text: String, from source: TargetLanguage? = nil, to target: TargetLanguage,
                   using engine: TranslationEngineSelection? = nil,
                   excluding excludedTexts: [String] = [],
                   onUpdate: (@MainActor (String) -> Void)? = nil,
                   completion: @escaping (Result<TranslationOutput, Error>) -> Void) {
        activeTask?.cancel()
        let engine = engine ?? .saved
        let provider = engine.provider
        if provider != .system {
            let configuration = Result { try engine.configuration() }
            activeTask = Task { @MainActor in
                do {
                    let configuration = try configuration.get()
                    let output = try await aiTranslator.translate(text, source: source, target: target,
                        excluding: excludedTexts, configuration: configuration, onUpdate: { text in
                            guard !Task.isCancelled else { return }
                            onUpdate?(text)
                        })
                    try Task.checkCancellation()
                    completion(.success(output))
                } catch {
                    guard !Task.isCancelled else { return }
                    completion(.failure(error))
                }
            }
            return
        }
        guard #available(macOS 15.0, *), let model = impl as? TranslatorModel else {
            completion(.failure(TranslatorError.unavailable))
            return
        }
        activeTask = Task { @MainActor in
            do {
                let plan = try TranslationPlan(text: text, source: source, excludedTexts: excludedTexts)
                var output = plan.parts.map(\.text)
                let languages = plan.languages.filter { $0 != target }
                for language in languages {
                    try Task.checkCancellation()
                    let indices = plan.parts.indices.filter { plan.parts[$0].source == language }
                    if language.identifier.hasPrefix("zh"), target.identifier.hasPrefix("zh") {
                        let transform = StringTransform(target.identifier == "zh-Hant" ? "Simplified-Traditional" : "Traditional-Simplified")
                        for index in indices {
                            guard let converted = plan.parts[index].text.applyingTransform(transform, reverse: false) else {
                                throw TranslatorError.incompleteResponse
                            }
                            output[index] = converted
                        }
                        continue
                    }
                    guard await Translator.availability(from: language, to: target) != .unsupported else {
                        throw TranslatorError.unsupportedSource(language.title)
                    }
                    try Task.checkCancellation()
                    let layouts = indices.map { TranslationTextLayout(plan.parts[$0].text) }
                    let values = try await model.translateBatch(layouts.map(\.content), source: language, target: target)
                    guard values.count == indices.count else { throw TranslatorError.incompleteResponse }
                    for (position, index) in indices.enumerated() { output[index] = layouts[position].render(values[position]) }
                }
                try Task.checkCancellation()
                completion(.success(TranslationOutput(text: output.joined(), sourceLanguages: plan.languages, didTranslate: !languages.isEmpty)))
            } catch {
                guard !Task.isCancelled else { return }
                completion(.failure(error))
            }
        }
    }

    func cancel() { activeTask?.cancel() }

    static func supportedSourceLanguages() async -> [TargetLanguage] {
        guard #available(macOS 15.0, *) else { return TargetLanguage.all }
        let languages = await LanguageAvailability().supportedLanguages
        var result = TargetLanguage.all
        for language in languages {
            let item = TargetLanguage.source(identifier: language.minimalIdentifier)
            if !result.contains(where: { $0.identifier == item.identifier }) { result.append(item) }
        }
        return result
    }

    static func availability(from source: TargetLanguage, to target: TargetLanguage) async -> TranslationAvailability {
        guard #available(macOS 15.0, *), source != target else { return .unsupported }
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source.identifier),
            to: Locale.Language(identifier: target.identifier))
        switch status {
        case .installed: return .installed
        case .supported: return .supported
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    func prepare(from source: TargetLanguage, to target: TargetLanguage,
                 completion: @escaping (Result<Void, Error>) -> Void) {
        guard #available(macOS 15.0, *), let model = impl as? TranslatorModel else {
            completion(.failure(TranslatorError.unavailable))
            return
        }
        model.prepare(source: source, target: target, completion: completion)
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
@MainActor
final class TranslatorModel: ObservableObject {
    @Published var config: TranslationSession.Configuration?
    enum Operation {
        case translate(String, (Result<String, Error>) -> Void)
        case batch([String], (Result<[String], Error>) -> Void)
        case prepare((Result<Void, Error>) -> Void)
    }
    var operation: Operation?

    func start(text: String, source: TargetLanguage?, target: TargetLanguage, completion: @escaping (Result<String, Error>) -> Void) {
        operation = .translate(text, completion)
        configure(source: source.map { Locale.Language(identifier: $0.identifier) }, target: target)
    }

    func translateBatch(_ texts: [String], source: TargetLanguage, target: TargetLanguage) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            operation = .batch(texts, { continuation.resume(with: $0) })
            configure(source: Locale.Language(identifier: source.identifier), target: target)
        }
    }

    func prepare(source: TargetLanguage, target: TargetLanguage, completion: @escaping (Result<Void, Error>) -> Void) {
        Log.info("translation prepare requested: \(source.identifier) -> \(target.identifier)")
        operation = .prepare(completion)
        configure(source: Locale.Language(identifier: source.identifier), target: target)
    }

    private func configure(source: Locale.Language?, target: TargetLanguage) {
        let targetLang = Locale.Language(identifier: target.identifier)
        if var existing = config, existing.source == source, existing.target == targetLang {
            existing.invalidate()
            config = existing
        } else {
            config = TranslationSession.Configuration(source: source, target: targetLang)
        }
    }
}

@available(macOS 15.0, *)
struct TranslatorHostView: View {
    @ObservedObject var model: TranslatorModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .modifier(TranslatorTaskModifier(model: model))
    }
}

/// SwiftUI 窗口直接把任务挂在自己的视图树中，保持任务和系统弹窗的呈现环境一致。
extension View {
    @MainActor @ViewBuilder
    func translationSession(using translator: Translator) -> some View {
        if #available(macOS 15.0, *), let model = translator.impl as? TranslatorModel {
            modifier(TranslatorTaskModifier(model: model))
        } else {
            self
        }
    }
}

@available(macOS 15.0, *)
private struct TranslatorTaskModifier: ViewModifier {
    @ObservedObject var model: TranslatorModel

    func body(content: Content) -> some View {
        content
            .translationTask(model.config) { session in
                // 在挂起前保存本次操作，避免后续请求覆盖回调。
                switch model.operation {
                case .translate(let text, let completion):
                    do {
                        let response = try await session.translate(text)
                        completion(.success(response.targetText))
                    } catch TranslationError.unableToIdentifyLanguage {
                        completion(.failure(TranslatorError.sourceLanguageRequired))
                    } catch {
                        completion(.failure(error))
                    }
                case .prepare(let completion):
                    Log.info("translation prepare: system session started")
                    do {
                        try await session.prepareTranslation()
                        Log.info("translation prepare: system request completed")
                        completion(.success(()))
                    } catch {
                        Log.info("translation prepare failed: \(error)")
                        completion(.failure(error))
                    }
                case .batch(let texts, let completion):
                    do {
                        let requests = texts.enumerated().map {
                            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                        }
                        let responses = try await session.translations(from: requests)
                        var ordered = [String?](repeating: nil, count: texts.count)
                        for response in responses {
                            guard let id = response.clientIdentifier, let index = Int(id), ordered.indices.contains(index), ordered[index] == nil else {
                                throw TranslatorError.incompleteResponse
                            }
                            ordered[index] = response.targetText
                        }
                        guard ordered.allSatisfy({ $0 != nil }) else { throw TranslatorError.incompleteResponse }
                        completion(.success(ordered.compactMap { $0 }))
                    } catch TranslationError.unableToIdentifyLanguage {
                        completion(.failure(TranslatorError.sourceLanguageRequired))
                    } catch {
                        completion(.failure(error))
                    }
                case nil: break
                }
            }
    }
}
#endif
