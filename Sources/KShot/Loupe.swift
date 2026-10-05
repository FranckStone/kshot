import AppKit

/// 选区时跟随鼠标的放大镜：像素网格 + 坐标 + 颜色值
enum Loupe {
    /// 放大的像素数（奇数，正中间是鼠标所在像素）
    static let pixels = 17
    static let cell: CGFloat = 9
    static var side: CGFloat { CGFloat(pixels) * cell }
    static let infoHeight: CGFloat = 70

    struct RGB {
        let r, g, b: UInt8
        var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
        var rgbText: String { "\(r), \(g), \(b)" }
        var nsColor: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    }

    /// 屏幕局部坐标（pt）→ 截图像素坐标
    static func pixel(at p: CGPoint, shot: ScreenShot) -> (Int, Int) {
        let x = min(max(0, Int(p.x * shot.scale)), shot.image.width - 1)
        let y = min(max(0, Int(p.y * shot.scale)), shot.image.height - 1)
        return (x, y)
    }

    static func color(at p: CGPoint, shot: ScreenShot) -> RGB? {
        let (x, y) = pixel(at: p, shot: shot)
        return color(ofPixel: x, y, in: shot.image)
    }

    static func color(ofPixel x: Int, _ y: Int, in image: CGImage) -> RGB? {
        guard let one = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var buf = [UInt8](repeating: 0, count: 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return ok ? RGB(r: buf[0], g: buf[1], b: buf[2]) : nil
    }

    /// 在 flipped 的上下文里画放大镜（位于鼠标右下方，靠边时翻到另一侧）
    static func draw(at p: CGPoint, shot: ScreenShot, in ctx: CGContext, bounds: CGRect) {
        let total = CGSize(width: side, height: side + infoHeight)
        let offset: CGFloat = 22
        var origin = CGPoint(x: p.x + offset, y: p.y + offset)
        if origin.x + total.width > bounds.maxX - 4 { origin.x = p.x - offset - total.width }
        if origin.y + total.height > bounds.maxY - 4 { origin.y = p.y - offset - total.height }
        let frame = CGRect(origin: origin, size: total)
        let zoomRect = CGRect(origin: origin, size: CGSize(width: side, height: side))

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // 外框阴影 + 圆角裁剪
        let outer = CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 14, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.setFillColor(NSColor(white: 0.08, alpha: 0.88).cgColor)
        ctx.addPath(outer)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(outer)
        ctx.clip()

        // 放大的像素
        let (px, py) = pixel(at: p, shot: shot)
        let half = pixels / 2
        let want = CGRect(x: px - half, y: py - half, width: pixels, height: pixels)
        let imgRect = CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height)
        let crop = want.intersection(imgRect)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(zoomRect)
        if !crop.isEmpty, let sub = shot.image.cropping(to: crop) {
            let dst = CGRect(x: zoomRect.minX + (crop.minX - want.minX) * cell,
                             y: zoomRect.minY + (crop.minY - want.minY) * cell,
                             width: crop.width * cell, height: crop.height * cell)
            ctx.interpolationQuality = .none
            NSImage(cgImage: sub, size: dst.size).draw(in: dst, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                                                       hints: [.interpolation: NSImageInterpolation.none.rawValue])
        }
        // 网格
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        ctx.setLineWidth(0.5)
        for i in 1..<pixels {
            let x = zoomRect.minX + CGFloat(i) * cell
            let y = zoomRect.minY + CGFloat(i) * cell
            ctx.move(to: CGPoint(x: x, y: zoomRect.minY)); ctx.addLine(to: CGPoint(x: x, y: zoomRect.maxY))
            ctx.move(to: CGPoint(x: zoomRect.minX, y: y)); ctx.addLine(to: CGPoint(x: zoomRect.maxX, y: y))
        }
        ctx.strokePath()
        // 十字准星（半透明绿色）+ 中心像素框
        let center = CGRect(x: zoomRect.minX + CGFloat(half) * cell, y: zoomRect.minY + CGFloat(half) * cell, width: cell, height: cell)
        ctx.setFillColor(NSColor.accentGreen.withAlphaComponent(0.25).cgColor)
        ctx.fill(CGRect(x: zoomRect.minX, y: center.minY, width: center.minX - zoomRect.minX, height: cell))
        ctx.fill(CGRect(x: center.maxX, y: center.minY, width: zoomRect.maxX - center.maxX, height: cell))
        ctx.fill(CGRect(x: center.minX, y: zoomRect.minY, width: cell, height: center.minY - zoomRect.minY))
        ctx.fill(CGRect(x: center.minX, y: center.maxY, width: cell, height: zoomRect.maxY - center.maxY))
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(center.insetBy(dx: -0.75, dy: -0.75))
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(0.75)
        ctx.stroke(center.insetBy(dx: -1.9, dy: -1.9))
        ctx.restoreGState()

        // 文字信息
        let info = CGRect(x: frame.minX, y: zoomRect.maxY, width: frame.width, height: infoHeight)
        let rgb = color(ofPixel: px, py, in: shot.image)
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
        NSAttributedString(string: "坐标 \(px), \(py)", attributes: small).draw(at: CGPoint(x: info.minX + 8, y: info.minY + 4))
        if let rgb {
            let sw = CGRect(x: info.minX + 8, y: info.minY + 21, width: 12, height: 12)
            ctx.setFillColor(rgb.nsColor.cgColor)
            ctx.fill(sw)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(sw.insetBy(dx: -0.5, dy: -0.5))
            NSAttributedString(string: rgb.hex, attributes: small).draw(at: CGPoint(x: sw.maxX + 6, y: info.minY + 19))
            NSAttributedString(string: "RGB \(rgb.rgbText)", attributes: small).draw(at: CGPoint(x: info.minX + 8, y: info.minY + 35))
        }
        NSAttributedString(string: "C 复制 HEX   ⇧C 复制 RGB", attributes: dim).draw(at: CGPoint(x: info.minX + 8, y: info.minY + 52))

        // 白色描边
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 9.5, cornerHeight: 9.5, transform: nil))
        ctx.strokePath()
    }
}
