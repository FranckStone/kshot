import AppKit

/// 文字识别结果窗口：玻璃面板 + 可编辑文本，⌘C / “复制全部” 复制，Esc 关闭
final class OCRResultWindow: NSWindow {
    nonisolated(unsafe) private static var all: [OCRResultWindow] = []
    nonisolated(unsafe) static weak var latest: OCRResultWindow?

    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")

    init(text: String, near rect: CGRect) {
        let size = NSSize(width: 520, height: 360)
        // 居中于选区，并限制在屏幕内
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
        content.autoresizingMask = [.width, .height]
        let backdrop = GlassBackdrop.make(cornerRadius: 18, content: content)
        backdrop.frame = root.bounds
        root.addSubview(backdrop)
        contentView = root

        // 标题
        let title = NSTextField(labelWithString: "提取的文字")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.frame = CGRect(x: 20, y: size.height - 40, width: 200, height: 22)
        content.addSubview(title)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.frame = CGRect(x: size.width - 240, y: size.height - 38, width: 220, height: 18)
        content.addSubview(statusLabel)

        // 文本
        let scroll = NSScrollView(frame: CGRect(x: 16, y: 56, width: size.width - 32, height: size.height - 108))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        textView.frame = scroll.bounds
        textView.autoresizingMask = [.width]
        textView.isEditable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.55)
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        textView.wantsLayer = true
        textView.layer?.cornerRadius = 10
        scroll.documentView = textView
        content.addSubview(scroll)

        // 按钮
        let close = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        close.frame = CGRect(x: size.width - 196, y: 14, width: 84, height: 30)
        content.addSubview(close)

        let copy = NSButton(title: "复制全部", target: self, action: #selector(copyAll))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = "\r"
        copy.frame = CGRect(x: size.width - 104, y: 14, width: 88, height: 30)
        if #available(macOS 26.0, *) { copy.bezelColor = .accentGreen }
        content.addSubview(copy)

        let hint = NSTextField(labelWithString: "⌘C 复制选中文字 · ⏎ 复制全部 · Esc 关闭")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.frame = CGRect(x: 20, y: 20, width: 300, height: 16)
        content.addSubview(hint)

        OCRResultWindow.all.append(self)
        OCRResultWindow.latest = self
    }

    override var canBecomeKey: Bool { true }

    func setStatus(_ s: String) { statusLabel.stringValue = s }
    func setText(_ s: String) { textView.string = s }
    var text: String { textView.string }

    @objc private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(textView.string, forType: .string)
        setStatus("已复制到剪贴板")
    }

    @objc private func closeWindow() {
        orderOut(nil)
        OCRResultWindow.all.removeAll { $0 === self }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closeWindow(); return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { closeWindow() }
}
