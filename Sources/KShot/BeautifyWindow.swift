import AppKit

/// 截图美化：背景（渐变 / 纯色 / 透明）+ 内边距 + 圆角 + 阴影
enum Beautifier {
    enum Background: Equatable {
        case gradient([UInt32])
        case solid(UInt32)
        case transparent
    }

    static let backgrounds: [Background] = [
        .gradient([0x7F7FD5, 0x86A8E7, 0x91EAE4]),
        .gradient([0xFF9A8B, 0xFF6A88, 0xFF99AC]),
        .gradient([0x43E97B, 0x38F9D7]),
        .gradient([0xF6D365, 0xFDA085]),
        .gradient([0x4FACFE, 0x00F2FE]),
        .gradient([0xA18CD1, 0xFBC2EB]),
        .gradient([0x232526, 0x414345]),
        .solid(0xF2F2F5),
        .transparent,
    ]

    struct Style {
        var background = 0       // backgrounds 下标
        var padding: CGFloat = 64
        var cornerRadius: CGFloat = 10
        var shadow = true

        static var saved: Style {
            let d = UserDefaults.standard
            var s = Style()
            if d.object(forKey: "beautify.bg") != nil { s.background = min(max(0, d.integer(forKey: "beautify.bg")), backgrounds.count - 1) }
            if d.object(forKey: "beautify.padding") != nil { s.padding = CGFloat(d.double(forKey: "beautify.padding")) }
            if d.object(forKey: "beautify.radius") != nil { s.cornerRadius = CGFloat(d.double(forKey: "beautify.radius")) }
            if d.object(forKey: "beautify.shadow") != nil { s.shadow = d.bool(forKey: "beautify.shadow") }
            return s
        }

        func save() {
            let d = UserDefaults.standard
            d.set(background, forKey: "beautify.bg")
            d.set(Double(padding), forKey: "beautify.padding")
            d.set(Double(cornerRadius), forKey: "beautify.radius")
            d.set(shadow, forKey: "beautify.shadow")
        }
    }

