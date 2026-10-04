import AppKit

/// 文字识别结果窗口：玻璃面板 + 可编辑文本，⌘C / “复制全部” 复制，Esc 关闭
final class OCRResultWindow: NSWindow {
    nonisolated(unsafe) private static var all: [OCRResultWindow] = []
    nonisolated(unsafe) static weak var latest: OCRResultWindow?

    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let translatedView = NSTextView()
    private var sourceScroll: NSScrollView!
    private var translatedScroll: NSScrollView!
    private var translatedTitle: NSTextField!
    private var copyTranslationButton: NSButton!
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let translator = Translator()
    private var content: NSView!

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
        self.content = content
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
        sourceScroll = scroll

        // 译文面板（翻译后显示）
        translatedTitle = NSTextField(labelWithString: "译文")
        translatedTitle.font = .systemFont(ofSize: 12, weight: .medium)
        translatedTitle.textColor = .secondaryLabelColor
        translatedTitle.isHidden = true
        content.addSubview(translatedTitle)
        translatedScroll = NSScrollView(frame: .zero)
        translatedScroll.hasVerticalScroller = true
        translatedScroll.drawsBackground = false
        translatedScroll.borderType = .noBorder
        translatedView.autoresizingMask = [.width]
        translatedView.isEditable = true
        translatedView.isRichText = false
        translatedView.drawsBackground = true
        translatedView.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.55)
        translatedView.font = .systemFont(ofSize: 14)
        translatedView.textColor = .labelColor
        translatedView.textContainerInset = NSSize(width: 10, height: 10)
        translatedView.wantsLayer = true
        translatedView.layer?.cornerRadius = 10
        translatedScroll.documentView = translatedView
        translatedScroll.isHidden = true
        content.addSubview(translatedScroll)
        content.addSubview(translator.hostView)

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

        // 翻译：目标语言 + 按钮
        for lang in TargetLanguage.all { languagePopup.addItem(withTitle: lang.title) }
        languagePopup.frame = CGRect(x: 16, y: 14, width: 110, height: 30)
        languagePopup.selectItem(at: TargetLanguage.all.firstIndex(of: TargetLanguage.guess(for: text)) ?? 0)
        content.addSubview(languagePopup)

        let translate = NSButton(title: "翻译", target: self, action: #selector(translateAction))
        translate.bezelStyle = .rounded
        translate.frame = CGRect(x: 130, y: 14, width: 70, height: 30)
        translate.isEnabled = Translator.isAvailable
        translate.toolTip = Translator.isAvailable ? "用系统翻译把文字译成所选语言" : "翻译需要 macOS 15 或更高版本"
        content.addSubview(translate)

        copyTranslationButton = NSButton(title: "复制译文", target: self, action: #selector(copyTranslation))
        copyTranslationButton.bezelStyle = .rounded
        copyTranslationButton.frame = CGRect(x: 204, y: 14, width: 90, height: 30)
        copyTranslationButton.isHidden = true
        content.addSubview(copyTranslationButton)

        OCRResultWindow.all.append(self)
        OCRResultWindow.latest = self
    }

    override var canBecomeKey: Bool { true }

    func setStatus(_ s: String) { statusLabel.stringValue = s }
    func setText(_ s: String) {
        textView.string = s
        languagePopup.selectItem(at: TargetLanguage.all.firstIndex(of: TargetLanguage.guess(for: s)) ?? 0)
    }
    var translatedText: String { translatedView.string }

    /// 翻译原文到所选语言
    @objc func translateAction() {
        let source = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { setStatus("没有可翻译的文字"); return }
        let target = TargetLanguage.all[max(0, languagePopup.indexOfSelectedItem)]
        showTranslationPane()
        translatedView.string = "正在翻译…"
        setStatus("")
        translator.translate(source, to: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                self.translatedView.string = text
                self.setStatus("已翻译为\(target.title)")
                Log.info("translate ok: \(text.count) chars")
            case .failure(let error):
                self.translatedView.string = ""
                self.setStatus("翻译失败：\(error.localizedDescription)")
                Log.info("translate failed: \(error)")
            }
        }
    }

    private func showTranslationPane() {
        guard translatedScroll.isHidden else { return }
        // 窗口加高，原文与译文上下各占一半
        var f = frame
        let extra: CGFloat = 180
        f.origin.y -= extra
        f.size.height += extra
        setFrame(f, display: true)
        let size = content.bounds.size
        let top = size.height - 56
        let bottom: CGFloat = 56
        let gap: CGFloat = 26
        let paneH = (top - bottom - gap) / 2
        sourceScroll.frame = CGRect(x: 16, y: bottom + paneH + gap, width: size.width - 32, height: paneH)
        translatedTitle.frame = CGRect(x: 20, y: bottom + paneH + 4, width: 100, height: 18)
        translatedScroll.frame = CGRect(x: 16, y: bottom, width: size.width - 32, height: paneH)
        translatedView.frame = translatedScroll.bounds
        translatedTitle.isHidden = false
        translatedScroll.isHidden = false
        copyTranslationButton.isHidden = false
    }

    @objc private func copyTranslation() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(translatedView.string, forType: .string)
        setStatus("译文已复制到剪贴板")
    }
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
