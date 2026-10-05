import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    /// 是否是 Mac 内置屏（四角是圆的）；外接显示器四角是直角
    var isBuiltIn: Bool {
        if CommandLine.arguments.contains("--assume-external") { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }

    /// 屏幕物理圆角（pt）：内置屏有圆角，外接显示器为 0
    var physicalCornerRadius: CGFloat { isBuiltIn ? 20 : 0 }

    /// 主屏（带菜单栏）的高度，用于 Cocoa ⇄ CG 坐标转换。
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// 本屏左上角在全局 CG 坐标系（原点为主屏左上角，y 向下）中的位置。
    var cgOrigin: CGPoint {
        CGPoint(x: frame.minX, y: NSScreen.primaryHeight - frame.maxY)
    }

    /// 全局 CG 矩形 → 本屏局部坐标（左上角原点，y 向下）。
    func localRect(fromCG rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - cgOrigin.x, y: rect.minY - cgOrigin.y, width: rect.width, height: rect.height)
    }

    /// 本屏局部坐标 → 全局 CG 坐标。
    func cgPoint(fromLocal p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + cgOrigin.x, y: p.y + cgOrigin.y)
    }

    /// 本屏局部矩形（左上原点）→ Cocoa 屏幕坐标矩形（左下原点）。
    func cocoaRect(fromLocal r: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
    }
}

extension CGRect {
    /// 由任意两点构成的标准化矩形。
    init(p1: CGPoint, p2: CGPoint) {
        self.init(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
    }

    func clamped(to bounds: CGRect) -> CGRect {
        var r = self
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = max(bounds.minX, min(r.minX, bounds.maxX - r.width))
        r.origin.y = max(bounds.minY, min(r.minY, bounds.maxY - r.height))
        return r
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension CGPoint {
    func clamped(to rect: CGRect) -> CGPoint {
        CGPoint(x: max(rect.minX, min(x, rect.maxX)), y: max(rect.minY, min(y, rect.maxY)))
    }

    func distance(to p: CGPoint) -> CGFloat { hypot(p.x - x, p.y - y) }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// 主题绿
    static let accentGreen = NSColor(hex: 0x07C160)
}

/// 选区边缘的 8 个把手
struct Handle: OptionSet, Hashable {
    let rawValue: Int
    static let left = Handle(rawValue: 1)
    static let right = Handle(rawValue: 2)
    static let top = Handle(rawValue: 4)
    static let bottom = Handle(rawValue: 8)

    static let all: [Handle] = [
        [.left, .top], [.top], [.right, .top],
        [.left], [.right],
        [.left, .bottom], [.bottom], [.right, .bottom],
    ]

    func point(in r: CGRect) -> CGPoint {
        let x: CGFloat = contains(.left) ? r.minX : (contains(.right) ? r.maxX : r.midX)
        let y: CGFloat = contains(.top) ? r.minY : (contains(.bottom) ? r.maxY : r.midY)
        return CGPoint(x: x, y: y)
    }
}

extension CGRect {
    /// 拖动某个把手到 p 后的矩形（越过对边时自动翻转）
    func resized(handle h: Handle, to p: CGPoint) -> CGRect {
        var minX = self.minX, maxX = self.maxX, minY = self.minY, maxY = self.maxY
        if h.contains(.left) { minX = Swift.min(p.x, self.maxX); maxX = Swift.max(p.x, self.maxX) }
        if h.contains(.right) { minX = Swift.min(p.x, self.minX); maxX = Swift.max(p.x, self.minX) }
        if h.contains(.top) { minY = Swift.min(p.y, self.maxY); maxY = Swift.max(p.y, self.maxY) }
        if h.contains(.bottom) { minY = Swift.min(p.y, self.minY); maxY = Swift.max(p.y, self.minY) }
        return CGRect(x: minX, y: minY, width: Swift.max(1, maxX - minX), height: Swift.max(1, maxY - minY))
    }
}
