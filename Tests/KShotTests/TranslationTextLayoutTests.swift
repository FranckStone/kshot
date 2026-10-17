import Foundation
import XCTest
@testable import KShot

final class TranslationTextLayoutTests: XCTestCase {
    func testOriginalLineSeparatorsBlankLinesAndWhitespaceAreUnchanged() {
        let source = "\r\n  First\r\n \t\r\nSecond\nThird\rFourth\u{0085}Fifth\u{2028}Sixth\u{2029}\n"
        let parts = TranslationTextLayout.split(source)
        XCTAssertEqual(Array(parts.joined().utf8), Array(source.utf8))
        let output = parts.map { value in
            let line = TranslationTextLayout(value)
            return line.isLiteral ? value : line.render("译文")
        }.joined()
        XCTAssertEqual(output, "\r\n  译文\r\n \t\r\n译文\n译文\r译文\u{0085}译文\u{2028}译文\u{2029}\n")
    }

    func testListsHeadingsQuotesAndIndentationArePreserved() {
        for prefix in ["\t1.  ", "1、", "2.", "  - ", "  - [x] ", "• ", "## ", "> ", "> - ", "（一）", "二、", "A. "] {
            let line = TranslationTextLayout(prefix + "Install the application.  ")
            XCTAssertEqual(line.content, "Install the application.")
            XCTAssertEqual(line.render("安装应用程序。"), prefix + "安装应用程序。  ")
        }
        XCTAssertEqual(TranslationTextLayout("1.25 million users").content, "1.25 million users")
    }

    func testModelCannotInsertExtraBlankLinesOrDuplicateListMarkers() {
        let line = TranslationTextLayout("  1. Hello\t")
        XCTAssertEqual(line.render("\n1. 你好\n\n世界\n"), "  1. 你好 世界\t")
        XCTAssertTrue(TranslationTextLayout("  ```swift").isLiteral)
        XCTAssertTrue(TranslationTextLayout("~~~").isLiteral)
    }
}
