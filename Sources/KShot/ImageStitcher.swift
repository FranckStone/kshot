import AppKit

/// 长截图拼接：比较相邻两帧，找出内容向上滚动的像素距离，把新露出的部分接到底部。
/// 会自动识别固定不动的顶栏 / 底栏（同一位置内容不变的行），匹配与追加时跳过它们，底栏在最后补一次。
final class ImageStitcher {
    struct Frame {
        let image: CGImage
        let width: Int
        let height: Int
        /// 每行的灰度采样签名（按 sampleColumns 列采样）
        let rows: [[UInt8]]
        /// 每行是否有纹理（非单色）
        let textured: [Bool]
    }

    enum Outcome {
        case appended(rows: Int)   // 接上了新内容
        case unchanged             // 画面没变（没有滚动 / 已到底）
        case scrolledUp            // 往回滚了（内容在已拼接范围内），忽略
        case noMatch               // 找不到重叠（滚得太快 / 画面变化太大）
    }

    struct Diagnostics {
        var shift = 0
        var score = 0.0
        var header = 0
        var footer = 0
    }

    private(set) var strips: [CGImage] = []
    private(set) var totalHeight = 0
    private(set) var lastDiagnostics = Diagnostics()
    /// 锚点：最后一次拼接进去的帧，新帧都和它比
    private var previous: Frame?
    private var footerStrip: CGImage?
    private let maxTotalHeight: Int
    private static let sampleColumns = 64

    init(maxTotalHeight: Int = 30000) {
        self.maxTotalHeight = maxTotalHeight
    }

    var width: Int { strips.first?.width ?? 0 }

    func push(_ image: CGImage, expectedShift: Int = 0) -> Outcome {
        guard let frame = Self.makeFrame(image) else { return .noMatch }
        return push(frame: frame, expectedShift: expectedShift)
    }

    /// 两帧是否几乎相同（用于判断滚动动画是否已静止）
    static func isSame(_ a: Frame, _ b: Frame) -> Bool {
        a.width == b.width && a.height == b.height && meanDiff(a.rows, b.rows, aStart: 0, bStart: 0, count: a.height, step: 3) < 1.5
    }

    /// 喂入一帧。expectedShift：预期滚动的像素数（内容单调时用于取舍），0 表示未知。
    func push(frame: Frame, expectedShift: Int = 0) -> Outcome {
        let image = frame.image
        guard let prev = previous else {
            previous = frame
            strips = [image]
            totalHeight = image.height
            return .appended(rows: image.height)
        }
        guard prev.width == frame.width, prev.height == frame.height else { return .noMatch }
        let h = frame.height

        // 画面完全没变
        if Self.isSame(prev, frame) { return .unchanged }

        // 固定顶栏 / 底栏：同一位置内容不变的连续行
        let header = Self.staticRun(prev, frame, fromTop: true)
        let footer = Self.staticRun(prev, frame, fromTop: false)
        let bandTop = header
        let bandBottom = h - footer
        guard bandBottom - bandTop > 24 else { return .noMatch }

        guard let (shift, score) = Self.findShift(prev: prev, next: frame, top: bandTop, bottom: bandBottom, expected: expectedShift) else {
            lastDiagnostics = Diagnostics(shift: 0, score: -1, header: header, footer: footer)
            // 反向能匹配上 → 用户往回滚了
            if Self.findShift(prev: frame, next: prev, top: bandTop, bottom: bandBottom, expected: 0) != nil { return .scrolledUp }
            return .noMatch
        }
        lastDiagnostics = Diagnostics(shift: shift, score: score, header: header, footer: footer)
        guard shift > 0, totalHeight + shift <= maxTotalHeight else { return .unchanged }
        previous = frame

        // 记住底栏（最后补一次）；首次发现底栏时，把第一帧条带底部的底栏裁掉，避免重复
        if footer > 0 {
            if footerStrip == nil, strips.count == 1, let first = strips.first, first.height > footer,
               let trimmed = first.cropping(to: CGRect(x: 0, y: 0, width: first.width, height: first.height - footer)) {
                strips[0] = trimmed
                totalHeight -= footer
            }
            footerStrip = image.cropping(to: CGRect(x: 0, y: h - footer, width: image.width, height: footer))
        }
        // 新露出的部分：动态区域的最后 shift 行
        guard let strip = image.cropping(to: CGRect(x: 0, y: bandBottom - shift, width: image.width, height: shift)) else { return .noMatch }
        strips.append(strip)
        totalHeight += shift
        return .appended(rows: shift)
    }

    /// 预览：最后若干条带（至少 minHeight 像素）竖向合成
    func preview(minHeight: Int) -> CGImage? {
        var picked: [CGImage] = []
        var h = 0
        for s in strips.reversed() {
            picked.insert(s, at: 0)
            h += s.height
            if h >= minHeight { break }
        }
        return Self.stack(picked)
    }

