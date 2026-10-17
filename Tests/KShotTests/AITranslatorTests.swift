import Foundation
import XCTest
@testable import KShot

private final class TranslationURLProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, [String: Any]))?
    static var streaming: ((TranslationURLProtocol) -> Void)?
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let streaming = Self.streaming { streaming(self); return }
        do {
            let (status, json) = try Self.respond!(request)
            let deepseek = request.url!.path.hasSuffix("/chat/completions")
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": deepseek ? "text/event-stream" : "application/x-ndjson"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if deepseek, let choices = json["choices"] as? [[String: Any]], let choice = choices.first {
                let chunk: [String: Any] = ["choices": [["delta": choice["message"] ?? [:], "finish_reason": choice["finish_reason"] ?? "stop"]]]
                let value = String(data: try JSONSerialization.data(withJSONObject: chunk), encoding: .utf8)!
                client?.urlProtocol(self, didLoad: Data("data: \(value)\n\ndata: [DONE]\n\n".utf8))
            } else {
                client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: json))
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
    func beginStream() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    func send(_ text: String, finish: Bool = false) {
        guard !lock.withLock({ stopped }) else { return }
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
}

final class AITranslatorTests: XCTestCase {
    private func config(_ provider: TranslationProvider = .ollama, url: String? = nil, model: String = "test-model", key: String = "test-key") -> AITranslationConfiguration {
        AITranslationConfiguration(provider: provider, baseURL: url ?? provider.defaultURL, model: model, apiKey: key)
    }

