import AppKit
import XCTest
@testable import KShot

final class LongShotTests: XCTestCase {
    // 固定随机种子，覆盖大片空白、稀疏纹理，避免自测结果随每次生成变化。
    private struct RNG: RandomNumberGenerator {
        var state: UInt64 = 42
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func image(width: Int = 800, height: Int = 3200, seed: UInt64 = 42) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var rng = RNG(state: seed)
        for i in 0..<140 {
            let x = Int.random(in: 0..<(width - 80), using: &rng)
            let y = Int.random(in: 0..<(height - 40), using: &rng)
            ctx.setFillColor(CGColor(red: Double(i % 7) / 7, green: Double(i % 5) / 5, blue: Double(i % 3) / 3, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: Int.random(in: 20...80, using: &rng), height: Int.random(in: 8...40, using: &rng)))
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 1200, width: width, height: 180))
        return ctx.makeImage()!
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private func assertImage(_ actual: CGImage?, equals expected: CGImage, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { XCTFail("合成失败", file: file, line: line); return }
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        XCTAssertTrue(pixels(actual) == pixels(expected), "完整 RGBA 像素不同", file: file, line: line)
    }

    func testRandomStepsAndBacktrackingPreserveEveryPixel() {
        for seed: UInt64 in [0, 1, 2, 42, 100] {
            let tall = image(seed: seed), stitcher = ImageStitcher(useVision: false)
            var offset = 0
            for step in [0, 230, 190, 260, -150, 240, 120, 250, 300, -80, 180, 220, 260, 240, 250, 250] {
                offset = max(0, min(2700, offset + step))
                let frame = tall.cropping(to: CGRect(x: 0, y: offset, width: 800, height: 500))!
                if case .noMatch = stitcher.push(frame) { XCTFail("无法匹配 seed=\(seed) offset=\(offset)") }
            }
            assertImage(stitcher.compose(), equals: tall)
        }
    }

    func testStartInMiddleScrollUpThenDown() {
        let tall = image(), stitcher = ImageStitcher(useVision: false)
        var offsets = Array(stride(from: 1500, to: 0, by: -170)) + [0]
        offsets += Array(stride(from: 190, to: 2700, by: 190)) + [2700]
        for offset in offsets {
            _ = stitcher.push(tall.cropping(to: CGRect(x: 0, y: offset, width: 800, height: 500))!)
        }
        assertImage(stitcher.compose(), equals: tall)
    }

    func testCaptureCopyKeepsBottomAndSingleFrame() {
        let tall = image()
        let bottom = tall.cropping(to: CGRect(x: 0, y: 2700, width: 800, height: 500))!
        let copy = RegionStream.copyImage(bottom)
        assertImage(copy, equals: bottom)
        let stitcher = ImageStitcher(useVision: false)
        _ = stitcher.push(copy!)
        assertImage(stitcher.compose(), equals: bottom)
    }

    func testCapturedFramesPreserveFinal26Rows() {
        let tall = image(), stitcher = ImageStitcher(useVision: false)
        for offset in stride(from: 0, through: 2700, by: 150) {
            let raw = tall.cropping(to: CGRect(x: 0, y: offset, width: 800, height: 500))!
            _ = stitcher.push(RegionStream.copyImage(raw)!)
        }
        assertImage(stitcher.compose(), equals: tall)
    }

    func testFixedBars() {
        let tall = image()
        let header = StitchTest.makeBar(width: 800, height: 60, seed: 1)!
        let footer = StitchTest.makeBar(width: 800, height: 60, seed: 2)!
        let stitcher = ImageStitcher(useVision: false)
        for offset in Array(stride(from: 0, to: 2820, by: 170)) + [2820] {
            let content = tall.cropping(to: CGRect(x: 0, y: offset, width: 800, height: 380))!
            if case .noMatch = stitcher.push(ImageStitcher.stack([header, content, footer])!) {
                XCTFail("固定栏无法匹配 offset=\(offset)")
            }
        }
        assertImage(stitcher.compose(), equals: ImageStitcher.stack([header, tall, footer])!)
    }

