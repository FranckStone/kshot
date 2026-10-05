import AppKit

/// 长截图拼接：比较相邻两帧，找出内容向上滚动的像素距离，把新露出的部分接到底部。
/// 会自动识别固定不动的顶栏 / 底栏（同一位置内容不变的行），匹配与追加时跳过它们，底栏在最后补一次。
final class ImageStitcher: @unchecked Sendable {
    final class Frame: @unchecked Sendable {
        init(image: CGImage, width: Int, height: Int, rows: [[UInt8]], textured: [Bool]) {
            self.image = image; self.width = width; self.height = height; self.rows = rows; self.textured = textured
        }
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

    private(set) var lastDiagnostics = Diagnostics()
    private let maxTotalHeight: Int
    private static let sampleColumns = 64
    private let estimator = VisionOffsetEstimator()

    // MARK: - 画布模型
    // 每一帧按位移放到一张纵向画布上（canvas 行号 = 帧在画布上的位置 + 帧内行号），向下、向上滚动都只会补充内容。
    // 新露出的行要等滚到视野中部（提交线）才写入画布：取自画面中部的像素，避开底部悬浮按钮这类覆盖层。

    /// 锚点：最后一次成功匹配的帧
    private var anchor: Frame?
    private var anchorY = 0
    private var failStreak = 0
    /// 固定栏候选：同一高度（±2px）连续出现的次数，达到 3 次才认定
    private var headerCandidate = (h: 0, n: 0)
    private var footerCandidate = (h: 0, n: 0)
    /// 画布最上 / 最下一行分别取自帧内第几行（固定栏确认后用来裁掉已混进来的栏）
    private var topEdgeFrameRow = 0
    private var bottomEdgeFrameRow = 0
    /// 关键帧：已放到画布上的帧（间隔约 1/3 屏），接不上当前锚点时用来找回位置
    private var keyframes: [(frame: Frame, y: Int)] = []
    private let maxKeyframes = 40
    /// 固定顶栏 / 底栏（一旦识别就保持，取历次最大值）
    private var stickyTop = 0
    private var stickyFooter = 0
    /// 已写入画布的范围 [committedMin, committedMax)
    private var committedMin: Int?
    private var committedMax = 0
    private var downStrips: [CGImage] = []   // 覆盖 [base, committedMax)，按顺序
    private var upStrips: [CGImage] = []     // 覆盖 [committedMin, base)，越靠后越靠上
    private var lastShift = 0

    /// 向下滚动时，帧内这一比例以上的行才写入（越大越靠下）
    private let commitDownRatio = 0.6
    /// 向上滚动时，帧内这一比例以下的行才写入
    private let commitUpRatio = 0.35

    init(maxTotalHeight: Int = 30000) {
        self.maxTotalHeight = maxTotalHeight
    }

    var width: Int { anchor?.width ?? 0 }

    /// 调试：当前锚点在画布上的位置与已提交范围
    var debugState: String { "anchorY=\(anchorY) committed=[\(committedMin.map(String.init) ?? "nil"),\(committedMax)) top=\(stickyTop) footer=\(stickyFooter)" }

    /// 当前已拼接高度（含固定栏）
    var totalHeight: Int {
        guard let a = anchor else { return 0 }
        guard let cMin = committedMin else { return a.height }
        return (committedMax - cMin) + stickyTop + stickyFooter
    }

    func push(_ image: CGImage, expectedShift: Int = 0) -> Outcome {
        guard let frame = Self.makeFrame(image) else { return .noMatch }
        return push(frame: frame, expectedShift: expectedShift)
    }

    /// 两帧是否几乎相同（用于判断滚动动画是否已静止）
    static func isSame(_ a: Frame, _ b: Frame) -> Bool {
        a.width == b.width && a.height == b.height && meanDiff(a.rows, b.rows, aStart: 0, bStart: 0, count: a.height, step: 3) < 1.5
    }