    private func client() -> AITranslator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationURLProtocol.self]
        return AITranslator(session: URLSession(configuration: configuration))
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let value = request.httpBody { data = value }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            var result = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                result.append(contentsOf: buffer.prefix(count))
            }
            data = result
        } else { throw AITranslationError.invalidResponse }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    override func tearDown() { TranslationURLProtocol.respond = nil; TranslationURLProtocol.streaming = nil; super.tearDown() }

    func testEndpointsAcceptBaseOrFullPathsWithoutDuplicatingAPIPath() throws {
        for url in ["http://localhost:11434", "http://localhost:11434/api/", "http://localhost:11434/api/chat"] {
            XCTAssertEqual(try config(url: url).endpoint().path, "/api/chat")
            XCTAssertEqual(try config(url: url).endpoint(models: true).path, "/api/tags")
        }
        XCTAssertEqual(try config(.deepseek, url: "https://api.deepseek.com/v1/").endpoint().path, "/v1/chat/completions")
        XCTAssertEqual(try config(.deepseek, url: "https://api.deepseek.com/chat/completions").endpoint().path, "/chat/completions")
        XCTAssertEqual(try config(url: "https://example.com/ollama").endpoint().path, "/ollama/api/chat")
        XCTAssertEqual(try config(.deepseek, url: "https://api.deepseek.com/v1/chat/completions").endpoint(models: true).path, "/v1/models")
        XCTAssertEqual(try config(.deepseek, url: "https://api.deepseek.com/v1/models").endpoint().path, "/v1/chat/completions")
    }

    func testInvalidConfigurationFailsBeforeNetwork() {
        for url in ["localhost:11434", "file:///tmp/service", "https://user:secret@example.com", "https://example.com?api_key=secret", "https://example.com/#chat"] {
            XCTAssertThrowsError(try config(url: url).validate(), url)
        }
        XCTAssertThrowsError(try config(.deepseek, url: "http://api.deepseek.com").validate())
        XCTAssertThrowsError(try config(.deepseek, key: " ").validate())
        XCTAssertThrowsError(try config(model: " ").validate())
    }

    func testDeepSeekRequestAndResponseUseChatCompletionProtocol() async throws {
        TranslationURLProtocol.respond = { request in
            XCTAssertEqual(request.url?.path, "/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try self.body(request)
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertEqual(body["model"] as? String, "test-model")
            XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertTrue(messages[0]["content"]!.contains("Identify the source language yourself"))
            let input = try XCTUnwrap(messages[1]["content"])
            XCTAssertTrue(["QXJZ", "Hello"].contains(input))
            return (200, ["choices": [["message": ["content": input == "Hello" ? "你好" : input], "finish_reason": "stop"]]])
        }
        let output = try await client().translate("QXJZ\nHello", source: nil, target: TargetLanguage.all[0], configuration: config(.deepseek))
        XCTAssertEqual(output.text, "QXJZ\n你好")
        XCTAssertEqual(output.provider, .deepseek)
        XCTAssertTrue(output.didTranslate)
        XCTAssertTrue(output.sourceLanguages.isEmpty)
    }

    func testOllamaPreservesProtectedQRPayloadAndUsesExplicitSourceHint() async throws {
        TranslationURLProtocol.respond = { request in
            XCTAssertEqual(request.url?.path, "/api/chat")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try self.body(request)
            XCTAssertEqual(body["think"] as? Bool, false)
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertTrue(messages[0]["content"]!.contains("The source language is English (en)"))
            let input = try XCTUnwrap(messages[1]["content"])
            XCTAssertFalse(input.contains("qr-private-payload"))
            return (200, ["done": true, "message": ["content": input.replacingOccurrences(of: "Hello", with: "你好")]])
        }
        let text = "Hello\r\nqr-private-payload\nqr-private-payload"
        let output = try await client().translate(text, source: TargetLanguage.all[2], target: TargetLanguage.all[0], excluding: ["qr-private-payload"], configuration: config())
        XCTAssertEqual(output.text, "你好\r\nqr-private-payload\nqr-private-payload")
        XCTAssertEqual(output.sourceLanguages, [TargetLanguage.all[2]])
    }

    func testQRCodeOnlyNeverCallsTheAIService() async throws {
        TranslationURLProtocol.respond = { _ in
            XCTFail("Protected content must not be sent")
            return (200, [:])
        }
        let output = try await client().translate("qr-private-payload", source: nil, target: TargetLanguage.all[0], excluding: ["qr-private-payload"], configuration: config())
        XCTAssertEqual(output.text, "qr-private-payload")
        XCTAssertFalse(output.didTranslate)
    }

    func testTargetLanguageLinesArePreservedEvenWhenModelOnlyReturnsForeignTextTranslation() async throws {
        TranslationURLProtocol.respond = { request in
            let messages = try XCTUnwrap(self.body(request)["messages"] as? [[String: String]])
            XCTAssertEqual(messages[1]["content"], "Hello, please restart the application.")
            return (200, ["done": true, "message": ["content": "你好，请重新启动应用程序。"]])
        }
        let output = try await client().translate("Hello, please restart the application.\r\n这是原文中的中文。\nhttps://example.com", source: nil, target: TargetLanguage.all[0], configuration: config())
        XCTAssertEqual(output.text, "你好，请重新启动应用程序。\r\n这是原文中的中文。\nhttps://example.com")
    }

    @MainActor
    func testFormattingIsPreservedWhenModelAddsLineBreaksOrListMarkers() async throws {
        var inputs: [String] = []
        var updates: [String] = []
        TranslationURLProtocol.respond = { request in
            let messages = try XCTUnwrap(self.body(request)["messages"] as? [[String: String]])
            let input = try XCTUnwrap(messages[1]["content"])
            inputs.append(input)
            let values = ["Hello": "\n你好\n世界\n", "Open": "- 打开\n窗口", "Save": "# 保存"]
            let output = try XCTUnwrap(values[input])
            return (200, ["done": true, "message": ["content": output]])
        }
        let text = "\t1.  Hello  \r\n \t\r\n  - [x] Open\t\n# Save\rhttps://example.com\u{2028}123-456\n"
        let output = try await client().translate(text, source: TargetLanguage.all[2], target: TargetLanguage.all[0], configuration: config(), onUpdate: { updates.append($0) })
        XCTAssertEqual(inputs, ["Hello", "Open", "Save"])
        let expected = "\t1.  你好 世界  \r\n \t\r\n  - [x] 打开 窗口\t\n# 保存\rhttps://example.com\u{2028}123-456\n"
        XCTAssertEqual(output.text, expected)
        XCTAssertEqual(updates.last, expected)
        for update in updates {
            XCTAssertTrue(expected.hasPrefix(update), "Unexpected layout in streaming text: \(update.debugDescription)")
        }
    }

    func testAutomaticMixedTextKeepsBlankLinesAndProtectedMultilinePayload() async throws {
        TranslationURLProtocol.respond = { request in
            let messages = try XCTUnwrap(self.body(request)["messages"] as? [[String: String]])
            XCTAssertEqual(messages[1]["content"], "Hello")
            return (200, ["done": true, "message": ["content": "你好"]])
        }
        let payload = "QR-LINE\r\nQR-SECOND"
        let text = "这是已经翻译成中文的内容。\r\n\r\nHello\n\n" + payload + "\n"
        let output = try await client().translate(text, source: nil, target: TargetLanguage.all[0], excluding: [payload], configuration: config())
        XCTAssertEqual(output.text, "这是已经翻译成中文的内容。\r\n\r\n你好\n\n" + payload + "\n")
    }

    func testAuthenticationErrorsEmptyAndTruncatedResponsesDoNotBecomeTranslations() async throws {
        TranslationURLProtocol.respond = { _ in (401, ["error": "secret server message"]) }
        do {
            _ = try await client().translate("Hello", source: nil, target: TargetLanguage.all[0], configuration: config(.deepseek))
            XCTFail("Expected authentication error")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("secret"))
            XCTAssertTrue(error.localizedDescription.contains("认证失败"))
        }
        for json: [String: Any] in [
            ["choices": [["message": ["content": ""], "finish_reason": "stop"]]],
            ["choices": [["message": ["content": "partial"], "finish_reason": "length"]]],
            ["error": "bad model"]
        ] {
            TranslationURLProtocol.respond = { _ in (200, json) }
            do {
                _ = try await client().translate("Hello", source: nil, target: TargetLanguage.all[0], configuration: config(.deepseek))
                XCTFail("Expected invalid or incomplete response error")
            } catch { XCTAssertTrue(error is AITranslationError) }
        }
    }

    func testOllamaModelsAreFetchedWithoutNeedingAModelName() async throws {
        TranslationURLProtocol.respond = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/tags")
            return (200, ["models": [["name": "model-b"], ["name": "model-a"], ["name": "model-b"]]])
        }
        let models = try await client().models(configuration: config(model: ""))
        XCTAssertEqual(models, ["model-a", "model-b"])
    }

    func testDeepSeekModelsUseAuthenticatedListEndpoint() async throws {
        TranslationURLProtocol.respond = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            return (200, ["data": [["id": "model-b"], ["id": "model-a"], ["id": "model-b"]]])
        }
        let models = try await client().models(configuration: config(.deepseek, url: "https://api.deepseek.com/v1", model: ""))
        XCTAssertEqual(models, ["model-a", "model-b"])
    }

    @MainActor
    func testWindowEngineAndModelOverrideAnotherWindowsDefault() async throws {
        let keys = ["translationProvider", "translation.ollama.url", "translation.ollama.model"]
        let defaults = UserDefaults.standard
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        Settings.saveAITranslation(provider: .ollama, url: "http://localhost:11434", model: "another-windows-model")
        Settings.translationProvider = .system
        TranslationURLProtocol.respond = { request in
            XCTAssertEqual(request.url?.path, "/api/chat")
            XCTAssertEqual(try self.body(request)["model"] as? String, "this-windows-model")
            return (200, ["done": true, "message": ["content": "你好"]])
        }
        let translator = Translator(aiTranslator: client())
        let result: Result<TranslationOutput, Error> = await withCheckedContinuation { continuation in
            translator.translate("Hello", to: TargetLanguage.all[0],
                                 using: TranslationEngineSelection(provider: .ollama, model: "this-windows-model")) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(try result.get().text, "你好")
        XCTAssertEqual(try result.get().provider, .ollama)
        XCTAssertEqual(Settings.translationProvider, .system)
    }

    @MainActor
    func testTextIsDeliveredWhileTheHTTPResponseIsStillOpen() async throws {
        var responseFinished = false
        var earlyText: String?
        TranslationURLProtocol.streaming = { connection in
            DispatchQueue.main.async {
                connection.beginStream()
                connection.send("{\"message\":{\"content\":\"你\"},\"done\":false}\n")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    responseFinished = true
                    connection.send("{\"message\":{\"content\":\"好\"},\"done\":true}\n", finish: true)
                }
            }
        }
        let output = try await client().translate("Hello", source: nil, target: TargetLanguage.all[0], configuration: config(), onUpdate: { partial in
            if !responseFinished { earlyText = partial }
        })
        XCTAssertEqual(earlyText, "你")
        XCTAssertEqual(output.text, "你好")
    }

    @MainActor
    func testStreamDisconnectReportsFailureAfterDeliveringPartialText() async {
        var partials: [String] = []
        TranslationURLProtocol.streaming = { connection in
            connection.beginStream()
            connection.send("{\"message\":{\"content\":\"部分译文\"},\"done\":false}\n", finish: true)
        }
        do {
            _ = try await client().translate("Hello", source: nil, target: TargetLanguage.all[0], configuration: config(), onUpdate: { partials.append($0) })
            XCTFail("An unfinished response must not be reported as complete")
        } catch {
            guard case AITranslationError.interrupted = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(partials, ["部分译文"])
    }

    @MainActor
    func testCancellationStopsFurtherStreamUpdates() async {
        var updates: [String] = []
        var running: Task<TranslationOutput, Error>?
        TranslationURLProtocol.streaming = { connection in
            DispatchQueue.main.async {
                connection.beginStream()
                connection.send("{\"message\":{\"content\":\"你\"},\"done\":false}\n")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    connection.send("{\"message\":{\"content\":\"不应显示\"},\"done\":true}\n", finish: true)
                }
            }
        }
        running = Task {
            try await client().translate("Hello", source: nil, target: TargetLanguage.all[0], configuration: config(), onUpdate: {
                updates.append($0)
                running?.cancel()
            })
        }
        do {
            _ = try await running!.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        XCTAssertEqual(updates, ["你"])
    }

    @MainActor
    func testSelectedAIEngineBypassesLocalLanguageIdentification() async throws {
        let keys = ["translationProvider", "translation.ollama.url", "translation.ollama.model"]
        let defaults = UserDefaults.standard
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        Settings.saveAITranslation(provider: .ollama, url: "http://localhost:11434", model: "test-model")
        TranslationURLProtocol.respond = { _ in (200, ["done": true, "message": ["content": "translated"]]) }
        let translator = Translator(aiTranslator: client())
        let result: Result<TranslationOutput, Error> = await withCheckedContinuation { continuation in
            translator.translate("QXJZ", to: TargetLanguage.all[0]) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(try result.get().text, "translated")
        XCTAssertEqual(try result.get().provider, .ollama)
    }
}