    func testLivePreviewIncludesAllCapturedRowsAndDoesNotCommitEdges() {
        let tall = image(), stitcher = ImageStitcher(useVision: false)
        var minY = 1500, maxY = 2000
        for offset in [1500, 1300, 1100, 900, 700, 500, 300, 100, 0, 200, 400, 600, 800, 1000, 1200, 1400, 1600, 1800, 2000, 2200, 2400, 2600, 2700] {
            _ = stitcher.push(tall.cropping(to: CGRect(x: 0, y: offset, width: 800, height: 500))!)
            minY = min(minY, offset)
            maxY = max(maxY, offset + 500)
            let state = stitcher.debugState
            assertImage(stitcher.preview(maxWidth: 800, maxHeight: 3200),
                        equals: tall.cropping(to: CGRect(x: 0, y: minY, width: 800, height: maxY - minY))!)
            XCTAssertEqual(stitcher.previewHeight, maxY - minY)
            XCTAssertEqual(stitcher.debugState, state, "预览不能提前提交边缘像素")
        }
        assertImage(stitcher.compose(), equals: tall)
    }

    func testLivePreviewIncludesFixedBarsOnceAndLimitsThumbnailSize() {
        let tall = image()
        let header = StitchTest.makeBar(width: 800, height: 60, seed: 1)!
        let footer = StitchTest.makeBar(width: 800, height: 60, seed: 2)!
        let stitcher = ImageStitcher(useVision: false)
        for offset in Array(stride(from: 0, to: 2820, by: 170)) + [2820] {
            let content = tall.cropping(to: CGRect(x: 0, y: offset, width: 800, height: 380))!
            _ = stitcher.push(ImageStitcher.stack([header, content, footer])!)
        }
        let expected = ImageStitcher.stack([header, tall, footer])!
        assertImage(stitcher.preview(maxWidth: 800, maxHeight: 3320), equals: expected)
        XCTAssertEqual(stitcher.previewHeight, expected.height)
        let thumbnail = stitcher.preview()!
        XCTAssertLessThanOrEqual(thumbnail.width, 536)
        XCTAssertLessThanOrEqual(thumbnail.height, 1024)
        XCTAssertEqual(Double(thumbnail.width) / Double(thumbnail.height), Double(expected.width) / Double(expected.height), accuracy: 0.001)
        assertImage(stitcher.compose(), equals: expected)
    }

    func testRepeatedRejectedFrameDoesNotRepeatRecoveryAndValidFrameStillWorks() {
        let tall = image(), stitcher = ImageStitcher(useVision: false)
        for offset in stride(from: 0, through: 2100, by: 150) {
            _ = stitcher.push(tall.cropping(to: CGRect(x: 0, y: offset, width: 800, height: 500))!)
        }
        let ctx = CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 800 * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        let rejected = ctx.makeImage()!
        let before = stitcher.matchingAttempts
        guard case .noMatch = stitcher.push(rejected) else { XCTFail("应拒绝无关画面"); return }
        XCTAssertLessThanOrEqual(stitcher.matchingAttempts - before, 5)
        let after = stitcher.matchingAttempts
        for _ in 0..<20 {
            guard case .noMatch = stitcher.push(rejected) else { XCTFail("失败画面不能追加"); return }
        }
        XCTAssertEqual(stitcher.matchingAttempts, after)
        guard case .appended = stitcher.push(tall.cropping(to: CGRect(x: 0, y: 2400, width: 800, height: 500))!) else {
            XCTFail("恢复到有效内容后应继续拼接"); return
        }
        assertImage(stitcher.compose(), equals: tall.cropping(to: CGRect(x: 0, y: 0, width: 800, height: 2900))!)
    }

    func testSmallScrollStepsRetainOnlyCommittedStripPixels() {
        let tall = image(), stitcher = ImageStitcher(useVision: false)
        for offset in stride(from: 0, through: 900, by: 20) {
            _ = stitcher.push(tall.cropping(to: CGRect(x: 0, y: offset, width: 800, height: 500))!)
        }
        XCTAssertGreaterThan(stitcher.debugStripStorageBytes, 0)
        XCTAssertLessThanOrEqual(stitcher.debugStripStorageBytes, 800 * stitcher.previewHeight * 4)
        assertImage(stitcher.compose(), equals: tall.cropping(to: CGRect(x: 0, y: 0, width: 800, height: 1400))!)
    }

