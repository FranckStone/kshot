import AppKit

/// 液态玻璃背板：macOS 26+ 用 NSGlassEffectView，更早的系统回退到 NSVisualEffectView。
enum GlassBackdrop {
    /// 返回 (背板视图, 应该把内容放进去的容器)。背板会随 superview 自动拉伸。
    static func make(cornerRadius: CGFloat, content: NSView, tint: NSColor? = nil) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.tintColor = tint
            glass.contentView = content
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = true
            }
            glass.autoresizingMask = [.width, .height]
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        effect.autoresizingMask = [.width, .height]
        content.autoresizingMask = [.width, .height]
        content.frame = effect.bounds
        effect.addSubview(content)
        return effect
    }
}

/// 竖向分隔线（用动态颜色，自动适配深浅外观）
final class SeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

/// 尺寸标签：玻璃胶囊 + 等宽数字
final class SizeLabelView: NSView {
    static let height: CGFloat = 24
    private let label = NSTextField(labelWithString: "")
    private let content = NSView()
    private let padX: CGFloat = 9

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 80, height: SizeLabelView.height))
        wantsLayer = true // NSGlassEffectView 需要 layer-backed 的父视图，否则不渲染
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        content.addSubview(label)
        let backdrop = GlassBackdrop.make(cornerRadius: SizeLabelView.height / 2, content: content)
        backdrop.frame = bounds
        addSubview(backdrop)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 更新文字并返回新的尺寸
    func setText(_ text: String) -> CGSize {
        label.stringValue = text
        label.sizeToFit()
        let w = ceil(label.frame.width) + padX * 2
        frame.size = CGSize(width: w, height: SizeLabelView.height)
        content.frame = CGRect(origin: .zero, size: frame.size)
        label.frame = CGRect(x: padX, y: (SizeLabelView.height - label.frame.height) / 2, width: ceil(label.frame.width), height: label.frame.height)
        return frame.size
    }

    /// 纯装饰，鼠标事件穿透到遮罩层
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var debugText: String { label.stringValue }
    var debugLabelFrame: CGRect { label.frame }
}

/// 通用玻璃面板（无内容，仅作背板）
final class GlassPanelView: NSView {
    private let cornerRadius: CGFloat
    private let ringColor: NSColor?
    private let ringWidth: CGFloat

    /// ringColor：在玻璃上叠加一圈描边（小尺寸玻璃在平坦背景上几乎看不见，需要描边提高可见度）
    init(cornerRadius: CGFloat, tint: NSColor? = nil, ringColor: NSColor? = nil, ringWidth: CGFloat = 1.5) {
        self.cornerRadius = cornerRadius
        self.ringColor = ringColor
        self.ringWidth = ringWidth
        super.init(frame: .zero)
        wantsLayer = true
        let backdrop = GlassBackdrop.make(cornerRadius: cornerRadius, content: NSView(), tint: tint)
        backdrop.frame = bounds
        addSubview(backdrop)
        if ringColor != nil {
            let ring = RingView(frame: bounds)
            ring.autoresizingMask = [.width, .height]
            ring.owner = self
            addSubview(ring)
        }
    }

    fileprivate func drawRing(in bounds: CGRect) {
        guard let ringColor else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: ringWidth / 2, dy: ringWidth / 2),
                                xRadius: cornerRadius - ringWidth / 2, yRadius: cornerRadius - ringWidth / 2)
        path.lineWidth = ringWidth
        ringColor.setStroke()
        path.stroke()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 纯装饰，鼠标事件穿透到遮罩层
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 玻璃面板上的描边层
final class RingView: NSView {
    weak var owner: GlassPanelView?
    override func draw(_ dirtyRect: NSRect) { owner?.drawRing(in: bounds) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 玻璃边框：一整块圆角玻璃，用遮罩抠掉中间，只留下一圈环
final class GlassFrameView: NSView {
    static let thickness: CGFloat = 4

    /// 四个角各自的外侧圆角（视图坐标，左上原点）
    struct Corners: Equatable {
        var topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat
        static func all(_ r: CGFloat) -> Corners { Corners(topLeft: r, topRight: r, bottomLeft: r, bottomRight: r) }
    }
    var corners = Corners.all(0) { didSet { if corners != oldValue { needsLayout = true } } }
    /// 兼容旧接口：统一圆角
    var cornerRadius: CGFloat {
        get { corners.topLeft }
        set { corners = .all(newValue) }
    }

    private let glass: NSView
    private let maskLayer = CAShapeLayer()

    override var isFlipped: Bool { true }

    init(tint: NSColor?) {
        glass = GlassBackdrop.make(cornerRadius: 0, content: NSView(), tint: tint)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(glass)
        maskLayer.fillRule = .evenOdd
        layer?.mask = maskLayer
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let t = GlassFrameView.thickness
        let b = bounds
        glass.frame = b
        // 形状完全由遮罩决定，玻璃本身不做圆角
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView { g.cornerRadius = 0 }
        else { glass.layer?.cornerRadius = 0 }
        // 环形遮罩：外轮廓 - 内轮廓（内轮廓圆角 = 外圆角 - 框宽）
        let path = CGMutablePath()
        path.addPath(Self.roundedPath(b, corners, flipped: isLayerFlipped))
        let innerCorners = Corners(topLeft: max(0, corners.topLeft - t), topRight: max(0, corners.topRight - t),
                                   bottomLeft: max(0, corners.bottomLeft - t), bottomRight: max(0, corners.bottomRight - t))
        path.addPath(Self.roundedPath(b.insetBy(dx: t, dy: t), innerCorners, flipped: isLayerFlipped))
        maskLayer.frame = b
        maskLayer.path = path
    }

    /// 遮罩层坐标是否与视图一样左上原点
    private var isLayerFlipped: Bool { layer?.contentsAreFlipped() ?? true }

    /// 四角分别圆角的矩形路径。flipped=true 时 minY 是视图顶部
    static func roundedPath(_ r: CGRect, _ c: Corners, flipped: Bool) -> CGPath {
        let maxR = min(r.width, r.height) / 2
        let tl = min(c.topLeft, maxR), tr = min(c.topRight, maxR), bl = min(c.bottomLeft, maxR), br = min(c.bottomRight, maxR)
        // 统一换算到“上边 = topY、下边 = botY”
        let topY = flipped ? r.minY : r.maxY
        let botY = flipped ? r.maxY : r.minY
        let dir: CGFloat = flipped ? 1 : -1   // 从上往下走的 y 方向
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + tl, y: topY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: topY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: topY), tangent2End: CGPoint(x: r.maxX, y: topY + dir * tr), radius: tr)
        p.addLine(to: CGPoint(x: r.maxX, y: botY - dir * br))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: botY), tangent2End: CGPoint(x: r.maxX - br, y: botY), radius: br)
        p.addLine(to: CGPoint(x: r.minX + bl, y: botY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: botY), tangent2End: CGPoint(x: r.minX, y: botY - dir * bl), radius: bl)
        p.addLine(to: CGPoint(x: r.minX, y: topY + dir * tl))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: topY), tangent2End: CGPoint(x: r.minX + tl, y: topY), radius: tl)
        p.closeSubpath()
        return p
    }

    /// 纯装饰，鼠标事件穿透到遮罩层（否则会吞掉点击，导致无法选区）
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
