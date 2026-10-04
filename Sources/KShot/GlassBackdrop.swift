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
