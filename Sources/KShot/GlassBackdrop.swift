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

    override func mouseDown(with event: NSEvent) {}

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

    override func mouseDown(with event: NSEvent) {}
}

/// 玻璃面板上的描边层
final class RingView: NSView {
    weak var owner: GlassPanelView?
    override func draw(_ dirtyRect: NSRect) { owner?.drawRing(in: bounds) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 玻璃边框：四条玻璃条拼成一圈，macOS 26+ 用容器视图把它们融合成连续的框
final class GlassFrameView: NSView {
    static let thickness: CGFloat = 7
    private var strips: [NSView] = []
    private var host: NSView?

    override var isFlipped: Bool { true }

    init(tint: NSColor?) {
        super.init(frame: .zero)
        wantsLayer = true
        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.spacing = 12
            let content = NSView()
            container.contentView = content
            for _ in 0..<4 {
                let g = NSGlassEffectView()
                g.cornerRadius = GlassFrameView.thickness / 2
                g.tintColor = tint
                content.addSubview(g)
                strips.append(g)
            }
            addSubview(container)
            host = container
        } else {
            let content = NSView()
            for _ in 0..<4 {
                let v = NSVisualEffectView()
                v.material = .popover
                v.blendingMode = .withinWindow
                v.state = .active
                v.wantsLayer = true
                v.layer?.cornerRadius = GlassFrameView.thickness / 2
                content.addSubview(v)
                strips.append(v)
            }
            addSubview(content)
            host = content
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let t = GlassFrameView.thickness
        let b = bounds
        host?.frame = b
        if #available(macOS 26.0, *), let c = host as? NSGlassEffectContainerView { c.contentView?.frame = b }
        guard strips.count == 4 else { return }
        strips[0].frame = CGRect(x: 0, y: 0, width: b.width, height: t)                // 上
        strips[1].frame = CGRect(x: 0, y: b.height - t, width: b.width, height: t)     // 下
        strips[2].frame = CGRect(x: 0, y: 0, width: t, height: b.height)               // 左
        strips[3].frame = CGRect(x: b.width - t, y: 0, width: t, height: b.height)     // 右
    }

    override func mouseDown(with event: NSEvent) {}
}
