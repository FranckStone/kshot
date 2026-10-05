import AppKit

/// 屏幕上短暂出现的玻璃提示条（例如“已复制颜色”）
@MainActor
enum Toast {
    private static var window: NSWindow?
    private static var hideWork: DispatchWorkItem?

    /// near：Cocoa 屏幕坐标；为空时显示在鼠标所在屏幕的上方中间
    static func show(_ text: String, symbol: String = "checkmark.circle.fill", near point: CGPoint? = nil, duration: TimeInterval = 1.6) {
        hideWork?.cancel()
        window?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.sizeToFit()
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) ?? NSImage())
        icon.contentTintColor = .accentGreen
        let width = min(560, ceil(label.frame.width)) + 58
        let height: CGFloat = 40
        let content = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        icon.frame = CGRect(x: 14, y: (height - 20) / 2, width: 20, height: 20)
        label.frame = CGRect(x: 40, y: (height - label.frame.height) / 2, width: width - 54, height: label.frame.height)
        content.addSubview(icon)
        content.addSubview(label)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point ?? mouse) } ?? NSScreen.main
        let v = screen?.visibleFrame ?? .zero
        var origin: CGPoint
        if let point {
            origin = CGPoint(x: point.x - width / 2, y: point.y - height / 2)
        } else {
            origin = CGPoint(x: v.midX - width / 2, y: v.maxY - height - 40)
        }
        origin.x = min(max(v.minX + 8, origin.x), v.maxX - width - 8)
        origin.y = min(max(v.minY + 8, origin.y), v.maxY - height - 8)

        let w = NSPanel(contentRect: CGRect(origin: origin, size: content.frame.size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.level = .screenSaver + 1 // 截图遮罩（screenSaver）之上也能看到
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        let root = NSView(frame: content.bounds)
        root.wantsLayer = true
        let backdrop = GlassBackdrop.make(cornerRadius: height / 2, content: content)
        backdrop.frame = root.bounds
        root.addSubview(backdrop)
        w.contentView = root
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; w.animator().alphaValue = 1 }
        window = w

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; w.animator().alphaValue = 0 }, completionHandler: {
                Task { @MainActor in
                    w.orderOut(nil)
                    if window === w { window = nil }
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
