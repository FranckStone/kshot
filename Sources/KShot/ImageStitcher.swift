import AppKit

/// 长截图拼接：比较相邻两帧，找出内容向上滚动的像素距离，把新露出的部分接到底部。
final class ImageStitcher {
    struct Frame {
        let image: CGImage
        let width: Int
        let height: Int
        /// 每行的灰度采样签名（按 sampleColumns 列采样）
        let rows: [[UInt8]]
    }

    enum Outcome {
        case appended(rows: Int)   // 接上了新内容
        case unchanged             // 画面没变（没有滚动 / 已到底）
        case noMatch               // 找不到重叠（画面变化太大）
    }

    private(set) var strips: [CGImage] = []
    private(set) var totalHeight = 0
    private var previous: Frame?
    private let maxTotalHeight: Int
    private static let sampleColumns = 64

    init(maxTotalHeight: Int = 24000) {
        self.maxTotalHeight = maxTotalHeight
    }

    var width: Int { strips.first?.width ?? 0 }

    /// 喂入一帧。expectedShift：预期滚动的像素数（用于在多个候选里取舍），0 表示未知。
    func push(_ image: CGImage, expectedShift: Int = 0) -> Outcome {
        guard let frame = Self.makeFrame(image) else { return .noMatch }
        defer { previous = frame }
        guard let prev = previous else {
            strips = [image]
            totalHeight = image.height
            return .appended(rows: image.height)
        }
        guard prev.width == frame.width, prev.height == frame.height else { return .noMatch }

        // 画面完全没变
        if Self.meanDiff(prev.rows, frame.rows, shift: 0, step: 3) < 1.5 { return .unchanged }

        guard let shift = Self.findShift(prev: prev, next: frame, expected: expectedShift) else { return .noMatch }
        guard shift > 0, totalHeight + shift <= maxTotalHeight else { return .unchanged }
        // 新露出的部分：新帧的最后 shift 行
        guard let strip = image.cropping(to: CGRect(x: 0, y: image.height - shift, width: image.width, height: shift)) else { return .noMatch }
        strips.append(strip)
        totalHeight += shift
        return .appended(rows: shift)
    }

    /// 把所有条带竖向合成一张图
    func compose() -> CGImage? {
        guard let first = strips.first else { return nil }
        let w = first.width, h = totalHeight
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CG 坐标左下原点：从顶部开始往下排
        var y = h
        for strip in strips {
            y -= strip.height
            ctx.draw(strip, in: CGRect(x: 0, y: y, width: strip.width, height: strip.height))
        }
        return ctx.makeImage()
    }

    // MARK: - 匹配

    /// 在 prev 的 [shift...] 与 next 的 [0...] 之间找最吻合的 shift（像素行）
    private static func findShift(prev: Frame, next: Frame, expected: Int) -> Int? {
        let h = prev.height
        let minShift = 4
        let maxShift = Int(Double(h) * 0.9)
        guard maxShift > minShift else { return nil }

        // 第一轮粗搜（步长 2），第二轮在最优值附近精搜
        var candidates: [(shift: Int, score: Double)] = []
        var s = minShift
        while s <= maxShift {
            candidates.append((s, meanDiff(prev.rows, next.rows, shift: s, step: 4)))
            s += 2
        }
        guard let coarse = candidates.min(by: { $0.score < $1.score }) else { return nil }
        var best = coarse
        for s in max(minShift, coarse.shift - 3)...min(maxShift, coarse.shift + 3) {
            let score = meanDiff(prev.rows, next.rows, shift: s, step: 1)
            if score < best.score { best = (s, score) }
        }
        guard best.score < 10 else { return nil }

        // 内容单调（大片空白）时会有很多几乎同分的候选：优先取最接近预期滚动量的
        if expected > 0 {
            let near = candidates.filter { $0.score <= best.score + 1.0 }
            if let pick = near.min(by: { abs($0.shift - expected) < abs($1.shift - expected) }), abs(pick.shift - expected) < abs(best.shift - expected) {
                var refined = pick
                for s in max(minShift, pick.shift - 3)...min(maxShift, pick.shift + 3) {
                    let score = meanDiff(prev.rows, next.rows, shift: s, step: 1)
                    if score < refined.score { refined = (s, score) }
                }
                return refined.shift
            }
        }
        return best.shift
    }

    /// prev[shift + i] 与 next[i] 的平均绝对差。跳过重叠区顶部 20%（避开固定表头）。
    private static func meanDiff(_ prev: [[UInt8]], _ next: [[UInt8]], shift: Int, step: Int) -> Double {
        let overlap = prev.count - shift
        guard overlap > 8 else { return .infinity }
        let start = overlap / 5
        var total = 0, n = 0
        var i = start
        while i < overlap {
            let a = prev[shift + i], b = next[i]
            for c in 0..<a.count { total += abs(Int(a[c]) - Int(b[c])) }
            n += a.count
            i += step
        }
        return n == 0 ? .infinity : Double(total) / Double(n)
    }

    /// 生成行签名：每行在 [6%, 88%] 宽度范围内采样若干列的灰度（避开右侧滚动条）
    static func makeFrame(_ image: CGImage) -> Frame? {
        let w = image.width, h = image.height
        guard w > 8, h > 8 else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let cols = (0..<sampleColumns).map { Int(Double(w) * (0.06 + 0.82 * Double($0) / Double(sampleColumns - 1))) }
        var rows: [[UInt8]] = []
        rows.reserveCapacity(h)
        // CGBitmapContext 的内存第 0 行就是图像顶部，直接按从上到下读
        for y in 0..<h {
            let rowBase = y * w * 4
            var sig = [UInt8](repeating: 0, count: cols.count)
            for (i, x) in cols.enumerated() {
                let p = rowBase + x * 4
                sig[i] = UInt8((Int(px[p]) + Int(px[p + 1]) + Int(px[p + 2])) / 3)
            }
            rows.append(sig)
        }
        return Frame(image: image, width: w, height: h, rows: rows)
    }
}
