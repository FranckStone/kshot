import AppKit

/// 演示模式（--demo）：用绘制的示例桌面代替真实抓屏，便于生成不含隐私的截图。
enum DemoScene {
    @MainActor
    static func make(for screen: NSScreen) -> (ScreenShot, [WindowInfo])? {
        let scale = screen.backingScaleFactor
        let size = screen.frame.size
        let pxW = Int(size.width * scale), pxH = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let bounds = CGRect(origin: .zero, size: size)
        // 壁纸渐变
        let wall = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [NSColor(hex: 0x1B3A6B).cgColor, NSColor(hex: 0x3C7FB8).cgColor, NSColor(hex: 0x8CC4E8).cgColor] as CFArray,
                              locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(wall, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        // 菜单栏
        NSColor(white: 1, alpha: 0.18).setFill()
        CGRect(x: 0, y: 0, width: size.width, height: 25).fill()

        // 示例窗口
        let win = CGRect(x: size.width * 0.22, y: size.height * 0.18, width: size.width * 0.56, height: size.height * 0.62)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 40, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor(hex: 0xF5F5F7).setFill()
        NSBezierPath(roundedRect: win, xRadius: 12, yRadius: 12).fill()
        ctx.restoreGState()
        // 标题栏
        ctx.saveGState()
        NSBezierPath(roundedRect: win, xRadius: 12, yRadius: 12).addClip()
        NSColor(hex: 0xE8E8EC).setFill()
        CGRect(x: win.minX, y: win.minY, width: win.width, height: 52).fill()
        for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            NSColor(hex: UInt32(c)).setFill()
            NSBezierPath(ovalIn: CGRect(x: win.minX + 20 + CGFloat(i) * 20, y: win.minY + 20, width: 12, height: 12)).fill()
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor(white: 0.25, alpha: 1)]
        let title = NSAttributedString(string: "示例窗口 — KShot Demo", attributes: titleAttrs)
        title.draw(at: CGPoint(x: win.midX - title.size().width / 2, y: win.minY + 17))
        // 侧栏
        NSColor(hex: 0xECECF1).setFill()
        CGRect(x: win.minX, y: win.minY + 52, width: 200, height: win.height - 52).fill()
        let itemAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.3, alpha: 1)]
        for (i, name) in ["收件箱", "已加星标", "草稿", "已发送", "归档", "垃圾桶"].enumerated() {
            let y = win.minY + 72 + CGFloat(i) * 34
            if i == 0 {
                NSColor.accentGreen.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: CGRect(x: win.minX + 10, y: y - 6, width: 180, height: 28), xRadius: 6, yRadius: 6).fill()
            }
            NSAttributedString(string: name, attributes: itemAttrs).draw(at: CGPoint(x: win.minX + 24, y: y))
        }
        // 内容卡片
        let contentX = win.minX + 224
        for i in 0..<5 {
            let y = win.minY + 76 + CGFloat(i) * 92
            NSColor.white.setFill()
            NSBezierPath(roundedRect: CGRect(x: contentX, y: y, width: win.maxX - contentX - 24, height: 76), xRadius: 8, yRadius: 8).fill()
            NSColor(hex: [0x07C160, 0x10AEFF, 0xFFC300, 0xFA5151, 0x6467F0][i]).setFill()
            NSBezierPath(ovalIn: CGRect(x: contentX + 16, y: y + 20, width: 36, height: 36)).fill()
            NSColor(white: 0.85, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: contentX + 68, y: y + 18, width: 220, height: 12), xRadius: 6, yRadius: 6).fill()
            NSBezierPath(roundedRect: CGRect(x: contentX + 68, y: y + 42, width: 360, height: 10), xRadius: 5, yRadius: 5).fill()
        }
        ctx.restoreGState()

        guard let image = ctx.makeImage() else { return nil }
        let cgBounds = CGRect(x: screen.cgOrigin.x + win.minX, y: screen.cgOrigin.y + win.minY, width: win.width, height: win.height)
        let window = WindowInfo(id: 1, bounds: cgBounds, pid: 0, ownerName: "Demo")
        return (ScreenShot(screen: screen, image: image), [window])
    }
}
