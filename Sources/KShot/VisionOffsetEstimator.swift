import AppKit
import Vision

// 帧间位移估计：移植自 ScrollSnap（MIT License, https://github.com/Brkgng/ScrollSnap）
// 思路：用 Vision 的平移配准（VNTranslationalImageRegistrationRequest）分别估计 5 条横带的位移，
// 至少 4 条一致（±3px）才采信；否则退回整帧配准且需要高置信度。固定的表头/底栏、撕裂帧所在的横带
// 会给出不一致的位移，从而被多数投票自然剔除。

struct OffsetEstimate {
    /// 像素位移：> 0 表示内容向上移动（向下滚动）
    let dy: CGFloat
    let dx: CGFloat
    let confidence: Float
    let source: String
}

struct VisionOffsetEstimator {
    private let comparisonBandCount = 5
    private let minimumComparisonBandHeight = 80
    private let agreementTolerance: CGFloat = 3
    private let maximumHorizontalMovement: CGFloat = 3
    private let minimumOverlapFraction: CGFloat = 0.15
    private let validatedBandConfidence: Float = 0.8
    private let fullFrameConfidence: Float = 0.9

    private struct T { let x: CGFloat; let y: CGFloat; let confidence: Float }

    /// 半分辨率配准（快约 4 倍），结果乘回原尺度；调用方再用行签名精修到整像素
    func estimateFast(current: CGImage, previous: CGImage) -> OffsetEstimate? {
        guard let c = Self.half(current), let p = Self.half(previous), let e = estimate(current: c, previous: p) else { return nil }
        return OffsetEstimate(dy: e.dy * 2, dx: e.dx * 2, confidence: e.confidence, source: e.source + "/2")
    }

    static func half(_ img: CGImage) -> CGImage? {
        let w = max(1, img.width / 2), h = max(1, img.height / 2)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// current 相对 previous 的位移
    func estimate(current: CGImage, previous: CGImage) -> OffsetEstimate? {
        guard current.width == previous.width, current.height == previous.height else { return nil }
        let frameHeight = CGFloat(current.height)
        let bands = comparisonBands(width: current.width, height: current.height).compactMap { band -> T? in
            guard let c = current.cropping(to: band), let p = previous.cropping(to: band),
                  let t = translation(from: c, to: p), isValid(t, frameHeight: frameHeight) else { return nil }
            return t
        }
        if let g = bestGroup(bands, minimumCount: 4), let a = average(g) {
            return OffsetEstimate(dy: a.y, dx: a.x, confidence: a.confidence, source: "bands")
        }
        guard let full = translation(from: current, to: previous), isValid(full, frameHeight: frameHeight) else { return nil }
        if full.confidence >= validatedBandConfidence,
           let g = bestGroup(bands, minimumCount: 3), let a = average(g), abs(a.y - full.y) <= agreementTolerance {
            return OffsetEstimate(dy: a.y, dx: a.x, confidence: min(a.confidence, full.confidence), source: "bands+full")
        }
        guard full.confidence >= fullFrameConfidence else { return nil }
        return OffsetEstimate(dy: full.y, dx: full.x, confidence: full.confidence, source: "full")
    }

    private func comparisonBands(width: Int, height: Int) -> [CGRect] {
        let bandHeight = min(height, max(minimumComparisonBandHeight, height / 3))
        let maxOriginY = max(0, height - bandHeight)
        let origins: [Int] = maxOriginY == 0 ? [0] : (0..<comparisonBandCount).map {
            Int((CGFloat(maxOriginY) * CGFloat($0) / CGFloat(max(1, comparisonBandCount - 1))).rounded())
        }
        return Array(Set(origins)).sorted().map { CGRect(x: 0, y: $0, width: width, height: bandHeight) }
    }

    private func bestGroup(_ ts: [T], minimumCount: Int) -> [T]? {
        var best: [T] = []
        for t in ts {
            let g = ts.filter { abs($0.y - t.y) <= agreementTolerance }
            if g.count > best.count { best = g }
        }
        return best.count >= minimumCount ? best : nil
    }

    private func average(_ ts: [T]) -> T? {
        guard !ts.isEmpty else { return nil }
        let n = CGFloat(ts.count)
        return T(x: ts.reduce(0) { $0 + $1.x } / n, y: ts.reduce(0) { $0 + $1.y } / n,
                 confidence: ts.reduce(0) { $0 + $1.confidence } / Float(ts.count))
    }

    private func isValid(_ t: T, frameHeight: CGFloat) -> Bool {
        abs(t.x) <= maximumHorizontalMovement && abs(t.y) <= frameHeight * (1 - minimumOverlapFraction)
    }

    private func translation(from image1: CGImage, to image2: CGImage) -> T? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: image2)
        let handler = VNImageRequestHandler(cgImage: image1, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        return T(x: obs.alignmentTransform.tx, y: obs.alignmentTransform.ty, confidence: obs.confidence)
    }
}