    /// image 为像素图，scale 为像素/pt；边距、圆角、阴影都按 pt 计算
    static func render(_ image: CGImage, scale: CGFloat, style: Style) -> CGImage? {
        let pad = (style.padding * scale).rounded()
        let w = image.width + Int(pad) * 2
        let h = image.height + Int(pad) * 2
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        let bg = backgrounds[min(max(0, style.background), backgrounds.count - 1)]
        switch bg {
        case .gradient(let hexes):
            let colors = hexes.map { NSColor(hex: $0).cgColor } as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
            }
        case .solid(let hex):
            ctx.setFillColor(NSColor(hex: hex).cgColor)
            ctx.fill(full)
        case .transparent:
            break
        }
        let imgRect = CGRect(x: pad, y: pad, width: CGFloat(image.width), height: CGFloat(image.height))
        let r = min(style.cornerRadius * scale, imgRect.width / 2, imgRect.height / 2)
        let path = CGPath(roundedRect: imgRect, cornerWidth: r, cornerHeight: r, transform: nil)
        if style.shadow {
            ctx.saveGState()
            // 内边距很小时阴影也相应收小，避免被画布裁掉
            let blur = min(36 * scale, max(4 * scale, pad * 0.6))
            ctx.setShadow(offset: CGSize(width: 0, height: -blur * 0.35), blur: blur, color: NSColor.black.withAlphaComponent(0.38).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.clear(imgRect)
        ctx.draw(image, in: imgRect)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

/// 美化窗口：左侧预览，右侧选项
final class BeautifyWindow: NSWindow {
    nonisolated(unsafe) private static var all: [BeautifyWindow] = []
    nonisolated(unsafe) static weak var latest: BeautifyWindow?

    private let image: CGImage
    private let scale: CGFloat
    private let previewSource: CGImage
    private let previewScale: CGFloat
    private var style: Beautifier.Style
    private let preview = CheckerImageView()
    private let swatches = SwatchPicker()
    private let paddingSlider = NSSlider(value: 64, minValue: 0, maxValue: 160, target: nil, action: nil)
    private let radiusSlider = NSSlider(value: 10, minValue: 0, maxValue: 40, target: nil, action: nil)
    private let paddingValue = NSTextField(labelWithString: "")
    private let radiusValue = NSTextField(labelWithString: "")
    private let shadowCheck = NSButton(checkboxWithTitle: "阴影", target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "")

    init(image: CGImage, scale: CGFloat, near rect: CGRect, fromWindow: Bool) {
        self.image = image
        self.scale = scale
        // 预览用缩小图，拖滑块时也流畅
        let maxPx: CGFloat = 1400
        let f = min(1, maxPx / CGFloat(max(image.width, image.height)))
        previewSource = f < 1 ? (History.thumbnail(of: image, maxPixel: Int(maxPx)) ?? image) : image
        previewScale = scale * CGFloat(previewSource.width) / CGFloat(image.width)
        style = .saved

        let size = NSSize(width: 860, height: 580)
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main {
            let v = screen.visibleFrame
            origin.x = min(max(v.minX + 12, origin.x), v.maxX - size.width - 12)
            origin.y = min(max(v.minY + 12, origin.y), v.maxY - size.height - 12)
        }
        super.init(contentRect: CGRect(origin: origin, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        let content = NSView(frame: root.bounds)
        let backdrop = GlassBackdrop.make(cornerRadius: 18, content: content)
        backdrop.frame = root.bounds
        root.addSubview(backdrop)
        contentView = root

        let sideW: CGFloat = 250
        let title = NSTextField(labelWithString: "美化")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = CGRect(x: 20, y: size.height - 40, width: 200, height: 22)
        content.addSubview(title)

        preview.frame = CGRect(x: 16, y: 16, width: size.width - sideW - 32, height: size.height - 64)
        content.addSubview(preview)

        let x0 = size.width - sideW
        var y = size.height - 48
        func label(_ s: String) {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 12, weight: .medium)
            l.textColor = .secondaryLabelColor
            l.frame = CGRect(x: x0, y: y, width: 120, height: 16)
            content.addSubview(l)
        }
        y -= 6
        label("背景")
        y -= 6 + SwatchPicker.height
        swatches.frame = CGRect(x: x0, y: y, width: sideW - 20, height: SwatchPicker.height)
        swatches.selected = style.background
        swatches.onChange = { [weak self] i in self?.style.background = i; self?.refresh() }
        content.addSubview(swatches)

        func slider(_ s: NSSlider, _ name: String, _ value: NSTextField, _ v: CGFloat) {
            y -= 34
            label(name)
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.textColor = .secondaryLabelColor
            value.alignment = .right
            value.frame = CGRect(x: x0 + sideW - 90, y: y, width: 70, height: 16)
            content.addSubview(value)
            y -= 26
            s.doubleValue = Double(v)
            s.target = self
            s.action = #selector(slidersChanged)
            s.isContinuous = true
            s.frame = CGRect(x: x0, y: y, width: sideW - 20, height: 22)
            content.addSubview(s)
        }
        slider(paddingSlider, "内边距", paddingValue, style.padding)
        slider(radiusSlider, "圆角", radiusValue, fromWindow ? max(style.cornerRadius, 10) : style.cornerRadius)
        y -= 36
        shadowCheck.state = style.shadow ? .on : .off
        shadowCheck.target = self
        shadowCheck.action = #selector(slidersChanged)
        shadowCheck.frame = CGRect(x: x0 - 2, y: y, width: 120, height: 20)
        content.addSubview(shadowCheck)

        y -= 30
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .tertiaryLabelColor
        sizeLabel.frame = CGRect(x: x0, y: y, width: sideW - 20, height: 16)
        content.addSubview(sizeLabel)

        let copy = NSButton(title: "复制", target: self, action: #selector(copyImage))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = "\r"
        if #available(macOS 26.0, *) { copy.bezelColor = .accentGreen }
        copy.frame = CGRect(x: x0 + (sideW - 20) - 76, y: 16, width: 76, height: 30)
        content.addSubview(copy)
        let save = NSButton(title: "保存…", target: self, action: #selector(saveImage))
        save.bezelStyle = .rounded
        save.frame = CGRect(x: copy.frame.minX - 82, y: 16, width: 76, height: 30)
        content.addSubview(save)
        let close = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        close.frame = CGRect(x: save.frame.minX - 82, y: 16, width: 76, height: 30)
        content.addSubview(close)

        slidersChanged()
        BeautifyWindow.all.append(self)
        BeautifyWindow.latest = self
    }

    override var canBecomeKey: Bool { true }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func slidersChanged() {
        style.padding = CGFloat(paddingSlider.doubleValue.rounded())
        style.cornerRadius = CGFloat(radiusSlider.doubleValue.rounded())
        style.shadow = shadowCheck.state == .on
        paddingValue.stringValue = "\(Int(style.padding)) pt"
        radiusValue.stringValue = "\(Int(style.cornerRadius)) pt"
        refresh()
    }

    private func refresh() {
        style.save()
        if let img = Beautifier.render(previewSource, scale: previewScale, style: style) {
            preview.image = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        }
        let pad = Int((style.padding * scale).rounded()) * 2
        sizeLabel.stringValue = "输出 \(image.width + pad) × \(image.height + pad) px"
    }

    private func output() -> CGImage? { Beautifier.render(image, scale: scale, style: style) }

    @objc private func copyImage() {
        guard let img = output() else { return }
        Exporter.deliver(img)
        closeWindow()
        Toast.show("已复制美化后的图片")
    }

    @objc private func saveImage() {
        guard let img = output() else { return }
        History.add(img)
        if Settings.quickSave {
            Exporter.quickSave(img)
            closeWindow()
            return
        }
        Exporter.save(img) { [weak self] ok in if ok { self?.closeWindow() } }
    }

    @objc private func closeWindow() {
        orderOut(nil)
        BeautifyWindow.all.removeAll { $0 === self }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closeWindow(); return }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c": copyImage(); return
            case "s": saveImage(); return
            case "w": closeWindow(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { closeWindow() }

    // 调试
    func debugSetStyle(background: Int, padding: CGFloat, radius: CGFloat, shadow: Bool) {
        swatches.selected = background
        style.background = background
        paddingSlider.doubleValue = Double(padding)
        radiusSlider.doubleValue = Double(radius)
        shadowCheck.state = shadow ? .on : .off
        slidersChanged()
    }
    var debugOutput: CGImage? { output() }
}

/// 预览：棋盘格底（显示透明区域）+ 等比缩放的图片
final class CheckerImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        path.addClip()
        NSColor(white: 0.5, alpha: 0.12).setFill()
        bounds.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let s = min(bounds.width / image.size.width, bounds.height / image.size.height) * 0.94
        let size = CGSize(width: image.size.width * s, height: image.size.height * s)
        let r = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        // 棋盘格
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).addClip()
        let cell: CGFloat = 8
        var row = 0
        var yy = r.minY
        while yy < r.maxY {
            var xx = r.minX + (row % 2 == 0 ? 0 : cell)
            NSColor(white: 0.85, alpha: 1).setFill()
            NSRect(x: r.minX, y: yy, width: r.width, height: cell).fill()
            NSColor(white: 0.97, alpha: 1).setFill()
            while xx < r.maxX {
                NSRect(x: xx, y: yy, width: cell, height: cell).fill()
                xx += cell * 2
            }
            yy += cell
            row += 1
        }
        NSGraphicsContext.restoreGraphicsState()
        image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
}

/// 背景色块选择器
final class SwatchPicker: NSView {
    static let cell: CGFloat = 40
    static let gap: CGFloat = 8
    static let columns = 5
    static var height: CGFloat {
        let rows = (Beautifier.backgrounds.count + columns - 1) / columns
        return CGFloat(rows) * cell + CGFloat(rows - 1) * gap
    }

    var selected = 0 { didSet { needsDisplay = true } }
    var onChange: ((Int) -> Void)?
    override var isFlipped: Bool { true }

    private func rect(_ i: Int) -> CGRect {
        let c = i % Self.columns, r = i / Self.columns
        return CGRect(x: CGFloat(c) * (Self.cell + Self.gap), y: CGFloat(r) * (Self.cell + Self.gap), width: Self.cell, height: Self.cell)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, bg) in Beautifier.backgrounds.enumerated() {
            let r = rect(i).insetBy(dx: 3, dy: 3)
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            switch bg {
            case .gradient(let hexes):
                NSGradient(colors: hexes.map { NSColor(hex: $0) })?.draw(in: r, angle: -45)
            case .solid(let hex):
                NSColor(hex: hex).setFill()
                r.fill()
            case .transparent:
                NSColor.white.setFill()
                r.fill()
                NSColor(white: 0.8, alpha: 1).setFill()
                let c = r.width / 4
                for yy in 0..<4 { for xx in 0..<4 where (xx + yy) % 2 == 0 {
                    NSRect(x: r.minX + CGFloat(xx) * c, y: r.minY + CGFloat(yy) * c, width: c, height: c).fill()
                } }
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.labelColor.withAlphaComponent(0.15).setStroke()
            path.lineWidth = 1
            path.stroke()
            if i == selected {
                let ring = NSBezierPath(roundedRect: rect(i).insetBy(dx: 0.75, dy: 0.75), xRadius: 10, yRadius: 10)
                ring.lineWidth = 2
                NSColor.accentGreen.setStroke()
                ring.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in Beautifier.backgrounds.indices where rect(i).contains(p) {
            selected = i
            onChange?(i)
            return
        }
    }
}
