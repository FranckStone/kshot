import Foundation
import XCTest
@testable import KShot

final class TranslatorTests: XCTestCase {
    func testRegionalLanguageAliasesHaveOneIdentity() {
        for identifier in ["en-US", "en-GB", "en_AU"] {
            XCTAssertEqual(TargetLanguage.source(identifier: identifier), TargetLanguage.all[2])
        }
        for identifier in ["zh-TW", "zh-HK", "zh-Hant-TW"] {
            XCTAssertEqual(TargetLanguage.source(identifier: identifier), TargetLanguage.all[1])
        }
        XCTAssertEqual(TargetLanguage.source(identifier: "zh-CN"), TargetLanguage.all[0])
        XCTAssertEqual(Set([TargetLanguage(title: "英语", identifier: "en-US"), TargetLanguage.all[2]]).count, 1)
        XCTAssertNotEqual(TargetLanguage.source(identifier: "sr-Latn"), TargetLanguage.source(identifier: "sr-Cyrl"))
        XCTAssertNotEqual(TargetLanguage.all[0], TargetLanguage.all[1])
    }

    func testJapaneseLabelsUseNearbyJapaneseSentences() throws {
        let plan = try TranslationPlan(text: "注文内容を確認してください。\n名前\n設定\n確認", source: nil)
        XCTAssertEqual(plan.languages.map(\.identifier), ["ja"])
        for part in plan.parts where !TranslationLanguageDetector.sample(part.text).isEmpty {
            XCTAssertEqual(part.source?.identifier, "ja", part.text)
        }
    }

    func testShortLatinLinesUseTheirOwnParagraphInMixedText() throws {
        let plan = try TranslationPlan(text: "这是一段中文说明，请按页面上的指引操作。\nPlease install the application and restart your computer.\nQXJZ", source: nil)
        XCTAssertEqual(plan.parts.last?.source?.identifier, "en")
        XCTAssertEqual(Set(plan.languages.map(\.identifier)), ["zh-Hans", "en"])
    }

    func testSharedLatinWordsUseContextWithoutOverridingClearEnglishLabels() throws {
        let plan = try TranslationPlan(text: "Bonjour, veuillez choisir une image pour continuer.\nImage\nContinue\nSettings", source: nil)
        XCTAssertEqual(plan.parts.first(where: { $0.text == "Image" })?.source?.identifier, "fr")
        XCTAssertEqual(plan.parts.first(where: { $0.text == "Continue" })?.source?.identifier, "fr")
        XCTAssertEqual(plan.parts.last?.source?.identifier, "en")
    }

    func testEquallyNearConflictingContextsDoNotForceAShortLine() throws {
        let text = "Please install the application and restart your computer.\nQXJZ\nBonjour, veuillez choisir une image pour continuer."
        XCTAssertThrowsError(try TranslationPlan(text: text, source: nil))
    }

    func testCommonShortUIWordsHaveAnExplicitEnglishSource() {
        for word in ["Hi", "Hello", "OK", "Save", "Cancel", "Copy", "Settings"] {
            XCTAssertEqual(TranslationLanguageDetector.detect(word)?.identifier, "en", word)
        }
        for word in ["你好", "保存", "取消", "设置", "复制"] {
            XCTAssertEqual(TranslationLanguageDetector.detect(word)?.identifier, "zh-Hans", word)
        }
        XCTAssertEqual(TranslationLanguageDetector.detect("檔案已儲存")?.identifier, "zh-Hant")
    }

    func testNoiseDoesNotHideChineseProse() throws {
        let text = "https://github.com/FranckStone/kshot\n订单联系人：张三 手机13812345678\n邮箱：zhangsan.test@example.com\n身份证号：110101199003078515\nAPI Key: sk-proj-4fT9aQ2xLmN8vR7cK1bZ\n备注：下午三点前送达，谢谢"
        XCTAssertEqual(TranslationLanguageDetector.detect(text)?.identifier, "zh-Hans")
        let sample = TranslationLanguageDetector.sample(text)
        XCTAssertTrue(sample.contains("下午三点前送达"))
        XCTAssertFalse(sample.contains("github"))
        XCTAssertFalse(sample.contains("example"))
        XCTAssertFalse(sample.contains("sk-proj"))
        let plan = try TranslationPlan(text: text, source: nil, excludedTexts: ["https://github.com/FranckStone/kshot"])
        XCTAssertEqual(Set(plan.languages.map(\.identifier)), ["zh-Hans", "en"])
        XCTAssertEqual(TranslationLanguageDetector.detect("API Key: sk-proj-4fT9aQ2xLmN8vR7cK1bZ")?.identifier, "en")
    }