    /// 把所有条带竖向合成一张图（末尾补上固定底栏）
    func compose() -> CGImage? {
        var all = strips
        if let footerStrip { all.append(footerStrip) }
        return Self.stack(all)
    }

    static func stack(_ all: [CGImage]) -> CGImage? {
        guard let first = all.first else { return nil }
        let w = first.width
        let h = all.reduce(0) { $0 + $1.height }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = h
        for strip in all {
            y -= strip.height
            ctx.draw(strip, in: CGRect(x: 0, y: y, width: strip.width, height: strip.height))
        }
        return ctx.makeImage()
    }

    // MARK: - 固定区域

    /// 从顶部（或底部）起，同一位置内容不变的连续行数。整段都是单色时视为滚动中的空白而不是固定栏。
    private static func staticRun(_ a: Frame, _ b: Frame, fromTop: Bool) -> Int {
        let h = a.height
        let limit = h / 2
        var run = 0
        var texturedCount = 0
        var lastTexturedRun = 0 // 固定区域只算到最后一个有纹理的行，紧挨着的空白行归内容
        while run < limit {
            let i = fromTop ? run : h - 1 - run
            guard rowDiff(a.rows[i], b.rows[i]) < 2.0 else { break }
            run += 1
            if a.textured[i] { texturedCount += 1; lastTexturedRun = run }
        }
        return texturedCount >= 2 ? lastTexturedRun : 0
    }

    // MARK: - 匹配

    /// 在动态区域 [top, bottom) 内寻找 shift：prev[top+shift+i] ≈ next[top+i]
    private static func findShift(prev: Frame, next: Frame, top: Int, bottom: Int, expected: Int) -> (Int, Double)? {
        let bandH = bottom - top
        let minShift = 4
        let maxShift = Int(Double(bandH) * 0.9)
        guard maxShift > minShift else { return nil }

        func score(_ s: Int, step: Int) -> Double {
            let overlap = bandH - s
            let skip = overlap / 10 // 跳过重叠区最顶上一点，容忍半固定的元素
            return meanDiff(prev.rows, next.rows, aStart: top + s + skip, bStart: top + skip, count: overlap - skip, step: step)
        }

        var candidates: [(shift: Int, score: Double)] = []
        var s = minShift
        while s <= maxShift {
            candidates.append((s, score(s, step: 4)))
            s += 2
        }
        guard let coarse = candidates.min(by: { $0.score < $1.score }) else { return nil }
        var best = coarse
        for s in max(minShift, coarse.shift - 3)...min(maxShift, coarse.shift + 3) {
            let sc = score(s, step: 1)
            if sc < best.score { best = (s, sc) }
        }
        guard best.score < 8 else { return nil }

        // 内容单调（大片空白）时很多候选几乎同分：只有在最优解本身已接近完美、且候选确实多到分不清时，才取最接近预期滚动量的
        if expected > 0, best.score < 1.0 {
            let near = candidates.filter { $0.score <= best.score + 0.5 }
            if near.count >= 4, let pick = near.min(by: { abs($0.shift - expected) < abs($1.shift - expected) }),
               abs(pick.shift - expected) < abs(best.shift - expected) {
                var refined = pick
                for s in max(minShift, pick.shift - 3)...min(maxShift, pick.shift + 3) {
                    let sc = score(s, step: 1)
                    if sc < refined.score { refined = (s, sc) }
                }
                return (refined.shift, refined.score)
            }
        }
        return (best.shift, best.score)
    }

    /// a[aStart + i] 与 b[bStart + i] 的平均绝对差
    private static func meanDiff(_ a: [[UInt8]], _ b: [[UInt8]], aStart: Int, bStart: Int, count: Int, step: Int) -> Double {
        guard count > 4 else { return .infinity }
        var total = 0, n = 0
        var i = 0
        while i < count {
            let ra = a[aStart + i], rb = b[bStart + i]
            for c in 0..<ra.count { total += abs(Int(ra[c]) - Int(rb[c])) }
            n += ra.count
            i += step
        }
        return n == 0 ? .infinity : Double(total) / Double(n)
    }

    private static func rowDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var total = 0
        for c in 0..<a.count { total += abs(Int(a[c]) - Int(b[c])) }
        return Double(total) / Double(a.count)
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
        var textured: [Bool] = []
        rows.reserveCapacity(h)
        textured.reserveCapacity(h)
        for y in 0..<h {
            let rowBase = y * w * 4
            var sig = [UInt8](repeating: 0, count: cols.count)
            var lo = 255, hi = 0
            for (i, x) in cols.enumerated() {
                let p = rowBase + x * 4
                let g = (Int(px[p]) + Int(px[p + 1]) + Int(px[p + 2])) / 3
                sig[i] = UInt8(g)
                lo = min(lo, g); hi = max(hi, g)
            }
            rows.append(sig)
            textured.append(hi - lo > 24)
        }
        return Frame(image: image, width: w, height: h, rows: rows, textured: textured)
    }
}
