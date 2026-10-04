import AppKit

/// 液态玻璃背板：macOS 26+ 用 NSGlassEffectView，更早的系统回退到 NSVisualEffectView。
enum GlassBackdrop {
    /// 返回 (背板视图, 应该把内容放进去的容器)。背板会随 superview 自动拉伸。
    static func make(cornerRadius: CGFloat, content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
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
