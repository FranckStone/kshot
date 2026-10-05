import AppKit

// 用法: make-icon <variant> <out.png>
// variant: aperture | crop | lens | glow | fold | sheet(拼图对比)
let size: CGFloat = 1024
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[1] : "aperture"
let outPath = CommandLine.arguments.last!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a).cgColor
}
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func gradient(_ stops: [(UInt32, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: stops.map { rgb($0.0) } as CFArray, locations: stops.map { $0.1 })!
}
func u(_ deg: CGFloat) -> CGPoint { CGPoint(x: cos(deg * .pi / 180), y: sin(deg * .pi / 180)) }

/// macOS 圆角方形底 + 阴影 + 渐变
func drawBase(_ ctx: CGContext, _ rect: CGRect, top: UInt32, mid: UInt32, bottom: UInt32) -> CGRect {
    let box = rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1)
    let radius = box.width * 0.224
    let path = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -rect.height * 0.012), blur: rect.height * 0.03, color: rgb(0x000000, 0.35))
    ctx.addPath(path); ctx.setFillColor(rgb(mid)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(gradient([(top, 0), (mid, 0.55), (bottom, 1)]),
                           start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
    let glow = CGGradient(colorsSpace: srgb, colors: [rgb(0xFFFFFF, 0.20), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    let gc = CGPoint(x: box.midX, y: box.maxY + box.height * 0.1)
    ctx.drawRadialGradient(glow, startCenter: gc, startRadius: 0, endCenter: gc, endRadius: box.width * 0.9, options: [])
    ctx.restoreGState()
    return box
}

func softShadow(_ ctx: CGContext, _ s: CGFloat, alpha: CGFloat = 0.25) {
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.014, color: rgb(0x000000, alpha))
}

// 1. 光圈：六片快门叶片
func drawAperture(_ ctx: CGContext, _ rect: CGRect) {
    let box = drawBase(ctx, rect, top: 0x34E08A, mid: 0x07C160, bottom: 0x05874A)
    let s = box.width
    let c = CGPoint(x: box.midX, y: box.midY)
    let R = s * 0.335, r = s * 0.135, w = s * 0.075
    ctx.saveGState()
    softShadow(ctx, s)
    // 外环
    ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(w)
    ctx.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
    ctx.restoreGState()
    // 叶片：六条与内圆相切的粗线，裁剪到外环内
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - R + w * 0.45, y: c.y - R + w * 0.45, width: (R - w * 0.45) * 2, height: (R - w * 0.45) * 2))
    ctx.clip()
    ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(w * 0.82); ctx.setLineCap(.butt)
    for i in 0..<6 {
        let a = CGFloat(i) * 60 + 15
        let t = CGPoint(x: c.x + r * u(a).x, y: c.y + r * u(a).y)
        let d = u(a + 90)
        ctx.move(to: CGPoint(x: t.x - d.x * r * 0.577, y: t.y - d.y * r * 0.577)) // 与前一条相切线的交点
        ctx.addLine(to: CGPoint(x: t.x + d.x * R * 1.5, y: t.y + d.y * R * 1.5))
    }
    ctx.strokePath()
    ctx.restoreGState()
}

// 0. 取景框：四个白色角
func drawCorners(_ ctx: CGContext, _ rect: CGRect) {
    let box = drawBase(ctx, rect, top: 0x3FE893, mid: 0x07C160, bottom: 0x038A4A)
    let s = box.width
    let frame = box.insetBy(dx: s * 0.20, dy: s * 0.20)
    let arm = frame.width * 0.25
    let lw = s * 0.075
    ctx.saveGState()
    softShadow(ctx, s)
    ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let corners: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: frame.minX, y: frame.maxY - arm), CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.minX + arm, y: frame.maxY)),
        (CGPoint(x: frame.maxX - arm, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY - arm)),
        (CGPoint(x: frame.maxX, y: frame.minY + arm), CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.maxX - arm, y: frame.minY)),
        (CGPoint(x: frame.minX + arm, y: frame.minY), CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.minX, y: frame.minY + arm)),
    ]
    for (a, b, c) in corners { ctx.move(to: a); ctx.addLine(to: b); ctx.addLine(to: c) }
    ctx.strokePath()
    ctx.restoreGState()
}

