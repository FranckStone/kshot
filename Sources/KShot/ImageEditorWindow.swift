import AppKit

/// 图片编辑窗口：对一张已有图片（如长截图）做标注，复用截图时的工具条、颜色面板与标注渲染。
final class ImageEditorWindow: NSWindow {
    nonisolated(unsafe) private static var all: [ImageEditorWindow] = []
    nonisolated(unsafe) static weak var latest: ImageEditorWindow?

    private let canvas: ImageCanvasView
    private let editorToolbar = ToolbarView(mode: .editor)
    private let options = OptionsView()
    private let scroll = NSScrollView()
    private let content = NSView()
    private let screenRef: NSScreen

    init(image: CGImage, scale: CGFloat, screen: NSScreen, title: String) {
        canvas = ImageCanvasView(image: image, scale: scale)
        screenRef = screen
        let v = screen.visibleFrame
        let bottomBar: CGFloat = 108
        let width = min(canvas.frame.width + 40, v.width * 0.85)
        let height = min(canvas.frame.height + 56 + bottomBar, v.height * 0.9)
        let size = NSSize(width: max(560, width), height: max(360, height))
        let origin = CGPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2)
        super.init(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 560, height: 360)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        content.frame = root.bounds
        content.autoresizingMask = [.width, .height]
        let backdrop = GlassBackdrop.make(cornerRadius: 18, content: content)
        backdrop.frame = root.bounds
        root.addSubview(backdrop)
        contentView = root

        let titleLabel = NSTextField(labelWithString: "\(title)  \(image.width) × \(image.height)")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.frame = CGRect(x: 20, y: size.height - 36, width: size.width - 40, height: 20)
        titleLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(titleLabel)

        scroll.frame = CGRect(x: 16, y: bottomBar, width: size.width - 32, height: size.height - 56 - bottomBar)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.masksToBounds = true
        scroll.documentView = canvas
        content.addSubview(scroll)

        editorToolbar.onAction = { [weak self] in self?.handle($0) }
        options.onChange = { [weak self] size, color in
            guard let self else { return }
            if let size { self.canvas.strokeSize = size }
            if let color { self.canvas.color = color }
        }
        options.size = canvas.strokeSize
        options.color = canvas.color
        options.isHidden = true
        content.addSubview(options)
        content.addSubview(editorToolbar)
        editorToolbar.setUndoEnabled(false)
        canvas.onAnnotationsChanged = { [weak self] in
            guard let self else { return }
            self.editorToolbar.setUndoEnabled(self.canvas.canUndo)
        }
        layoutBars()

        ImageEditorWindow.all.append(self)
        ImageEditorWindow.latest = self
        makeFirstResponder(canvas)
    }

    override var canBecomeKey: Bool { true }

    private func layoutBars() {
        let w = content.bounds.width
        var tf = editorToolbar.frame
        tf.origin = CGPoint(x: (w - tf.width) / 2, y: 14)
        editorToolbar.frame = tf
        var of = options.frame
        of.origin = CGPoint(x: (w - of.width) / 2, y: tf.maxY + 6)
        options.frame = of
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        layoutBars()
    }

    // MARK: - 工具条

    private func handle(_ action: ToolbarAction) {
        switch action {
        case .tool(let t):
            canvas.commitText()
            canvas.tool = (canvas.tool == t) ? .none : t
            editorToolbar.setSelectedTool(canvas.tool)
            options.isHidden = (canvas.tool == .none)
        case .undo:
            canvas.undo()
        case .save:
            guard let img = canvas.export() else { return }
            Exporter.save(img) { _ in }
        case .confirm:
            guard let img = canvas.export() else { return }
            Exporter.copyToClipboard(img)
            closeEditor()
        case .cancel:
            closeEditor()
        case .ocr:
            runOCR(translate: false)
        case .translate:
            runOCR(translate: true)
        case .pin, .longShot:
            break
        }
    }

    private func runOCR(translate: Bool) {
        let img = canvas.image
        let win = OCRResultWindow(text: "正在识别…", near: frame)
        win.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            do {
                let lines = try await TextRecognizer.recognize(img)
                let text = TextRecognizer.joined(lines)
                win.setText(text)
                if text.isEmpty {
                    win.setStatus("未识别到文字")
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    win.setStatus("已识别 \(lines.count) 处文字，已复制到剪贴板")
                    if translate { win.translateAction() }
                }
            } catch {
                win.setStatus("识别失败：\(error.localizedDescription)")
            }
        }
    }

    func closeEditor() {
        canvas.commitText()
        orderOut(nil)
        ImageEditorWindow.all.removeAll { $0 === self }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: closeEditor(); return
        case 36, 76: handle(.confirm); return
        default: break
        }
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "z": canvas.undo(); return
            case "s": handle(.save); return
            case "c": handle(.confirm); return
            case "t": handle(.ocr); return
            case "l": handle(.translate); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    // 调试
    var debugCanvas: ImageCanvasView { canvas }
    func debugHandle(_ a: ToolbarAction) { handle(a) }
}

