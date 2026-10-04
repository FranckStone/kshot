import AppKit

enum ToolbarAction {
    case tool(Tool)
    case undo
    case pin
    case save
    case cancel
    case confirm
}

/// 工具条按钮（纯图标）
final class ToolButton: NSButton {
    static let normalTint = NSColor(white: 0.22, alpha: 1)
    var tintOverride: NSColor?

    var isActiveTool = false {
        didSet { refresh() }
    }

    init(symbol: String, fallback: String? = nil, tip: String, tint: NSColor? = nil) {
        super.init(frame: CGRect(x: 0, y: 0, width: ToolbarView.buttonSize, height: ToolbarView.buttonSize))
        if symbol.hasPrefix("text:") {
            // 自绘字母图标（SF Symbol 的 textformat 在中文系统会被本地化成“格式”）
            image = ToolButton.letterIcon(String(symbol.dropFirst(5)))
        } else {
            var img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            if img == nil, let fallback { img = NSImage(systemSymbolName: fallback, accessibilityDescription: tip) }
            image = img?.withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        }
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        toolTip = tip
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6
        tintOverride = tint
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    static func letterIcon(_ letter: String) -> NSImage {
        let size = NSSize(width: 20, height: 20)
        let img = NSImage(size: size, flipped: false) { rect in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: NSColor.black,
            ]
            let str = NSAttributedString(string: letter, attributes: attrs)
            let s = str.size()
            str.draw(at: NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2))
            return true
        }
        img.isTemplate = true
        return img
    }

    private func refresh() {
        if isActiveTool {
            contentTintColor = .wechatGreen
            layer?.backgroundColor = NSColor.wechatGreen.withAlphaComponent(0.14).cgColor
        } else {
            contentTintColor = tintOverride ?? ToolButton.normalTint
            layer?.backgroundColor = nil
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if !isActiveTool { layer?.backgroundColor = NSColor(white: 0, alpha: 0.06).cgColor }
    }

    override func mouseExited(with event: NSEvent) {
        if !isActiveTool { layer?.backgroundColor = nil }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
}

/// 微信风格的白底圆角工具条
final class ToolbarView: NSView {
    static let buttonSize: CGFloat = 30
    static let spacing: CGFloat = 2
    static let padding: CGFloat = 5
    static let height: CGFloat = buttonSize + padding * 2

    var onAction: ((ToolbarAction) -> Void)?

    private var toolButtons: [Tool: ToolButton] = [:]
    private var undoButton: ToolButton!

    private struct Item {
        let action: ToolbarAction
        let button: ToolButton
    }
    private var items: [Item] = []

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.98).cgColor
        layer?.cornerRadius = 8
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false

        func add(_ action: ToolbarAction, _ symbol: String, fallback: String? = nil, _ tip: String, tint: NSColor? = nil) {
            let b = ToolButton(symbol: symbol, fallback: fallback, tip: tip, tint: tint)
            b.target = self
            b.action = #selector(buttonPressed(_:))
            b.tag = items.count
            items.append(Item(action: action, button: b))
            addSubview(b)
            if case .tool(let t) = action { toolButtons[t] = b }
        }

        add(.tool(.rect), "rectangle", "矩形")
        add(.tool(.ellipse), "circle", "椭圆")
        add(.tool(.arrow), "arrow.up.right", "箭头")
        add(.tool(.pen), "pencil.line", fallback: "scribble", "画笔")
        add(.tool(.mosaic), "mosaic", fallback: "square.grid.3x3.fill", "马赛克")
        add(.tool(.text), "text:T", "文字")
        addSeparatorMarker()
        add(.undo, "arrow.uturn.backward", "撤销  ⌘Z")
        undoButton = items.last!.button
        add(.pin, "pin", "钉在屏幕上")
        add(.save, "square.and.arrow.down", "保存  ⌘S")
        addSeparatorMarker()
        add(.cancel, "xmark", "取消  Esc", tint: NSColor(hex: 0xFA5151))
        add(.confirm, "checkmark", "完成  ⏎", tint: .wechatGreen)

        layoutButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var separatorsAfter: Set<Int> = []
    private func addSeparatorMarker() { separatorsAfter.insert(items.count - 1) }

    private func layoutButtons() {
        var x = ToolbarView.padding
        for (i, item) in items.enumerated() {
            item.button.frame = CGRect(x: x, y: ToolbarView.padding, width: ToolbarView.buttonSize, height: ToolbarView.buttonSize)
            x += ToolbarView.buttonSize + ToolbarView.spacing
            if separatorsAfter.contains(i) { x += 10 }
        }
        frame.size = CGSize(width: x - ToolbarView.spacing + ToolbarView.padding, height: ToolbarView.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 分隔线
        NSColor(white: 0, alpha: 0.12).setFill()
        for i in separatorsAfter {
            let b = items[i].button.frame
            let x = b.maxX + 5
            NSRect(x: x, y: 9, width: 1, height: bounds.height - 18).fill()
        }
    }

    @objc private func buttonPressed(_ sender: ToolButton) {
        guard sender.tag < items.count else { return }
        onAction?(items[sender.tag].action)
    }

    func setSelectedTool(_ tool: Tool) {
        for (t, b) in toolButtons { b.isActiveTool = (t == tool) }
    }

    func setUndoEnabled(_ enabled: Bool) {
        undoButton.isEnabled = enabled
        undoButton.alphaValue = enabled ? 1 : 0.35
    }

    override func mouseDown(with event: NSEvent) {
        // 吞掉点击，避免穿透到遮罩层
    }
}

/// 粗细 + 颜色 选项面板
final class OptionsView: NSView {
    static let height: CGFloat = 34
    var onChange: ((StrokeSize?, NSColor?) -> Void)?

    var size: StrokeSize = .medium { didSet { needsDisplay = true } }
    var color: NSColor = Palette.colors[0] { didSet { needsDisplay = true } }

    private let cell: CGFloat = 26
    private let pad: CGFloat = 8
    private let gap: CGFloat = 10

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.98).cgColor
        layer?.cornerRadius = 8
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
        let width = pad * 2 + cell * CGFloat(StrokeSize.allCases.count) + gap + 1 + gap + cell * CGFloat(Palette.colors.count)
        frame.size = CGSize(width: width, height: OptionsView.height)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func sizeRect(_ i: Int) -> CGRect {
        CGRect(x: pad + CGFloat(i) * cell, y: (bounds.height - cell) / 2, width: cell, height: cell)
    }

    private func colorRect(_ i: Int) -> CGRect {
        let start = pad + cell * CGFloat(StrokeSize.allCases.count) + gap + 1 + gap
        return CGRect(x: start + CGFloat(i) * cell, y: (bounds.height - cell) / 2, width: cell, height: cell)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, s) in StrokeSize.allCases.enumerated() {
            let r = sizeRect(i)
            if s == size {
                NSColor.wechatGreen.withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
            }
            let d = s.dotDiameter
            let dot = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
            (s == size ? NSColor.wechatGreen : NSColor(white: 0.3, alpha: 1)).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        // 分隔线
        let sepX = pad + cell * CGFloat(StrokeSize.allCases.count) + gap
        NSColor(white: 0, alpha: 0.12).setFill()
        NSRect(x: sepX, y: 8, width: 1, height: bounds.height - 16).fill()

        for (i, c) in Palette.colors.enumerated() {
            let r = colorRect(i)
            let selected = c.isClose(to: color)
            let d: CGFloat = selected ? 18 : 14
            let circle = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
            c.setFill()
            NSBezierPath(ovalIn: circle).fill()
            // 浅色需要描边
            NSColor(white: 0, alpha: selected ? 0.35 : 0.18).setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (i, s) in StrokeSize.allCases.enumerated() where sizeRect(i).contains(p) {
            size = s
            onChange?(s, nil)
            return
        }
        for (i, c) in Palette.colors.enumerated() where colorRect(i).contains(p) {
            color = c
            onChange?(nil, c)
            return
        }
    }
}

extension NSColor {
    func isClose(to other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return self == other }
        return abs(a.redComponent - b.redComponent) < 0.01 &&
            abs(a.greenComponent - b.greenComponent) < 0.01 &&
            abs(a.blueComponent - b.blueComponent) < 0.01
    }
}