// 0b. 取景框 + 中心图形（几种备选）
func drawCornersWith(_ ctx: CGContext, _ rect: CGRect, center kind: String) {
    drawCorners(ctx, rect)
    let box = rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1)
    let s = box.width
    let c = CGPoint(x: box.midX, y: box.midY)
    ctx.saveGState()
    softShadow(ctx, s)
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    switch kind {
    case "dot":
        // 实心圆点：快门 / 对焦点
        let r = s * 0.085
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    case "ring":
        // 镜头：外环 + 内点
        let r = s * 0.15
        ctx.setLineWidth(s * 0.05)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        let r2 = s * 0.055
        ctx.fillEllipse(in: CGRect(x: c.x - r2, y: c.y - r2, width: r2 * 2, height: r2 * 2))
    case "cross":
        // 十字准星
        let a = s * 0.11
        ctx.setLineWidth(s * 0.05)
        ctx.move(to: CGPoint(x: c.x - a, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + a, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - a)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + a))
        ctx.strokePath()
    case "spark":
        // 四角星：闪光 / 截取的瞬间
        let R = s * 0.15, r = s * 0.035
        let path = CGMutablePath()
        for i in 0..<8 {
            let ang = CGFloat(i) * .pi / 4 + .pi / 2
            let rad = i % 2 == 0 ? R : r
            let p = CGPoint(x: c.x + cos(ang) * rad, y: c.y + sin(ang) * rad)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        ctx.addPath(path); ctx.fillPath()
    case "aperture":
        // 小光圈：六片叶片
        let R = s * 0.15, rr = s * 0.055, w = s * 0.04
        ctx.setLineWidth(w)
        ctx.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - R + w * 0.4, y: c.y - R + w * 0.4, width: (R - w * 0.4) * 2, height: (R - w * 0.4) * 2))
        ctx.clip()
        ctx.setLineWidth(w * 0.85); ctx.setLineCap(.butt)
        for i in 0..<6 {
            let a = CGFloat(i) * 60 + 15
            let t = CGPoint(x: c.x + rr * u(a).x, y: c.y + rr * u(a).y)
            let d = u(a + 90)
            ctx.move(to: CGPoint(x: t.x - d.x * rr * 0.577, y: t.y - d.y * rr * 0.577))
            ctx.addLine(to: CGPoint(x: t.x + d.x * R * 1.5, y: t.y + d.y * R * 1.5))
        }
        ctx.strokePath()
        ctx.restoreGState()
    default:
        break
    }
    ctx.restoreGState()
}

// 2. 裁切：两个互扣的 L 形
func drawCrop(_ ctx: CGContext, _ rect: CGRect) {
    let box = drawBase(ctx, rect, top: 0x34E08A, mid: 0x07C160, bottom: 0x05874A)
    let s = box.width
    let c = CGPoint(x: box.midX, y: box.midY)
    let off = s * 0.135, arm = s * 0.46, w = s * 0.085
    let a = CGPoint(x: c.x - off, y: c.y + off) // 左上 L 的拐角
    let b = CGPoint(x: c.x + off, y: c.y - off) // 右下 L 的拐角
    // 内部区域微亮
    ctx.setFillColor(rgb(0xFFFFFF, 0.22))
    ctx.fill(CGRect(x: a.x, y: b.y, width: b.x - a.x, height: a.y - b.y))
    ctx.saveGState()
    softShadow(ctx, s)
    ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(w); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: a.x, y: a.y - arm)); ctx.addLine(to: a); ctx.addLine(to: CGPoint(x: a.x + arm, y: a.y))
    ctx.move(to: CGPoint(x: b.x, y: b.y + arm)); ctx.addLine(to: b); ctx.addLine(to: CGPoint(x: b.x - arm, y: b.y))
    ctx.strokePath()
    ctx.restoreGState()
}

