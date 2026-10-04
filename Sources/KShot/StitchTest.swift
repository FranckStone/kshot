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
