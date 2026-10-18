import Foundation
import XCTest
@testable import KShot

final class AITranslationBatchTests: XCTestCase {
    func testChunkLimitsSkipLiteralPartsAndKeepOversizedLinesWhole() throws {
        let lines = ["Hello", "\r\n", "secret", "Open", "a very long sentence", "Save"]
        let plan = AITranslationBatch(lines: lines.map { ($0, $0 == "secret") }, maxLines: 2, maxBytes: 10)
        XCTAssertEqual(plan.chunks, [[0, 3], [4], [5]])
        let input = try plan.input(for: plan.chunks[0])
        XCTAssertFalse(input.contains("secret"))
        XCTAssertFalse(input.contains("\\r"))
        XCTAssertEqual(plan.render([0: "你好", 3: "打开"], partial: (4, "很长")), "你好\r\nsecret打开很长")
    }

    func testLayoutKeepsEverySeparatorAndWhitespaceOutsideModelOutput() {
        let source = "\t1. Hello  \r\n\r\n - Open\t\u{2028}123-456\n# Save\r"
        let plan = AITranslationBatch(lines: TranslationTextLayout.split(source).map { ($0, false) })
        let indices = plan.chunks[0]
        XCTAssertEqual(indices.count, 3)
        let translations = Dictionary(uniqueKeysWithValues: zip(indices, ["你好", "- 打开\n窗口", "# 保存"]))
        XCTAssertEqual(plan.render(translations), "\t1. 你好  \r\n\r\n - 打开 窗口\t\u{2028}123-456\n# 保存\r")
    }

    func testPartialJSONStringDecodesEscapesWithoutLeakingProtocol() throws {
        let first = #"{"id":0,"text":"你好\n\"世界\"\\路径"}"#
        let text = first + "\n" + #"{"id":1,"text":"保存\uD83D\uDE00"}"#
        for length in 0...text.count {
            let prefix = String(text.prefix(length))
            let response = try AITranslationBatchResponse(prefix, count: 2)
            XCTAssertLessThanOrEqual(response.translations.count, 2)
            if let partial = response.partial {
                let expected = response.translations.isEmpty ? "你好\n\"世界\"\\路径" : "保存😀"
                XCTAssertTrue(expected.hasPrefix(partial), "Bad partial: \(partial.debugDescription)")
            }
        }
        let response = try AITranslationBatchResponse(text, count: 2, finished: true)
        XCTAssertEqual(response.translations, ["你好\n\"世界\"\\路径", "保存😀"])
    }

    func testInvalidOrMissingRecordsCannotSilentlyChangeLineMapping() {
        let valid = #"{"id":0,"text":"你好"}"#
        for text in [
            valid,
            valid + "\n" + valid,
            #"{"id":1,"text":"打开"}"# + "\n" + valid,
            valid + "\n" + #"{"id":3,"text":"打开"}"#,
            valid + "\n" + #"{"id":1,"text":"  "}"#,
            valid + "\n" + #"{"id":1,"text":"打开"}"# + "\n" + #"{"id":2,"text":"多余"}"#,
            "```json\n" + valid + "\n```",
            #"{"id":0,"text":"未闭合"#
        ] {
            XCTAssertThrowsError(try AITranslationBatchResponse(text, count: 2, finished: true), text)
        }
    }
}
