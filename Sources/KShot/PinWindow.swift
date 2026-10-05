import AppKit

/// “钉在屏幕上”的悬浮图片窗口：可拖动，双击/Esc 关闭，⌘C 复制，滚轮缩放，⌥滚轮调透明度，⌥拖动把图片拖出成文件。
final class PinWindow: NSWindow {
    /// 玻璃边框宽度
    static let border: CGFloat = 8
    private let cgImage: CGImage
    private var zoom: CGFloat = 1
    private let baseSize: CGSize

    nonisolated(unsafe) private static var all: [PinWindow] = []
    nonisolated(unsafe) static weak var latest: PinWindow?
    nonisolated(unsafe) private(set) static var allHidden = false

    static var count: Int { all.count }
    static var hasClickThrough: Bool { all.contains { $0.ignoresMouseEvents } }

    /// 显示 / 隐藏全部钉图
    static func setAllHidden(_ hidden: Bool) {
        allHidden = hidden
        for p in all { hidden ? p.orderOut(nil) : p.orderFront(nil) }
    }

    static func restoreAllClicks() {
        for p in all { p.setClickThrough(false) }
    }

    static func closeAll() {
        for p in all { p.orderOut(nil) }
        all.removeAll()
        allHidden = false
    }

    /// imageFrame：图片在屏幕上的位置；窗口会向外扩出一圈玻璃边框
    init(image: CGImage, frame imageFrame: CGRect) {
        cgImage = image
        let windowFrame = imageFrame.insetBy(dx: -PinWindow.border, dy: -PinWindow.border)
        baseSize = windowFrame.size
        super.init(contentRect: windowFrame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        let view = PinContentView(frame: CGRect(origin: .zero, size: windowFrame.size))
        view.image = NSImage(cgImage: image, size: imageFrame.size)
        view.cgImage = image
        view.onDoubleClick = { [weak self] in self?.closePin() }
        contentView = view
        PinWindow.all.append(self)
        PinWindow.latest = self
        if PinWindow.allHidden { PinWindow.setAllHidden(false) }
    }

    /// 鼠标穿透：钉图不再响应点击（从菜单栏“钉图”里恢复）
    func setClickThrough(_ on: Bool) {
        ignoresMouseEvents = on
        if on {
            Toast.show("钉图已设为鼠标穿透，可在菜单栏“钉图”中恢复", symbol: "cursorarrow.motionlines")
        }
    }

    func setOpacity(_ v: CGFloat) {
        alphaValue = max(0.15, min(1, v))
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
        // ⌥ + 滚轮：调透明度
        if event.modifierFlags.contains(.option) {
            setOpacity(alphaValue + (delta > 0 ? 0.05 : -0.05))
            return
        }
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
        menu.addItem(withTitle: "标注编辑…", action: #selector(editImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "还原大小", action: #selector(resetZoom), keyEquivalent: "").target = self
        let opacity = NSMenuItem(title: "透明度（⌥ 滚轮）", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [100, 80, 60, 40, 20] {
            let mi = NSMenuItem(title: "\(v)%", action: #selector(setOpacityFromMenu(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = v
            mi.state = abs(alphaValue * 100 - CGFloat(v)) < 2.5 ? .on : .off
            sub.addItem(mi)
        }
        opacity.submenu = sub
        menu.addItem(opacity)
        menu.addItem(withTitle: "鼠标穿透", action: #selector(clickThrough), keyEquivalent: "").target = self
        menu.addItem(withTitle: "按住 ⌥ 拖动可把图片拖到其他应用", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭  Esc", action: #selector(closeFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "关闭所有钉图", action: #selector(closeAllFromMenu), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: contentView!)
    }

    @objc private func copyImage() { Exporter.copyToClipboard(cgImage) }
    @objc private func saveImage() { Exporter.save(cgImage) { _ in } }
    @objc private func closeFromMenu() { closePin() }
    @objc private func closeAllFromMenu() { PinWindow.closeAll() }
    @objc private func clickThrough() { setClickThrough(true) }
    @objc private func setOpacityFromMenu(_ sender: NSMenuItem) { setOpacity(CGFloat(sender.tag) / 100) }
    @objc private func editImage() {
        let screen = self.screen ?? NSScreen.main!
        let w = ImageEditorWindow(image: cgImage, scale: screen.backingScaleFactor, screen: screen, title: "钉图")
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        closePin()
    }
    @objc private func resetZoom() {
        zoom = 1
        let c = frame.center
        setFrame(CGRect(x: c.x - baseSize.width / 2, y: c.y - baseSize.height / 2, width: baseSize.width, height: baseSize.height), display: true)
    }
}

final class PinContentView: NSView {
    var image: NSImage?
    var cgImage: CGImage?
    var onDoubleClick: (() -> Void)?
    private let glass = GlassPanelView(cornerRadius: 14)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        let imageView = PinImageView(frame: bounds.insetBy(dx: PinWindow.border, dy: PinWindow.border))
        imageView.autoresizingMask = [.width, .height]
        imageView.owner = self
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else if event.modifierFlags.contains(.option) {
            beginFileDrag(with: event)
        } else {
            window?.performDrag(with: event)
        }
    }

    /// ⌥ 拖动：把图片作为 PNG 文件拖到其他应用（Finder、聊天窗口等）
    private func beginFileDrag(with event: NSEvent) {
        guard let cgImage, let data = Exporter.pngData(cgImage) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KShot-drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Settings.fileName(width: cgImage.width, height: cgImage.height, ext: "png"))
        guard (try? data.write(to: url)) != nil else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let p = convert(event.locationInWindow, from: nil)
        let w: CGFloat = min(160, bounds.width)
        let h = w * bounds.height / max(1, bounds.width)
        item.setDraggingFrame(CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

extension PinContentView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

/// 圆角裁剪的图片层（放在玻璃面板之上）
final class PinImageView: NSView {
    weak var owner: PinContentView?

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).addClip()
        owner?.image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.mouseDown(with: event)
    }

    override var mouseDownCanMoveWindow: Bool { false }
}