    func testDistinctScriptsAndSupportedLatinLanguages() {
        let examples = [
            ("这是中文，下午三点送达。", "zh-Hans"),
            ("注文内容を確認してください。", "ja"),
            ("안녕하세요. 주문 내용을 확인해 주세요.", "ko"),
            ("Bonjour, comment allez-vous aujourd’hui ?", "fr"),
            ("Bitte installieren Sie die Anwendung und starten Sie sie neu.", "de"),
            ("Hola, ¿cómo estás? Por favor, abre la ventana.", "es"),
            ("Привет, как дела?", "ru")
        ]
        for (text, identifier) in examples {
            XCTAssertEqual(TranslationLanguageDetector.detect(text)?.identifier, identifier, text)
        }
        XCTAssertEqual(TargetLanguage.guess(for: "注文内容を確認してください。").identifier, "zh-Hans")
    }

    func testIdentifiersAndAmbiguousStringsAreNotGuessedAsAProseLanguage() {
        for text in ["https://example.com/path?q=1", "user@example.com", "138 1234 5678", "sk-proj-4fT9aQ2xLmN8vR7cK1bZ", "123-456", "✅"] {
            XCTAssertTrue(TranslationLanguageDetector.sample(text).isEmpty, text)
            XCTAssertNil(TranslationLanguageDetector.detect(text), text)
        }
        XCTAssertNil(TranslationLanguageDetector.detect("QXJZ"))
        XCTAssertNil(TranslationLanguageDetector.detect("注文番号"))
    }

    func testPlanPreservesMixedLanguageOrderLineBreaksAndNonProse() throws {
        let text = "安装完成，请重新启动应用。\r\n\r\nInstall the package and restart the application.\nhttps://example.com\n123-456\n"
        let plan = try TranslationPlan(text: text, source: nil)
        XCTAssertEqual(plan.parts.map(\.text).joined(), text)
        XCTAssertEqual(plan.languages.map(\.identifier), ["zh-Hans", "en"])
        XCTAssertEqual(plan.parts.first?.source?.identifier, "zh-Hans")
        XCTAssertNil(plan.parts.first(where: { $0.text == "https://example.com" })?.source)
        XCTAssertNil(plan.parts.first(where: { $0.text == "123-456" })?.source)
    }

    func testExplicitLanguageResolvesAmbiguityAndCodePayloadStaysUnchanged() throws {
        XCTAssertThrowsError(try TranslationPlan(text: "QXJZ", source: nil))
        let plan = try TranslationPlan(text: "QXJZ\n请勿翻译此二维码内容", source: TargetLanguage.all[2], excludedTexts: ["请勿翻译此二维码内容"])
        XCTAssertEqual(plan.languages.map(\.identifier), ["en"])
        XCTAssertEqual(plan.parts.first?.source?.identifier, "en")
        XCTAssertNil(plan.parts.last?.source)
    }

    func testJapaneseContextResolvesAnOtherwiseAmbiguousKanjiLabel() throws {
        let plan = try TranslationPlan(text: "注文内容を確認してください。\n注文番号", source: nil)
        XCTAssertEqual(plan.languages.map(\.identifier), ["ja"])
        XCTAssertEqual(plan.parts.last?.source?.identifier, "ja")
        XCTAssertFalse(TranslationLanguageDetector.isCompatible(TargetLanguage.all[2], with: "注文番号"))
    }

    func testExplicitSourceIsKeptWhenTargetChangesAndCanReturnToAutomatic() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Requires Translation framework") }
        await MainActor.run {
            let model = TranslatorModel()
            let english = TargetLanguage.all[2]
            let chinese = TargetLanguage.all[0]
            let japanese = TargetLanguage.all[3]
            model.start(text: "Hi", source: english, target: chinese) { _ in }
            XCTAssertEqual(model.config?.source, Locale.Language(identifier: "en"))
            XCTAssertEqual(model.config?.target, Locale.Language(identifier: "zh-Hans"))

            model.start(text: "Hi", source: english, target: japanese) { _ in }
            XCTAssertEqual(model.config?.source, Locale.Language(identifier: "en"))
            XCTAssertEqual(model.config?.target, Locale.Language(identifier: "ja"))

            model.start(text: "Hi", source: nil, target: japanese) { _ in }
            XCTAssertNil(model.config?.source)
            XCTAssertEqual(model.config?.target, Locale.Language(identifier: "ja"))
        }
    }
}
