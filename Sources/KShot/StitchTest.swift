import AppKit

/// 拼接算法自测：画一张很长的合成图，按固定/随机步长模拟滚动抓帧，和原图逐像素比对。
enum StitchTest {
    static func run() {
        let w = 800, viewport = 500, total = 3200
        guard let tall = makeTallImage(width: w, height: total) else { Log.info("stitch-test: 生成失败"); return }
        for (name, steps) in [("fixed", Array(repeating: 250, count: 20)), ("random", [230, 190, 260, 240, 120, 250, 300, 180, 220, 260, 240, 250, 250])] {
            let stitcher = ImageStitcher()
            var offset = 0
            var frames: [CGImage] = []
            frames.append(tall.cropping(to: CGRect(x: 0, y: 0, width: w, height: viewport))!)
            for s in steps {
                offset = min(total - viewport, offset + s)
                frames.append(tall.cropping(to: CGRect(x: 0, y: offset, width: w, height: viewport))!)
            }
            var outcomes: [String] = []
            for f in frames {
                switch stitcher.push(f, expectedShift: 250) {
                case .appended(let r): outcomes.append("+\(r)")
                case .unchanged: outcomes.append("=")
                case .noMatch: outcomes.append("x")
                }
            }
            guard let result = stitcher.compose() else { Log.info("stitch-test \(name): compose 失败"); continue }
            let diff = pixelDiff(result, tall)
            Log.info("stitch-test \(name): result \(result.width)x\(result.height) expected \(w)x\(total) outcomes=\(outcomes.joined(separator: " ")) diff=\(String(format: "%.3f", diff))")
            print("stitch-test \(name): \(result.width)x\(result.height) / \(w)x\(total) diff=\(String(format: "%.3f", diff)) \(outcomes.joined(separator: " "))")
        }

        // 固定顶栏 + 底栏：每帧 = 顶栏(60) + 内容窗口(380) + 底栏(60)，期望结果 = 顶栏 + 完整内容 + 底栏
        let headerH = 60, footerH = 60, inner = viewport - headerH - footerH
        guard let header = makeBar(width: w, height: headerH, seed: 1), let footer = makeBar(width: w, height: footerH, seed: 2) else { return }
        let stitcher = ImageStitcher()
        var offset = 0
        var outcomes: [String] = []
        var steps = Array(repeating: 170, count: 20)
        steps[3] = 110; steps[7] = 200
        for (i, s) in ([0] + steps).enumerated() {
            if i > 0 { offset = min(total - inner, offset + s) }
            guard let content = tall.cropping(to: CGRect(x: 0, y: offset, width: w, height: inner)),
                  let frame = stack([header, content, footer]) else { continue }
            switch stitcher.push(frame, expectedShift: 170) {
            case .appended(let r): outcomes.append("+\(r)")
            case .unchanged: outcomes.append("=")
            case .noMatch: outcomes.append("x")
            }
        }
        guard let result = stitcher.compose(), let expectedImg = stack([header, tall, footer]) else { return }
        let diff = pixelDiff(result, expectedImg)
        let d = stitcher.lastDiagnostics
        print("stitch-test fixed-bars: \(result.width)x\(result.height) / \(w)x\(total + headerH + footerH) diff=\(String(format: "%.3f", diff)) header=\(d.header) footer=\(d.footer) \(outcomes.joined(separator: " "))")
    }

    /// 有纹理的横条（模拟固定的工具栏/输入框）
    static func makeBar(width w: Int, height h: Int, seed: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.9, green: 0.92, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for i in 0..<12 {
            ctx.setFillColor(CGColor(red: Double((i * 37 + seed * 11) % 100) / 100, green: Double((i * 53 + seed * 7) % 100) / 100, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 20 + i * 60, y: 10 + (i * seed) % 20, width: 40, height: 24))
        }
        return ctx.makeImage()
    }

    /// 竖向堆叠（第一个在最上面）
    static func stack(_ parts: [CGImage]) -> CGImage? {
        let w = parts[0].width
        let h = parts.reduce(0) { $0 + $1.height }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = h
        for p in parts {
            y -= p.height
            ctx.draw(p, in: CGRect(x: 0, y: y, width: p.width, height: p.height))
        }
        return ctx.makeImage()
    }

    /// 合成内容：渐变底 + 随机色块 + 文字，确保有足够纹理
    static func makeTallImage(width w: Int, height h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var rng = SystemRandomNumberGenerator()
        for i in 0..<140 {
            let x = Int.random(in: 0..<(w - 80), using: &rng), y = Int.random(in: 0..<(h - 40), using: &rng)
            ctx.setFillColor(CGColor(red: Double(i % 7) / 7, green: Double(i % 5) / 5, blue: Double(i % 3) / 3, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: Int.random(in: 20...80, using: &rng), height: Int.random(in: 8...40, using: &rng)))
        }
        // 一些空白带，测试单调区域
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 1200, width: w, height: 180))
        return ctx.makeImage()
    }

    /// 平均每通道差异（0 为完全一致）；尺寸不同则返回 -1
    static func pixelDiff(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return -1 }
        guard let fa = ImageStitcher.makeFrame(a), let fb = ImageStitcher.makeFrame(b) else { return -1 }
        var total = 0, n = 0
        for y in 0..<fa.rows.count {
            for c in 0..<fa.rows[y].count { total += abs(Int(fa.rows[y][c]) - Int(fb.rows[y][c])); n += 1 }
        }
        return Double(total) / Double(max(1, n))
    }
}