/// 可标注的图片画布（左上原点、pt）
final class ImageCanvasView: NSView {
    let image: CGImage
    let scale: CGFloat
    private let nsImage: NSImage
    private let renderer: AnnotationRenderer

    private(set) var annotations: [Annotation] = []
    private var current: Annotation?
    private var startPoint: CGPoint = .zero
    private var textEditor: TextEditorView?
    private var textGlass: GlassPanelView?
    var tool: Tool = .none { didSet { if tool != .text { commitText() } } }
    var color: NSColor = Palette.colors[0] { didSet { textEditor?.strokeColor = color } }
    var strokeSize: StrokeSize = .medium { didSet { textEditor?.fontSize = strokeSize.fontSize } }
    var onAnnotationsChanged: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var canUndo: Bool { !annotations.isEmpty || textEditor != nil }

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        nsImage = NSImage(cgImage: image, size: size)
        renderer = AnnotationRenderer(mosaicImage: AnnotationRenderer.makeMosaicSource(from: image, blockPixels: Int(8 * scale)),
                                      screenBounds: CGRect(origin: .zero, size: size))
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        nsImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        ctx.interpolationQuality = .high
        var list = annotations
        if let current { list.append(current) }
        renderer.draw(list, clip: bounds, in: ctx)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .none ? .arrow : .crosshair)
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        if textEditor != nil { commitText(); return }
        guard tool != .none, bounds.contains(p) else { return }
        if tool == .text { beginText(at: p); return }
        startPoint = p
        let kind: Annotation.Kind
        switch tool {
        case .rect: kind = .rect(CGRect(origin: p, size: .zero))
        case .ellipse: kind = .ellipse(CGRect(origin: p, size: .zero))
        case .arrow: kind = .arrow(from: p, to: p)
        case .pen: kind = .pen([p])
        case .mosaic: kind = .mosaic([p])
        default: return
        }
        current = Annotation(kind: kind, color: color, size: strokeSize)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var a = current else { return }
        let q = convert(event.locationInWindow, from: nil).clamped(to: bounds)
        switch a.kind {
        case .rect: a.kind = .rect(CGRect(p1: startPoint, p2: q))
        case .ellipse: a.kind = .ellipse(CGRect(p1: startPoint, p2: q))
        case .arrow(let from, _): a.kind = .arrow(from: from, to: q)
        case .pen(var pts): pts.append(q); a.kind = .pen(pts)
        case .mosaic(var pts): pts.append(q); a.kind = .mosaic(pts)
        case .text: break
        }
        current = a
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let a = current, !a.isDegenerate { annotations.append(a); onAnnotationsChanged?() }
        current = nil
        needsDisplay = true
    }

    // MARK: - 文字

    private func beginText(at p: CGPoint) {
        let fontSize = strokeSize.fontSize
        var origin = CGPoint(x: p.x - Annotation.textInset.width, y: p.y - fontSize * 0.7)
        origin.x = min(max(0, origin.x), bounds.width - fontSize)
        origin.y = min(max(0, origin.y), bounds.height - fontSize)
        let editor = TextEditorView(origin: origin, color: color, fontSize: fontSize)
        editor.onCommit = { [weak self] in self?.commitText() }
        let glass = GlassPanelView(cornerRadius: 10)
        let inset = CGSize(width: 8, height: 5)
        glass.frame = editor.frame.insetBy(dx: -inset.width, dy: -inset.height)
        editor.onFrameChange = { [weak glass] f in glass?.frame = f.insetBy(dx: -inset.width, dy: -inset.height) }
        addSubview(glass)
        addSubview(editor)
        textEditor = editor
        textGlass = glass
        window?.makeFirstResponder(editor)
        onAnnotationsChanged?()
    }

    func commitText() {
        guard let editor = textEditor else { return }
        let a = Annotation(kind: .text(origin: editor.frame.origin, string: editor.string, fontSize: editor.fontSize),
                           color: editor.strokeColor, size: strokeSize)
        if !a.isDegenerate { annotations.append(a) }
        editor.removeFromSuperview()
        textGlass?.removeFromSuperview()
        textEditor = nil
        textGlass = nil
        window?.makeFirstResponder(self)
        onAnnotationsChanged?()
        needsDisplay = true
    }

    func undo() {
        if textEditor != nil { commitText() }
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        onAnnotationsChanged?()
        needsDisplay = true
    }

    /// 导出：原图 + 标注，像素尺寸与原图一致
    func export() -> CGImage? {
        commitText()
        return Exporter.render(image: image, scale: scale, annotations: annotations, renderer: renderer)
    }

    // 调试：合成一次点击/拖拽
    func debugDrag(_ pts: [CGPoint]) {
        func ev(_ t: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            let wp = convert(p, to: nil)
            return NSEvent.mouseEvent(with: t, location: wp, modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        guard let f = pts.first, let l = pts.last else { return }
        mouseDown(with: ev(.leftMouseDown, f))
        for p in pts.dropFirst() { mouseDragged(with: ev(.leftMouseDragged, p)) }
        mouseUp(with: ev(.leftMouseUp, l))
    }
}
