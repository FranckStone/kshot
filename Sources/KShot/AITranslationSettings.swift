import SwiftUI

@MainActor
final class AITranslationSettings: ObservableObject {
    @Published var provider = Settings.translationProvider {
        didSet { if provider != oldValue { load() } }
    }
    @Published var baseURL = ""
    @Published var model = ""
    @Published var apiKey = ""
    @Published private(set) var models: [String] = []
    @Published private(set) var working = false
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?

    init() { load() }

    func reloadSavedConfiguration() {
        let saved = Settings.translationProvider
        if provider != saved { provider = saved }
        else { load() }
    }

    private func load() {
        task?.cancel()
        working = false
        message = nil
        models = []
        baseURL = Settings.aiTranslationURL(for: provider)
        model = Settings.aiTranslationModel(for: provider)
        apiKey = ""
        if provider == .deepseek {
            do { apiKey = try TranslationCredentials.read() }
            catch { message = error.localizedDescription }
        }
    }

    var configuration: AITranslationConfiguration {
        AITranslationConfiguration(provider: provider, baseURL: baseURL, model: model, apiKey: apiKey)
    }

    func save() {
        do {
            if provider != .system { try configuration.validate() }
            if provider == .deepseek { try TranslationCredentials.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines)) }
            Settings.saveAITranslation(provider: provider, url: baseURL, model: model)
            message = "已保存并启用 \(provider.title)，下次翻译立即生效"
        } catch { message = error.localizedDescription }
    }

    func testConnection() {
        guard !working else { return }
        let configuration = configuration
        working = true
        message = "正在发送示例 Hello，首次加载本地模型可能需要一些时间…"
        task = Task {
            do {
                let result = try await AITranslator().translate("Hello", source: TargetLanguage.all[2], target: TargetLanguage.all[0], configuration: configuration)
                guard !Task.isCancelled else { return }
                message = "连接成功，测试译文：\(result.text.prefix(120))。点击“保存并启用”使用此配置。"
            } catch {
                guard !Task.isCancelled else { return }
                message = "连接失败：\(error.localizedDescription)"
            }
            working = false
        }
    }

    func refreshModels() {
        guard !working, provider == .ollama else { return }
        let configuration = configuration
        working = true
        message = "正在读取 Ollama 模型…"
        task = Task {
            do {
                let available = try await AITranslator().models(configuration: configuration)
                guard !Task.isCancelled else { return }
                models = available
                message = available.isEmpty ? "服务已连接，尚未安装模型。请先在 Ollama 中下载模型。" : "已读取 \(available.count) 个模型，请选择后保存配置"
            } catch {
                guard !Task.isCancelled else { return }
                message = "读取模型失败：\(error.localizedDescription)"
            }
            working = false
        }
    }

    func cancel() {
        task?.cancel()
        working = false
        message = "已取消"
    }
}