    func testCanvasPartialRedrawPreservesImageAtBothScales() {
        let tall = image()
        for scale: CGFloat in [1, 2] {
            let canvas = ImageCanvasView(image: tall, scale: scale)
            let ctx = CGContext(data: nil, width: tall.width, height: tall.height, bitsPerComponent: 8,
                                bytesPerRow: tall.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(tall.height))
            ctx.scaleBy(x: scale, y: -scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            // 模拟长图滚动时不同大小的局部重绘，不能只测试全图一次绘制。
            let edges = [0, 311, 1025, 1888, 2700, 3200]
            for index in [2, 4, 0, 3, 1] {
                let rect = CGRect(x: 0, y: CGFloat(edges[index]) / scale, width: CGFloat(tall.width) / scale,
                                  height: CGFloat(edges[index + 1] - edges[index]) / scale)
                canvas.draw(rect)
            }
            NSGraphicsContext.restoreGraphicsState()
            assertImage(ctx.makeImage(), equals: tall)
        }
    }

    func testCanvasExportMatchesUnannotatedSource() {
        let tall = image()
        let canvas = ImageCanvasView(image: tall, scale: 2)
        assertImage(canvas.export(), equals: tall)
    }

    func testNarrowCanvasStaysCenteredWhenResizingAndScrolling() {
        let tall = image(width: 588, height: 3527)
        let canvas = ImageCanvasView(image: tall, scale: 2)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 528, height: 600))
        scroll.contentView = CenteredImageClipView()
        scroll.documentView = canvas
        scroll.tile()
        XCTAssertEqual(canvas.frame.midX, scroll.contentView.bounds.midX, accuracy: 0.5)
        for width: CGFloat in [768, 528] {
            scroll.setFrameSize(CGSize(width: width, height: 600))
            scroll.tile()
            var bounds = scroll.contentView.bounds
            bounds.origin.y = 800
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
            XCTAssertEqual(canvas.frame.midX, scroll.contentView.bounds.midX, accuracy: 0.5)
            XCTAssertEqual(scroll.contentView.bounds.minY, 800, accuracy: 0.5)
        }
        // 图片宽于视口时，仍能水平滚动，不改动画布及标注使用的坐标。
        scroll.setFrameSize(CGSize(width: 200, height: 600))
        scroll.tile()
        var bounds = scroll.contentView.bounds
        bounds.origin.x = 60
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
        XCTAssertEqual(scroll.contentView.bounds.minX, 60, accuracy: 0.5)
        XCTAssertEqual(canvas.frame.origin, .zero)
        XCTAssertEqual(canvas.bounds.size, CGSize(width: 294, height: 1763.5))
        assertImage(canvas.export(), equals: tall)
    }

    func testAutoScrollWaitsForFirstFrameAndPausesCaptureStall() {
        var state = LongShotAutoScroll()
        state.begin(at: 100)
        XCTAssertEqual(state.next(at: 100.16), .wait)
        XCTAssertEqual(state.next(at: 103.1), .pauseStalled)
    }

    func testOldQueuedFramesCannotAcknowledgeScroll() {
        var state = LongShotAutoScroll()
        state.begin(at: 100)
        state.observe(.moved, capturedAt: 100.1)
        XCTAssertEqual(state.next(at: 100.2), .scroll)
        state.observe(.unchanged, capturedAt: 100.21)
        XCTAssertEqual(state.next(at: 100.9), .wait)
        XCTAssertEqual(state.next(at: 103.3), .pauseStalled)
    }

    func testRepeatedUnchangedResponsesOnlyPause() {
        var state = LongShotAutoScroll()
        state.begin(at: 100)
        state.observe(.moved, capturedAt: 100.1)
        for time in [100.2, 100.7, 101.2] {
            XCTAssertEqual(state.next(at: time), .scroll)
            state.observe(.unchanged, capturedAt: time + 0.1)
            state.observe(.unchanged, capturedAt: time + 0.2)
        }
        XCTAssertEqual(state.next(at: 101.5), .pauseStationary)
    }

    func testDelayedPageMovementResetsStationaryEvidence() {
        var state = LongShotAutoScroll()
        state.begin(at: 100)
        state.observe(.moved, capturedAt: 100.1)
        for time in [100.2, 100.7, 101.2] {
            XCTAssertEqual(state.next(at: time), .scroll)
            state.observe(.unchanged, capturedAt: time + 0.1)
        }
        state.observe(.moved, capturedAt: 101.4)
        XCTAssertEqual(state.next(at: 101.5), .scroll)
        state.observe(.unmatched, capturedAt: 101.6)
        XCTAssertEqual(state.next(at: 101.7), .scroll)
    }
}
