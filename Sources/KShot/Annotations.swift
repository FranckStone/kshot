import AppKit
import CoreImage

enum Tool: Equatable {
    case none, rect, ellipse, line, arrow, pen, highlighter, mosaic, blur, text, step
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

    var highlighterWidth: CGFloat {
        switch self {
        case .small: return 12
        case .medium: return 20
        case .large: return 30
        }
    }

    /// 序号圆圈直径
    var stepDiameter: CGFloat {
        switch self {
        case .small: return 22
        case .medium: return 28
        case .large: return 38
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

    /// 字号 → 最接近的档位（编辑旧文字标注时回显）
    static func nearest(fontSize: CGFloat) -> StrokeSize {
        allCases.min { abs($0.fontSize - fontSize) < abs($1.fontSize - fontSize) } ?? .medium
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

/// 一条标注。坐标均为所在画布的局部坐标（左上原点，单位 pt）。
struct Annotation {
    enum Kind {
        case rect(CGRect)
        case ellipse(CGRect)
        case line(from: CGPoint, to: CGPoint)
        case arrow(from: CGPoint, to: CGPoint)
        case pen([CGPoint])
        case highlighter([CGPoint])
        case mosaic([CGPoint])
        case blur(CGRect)          // 高斯模糊区域
        case pixelate(CGRect)      // 马赛克区域（自动打码）
        case text(origin: CGPoint, string: String, fontSize: CGFloat)
        case step(center: CGPoint, number: Int)
    }

    var kind: Kind
    var color: NSColor
    var size: StrokeSize

    /// 过小/无意义的标注在松手时丢弃
    var isDegenerate: Bool {
        switch kind {
        case .rect(let r), .ellipse(let r), .blur(let r), .pixelate(let r):
            return r.width < 3 && r.height < 3
        case .line(let a, let b), .arrow(let a, let b):
            return a.distance(to: b) < 4
        case .pen(let pts), .highlighter(let pts), .mosaic(let pts):
            return pts.count < 2
        case .text(_, let s, _):
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .step:
            return false
        }
    }

    static func textFont(size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .regular)
    }

    static let textInset = CGSize(width: 4, height: 2)

    static func textSize(_ string: String, fontSize: CGFloat) -> CGSize {
        let s = NSAttributedString(string: string, attributes: [.font: textFont(size: fontSize)])
            .boundingRect(with: CGSize(width: 4000, height: 4000), options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        return CGSize(width: ceil(s.width) + textInset.width * 2, height: ceil(s.height) + textInset.height * 2)
    }

    // MARK: - 几何（选中、移动、缩放）

    /// 可以用 8 个把手缩放的矩形类标注
    var boxRect: CGRect? {
        switch kind {
        case .rect(let r), .ellipse(let r), .blur(let r), .pixelate(let r): return r
        default: return nil
        }
    }

    /// 线段类标注的两个端点
    var endpoints: (CGPoint, CGPoint)? {
        switch kind {
        case .line(let a, let b), .arrow(let a, let b): return (a, b)
        default: return nil
        }
    }

    /// 包围盒（含线宽）
    var bounds: CGRect {
        switch kind {
        case .rect(let r), .ellipse(let r), .blur(let r), .pixelate(let r):
            return r
        case .line(let a, let b), .arrow(let a, let b):
            return CGRect(p1: a, p2: b).insetBy(dx: -size.lineWidth * 3, dy: -size.lineWidth * 3)
        case .pen(let pts):
            return Self.box(pts).insetBy(dx: -size.lineWidth, dy: -size.lineWidth)
        case .highlighter(let pts):
            return Self.box(pts).insetBy(dx: -size.highlighterWidth / 2, dy: -size.highlighterWidth / 2)
        case .mosaic(let pts):
            return Self.box(pts).insetBy(dx: -size.mosaicWidth / 2, dy: -size.mosaicWidth / 2)
        case .text(let origin, let string, let fontSize):
            return CGRect(origin: origin, size: Self.textSize(string, fontSize: fontSize))
        case .step(let c, _):
            let d = size.stepDiameter
            return CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        }
    }

    private static func box(_ pts: [CGPoint]) -> CGRect {
        guard let f = pts.first else { return .zero }
        var r = CGRect(origin: f, size: .zero)
        for p in pts { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    /// 鼠标是否点中：线框类只认描边附近，填充类认整个区域
    func hitTest(_ p: CGPoint) -> Bool {
        let slop: CGFloat = 6
        func strokeHit(_ path: CGPath, _ width: CGFloat) -> Bool {
            path.copy(strokingWithWidth: width + slop * 2, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(p)
        }
        switch kind {
        case .rect(let r):
            return strokeHit(CGPath(rect: r, transform: nil), size.lineWidth)
        case .ellipse(let r):
            return strokeHit(CGPath(ellipseIn: r, transform: nil), size.lineWidth)
        case .line(let a, let b), .arrow(let a, let b):
            let path = CGMutablePath()
            path.move(to: a)
            path.addLine(to: b)
            return strokeHit(path, size.lineWidth)
        case .pen(let pts):
            return strokeHit(AnnotationRenderer.smoothPath(pts), size.lineWidth)
        case .highlighter(let pts):
            return strokeHit(AnnotationRenderer.smoothPath(pts), size.highlighterWidth - slop)
        case .mosaic(let pts):
            return strokeHit(AnnotationRenderer.smoothPath(pts), size.mosaicWidth - slop)
        case .blur, .pixelate, .text, .step:
            return bounds.insetBy(dx: -2, dy: -2).contains(p)
        }
    }

    func translated(by d: CGPoint) -> Annotation {
        func t(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.x, y: p.y + d.y) }
        func tr(_ r: CGRect) -> CGRect { r.offsetBy(dx: d.x, dy: d.y) }
        var a = self
        switch kind {
        case .rect(let r): a.kind = .rect(tr(r))
        case .ellipse(let r): a.kind = .ellipse(tr(r))
        case .blur(let r): a.kind = .blur(tr(r))
        case .pixelate(let r): a.kind = .pixelate(tr(r))
        case .line(let f, let to): a.kind = .line(from: t(f), to: t(to))
        case .arrow(let f, let to): a.kind = .arrow(from: t(f), to: t(to))
        case .pen(let pts): a.kind = .pen(pts.map(t))
        case .highlighter(let pts): a.kind = .highlighter(pts.map(t))
        case .mosaic(let pts): a.kind = .mosaic(pts.map(t))
        case .text(let o, let s, let f): a.kind = .text(origin: t(o), string: s, fontSize: f)
        case .step(let c, let n): a.kind = .step(center: t(c), number: n)
        }
        return a
    }

    /// 替换矩形类标注的矩形
    func withBox(_ r: CGRect) -> Annotation {
        var a = self
        switch kind {
        case .rect: a.kind = .rect(r)
        case .ellipse: a.kind = .ellipse(r)
        case .blur: a.kind = .blur(r)
        case .pixelate: a.kind = .pixelate(r)
        default: break
        }
        return a
    }

    /// 替换线段类标注的端点
    func withEndpoints(_ a0: CGPoint, _ b0: CGPoint) -> Annotation {
        var a = self
        switch kind {
        case .line: a.kind = .line(from: a0, to: b0)
        case .arrow: a.kind = .arrow(from: a0, to: b0)
        default: break
        }
        return a
    }

    /// 改粗细档位（文字同步字号）
    func withSize(_ s: StrokeSize) -> Annotation {
        var a = self
        a.size = s
        if case .text(let o, let str, _) = kind { a.kind = .text(origin: o, string: str, fontSize: s.fontSize) }
        return a
    }

    /// 涂抹类效果：拿着工具时不参与点选，方便在上面继续涂
    var isAreaEffect: Bool {
        switch kind {
        case .mosaic, .blur, .pixelate, .highlighter: return true
        default: return false
        }
    }

    /// 是否有颜色可改（模糊/马赛克没有颜色）
    var usesColor: Bool {
        switch kind {
        case .mosaic, .blur, .pixelate: return false
        default: return true
        }
    }
}

/// 负责把标注画到当前 NSGraphicsContext（要求是 flipped 坐标）。
final class AnnotationRenderer {
    /// 画布底图（像素），马赛克 / 模糊都从它派生
    private let source: CGImage
    /// 底图对应的区域（pt）
    let screenBounds: CGRect
    private let scale: CGFloat

    init(source: CGImage, bounds: CGRect, scale: CGFloat) {
        self.source = source
        self.screenBounds = bounds
        self.scale = scale
    }

    /// 低分辨率的马赛克源图，绘制时放大并关闭插值
    private(set) lazy var mosaicImage: NSImage? = Self.makeMosaicSource(from: source, blockPixels: Int(8 * scale))
    /// 整张模糊图（第一次用到模糊时才生成）
    private(set) lazy var blurImage: NSImage? = Self.makeBlurSource(from: source, radius: 10 * scale, size: screenBounds.size)

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

        case .line(let from, let to):
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()

        case .arrow(let from, let to):
            drawArrow(from: from, to: to, width: a.size.lineWidth, in: ctx)

        case .pen(let pts):
            ctx.addPath(Self.smoothPath(pts))
            ctx.strokePath()

        case .highlighter(let pts):
            // 荧光笔：正片叠底的半透明粗线，底下的文字仍然清晰
            ctx.setBlendMode(.multiply)
            ctx.setAlpha(0.45)
            ctx.setLineCap(.square)
            ctx.setLineWidth(a.size.highlighterWidth)
            ctx.addPath(Self.smoothPath(pts))
            ctx.strokePath()

        case .mosaic(let pts):
            guard let mosaicImage else { return }
            let path = Self.smoothPath(pts)
            let stroked = path.copy(strokingWithWidth: a.size.mosaicWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
            ctx.addPath(stroked)
            ctx.clip()
            drawPixelated(mosaicImage, in: ctx)

        case .pixelate(let r):
            guard let mosaicImage else { return }
            ctx.clip(to: r)
            drawPixelated(mosaicImage, in: ctx)

        case .blur(let r):
            guard let blurImage else { return }
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.clip()
            blurImage.draw(in: screenBounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        case .text(let origin, let string, let fontSize):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Annotation.textFont(size: fontSize),
                .foregroundColor: a.color,
            ]
            let p = CGPoint(x: origin.x + Annotation.textInset.width, y: origin.y + Annotation.textInset.height)
            NSAttributedString(string: string, attributes: attrs).draw(at: p)

        case .step(let c, let n):
            Self.drawStep(center: c, number: n, diameter: a.size.stepDiameter, color: a.color, in: ctx)
        }
    }

    private func drawPixelated(_ image: NSImage, in ctx: CGContext) {
        ctx.interpolationQuality = .none
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: screenBounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.none.rawValue])
    }

    /// 序号：实心圆 + 白色描边 + 居中数字
    static func drawStep(center c: CGPoint, number n: Int, diameter d: CGFloat, color: NSColor, in ctx: CGContext) {
        let r = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: r)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(max(1.5, d / 16))
        ctx.strokeEllipse(in: r.insetBy(dx: d / 32 + 0.75, dy: d / 32 + 0.75))
        let textColor: NSColor = color.isLight ? .black : .white
        let font = NSFont.monospacedDigitSystemFont(ofSize: d * (n >= 10 ? 0.46 : 0.56), weight: .bold)
        let s = NSAttributedString(string: "\(n)", attributes: [.font: font, .foregroundColor: textColor])
        let size = s.size()
        s.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2))
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

    /// 生成整张高斯模糊图（先缩小再模糊，速度快且效果更柔和）
    static func makeBlurSource(from image: CGImage, radius: CGFloat, size: CGSize) -> NSImage? {
        let down: CGFloat = 0.25
        let ci = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: down, y: down))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius * down))
        let extent = CGRect(x: 0, y: 0, width: CGFloat(image.width) * down, height: CGFloat(image.height) * down).integral
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let out = context.createCGImage(ci, from: extent) else { return nil }
        return NSImage(cgImage: out, size: size)
    }
}

