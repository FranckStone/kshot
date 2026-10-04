import AppKit

/// 菜单栏图标：与 App 图标一致的取景框四角（模板图，自动适配深浅色菜单栏）
enum MenuBarIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width
            let frame = rect.insetBy(dx: s * 0.14, dy: s * 0.14)
            let arm = frame.width * 0.32
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(s * 0.11)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let corners: [(CGPoint, CGPoint, CGPoint)] = [
                (CGPoint(x: frame.minX, y: frame.maxY - arm), CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.minX + arm, y: frame.maxY)),
                (CGPoint(x: frame.maxX - arm, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY - arm)),
                (CGPoint(x: frame.maxX, y: frame.minY + arm), CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.maxX - arm, y: frame.minY)),
                (CGPoint(x: frame.minX + arm, y: frame.minY), CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.minX, y: frame.minY + arm)),
            ]
            for (a, b, c) in corners { ctx.move(to: a); ctx.addLine(to: b); ctx.addLine(to: c) }
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
