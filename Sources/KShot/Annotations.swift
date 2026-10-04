import AppKit

enum Tool: Equatable {
    case none, rect, ellipse, arrow, pen, mosaic, text
}

enum StrokeSize: Int, CaseIterable {
    case small, medium, large

    var lineWidth: CGFloat {
        switch self {
        case .small: return 2
        case .medium: return 4
        case .large: return 7
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .small: return 14
        case .medium: return 20
        case .large: return 28
        }
    }

    var mosaicWidth: CGFloat {
        switch self {
        case .small: return 14
        case .medium: return 24
        case .large: return 36
        }
    }

    /// 选项面板上圆点的直径
    var dotDiameter: CGFloat {
        switch self {
        case .small: return 5
        case .medium: return 8
        case .large: return 12
        }
    }
}

/// 标注调色板
enum Palette {
    static let colors: [NSColor] = [
        NSColor(hex: 0xFA5151), // 红
        NSColor(hex: 0xFF8F1F), // 橙
        NSColor(hex: 0xFFC300), // 黄
        NSColor(hex: 0x07C160), // 绿
        NSColor(hex: 0x10AEFF), // 蓝
        NSColor(hex: 0x6467F0), // 紫
        NSColor(hex: 0x000000), // 黑
        NSColor(hex: 0xFFFFFF), // 白
    ]
}

/// 一条标注。坐标均为所在屏幕的局部坐标（左上原点，单位 pt）。
struct Annotation {
    enum Kind {
        case rect(CGRect)
        case ellipse(CGRect)
        case arrow(from: CGPoint, to: CGPoint)
        case pen([CGPoint])
        case mosaic([CGPoint])
        case text(origin: CGPoint, string: String, fontSize: CGFloat)
    }

    var kind: Kind
    var color: NSColor
    var size: StrokeSize

    /// 过小/无意义的标注在松手时丢弃
    var isDegenerate: Bool {
        switch kind {
        case .rect(let r), .ellipse(let r):
            return r.width < 3 && r.height < 3
        case .arrow(let a, let b):
            return a.distance(to: b) < 4
        case .pen(let pts), .mosaic(let pts):
            return pts.count < 2
        case .text(_, let s, _):
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func textFont(size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .regular)
    }

    static let textInset = CGSize(width: 4, height: 2)
}

/// 负责把标注画到当前 NSGraphicsContext（要求是 flipped 坐标）。
struct AnnotationRenderer {
    /// 低分辨率的马赛克源图，绘制时放大并关闭插值
    let mosaicImage: NSImage?
    /// 马赛克源图应被拉伸到的区域（整屏）
    let screenBounds: CGRect

    func draw(_ annotations: [Annotation], clip: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        ctx.clip(to: clip)
        for a in annotations { draw(a, in: ctx) }
        ctx.restoreGState()
    }

    func draw(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.size.lineWidth)

        switch a.kind {
        case .rect(let r):
            ctx.stroke(r.insetBy(dx: a.size.lineWidth / 2, dy: a.size.lineWidth / 2))

        case .ellipse(let r):
            ctx.strokeEllipse(in: r.insetBy(dx: a.size.lineWidth / 2, dy: a.size.lineWidth / 2))

        case .arrow(let from, let to):
            drawArrow(from: from, to: to, width: a.size.lineWidth, in: ctx)

        case .pen(let pts):
            ctx.addPath(Self.smoothPath(pts))
            ctx.strokePath()

        case .mosaic(let pts):
            guard let mosaicImage else { return }
            let path = Self.smoothPath(pts)
            let stroked = path.copy(strokingWithWidth: a.size.mosaicWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
            ctx.addPath(stroked)
            ctx.clip()
            ctx.interpolationQuality = .none
            NSGraphicsContext.current?.imageInterpolation = .none
            mosaicImage.draw(in: screenBounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])

        case .text(let origin, let string, let fontSize):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Annotation.textFont(size: fontSize),
                .foregroundColor: a.color,
            ]
            let p = CGPoint(x: origin.x + Annotation.textInset.width, y: origin.y + Annotation.textInset.height)
            NSAttributedString(string: string, attributes: attrs).draw(at: p)
        }
    }

    private func drawArrow(from: CGPoint, to: CGPoint, width: CGFloat, in ctx: CGContext) {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return }
        let ux = dx / len, uy = dy / len
        let headLen = min(len, max(14, width * 4.5))
        let headHalf = max(6, width * 2.2)
        let base = CGPoint(x: to.x - ux * headLen, y: to.y - uy * headLen)
        // 箭杆
        ctx.move(to: from)
        ctx.addLine(to: CGPoint(x: to.x - ux * headLen * 0.6, y: to.y - uy * headLen * 0.6))
        ctx.strokePath()
        // 箭头（实心三角）
        let px = -uy, py = ux
        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: base.x + px * headHalf, y: base.y + py * headHalf))
        ctx.addLine(to: CGPoint(x: base.x - px * headHalf, y: base.y - py * headHalf))
        ctx.closePath()
        ctx.fillPath()
    }

    /// 用二次贝塞尔经过中点平滑折线
    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.addLine(to: first)
            return path
        }
        if pts.count == 2 {
            path.addLine(to: pts[1])
            return path
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    /// 生成马赛克源图：把截图缩小到每个色块 1 像素
    static func makeMosaicSource(from image: CGImage, blockPixels: Int) -> NSImage? {
        let w = max(1, image.width / max(1, blockPixels))
        let h = max(1, image.height / max(1, blockPixels))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        return NSImage(cgImage: small, size: NSSize(width: w, height: h))
    }
}