extension NSColor {
    /// 亮色（序号上的数字用黑色）
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.72
    }
}

// MARK: - 标注图层：列表、撤销/重做、选中、拖动编辑

/// 两种画布（截图遮罩、图片编辑窗口）共用的标注交互逻辑
final class AnnotationLayer {
    private(set) var items: [Annotation] = []
    /// 正在绘制的标注
    private(set) var current: Annotation?
    /// 选中的标注（可移动、缩放、改色、删除）
    private(set) var selectedIndex: Int?

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    var onChange: (() -> Void)?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isEmpty: Bool { items.isEmpty }
    var selected: Annotation? { selectedIndex.map { items[$0] } }

    /// 当前要显示的全部标注（含正在绘制的）
    var visible: [Annotation] {
        var list = items
        if let current { list.append(current) }
        return list
    }

    // MARK: 编辑操作（都会记录撤销）

    private func snapshot() {
        undoStack.append(items)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func add(_ a: Annotation, recordUndo: Bool = true) {
        guard !a.isDegenerate else { return }
        if recordUndo { snapshot() }
        items.append(a)
        onChange?()
    }

    func add(_ list: [Annotation]) {
        let valid = list.filter { !$0.isDegenerate }
        guard !valid.isEmpty else { return }
        snapshot()
        items.append(contentsOf: valid)
        onChange?()
    }

    /// 取出一条标注用于重新编辑（记录撤销；编辑完成后用 add(_, recordUndo: false) 放回）
    func extract(at i: Int) -> Annotation {
        snapshot()
        selectedIndex = nil
        let a = items.remove(at: i)
        onChange?()
        return a
    }

    func deleteSelected() {
        guard let i = selectedIndex else { return }
        snapshot()
        items.remove(at: i)
        selectedIndex = nil
        onChange?()
    }

    func updateSelected(color: NSColor? = nil, size: StrokeSize? = nil) {
        guard let i = selectedIndex else { return }
        var a = items[i]
        if let color, a.usesColor { a.color = color }
        if let size { a = a.withSize(size) }
        snapshot()
        items[i] = a
        onChange?()
    }

    func nudgeSelected(_ d: CGPoint) {
        guard let i = selectedIndex else { return }
        snapshot()
        items[i] = items[i].translated(by: d)
        onChange?()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(items)
        items = prev
        selectedIndex = nil
        onChange?()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        selectedIndex = nil
        onChange?()
    }

    func deselect() {
        guard selectedIndex != nil else { return }
        selectedIndex = nil
        onChange?()
    }

    func removeAll() {
        items.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        selectedIndex = nil
        current = nil
        drag = .none
    }

    /// 下一个序号
    var nextStepNumber: Int {
        var n = 0
        for a in items { if case .step(_, let k) = a.kind { n = max(n, k) } }
        return n + 1
    }

    // MARK: 鼠标交互

    private enum Drag {
        case none
        case drawing(start: CGPoint)
        case moving(start: CGPoint, orig: Annotation, moved: Bool)
        case resizingBox(Handle, orig: CGRect, origItem: Annotation)
        case resizingEnd(first: Bool, origItem: Annotation)
    }
    private var drag: Drag = .none
    private var clip: CGRect = .zero

    var isDragging: Bool {
        if case .none = drag { return false }
        return true
    }

    enum PressResult {
        /// 没有处理（交给画布自己，比如移动选区）
        case ignored
        case handled
        /// 文字工具点在空白处：开始新的文字
        case beginText
        /// 双击文字标注：重新编辑
        case editText(index: Int)
    }

    static let handleRadius: CGFloat = 5

    /// 选中标注的把手位置
    private func handlePoints(_ a: Annotation) -> [(Handle?, Bool, CGPoint)] {
        if let r = a.boxRect {
            return Handle.all.map { ($0, false, $0.point(in: r)) }
        }
        if let (p, q) = a.endpoints {
            return [(nil, true, p), (nil, false, q)]
        }
        return []
    }

    func mouseDown(at p: CGPoint, clip: CGRect, tool: Tool, color: NSColor, size: StrokeSize, clickCount: Int) -> PressResult {
        self.clip = clip
        // 1. 选中标注的把手
        if let i = selectedIndex {
            let a = items[i]
            for (h, first, hp) in handlePoints(a) where hp.distance(to: p) <= Self.handleRadius + 4 {
                if let h, let r = a.boxRect {
                    drag = .resizingBox(h, orig: r, origItem: a)
                } else {
                    drag = .resizingEnd(first: first, origItem: a)
                }
                return .handled
            }
        }
        // 2. 点中已有标注：选中并准备拖动（从最上面一层开始找）
        if let i = hitIndex(at: p, tool: tool) {
            if clickCount >= 2, case .text = items[i].kind { return .editText(index: i) }
            selectedIndex = i
            drag = .moving(start: p, orig: items[i], moved: false)
            onChange?()
            return .handled
        }
        // 3. 空白处
        let hadSelection = selectedIndex != nil
        selectedIndex = nil
        guard tool != .none, clip.contains(p) else {
            if hadSelection { onChange?(); return .handled }
            return .ignored
        }
        if tool == .text { if hadSelection { onChange?() }; return .beginText }
        let q = p.clamped(to: clip)
        let kind: Annotation.Kind
        switch tool {
        case .rect: kind = .rect(CGRect(origin: q, size: .zero))
        case .ellipse: kind = .ellipse(CGRect(origin: q, size: .zero))
        case .blur: kind = .blur(CGRect(origin: q, size: .zero))
        case .line: kind = .line(from: q, to: q)
        case .arrow: kind = .arrow(from: q, to: q)
        case .pen: kind = .pen([q])
        case .highlighter: kind = .highlighter([q])
        case .mosaic: kind = .mosaic([q])
        case .step: kind = .step(center: q, number: nextStepNumber)
        case .text, .none: return .ignored
        }
        current = Annotation(kind: kind, color: color, size: size)
        drag = .drawing(start: q)
        onChange?()
        return .handled
    }

    /// shift：矩形/椭圆约束为正方形/圆，直线/箭头约束到 45° 倍数，荧光笔画水平直线
    func mouseDragged(to p0: CGPoint, shift: Bool = false) {
        let p = p0.clamped(to: clip)
        switch drag {
        case .none:
            return
        case .drawing(let start):
            guard var a = current else { return }
            switch a.kind {
            case .rect: a.kind = .rect(Self.box(start, p, square: shift))
            case .ellipse: a.kind = .ellipse(Self.box(start, p, square: shift))
            case .blur: a.kind = .blur(Self.box(start, p, square: shift))
            case .line: a.kind = .line(from: start, to: shift ? Self.snap45(start, p) : p)
            case .arrow: a.kind = .arrow(from: start, to: shift ? Self.snap45(start, p) : p)
            case .pen(var pts): pts.append(p); a.kind = .pen(pts)
            case .highlighter(var pts):
                if shift { a.kind = .highlighter([start, CGPoint(x: p.x, y: start.y)]) }
                else { pts.append(p); a.kind = .highlighter(pts) }
            case .mosaic(var pts): pts.append(p); a.kind = .mosaic(pts)
            case .step: a.kind = .step(center: p, number: { if case .step(_, let n) = a.kind { return n }; return 1 }())
            case .text, .pixelate: break
            }
            current = a
        case .moving(let start, let orig, _):
            guard let i = selectedIndex else { return }
            items[i] = orig.translated(by: CGPoint(x: p0.x - start.x, y: p0.y - start.y))
            drag = .moving(start: start, orig: orig, moved: true)
        case .resizingBox(let h, let orig, let origItem):
            guard let i = selectedIndex else { return }
            items[i] = origItem.withBox(orig.resized(handle: h, to: p))
        case .resizingEnd(let first, let origItem):
            guard let i = selectedIndex, let (a, b) = origItem.endpoints else { return }
            items[i] = first ? origItem.withEndpoints(shift ? Self.snap45(b, p) : p, b)
                             : origItem.withEndpoints(a, shift ? Self.snap45(a, p) : p)
        }
        onChange?()
    }

    func mouseUp() {
        switch drag {
        case .drawing:
            if let a = current, !a.isDegenerate {
                snapshot()
                items.append(a)
            }
            current = nil
        case .moving(_, let orig, let moved):
            if moved, let i = selectedIndex { recordEdit(index: i, original: orig) }
        case .resizingBox(_, _, let origItem), .resizingEnd(_, let origItem):
            if let i = selectedIndex { recordEdit(index: i, original: origItem) }
        case .none:
            break
        }
        drag = .none
        onChange?()
    }

    /// 拖动编辑结束：把改动前的状态压进撤销栈
    private func recordEdit(index i: Int, original: Annotation) {
        var before = items
        before[i] = original
        undoStack.append(before)
        redoStack.removeAll()
    }

    private func hitIndex(at p: CGPoint, tool: Tool) -> Int? {
        items.indices.reversed().first { items[$0].hitTest(p) && (tool == .none || !items[$0].isAreaEffect) }
    }

    func cursor(at p: CGPoint, tool: Tool) -> NSCursor? {
        switch drag {
        case .moving: return .closedHand
        case .resizingBox, .resizingEnd: return .crosshair
        case .drawing: return nil
        case .none: break
        }
        if let a = selected {
            for (_, _, hp) in handlePoints(a) where hp.distance(to: p) <= Self.handleRadius + 4 { return .crosshair }
        }
        if hitIndex(at: p, tool: tool) != nil { return .openHand }
        return nil
    }

    private static func box(_ a: CGPoint, _ b: CGPoint, square: Bool) -> CGRect {
        guard square else { return CGRect(p1: a, p2: b) }
        let s = max(abs(b.x - a.x), abs(b.y - a.y))
        return CGRect(p1: a, p2: CGPoint(x: a.x + (b.x >= a.x ? s : -s), y: a.y + (b.y >= a.y ? s : -s)))
    }

    private static func snap45(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
    }

    // MARK: 绘制

    func draw(with renderer: AnnotationRenderer, clip: CGRect, in ctx: CGContext) {
        renderer.draw(visible, clip: clip, in: ctx)
        drawSelection(in: ctx)
    }

    /// 选中标注：虚线外框 + 把手
    private func drawSelection(in ctx: CGContext) {
        guard let a = selected else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if a.endpoints == nil {
            let r = a.bounds.insetBy(dx: -4, dy: -4)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r)
            ctx.setStrokeColor(NSColor.accentGreen.cgColor)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        let hr = Self.handleRadius
        for (_, _, p) in handlePoints(a) {
            let r = CGRect(x: p.x - hr, y: p.y - hr, width: hr * 2, height: hr * 2)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(NSColor.accentGreen.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: r.insetBy(dx: 0.75, dy: 0.75))
        }
    }
}