// 3. 镜头：白色镜筒 + 深色玻璃 + 高光
func drawLens(_ ctx: CGContext, _ rect: CGRect) {
    let box = drawBase(ctx, rect, top: 0x34E08A, mid: 0x07C160, bottom: 0x05874A)
    let s = box.width
    let c = CGPoint(x: box.midX, y: box.midY)
    let R = s * 0.34
    ctx.saveGState()
    softShadow(ctx, s, alpha: 0.3)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
    ctx.restoreGState()
    let r = R * 0.74
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)); ctx.clip()
    ctx.drawRadialGradient(gradient([(0x1E9E62, 0), (0x0B4F33, 0.55), (0x052A1B, 1)]),
                           startCenter: CGPoint(x: c.x - r * 0.3, y: c.y + r * 0.3), startRadius: 0,
                           endCenter: c, endRadius: r * 1.1, options: [])
    // 内环
    ctx.setStrokeColor(rgb(0x7FE8B5, 0.6)); ctx.setLineWidth(s * 0.012)
    ctx.strokeEllipse(in: CGRect(x: c.x - r * 0.72, y: c.y - r * 0.72, width: r * 1.44, height: r * 1.44))
    // 高光
    ctx.setFillColor(rgb(0xFFFFFF, 0.85))
    let h = r * 0.22
    ctx.fillEllipse(in: CGRect(x: c.x - r * 0.52 - h / 2, y: c.y + r * 0.42 - h / 2, width: h, height: h))
    ctx.setFillColor(rgb(0xFFFFFF, 0.35))
    let h2 = r * 0.12
    ctx.fillEllipse(in: CGRect(x: c.x - r * 0.25 - h2 / 2, y: c.y + r * 0.62 - h2 / 2, width: h2, height: h2))
    ctx.restoreGState()
}

// 4. 暗色发光选区
func drawGlow(_ ctx: CGContext, _ rect: CGRect) {
    let box = drawBase(ctx, rect, top: 0x16382A, mid: 0x0B2419, bottom: 0x05150E)
    let s = box.width
    let sel = CGRect(x: box.midX - s * 0.27, y: box.midY - s * 0.21, width: s * 0.54, height: s * 0.42)
    let path = CGPath(roundedRect: sel, cornerWidth: s * 0.04, cornerHeight: s * 0.04, transform: nil)
    ctx.saveGState()
    ctx.setFillColor(rgb(0x07C160, 0.18)); ctx.addPath(path); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: s * 0.06, color: rgb(0x2EE59D, 0.9))
    ctx.setStrokeColor(rgb(0x3BF0A3)); ctx.setLineWidth(s * 0.028)
    ctx.addPath(path); ctx.strokePath()
    ctx.addPath(path); ctx.strokePath()
    let hr = s * 0.032
    ctx.setFillColor(rgb(0xFFFFFF))
    for p in [CGPoint(x: sel.minX, y: sel.minY), CGPoint(x: sel.maxX, y: sel.minY),
              CGPoint(x: sel.minX, y: sel.maxY), CGPoint(x: sel.maxX, y: sel.maxY)] {
        ctx.fillEllipse(in: CGRect(x: p.x - hr, y: p.y - hr, width: hr * 2, height: hr * 2))
    }
    ctx.restoreGState()
}

