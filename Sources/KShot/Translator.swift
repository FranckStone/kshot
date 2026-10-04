import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// 翻译目标语言
struct TargetLanguage: Hashable {
    let title: String
    let identifier: String

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
        let hasCJK = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        return hasCJK ? all[2] : all[0]
    }
}

enum TranslatorError: LocalizedError {
    case unavailable
    var errorDescription: String? { "翻译需要 macOS 15 或更高版本" }
}

/// 基于系统 Translation 框架的翻译器。需要把 hostView 加进某个窗口后才能工作（语言包下载提示会挂在该窗口上）。
@MainActor
final class Translator {
    let hostView: NSView
    private var impl: AnyObject?

    static var isAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    init() {
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

    func translate(_ text: String, to target: TargetLanguage, completion: @escaping (Result<String, Error>) -> Void) {
        guard #available(macOS 15.0, *), let model = impl as? TranslatorModel else {
            completion(.failure(TranslatorError.unavailable))
            return
        }
        model.start(text: text, target: target, completion: completion)
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
@MainActor
final class TranslatorModel: ObservableObject {
    @Published var config: TranslationSession.Configuration?
    var text = ""
    var completion: ((Result<String, Error>) -> Void)?

    func start(text: String, target: TargetLanguage, completion: @escaping (Result<String, Error>) -> Void) {
        self.text = text
        self.completion = completion
        let targetLang = Locale.Language(identifier: target.identifier)
        if var existing = config, existing.target == targetLang {
            existing.invalidate()
            config = existing
        } else {
            config = TranslationSession.Configuration(source: nil, target: targetLang)
        }
    }
}

@available(macOS 15.0, *)
struct TranslatorHostView: View {
    @ObservedObject var model: TranslatorModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(model.config) { session in
                let text = model.text
                do {
                    let response = try await session.translate(text)
                    model.completion?(.success(response.targetText))
                } catch {
                    model.completion?(.failure(error))
                }
            }
    }
}
#endif
