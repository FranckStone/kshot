import AppKit

/// 长截图拼接：比较相邻两帧，找出内容向上滚动的像素距离，把新露出的部分接到底部。
/// 会自动识别固定不动的顶栏 / 底栏（同一位置内容不变的行），匹配与追加时跳过它们，底栏在最后补一次。
final class ImageStitcher: @unchecked Sendable {
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
        var halves = (0.0, 0.0)
        var reason = ""
        var rough = 0.0
    }
    /// findShift 失败时的细节（调试）
    private static var lastFailure = Diagnostics()

    private(set) var strips: [CGImage] = []
    private(set) var totalHeight = 0
    private(set) var lastDiagnostics = Diagnostics()
    /// 锚点：最后一次拼接进去的帧，新帧都和它比
    private var previous: Frame?
    private var footerStrip: CGImage?
    /// 上一次拼入的滚动量：手动模式下用作下一帧的预期值（滚动速度连续）
    private var lastShift = 0
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

    private let estimator = VisionOffsetEstimator()
    /// 往回滚需要连续两帧确认（移植自 ScrollSnap）
    private var pendingReverse = false
    /// 位移小于这个值视为没动（px）
    private let deadZone = 4

    /// 喂入一帧：用 Vision 横带一致性配准求位移，行签名精修到整像素。
    /// expectedShift 仅为兼容旧调用保留。
    func push(frame: Frame, expectedShift: Int = 0) -> Outcome {
        let image = frame.image
        guard let prev = previous else {
            previous = frame
            strips = [image]
            totalHeight = image.height
            return .appended(rows: image.height)
        }
        guard prev.width == frame.width, prev.height == frame.height else { return .noMatch }
        if Self.isSame(prev, frame) { return .unchanged }

        // footer/header：用于裁剪底栏（截到最后一个有纹理行）；matchTop/matchBottom：用于匹配（包含所有静止行）
        let footerRuns = Self.staticRuns(prev, frame, fromTop: false)
        let headerRuns = Self.staticRuns(prev, frame, fromTop: true)
        let footer = footerRuns.textured, header = headerRuns.textured
        let matchTop = headerRuns.full, matchBottom = frame.height - footerRuns.full
        // 位移：半分辨率 Vision → 全分辨率 Vision → 行签名搜索（仅向下）
        let shift: Int
        var source: String
        var roughDy = 0.0
        var confidence: Float = 0
        // 只在滚动区域（去掉固定顶栏/底栏）上配准
        let band = CGRect(x: 0, y: matchTop, width: frame.width, height: matchBottom - matchTop)
        let curBand = band.height >= 64 ? (image.cropping(to: band) ?? image) : image
        let prevBand = band.height >= 64 ? (prev.image.cropping(to: band) ?? prev.image) : prev.image
        if let est = estimator.estimateFast(current: curBand, previous: prevBand) ?? estimator.estimate(current: curBand, previous: prevBand) {
            shift = Self.refine(prev: prev, next: frame, around: Int(est.dy.rounded()), top: matchTop, bottom: matchBottom)
            source = est.source
            roughDy = Double(est.dy)
            confidence = est.confidence
        } else if matchBottom - matchTop > 24,
                  let (s, _) = Self.findShift(prev: prev, next: frame, top: matchTop, bottom: matchBottom, expected: lastShift) {
            shift = s
            source = "rows"
        } else {
            lastDiagnostics = Diagnostics(header: header, footer: footer, reason: "none")
            pendingReverse = false
            return .noMatch
        }
        lastDiagnostics = Diagnostics(shift: shift, score: Double(confidence), header: header, footer: footer, reason: source, rough: roughDy)

        if abs(shift) < deadZone {
            pendingReverse = false
            return .unchanged
        }
        if shift < 0 {
            // 往回滚：第一次只记下，第二次确认后从底部裁掉
            guard pendingReverse else { pendingReverse = true; return .scrolledUp }
            pendingReverse = false
            removeBottom(-shift)
            previous = frame
            return .scrolledUp
        }
        pendingReverse = false
        guard totalHeight + shift <= maxTotalHeight else { return .unchanged }

        // 固定底栏：首次发现时从第一条带里裁掉，之后每次只记最新的，合成时补一次
        let h = frame.height
        if footer > 0 {
            if footerStrip == nil, strips.count == 1, let first = strips.first, first.height > footer,
               let trimmed = first.cropping(to: CGRect(x: 0, y: 0, width: first.width, height: first.height - footer)) {
                strips[0] = trimmed
                totalHeight -= footer
            }
            footerStrip = image.cropping(to: CGRect(x: 0, y: h - footer, width: image.width, height: footer))
        }
        let bandBottom = h - footer
        let take = min(shift, bandBottom)
        guard take > 0, let strip = image.cropping(to: CGRect(x: 0, y: bandBottom - take, width: image.width, height: take)) else {
            return .noMatch
        }
        strips.append(strip)
        totalHeight += take
        previous = frame
        lastShift = shift
        return .appended(rows: take)
    }

    /// 从拼接结果底部移除 n 行（往回滚时用）
    private func removeBottom(_ n: Int) {
        var remaining = n
        while remaining > 0, strips.count > 1, let last = strips.last {
            if last.height <= remaining {
                strips.removeLast()
                totalHeight -= last.height
                remaining -= last.height
            } else {
                if let cut = last.cropping(to: CGRect(x: 0, y: 0, width: last.width, height: last.height - remaining)) {
                    strips[strips.count - 1] = cut
                    totalHeight -= remaining
                }
                remaining = 0
            }
        }
    }

    /// 在 Vision 的粗略位移附近 ±8px 用行签名找最吻合的整像素位移
    private static func refine(prev: Frame, next: Frame, around rough: Int, top: Int, bottom: Int) -> Int {
        let h = bottom - top
        var best = rough, bestScore = Double.infinity
        // 半分辨率 ×2 与横带平均最多带来约 ±8px 误差
        for s in (rough - 8)...(rough + 8) {
            let overlap = h - abs(s)
            guard overlap > 24 else { continue }
            // 两端各跳过 10%，避开紧挨固定栏、没被识别进去的过渡行
            let skip = overlap / 10
            let n = overlap - skip * 2
            let sc = s >= 0
                ? meanDiff(prev.rows, next.rows, aStart: top + s + skip, bStart: top + skip, count: n, step: 1)
                : meanDiff(prev.rows, next.rows, aStart: top + skip, bStart: top - s + skip, count: n, step: 1)
            // 得分几乎相同（空白区）时取最接近 Vision 估计的
            if sc < bestScore - 0.05 || (abs(sc - bestScore) <= 0.05 && abs(s - rough) < abs(best - rough)) {
                bestScore = min(sc, bestScore); best = s
            }
        }
        return best
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

    /// [from, to) 范围内有纹理的行，是否绝大多数与上一帧同位置完全相同（= 未刷新的旧内容）
    private static func isStale(prev: Frame, next: Frame, from: Int, to: Int) -> Bool {
        var textured = 0, same = 0
        for i in from..<to where next.textured[i] {
            textured += 1
            if rowDiff(prev.rows[i], next.rows[i]) < 2.0 { same += 1 }
        }
        return textured >= 6 && Double(same) / Double(textured) > 0.8
    }

    // MARK: - 固定区域

    /// 从顶部（或底部）起，同一位置内容不变的连续行数。整段都是单色时视为滚动中的空白而不是固定栏。
    private static func staticRun(_ a: Frame, _ b: Frame, fromTop: Bool) -> Int {
        staticRuns(a, b, fromTop: fromTop).textured
    }

    /// (所有静止行数, 截止到最后一个有纹理行的静止行数)；整段单色时都为 0
    private static func staticRuns(_ a: Frame, _ b: Frame, fromTop: Bool) -> (full: Int, textured: Int) {
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
        return texturedCount >= 2 ? (run, lastTexturedRun) : (0, 0)
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

        // 快速路径：先在预期滚动量附近找（连续滚动时相邻帧位移变化很小）
        if expected > 0 {
            let lo = max(minShift, expected - 48), hi = min(maxShift, expected + 48)
            if lo <= hi {
                var local = (shift: lo, score: Double.infinity)
                for s in lo...hi {
                    let sc = score(s, step: 3)
                    if sc < local.score { local = (s, sc) }
                }
                if local.score < 1.0 {
                    let fine = score(local.shift, step: 1)
                    let halves = halfScores(prev: prev, next: next, top: top, bandH: bandH, shift: local.shift)
                    if fine < 1.5, halves.0 < 6, halves.1 < 6 { return (local.shift, fine) }
                }
            }
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
        guard best.score < 6 else {
            lastFailure = Diagnostics(shift: best.shift, score: best.score, reason: "score")
            return nil
        }
        // 重叠区上下两半分别校验：撕裂帧（一半已刷新、一半未刷新）整体得分可能仍低，但必有一半对不上
        let halves = halfScores(prev: prev, next: next, top: top, bandH: bandH, shift: best.shift)
        if halves.0 >= 6 || halves.1 >= 6 {
            lastFailure = Diagnostics(shift: best.shift, score: best.score, halves: halves, reason: "halves")
            return nil
        }

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

    private static func halfScores(prev: Frame, next: Frame, top: Int, bandH: Int, shift: Int) -> (Double, Double) {
        let overlap = bandH - shift
        let skip = overlap / 10
        let usable = overlap - skip
        guard usable >= 16 else { return (0, 0) }
        let half = usable / 2
        let a = meanDiff(prev.rows, next.rows, aStart: top + shift + skip, bStart: top + skip, count: half, step: 1)
        let b = meanDiff(prev.rows, next.rows, aStart: top + shift + skip + half, bStart: top + skip + half, count: usable - half, step: 1)
        return (a, b)
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