// 5. 折角纸片（可换配色）
struct FoldPalette { let top: UInt32; let mid: UInt32; let bottom: UInt32; let accent: UInt32; let foldTop: UInt32; let foldBottom: UInt32 }
let foldPalettes: [String: FoldPalette] = [
    "green":    FoldPalette(top: 0x3FE893, mid: 0x07C160, bottom: 0x038A4A, accent: 0x07C160, foldTop: 0xE9FBF1, foldBottom: 0xBFEFD6),
    "blue":     FoldPalette(top: 0x5AB9FF, mid: 0x1C8CF6, bottom: 0x0F5FC2, accent: 0x1C8CF6, foldTop: 0xEAF4FF, foldBottom: 0xC6E1FF),
    "orange":   FoldPalette(top: 0xFFB24A, mid: 0xFF8A1F, bottom: 0xD95F0A, accent: 0xFF8A1F, foldTop: 0xFFF3E6, foldBottom: 0xFFD9B3),
    "purple":   FoldPalette(top: 0xA78BFF, mid: 0x7A5CF5, bottom: 0x4F38C9, accent: 0x7A5CF5, foldTop: 0xF1ECFF, foldBottom: 0xD8CCFF),
    "teal":     FoldPalette(top: 0x4FE0D0, mid: 0x14B8A6, bottom: 0x0B7F74, accent: 0x14B8A6, foldTop: 0xE8FBF9, foldBottom: 0xBDEFE9),
    "graphite": FoldPalette(top: 0x5A6472, mid: 0x2F3741, bottom: 0x161B22, accent: 0x2EE59D, foldTop: 0xF4F6F8, foldBottom: 0xD0D6DD),
]
func drawFold(_ ctx: CGContext, _ rect: CGRect) { drawFold(ctx, rect, palette: foldPalettes["green"]!) }
func drawFold(_ ctx: CGContext, _ rect: CGRect, palette pal: FoldPalette) {
    let box = drawBase(ctx, rect, top: pal.top, mid: pal.mid, bottom: pal.bottom)
    let s = box.width

    // 底色内侧一圈细高光，增加立体感
    ctx.saveGState()
    let edge = CGPath(roundedRect: box.insetBy(dx: s * 0.008, dy: s * 0.008), cornerWidth: s * 0.215, cornerHeight: s * 0.215, transform: nil)
    ctx.addPath(edge); ctx.setStrokeColor(rgb(0xFFFFFF, 0.18)); ctx.setLineWidth(s * 0.012); ctx.strokePath()
    ctx.restoreGState()

    // 纸片
    let sheet = CGRect(x: box.minX + s * 0.215, y: box.minY + s * 0.205, width: s * 0.57, height: s * 0.59)
    let fold = s * 0.19
    let cr = s * 0.04
    let p = CGMutablePath()
    p.move(to: CGPoint(x: sheet.minX + cr, y: sheet.maxY))
    p.addLine(to: CGPoint(x: sheet.maxX - cr, y: sheet.maxY))
    p.addArc(tangent1End: CGPoint(x: sheet.maxX, y: sheet.maxY), tangent2End: CGPoint(x: sheet.maxX, y: sheet.maxY - cr), radius: cr)
    p.addLine(to: CGPoint(x: sheet.maxX, y: sheet.minY + fold))
    p.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.minY))
    p.addLine(to: CGPoint(x: sheet.minX + cr, y: sheet.minY))
    p.addArc(tangent1End: CGPoint(x: sheet.minX, y: sheet.minY), tangent2End: CGPoint(x: sheet.minX, y: sheet.minY + cr), radius: cr)
    p.addLine(to: CGPoint(x: sheet.minX, y: sheet.maxY - cr))
    p.addArc(tangent1End: CGPoint(x: sheet.minX, y: sheet.maxY), tangent2End: CGPoint(x: sheet.minX + cr, y: sheet.maxY), radius: cr)
    p.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.018), blur: s * 0.045, color: rgb(0x000000, 0.32))
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.addPath(p); ctx.fillPath()
    ctx.restoreGState()

    // 选区：纸面上选区之外轻微压暗，选区内保持纯白（呼应截图时的遮罩）
    let sel = CGRect(x: sheet.minX + s * 0.075, y: sheet.minY + s * 0.275, width: s * 0.28, height: s * 0.22)
    let selPath = CGPath(roundedRect: sel, cornerWidth: s * 0.012, cornerHeight: s * 0.012, transform: nil)
    ctx.saveGState()
    ctx.addPath(p); ctx.clip()
    ctx.addRect(rect); ctx.addPath(selPath); ctx.clip(using: .evenOdd)
    ctx.setFillColor(rgb(0x0B3D26, 0.085)); ctx.fill(rect)
    ctx.restoreGState()

    // 折角：先画折角下方的阴影，再画折起的三角
    let fa = CGPoint(x: sheet.maxX, y: sheet.minY + fold)
    let fb = CGPoint(x: sheet.maxX - fold, y: sheet.minY)
    let fc = CGPoint(x: sheet.maxX - fold, y: sheet.minY + fold)
    ctx.saveGState()
    ctx.addPath(p); ctx.clip()
    let sh = CGMutablePath()
    sh.move(to: fa); sh.addLine(to: fb); sh.addLine(to: CGPoint(x: fc.x - fold * 0.08, y: fc.y - fold * 0.08)); sh.closeSubpath()
    ctx.setShadow(offset: .zero, blur: s * 0.02, color: rgb(0x000000, 0.28))
    ctx.setFillColor(rgb(0x000000, 0.12)); ctx.addPath(sh); ctx.fillPath()
    ctx.restoreGState()

    let f = CGMutablePath()
    f.move(to: fa); f.addLine(to: fb); f.addLine(to: fc); f.closeSubpath()
    ctx.saveGState()
    ctx.addPath(f); ctx.clip()
    ctx.drawLinearGradient(gradient([(pal.foldTop, 0), (pal.foldBottom, 1)]),
                           start: CGPoint(x: fc.x, y: fc.y), end: CGPoint(x: fa.x, y: fb.y), options: [])
    ctx.restoreGState()
    // 折痕高光
    ctx.saveGState()
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.9)); ctx.setLineWidth(s * 0.006)
    ctx.move(to: fa); ctx.addLine(to: fb); ctx.strokePath()
    ctx.restoreGState()

    // 选区虚线边框
    ctx.saveGState()
    ctx.setStrokeColor(rgb(pal.accent)); ctx.setLineWidth(s * 0.017)
    ctx.setLineCap(.round); ctx.setLineDash(phase: 0, lengths: [s * 0.0001, s * 0.034])
    ctx.addPath(selPath); ctx.strokePath()
    ctx.restoreGState()
    // 四角把手：白底绿边（与应用内一致）
    let hr = s * 0.026
    for q in [CGPoint(x: sel.minX, y: sel.minY), CGPoint(x: sel.maxX, y: sel.minY),
              CGPoint(x: sel.minX, y: sel.maxY), CGPoint(x: sel.maxX, y: sel.maxY)] {
        let r = CGRect(x: q.x - hr, y: q.y - hr, width: hr * 2, height: hr * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.004), blur: s * 0.008, color: rgb(0x000000, 0.25))
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillEllipse(in: r)
        ctx.restoreGState()
        ctx.setStrokeColor(rgb(pal.accent)); ctx.setLineWidth(s * 0.012); ctx.strokeEllipse(in: r.insetBy(dx: s * 0.006, dy: s * 0.006))
    }
}

