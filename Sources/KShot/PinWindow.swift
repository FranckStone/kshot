import AppKit

/// “钉在屏幕上”的悬浮图片窗口：可拖动，双击/Esc 关闭，⌘C 复制，滚轮缩放。
final class PinWindow: NSWindow {
    private let cgImage: CGImage
    private var zoom: CGFloat = 1
    private let baseSize: CGSize

    nonisolated(unsafe) private static var all: [PinWindow] = []

    init(image: CGImage, frame screenFrame: CGRect) {
        cgImage = image
        baseSize = screenFrame.size
        super.init(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        let view = PinContentView(frame: CGRect(origin: .zero, size: screenFrame.size))
        view.image = NSImage(cgImage: image, size: screenFrame.size)
        view.onDoubleClick = { [weak self] in self?.closePin() }
        contentView = view
        PinWindow.all.append(self)
    }

    override var canBecomeKey: Bool { true }

    func closePin() {
        orderOut(nil)
        PinWindow.all.removeAll { $0 === self }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePin(); return } // Esc
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c": Exporter.copyToClipboard(cgImage); return
            case "s": Exporter.save(cgImage) { _ in }; return
            case "w": closePin(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.1 else { return }
        let factor: CGFloat = delta > 0 ? 1.05 : 1 / 1.05
        let newZoom = max(0.2, min(4, zoom * factor))
        guard newZoom != zoom else { return }
        zoom = newZoom
        let newSize = CGSize(width: baseSize.width * zoom, height: baseSize.height * zoom)
        // 围绕鼠标位置缩放
        let mouse = NSEvent.mouseLocation
        let old = frame
        let rx = (mouse.x - old.minX) / max(1, old.width)
        let ry = (mouse.y - old.minY) / max(1, old.height)
        let newOrigin = CGPoint(x: mouse.x - rx * newSize.width, y: mouse.y - ry * newSize.height)
        setFrame(CGRect(origin: newOrigin, size: newSize), display: true)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "复制图片  ⌘C", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "保存图片…  ⌘S", action: #selector(saveImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "还原大小", action: #selector(resetZoom), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭  Esc", action: #selector(closeFromMenu), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: contentView!)
    }

    @objc private func copyImage() { Exporter.copyToClipboard(cgImage) }
    @objc private func saveImage() { Exporter.save(cgImage) { _ in } }
    @objc private func closeFromMenu() { closePin() }
    @objc private func resetZoom() {
        zoom = 1
        let c = frame.center
        setFrame(CGRect(x: c.x - baseSize.width / 2, y: c.y - baseSize.height / 2, width: baseSize.width, height: baseSize.height), display: true)
    }
}

final class PinContentView: NSView {
    var image: NSImage?
    var onDoubleClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        NSColor.wechatGreen.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            super.mouseDown(with: event)
        }
    }
}