    /// 喂入一帧。expectedShift 仅为兼容旧调用保留。
    func push(frame: Frame, expectedShift: Int = 0) -> Outcome {
        guard let prev = anchor else {
            // 起点：直接用第一帧；若它是过渡画面，后面连续接不上时会自动换掉
            anchor = frame
            anchorY = 0
            keyframes = [(frame, 0)]
            return .appended(rows: frame.height)
        }
        guard prev.width == frame.width, prev.height == frame.height else { return .noMatch }
        if Self.isSame(prev, frame) { failStreak = 0; return .unchanged }

        let outcome = place(frame, relativeTo: prev, at: anchorY)
        if case .noMatch = outcome {
            failStreak += 1
            if committedMin == nil {
                // 还没拼进内容：连续接不上说明起点帧不对（过渡画面），换成当前帧
                if failStreak >= 4 {
                    anchor = frame; anchorY = 0; keyframes = [(frame, 0)]; failStreak = 0
                    lastDiagnostics.reason += " re-anchor"
                }
                return .noMatch
            }
            // 已有内容：和关键帧逐个比，找回位置（从最近的开始）
            for k in keyframes.reversed() where k.frame !== prev {
                let saved = (anchor, anchorY)
                anchor = k.frame; anchorY = k.y
                let o = place(frame, relativeTo: k.frame, at: k.y)
                if case .noMatch = o { anchor = saved.0; anchorY = saved.1; continue }
                failStreak = 0
                lastDiagnostics.reason += " via-keyframe"
                return o
            }
            return .noMatch
        }
        failStreak = 0
        return outcome
    }

    /// 尝试把 frame 放到画布上：ref 是已在画布上的帧，refY 是它的位置
    private func place(_ frame: Frame, relativeTo prev: Frame, at refY: Int) -> Outcome {

        let h = frame.height
        let footerRuns = Self.staticRuns(prev, frame, fromTop: false)
        let headerRuns = Self.staticRuns(prev, frame, fromTop: true)
        let matchTop = max(stickyTop, headerRuns.full)
        let matchBottom = h - max(stickyFooter, footerRuns.full)
        guard matchBottom - matchTop > 48 else { return .noMatch }

        // 1. 位移：半分辨率 Vision → 全分辨率 Vision → 行签名搜索（仅向下）
        var shift: Int?
        var source = ""
        var roughDy = 0.0
        let band = CGRect(x: 0, y: matchTop, width: frame.width, height: matchBottom - matchTop)
        if let cur = frame.image.cropping(to: band), let pre = prev.image.cropping(to: band),
           let est = estimator.estimateFast(current: cur, previous: pre) ?? estimator.estimate(current: cur, previous: pre) {
            shift = Self.refine(prev: prev, next: frame, around: Int(est.dy.rounded()), top: matchTop, bottom: matchBottom)
            source = est.source
            roughDy = Double(est.dy)
        } else {
            // 行签名搜索：向下、向上各试一次，取重叠区更吻合的
            let down = Self.findShift(prev: prev, next: frame, top: matchTop, bottom: matchBottom, expected: max(0, lastShift))
            let up = Self.findShift(prev: frame, next: prev, top: matchTop, bottom: matchBottom, expected: max(0, -lastShift))
            switch (down, up) {
            case let (d?, u?): shift = d.1 <= u.1 ? d.0 : -u.0
            case let (d?, nil): shift = d.0
            case let (nil, u?): shift = -u.0
            default: break
            }
            source = "rows"
        }
        guard let s = shift else {
            lastDiagnostics = Diagnostics(reason: "none")
            return .noMatch
        }

        // 2. 校验：重叠区必须真的吻合，且有足够的纹理（空白对空白无法确定位移）
        let v = Self.verify(prev: prev, next: frame, shift: s, top: matchTop, bottom: matchBottom)
        lastDiagnostics = Diagnostics(shift: s, score: v.diff, header: headerRuns.textured, footer: footerRuns.textured,
                                      halves: v.halves, reason: v.ok ? source : "verify(\(source))", rough: roughDy)
        guard v.ok else { return .noMatch }
        if s == 0 { return .unchanged }

        // 3. 固定栏：同一高度连续 3 次匹配都静止才认定（避免内容恰好相同被误判），一旦认定就保持
        func confirm(_ cand: inout (h: Int, n: Int), _ detected: Int) -> Int? {
            guard detected > 0 else { cand = (0, 0); return nil }
            if abs(cand.h - detected) <= 2 { cand.n += 1; cand.h = max(cand.h, detected) } else { cand = (detected, 1) }
            return cand.n >= 3 ? cand.h : nil
        }
        if let t = confirm(&headerCandidate, headerRuns.textured), t > stickyTop {
            stickyTop = t
            trimTopEdge(toFrameRow: t)
        }
        if let f = confirm(&footerCandidate, footerRuns.textured), f > stickyFooter {
            stickyFooter = f
            trimBottomEdge(toFrameRow: h - f)
        }
        let top = stickyTop, bottom = h - stickyFooter
        let frameY = refY + s

        // 4. 首次移动：把锚点帧中部以上的内容作为起点写入
        if committedMin == nil {
            let lineDown = top + Int(Double(bottom - top) * commitDownRatio)
            let lineUp = top + Int(Double(bottom - top) * commitUpRatio)
            let first = s > 0 ? (top, lineDown) : (lineUp, bottom)
            if let img = prev.image.cropping(to: CGRect(x: 0, y: first.0, width: prev.width, height: first.1 - first.0)) {
                downStrips = [img]
                committedMin = anchorY + first.0
                committedMax = anchorY + first.1
                topEdgeFrameRow = first.0
                bottomEdgeFrameRow = first.1
            }
        }
        let before = totalHeight

        // 掉头（≥12px）：上一个方向上还没过提交线的行以后不会再经过提交线了，用掉头那一帧补上
        if lastShift != 0, (lastShift > 0) != (s > 0), abs(s) >= 12 {
            if lastShift > 0 {
                commitDown(from: prev, frameY: anchorY, endRow: bottom, top: top)
            } else {
                commitUp(from: prev, frameY: anchorY, startRow: top, bottom: bottom)
            }
        }

        if s > 0 {
            // 先用锚点补上滚得太快时跳过的行（它们只在锚点的下半部出现过）
            if committedMax < frameY + top {
                commitDown(from: prev, frameY: anchorY, endRow: min(bottom, frameY + top - anchorY), top: top)
            }
            let line = top + Int(Double(bottom - top) * commitDownRatio)
            if frameY + line > committedMax { commitDown(from: frame, frameY: frameY, endRow: line, top: top) }
        } else {
            if let cMin = committedMin, cMin > frameY + bottom {
                commitUp(from: prev, frameY: anchorY, startRow: max(top, frameY + bottom - anchorY), bottom: bottom)
            }
            let line = top + Int(Double(bottom - top) * commitUpRatio)
            if let cMin = committedMin, frameY + line < cMin { commitUp(from: frame, frameY: frameY, startRow: line, bottom: bottom) }
        }

        anchor = frame
        anchorY = frameY
        lastShift = s
        if let last = keyframes.last, abs(last.y - frameY) >= frame.height / 3 {
            keyframes.append((frame, frameY))
            if keyframes.count > maxKeyframes { keyframes.removeFirst() }
        }
        return .appended(rows: max(0, totalHeight - before))
    }