var drawers: [(String, (CGContext, CGRect) -> Void)] = [
    ("corners", drawCorners),
    ("corners-dot", { drawCornersWith($0, $1, center: "dot") }),
    ("corners-ring", { drawCornersWith($0, $1, center: "ring") }),
    ("corners-cross", { drawCornersWith($0, $1, center: "cross") }),
    ("corners-spark", { drawCornersWith($0, $1, center: "spark") }),
    ("corners-aperture", { drawCornersWith($0, $1, center: "aperture") }),
    ("aperture", drawAperture), ("crop", drawCrop), ("lens", drawLens), ("glow", drawGlow), ("fold", drawFold),
]
for (name, pal) in foldPalettes { drawers.append(("fold-\(name)", { ctx, rect in drawFold(ctx, rect, palette: pal) })) }
// 拼图：sheet 显示五种风格；sheet-fold 显示折角方案的各种配色
let sheetNames: [String] = variant == "sheet-center"
    ? ["corners-dot", "corners-ring", "corners-cross", "corners-spark", "corners-aperture"]
    : variant == "sheet-fold"
    ? ["fold-blue", "fold-orange", "fold-purple", "fold-teal", "fold-graphite"]
    : ["aperture", "crop", "lens", "glow", "fold"]
let sheetDrawers = sheetNames.map { n in drawers.first { $0.0 == n }! }

func render(_ w: CGFloat, _ h: CGFloat, _ body: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    body(gc.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let rep: NSBitmapImageRep
if variant.hasPrefix("sheet") {
    let cell: CGFloat = 400, pad: CGFloat = 30
    let w = cell * CGFloat(sheetDrawers.count) + pad * 2
    rep = render(w, cell + 90) { ctx in
        ctx.setFillColor(rgb(0xF2F2F2)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: cell + 90))
        for (i, (name, draw)) in sheetDrawers.enumerated() {
            ctx.saveGState()
            let origin = CGPoint(x: pad + CGFloat(i) * cell, y: 70)
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.scaleBy(x: cell / size, y: cell / size)
            draw(ctx, CGRect(x: 0, y: 0, width: size, height: size))
            ctx.restoreGState()
            let label = NSAttributedString(string: "\(i + 1). \(name)", attributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: NSColor.darkGray])
            label.draw(at: CGPoint(x: origin.x + (cell - label.size().width) / 2, y: 25))
        }
    }
} else {
    guard let draw = drawers.first(where: { $0.0 == variant })?.1 else { fatalError("unknown variant \(variant)") }
    rep = render(size, size) { ctx in draw(ctx, CGRect(x: 0, y: 0, width: size, height: size)) }
}
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
