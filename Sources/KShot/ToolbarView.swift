import AppKit

enum ToolbarAction {
    case tool(Tool)
    case undo
    case pin
    case save
    case cancel
    case confirm
}

/// 工具条按钮（纯图标，胶囊高亮），颜色全部用动态色以适配玻璃背板的深浅外观
final class ToolButton: NSButton {
    enum Role { case normal, destructive, prominent }

    let role: Role
    var isActiveTool = false {
        didSet { refresh() }
    }
    private var hovered = false {
        didSet { needsDisplay = true }
    }

    init(symbol: String, fallback: String? = nil, tip: String, role: Role = .normal) {
        self.role = role
        super.init(frame: CGRect(x: 0, y: 0, width: ToolbarView.buttonSize, height: ToolbarView.buttonSize))
        if symbol.hasPrefix("text:") {
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
        switch (role, isActiveTool) {
        case (.prominent, _), (_, true):
            contentTintColor = .white
        case (.destructive, _):
            contentTintColor = NSColor(hex: 0xFA5151)
        default:
            contentTintColor = .labelColor
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if role == .prominent || isActiveTool {
            NSColor.wechatGreen.setFill()
            capsule.fill()
            if hovered {
                NSColor.white.withAlphaComponent(0.15).setFill()
                capsule.fill()
            }
        } else if hovered {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            capsule.fill()
        }
        super.draw(dirtyRect)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
}

/// 工具条内容（按钮 + 分隔线），放进玻璃背板里
final class ToolbarContentView: NSView {
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {
        // 吞掉点击，避免穿透到遮罩层
    }
}

/// 液态玻璃胶囊工具条
final class ToolbarView: NSView {
    static let buttonSize: CGFloat = 32
    static let spacing: CGFloat = 2
    static let padding: CGFloat = 6
    static let height: CGFloat = buttonSize + padding * 2

    var onAction: ((ToolbarAction) -> Void)?

    private var toolButtons: [Tool: ToolButton] = [:]
    private var undoButton: ToolButton!
    private let content = ToolbarContentView()
    private var backdrop: NSView!

    private struct Item {
        let action: ToolbarAction
        let button: ToolButton
    }
    private var items: [Item] = []
    private var separatorsAfter: Set<Int> = []

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)

        func add(_ action: ToolbarAction, _ symbol: String, fallback: String? = nil, _ tip: String, role: ToolButton.Role = .normal) {
            let b = ToolButton(symbol: symbol, fallback: fallback, tip: tip, role: role)
            b.target = self
            b.action = #selector(buttonPressed(_:))
            b.tag = items.count
            items.append(Item(action: action, button: b))
            content.addSubview(b)
            if case .tool(let t) = action { toolButtons[t] = b }
        }

        add(.tool(.rect), "rectangle", "矩形")
        add(.tool(.ellipse), "circle", "椭圆")
        add(.tool(.arrow), "arrow.up.right", "箭头")
        add(.tool(.pen), "pencil.line", fallback: "scribble", "画笔")
        add(.tool(.mosaic), "mosaic", fallback: "square.grid.3x3.fill", "马赛克")
        add(.tool(.text), "text:T", "文字")
        separatorsAfter.insert(items.count - 1)
        add(.undo, "arrow.uturn.backward", "撤销  ⌘Z")
        undoButton = items.last!.button
        add(.pin, "pin", "钉在屏幕上  ⌘P")
        add(.save, "square.and.arrow.down", "保存  ⌘S")
        separatorsAfter.insert(items.count - 1)
        add(.cancel, "xmark", "取消  Esc", role: .destructive)
        add(.confirm, "checkmark", "完成  ⏎", role: .prominent)

        layoutButtons()
        backdrop = GlassBackdrop.make(cornerRadius: ToolbarView.height / 2, content: content)
        backdrop.frame = bounds
        addSubview(backdrop)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func layoutButtons() {
        var x = ToolbarView.padding
        for (i, item) in items.enumerated() {
            item.button.frame = CGRect(x: x, y: ToolbarView.padding, width: ToolbarView.buttonSize, height: ToolbarView.buttonSize)
            x += ToolbarView.buttonSize + ToolbarView.spacing
            if separatorsAfter.contains(i) {
                let sep = SeparatorView(frame: CGRect(x: x + 4, y: 12, width: 1, height: ToolbarView.height - 24))
                content.addSubview(sep)
                x += 10
            }
        }
        let width = x - ToolbarView.spacing + ToolbarView.padding
        frame.size = CGSize(width: width, height: ToolbarView.height)
        content.frame = CGRect(origin: .zero, size: frame.size)
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

    override func mouseDown(with event: NSEvent) {}
}

/// 粗细 + 颜色 选项面板（液态玻璃胶囊）
final class OptionsView: NSView {
    static let height: CGFloat = 40
    var onChange: ((StrokeSize?, NSColor?) -> Void)?

    var size: StrokeSize = .medium { didSet { content.needsDisplay = true } }
    var color: NSColor = Palette.colors[0] { didSet { content.needsDisplay = true } }

    fileprivate let cell: CGFloat = 28
    fileprivate let pad: CGFloat = 10
    fileprivate let gap: CGFloat = 10

    private let content = OptionsContentView()
    private var backdrop: NSView!

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        let width = pad * 2 + cell * CGFloat(StrokeSize.allCases.count) + gap + 1 + gap + cell * CGFloat(Palette.colors.count)
        frame.size = CGSize(width: width, height: OptionsView.height)
        content.owner = self
        content.frame = bounds
        backdrop = GlassBackdrop.make(cornerRadius: OptionsView.height / 2, content: content)
        backdrop.frame = bounds
        addSubview(backdrop)
    }

    required init?(coder: NSCoder) { fatalError() }

    fileprivate func sizeRect(_ i: Int) -> CGRect {
        CGRect(x: pad + CGFloat(i) * cell, y: (bounds.height - cell) / 2, width: cell, height: cell)
    }

    fileprivate func colorRect(_ i: Int) -> CGRect {
        let start = pad + cell * CGFloat(StrokeSize.allCases.count) + gap + 1 + gap
        return CGRect(x: start + CGFloat(i) * cell, y: (bounds.height - cell) / 2, width: cell, height: cell)
    }

    fileprivate func handleClick(at p: CGPoint) {
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

    override func mouseDown(with event: NSEvent) {}
}

final class OptionsContentView: NSView {
    weak var owner: OptionsView?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let o = owner else { return }
        for (i, s) in StrokeSize.allCases.enumerated() {
            let r = o.sizeRect(i)
            if s == o.size {
                NSColor.wechatGreen.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: r.height / 2, yRadius: r.height / 2).fill()
            }
            let d = s.dotDiameter
            let dot = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
            (s == o.size ? NSColor.white : NSColor.labelColor).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        let sepX = o.pad + o.cell * CGFloat(StrokeSize.allCases.count) + o.gap
        NSColor.separatorColor.setFill()
        NSRect(x: sepX, y: 12, width: 1, height: bounds.height - 24).fill()

        for (i, c) in Palette.colors.enumerated() {
            let r = o.colorRect(i)
            let selected = c.isClose(to: o.color)
            let d: CGFloat = selected ? 20 : 15
            let circle = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
            c.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.labelColor.withAlphaComponent(selected ? 0.5 : 0.2).setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = selected ? 1.5 : 1
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        owner?.handleClick(at: convert(event.locationInWindow, from: nil))
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