    /// 把 frame 中 [committedMax - frameY, endRow) 行接到画布底部
    private func commitDown(from f: Frame, frameY: Int, endRow: Int, top: Int) {
        let startRow = max(top, committedMax - frameY)
        guard endRow > startRow, totalHeight + (endRow - startRow) <= maxTotalHeight,
              let img = f.image.cropping(to: CGRect(x: 0, y: startRow, width: f.width, height: endRow - startRow)) else { return }
        downStrips.append(img)
        committedMax = frameY + endRow
        bottomEdgeFrameRow = endRow
    }

    /// 顶栏确认后：画布最上面若混进了栏的行（取自帧内 < row 的行），裁掉
    private func trimTopEdge(toFrameRow row: Int) {
        let n = row - topEdgeFrameRow
        guard n > 0, let cMin = committedMin else { return }
        if var s = upStrips.last, s.height > n, let c = s.cropping(to: CGRect(x: 0, y: n, width: s.width, height: s.height - n)) {
            s = c; upStrips[upStrips.count - 1] = s
        } else if upStrips.isEmpty, let s = downStrips.first, s.height > n,
                  let c = s.cropping(to: CGRect(x: 0, y: n, width: s.width, height: s.height - n)) {
            downStrips[0] = c
        } else { return }
        committedMin = cMin + n
        topEdgeFrameRow = row
    }

    /// 底栏确认后：画布最下面若混进了栏的行，裁掉
    private func trimBottomEdge(toFrameRow row: Int) {
        let n = bottomEdgeFrameRow - row
        guard n > 0, let s = downStrips.last, s.height > n,
              let c = s.cropping(to: CGRect(x: 0, y: 0, width: s.width, height: s.height - n)) else { return }
        downStrips[downStrips.count - 1] = c
        committedMax -= n
        bottomEdgeFrameRow = row
    }

