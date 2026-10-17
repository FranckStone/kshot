import Foundation
import XCTest
@testable import KShot

final class AITranslationStreamTests: XCTestCase {
    func testSSEHeartbeatsReasoningAndUnicodeAcrossByteBoundaries() throws {
        let response = ": heartbeat\r\n\r\ndata: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"reasoning_content\":\"private thought\"}}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"你🙂\"}}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"好\"},\"finish_reason\":\"stop\"}]}\r\n\r\ndata: [DONE]\r\n\r\n"
        var lines = AITranslationLines()
        var stream = AITranslationStream(provider: .deepseek)
        var updates: [String] = []
        for byte in response.utf8 {
            if let line = try lines.consume(byte), let delta = try stream.consume(line: line) { updates.append(delta) }
        }
        XCTAssertEqual(updates, ["你🙂", "好"])
        XCTAssertEqual(try stream.finish(), "你🙂好")
    }

    func testMultilineSSEEventAndLastLineWithoutNewline() throws {
        var lines = AITranslationLines()
        var stream = AITranslationStream(provider: .deepseek)
        for byte in "data: {\"choices\":\n data: ignored\ndata: [{\"delta\":{\"content\":\"译文\"}}]}\n\ndata: [DONE]".utf8 {
            if let line = try lines.consume(byte) { _ = try stream.consume(line: line) }
        }
        if let line = try lines.finish() { _ = try stream.consume(line: line) }
        XCTAssertEqual(try stream.finish(), "译文")
    }

    func testMissingEndMarkerAndTruncationCannotBeSuccessful() throws {
        var stream = AITranslationStream(provider: .deepseek)
        _ = try stream.consume(line: "data: {\"choices\":[{\"delta\":{\"content\":\"部分\"}}]}")
        _ = try stream.consume(line: "")
        XCTAssertThrowsError(try stream.finish())
        _ = try stream.consume(line: "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}")
        XCTAssertThrowsError(try stream.consume(line: ""))
        XCTAssertEqual(stream.text, "部分")
    }

    func testOllamaThinkingIsNotDisplayedAndFinalChunkCanContainContent() throws {
        var stream = AITranslationStream(provider: .ollama)
        XCTAssertNil(try stream.consume(line: "{\"message\":{\"thinking\":\"private thought\",\"content\":\"\"},\"done\":false}"))
        XCTAssertEqual(try stream.consume(line: "{\"message\":{\"content\":\"译文\"},\"done\":true}"), "译文")
        XCTAssertEqual(try stream.finish(), "译文")
    }

    func testMalformedAndEmptyResponsesAreRejected() throws {
        var stream = AITranslationStream(provider: .ollama)
        XCTAssertThrowsError(try stream.consume(line: "not json"))
        XCTAssertThrowsError(try stream.consume(line: "{\"error\":\"server error\"}"))
        _ = try stream.consume(line: "{\"done\":true,\"message\":{\"content\":\"\"}}")
        XCTAssertThrowsError(try stream.finish())
        var lines = AITranslationLines()
        _ = try lines.consume(0xE4)
        XCTAssertThrowsError(try lines.finish())
    }
}
