import AppKit

/// 文字标注的就地编辑器：Esc / ⌘⏎ / 点击别处 结束编辑
final class TextEditorView: NSTextView {
    var onCommit: (() -> Void)?
    /// 尺寸随内容变化时回调（用于同步底下的玻璃面板）
    var onFrameChange: ((CGRect) -> Void)?
    var strokeColor: NSColor = Palette.colors[0] {
        didSet {
            textColor = strokeColor
            insertionPointColor = strokeColor
        }
    }
    var fontSize: CGFloat = 20 {
        didSet {
            font = Annotation.textFont(size: fontSize)
            fit()
        }
    }

    init(origin: CGPoint, color: NSColor, fontSize: CGFloat) {
        let container = NSTextContainer(size: CGSize(width: 4000, height: 4000))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        super.init(frame: CGRect(origin: origin, size: CGSize(width: 40, height: fontSize + 8)), textContainer: container)

        drawsBackground = false
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        textContainerInset = Annotation.textInset
        isVerticallyResizable = false
        isHorizontallyResizable = false

        self.fontSize = fontSize
        self.strokeColor = color
        typingAttributes = [.font: Annotation.textFont(size: fontSize), .foregroundColor: color]
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 根据内容自适应尺寸
    func fit() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let minW = fontSize * 1.5
        let w = max(minW, ceil(used.width)) + textContainerInset.width * 2 + 2
        let h = max(fontSize * 1.3, ceil(used.height)) + textContainerInset.height * 2
        frame.size = CGSize(width: w, height: h)
        onFrameChange?(frame)
    }

    override func didChangeText() {
        super.didChangeText()
        // 保持新输入文字沿用当前颜色与字号
        typingAttributes = [.font: Annotation.textFont(size: fontSize), .foregroundColor: strokeColor]
        fit()
    }

    override func cancelOperation(_ sender: Any?) {
        onCommit?()
    }

    override func keyDown(with event: NSEvent) {
        // ⌘⏎ 结束编辑
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }
}