    /// 把 frame 中 [startRow, committedMin - frameY) 行接到画布顶部
    private func commitUp(from f: Frame, frameY: Int, startRow: Int, bottom: Int) {
        guard let cMin = committedMin else { return }
        let endRow = min(bottom, cMin - frameY)
        guard endRow > startRow, totalHeight + (endRow - startRow) <= maxTotalHeight,
              let img = f.image.cropping(to: CGRect(x: 0, y: startRow, width: f.width, height: endRow - startRow)) else { return }
        upStrips.append(img)
        committedMin = frameY + startRow
        topEdgeFrameRow = startRow
    }

    /// 结束时把锚点帧里还没写入的上下两端补上
    func flush() {
        guard let a = anchor, committedMin != nil else { return }
        let top = stickyTop, bottom = a.height - stickyFooter
        commitDown(from: a, frameY: anchorY, endRow: bottom, top: top)
        commitUp(from: a, frameY: anchorY, startRow: top, bottom: bottom)
    }

    /// 重叠区校验：整体差异、上下两半差异、纹理行数
    private static func verify(prev: Frame, next: Frame, shift s: Int, top: Int, bottom: Int) -> (ok: Bool, diff: Double, halves: (Double, Double)) {
        let overlap = (bottom - top) - abs(s)
        guard overlap >= 32 else { return (false, .infinity, (0, 0)) }
        let aStart = s >= 0 ? top + s : top
        let bStart = s >= 0 ? top : top - s
        var textured = 0
        for i in 0..<overlap where next.textured[bStart + i] { textured += 1 }
        let half = overlap / 2
        let d = meanDiff(prev.rows, next.rows, aStart: aStart, bStart: bStart, count: overlap, step: 1)
        let h1 = meanDiff(prev.rows, next.rows, aStart: aStart, bStart: bStart, count: half, step: 1)
        let h2 = meanDiff(prev.rows, next.rows, aStart: aStart + half, bStart: bStart + half, count: overlap - half, step: 1)
        let ok = textured >= 8 && d < 4 && h1 < 6 && h2 < 6
        return (ok, d, (h1, h2))
    }

    /// 在 Vision 的粗略位移附近 ±8px 用行签名找最吻合的整像素位移
    private static func refine(prev: Frame, next: Frame, around rough: Int, top: Int, bottom: Int) -> Int {
        let h = bottom - top
        var best = rough, bestScore = Double.infinity
        for s in (rough - 8)...(rough + 8) {
            let overlap = h - abs(s)
            guard overlap > 24 else { continue }
            let skip = overlap / 10
            let n = overlap - skip * 2
            let sc = s >= 0
                ? meanDiff(prev.rows, next.rows, aStart: top + s + skip, bStart: top + skip, count: n, step: 1)
                : meanDiff(prev.rows, next.rows, aStart: top + skip, bStart: top - s + skip, count: n, step: 1)
            if sc < bestScore - 0.05 || (abs(sc - bestScore) <= 0.05 && abs(s - rough) < abs(best - rough)) {
                bestScore = min(sc, bestScore); best = s
            }
        }
        return best
    }

    /// 预览：画布底部若干像素 + 锚点帧里还没写入的部分
    func preview(minHeight: Int) -> CGImage? {
        guard let a = anchor else { return nil }
        guard committedMin != nil else { return a.image }
        var picked: [CGImage] = []
        let pendingStart = max(stickyTop, committedMax - anchorY)
        let pendingEnd = a.height - stickyFooter
        if pendingEnd > pendingStart, let p = a.image.cropping(to: CGRect(x: 0, y: pendingStart, width: a.width, height: pendingEnd - pendingStart)) {
            picked.append(p)
        }
        var hgt = picked.first?.height ?? 0
        for s in downStrips.reversed() {
            picked.insert(s, at: 0)
            hgt += s.height
            if hgt >= minHeight { break }
        }
        return Self.stack(picked)
    }

    /// 合成整张图：顶栏 + 画布 + 底栏
    func compose() -> CGImage? {
        guard let a = anchor else { return nil }
        guard committedMin != nil else { return a.image }
        flush()
        var all: [CGImage] = []
        if stickyTop > 0, let hdr = a.image.cropping(to: CGRect(x: 0, y: 0, width: a.width, height: stickyTop)) { all.append(hdr) }
        all.append(contentsOf: upStrips.reversed())
        all.append(contentsOf: downStrips)
        if stickyFooter > 0, let ftr = a.image.cropping(to: CGRect(x: 0, y: a.height - stickyFooter, width: a.width, height: stickyFooter)) { all.append(ftr) }
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
