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
    private let toolbarPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let optionsPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var controlsReady = false
    private var moveObserver: NSObjectProtocol?
    private let screenRef: NSScreen

    init(image: CGImage, scale: CGFloat, screen: NSScreen, title: String) {
        canvas = ImageCanvasView(image: image, scale: scale)
        screenRef = screen
        let v = screen.visibleFrame
        let controlsSpace = ToolbarView.height + OptionsView.height + 28
        let width = min(canvas.frame.width + 40, v.width * 0.85)
        let height = min(canvas.frame.height + 72, v.height - controlsSpace - 32)
        let size = NSSize(width: max(560, width), height: max(360, height))
        let origin = CGPoint(x: v.midX - size.width / 2, y: v.midY - (size.height + controlsSpace) / 2 + controlsSpace)
        super.init(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // 画布、工具按钮和选项都要收到自己的鼠标事件；只允许标题栏拖动窗口。
        isMovableByWindowBackground = false
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
        let titlebar = ImageEditorTitlebar(frame: CGRect(x: 0, y: size.height - 56, width: size.width, height: 56))
        titlebar.autoresizingMask = [.width, .minYMargin]
        titlebar.toolTip = "拖动标题栏移动窗口"
        titleLabel.frame = CGRect(x: 20, y: 20, width: size.width - 40, height: 20)
        titleLabel.autoresizingMask = [.width]
        titlebar.addSubview(titleLabel)
        content.addSubview(titlebar)

        scroll.frame = CGRect(x: 16, y: 16, width: size.width - 32, height: size.height - 72)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView = CenteredImageClipView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
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
            if self.canvas.marks.selected != nil { self.canvas.marks.updateSelected(color: color, size: size) }
        }
        options.size = canvas.strokeSize
        options.color = canvas.color
        options.isHidden = true
        configurePanel(toolbarPanel, view: editorToolbar)
        configurePanel(optionsPanel, view: options)
        editorToolbar.setUndoEnabled(false)
        editorToolbar.setRedoEnabled(false)
        canvas.onAnnotationsChanged = { [weak self] in
            guard let self else { return }
            self.editorToolbar.setUndoEnabled(self.canvas.canUndo)
            self.editorToolbar.setRedoEnabled(self.canvas.canRedo)
            if let a = self.canvas.marks.selected {
                self.options.size = a.size
                if a.usesColor { self.options.color = a.color }
            }
            self.options.isHidden = (self.canvas.tool == .none && self.canvas.marks.selected == nil)
            self.layoutBars()
        }
        controlsReady = true
        layoutBars()
        addChildWindow(toolbarPanel, ordered: .above)
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutBars() }
        }

        ImageEditorWindow.all.append(self)
        ImageEditorWindow.latest = self
        makeFirstResponder(canvas)
    }

    override var canBecomeKey: Bool { true }

    private func configurePanel(_ panel: NSPanel, view: NSView) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view.setFrameOrigin(.zero)
        panel.setContentSize(view.frame.size)
        panel.contentView = view
    }

    private func layoutBars() {
        guard controlsReady else { return }
        let visible = (screen ?? screenRef).visibleFrame.insetBy(dx: 8, dy: 8)
        let toolbarSize = editorToolbar.frame.size
        let optionsSize = options.frame.size
        let stackHeight = toolbarSize.height + (options.isHidden ? 0 : optionsSize.height + 8)
        // 各面板独立保持原尺寸，窗口再窄也不会裁掉左右两端的按钮。
        var y = frame.minY - 12 - toolbarSize.height
        if y - (stackHeight - toolbarSize.height) < visible.minY,
           frame.maxY + 12 + stackHeight <= visible.maxY {
            y = frame.maxY + 12 + stackHeight - toolbarSize.height
        }
        y = min(max(y, visible.minY + stackHeight - toolbarSize.height), visible.maxY - toolbarSize.height)
        let x = min(max(frame.midX - toolbarSize.width / 2, visible.minX), visible.maxX - toolbarSize.width)
        toolbarPanel.setFrameOrigin(CGPoint(x: x, y: y))
        let optionsX = min(max(frame.midX - optionsSize.width / 2, visible.minX), visible.maxX - optionsSize.width)
        optionsPanel.setFrameOrigin(CGPoint(x: optionsX, y: y - 8 - optionsSize.height))
        if options.isHidden {
            optionsPanel.orderOut(nil)
            if optionsPanel.parent != nil { removeChildWindow(optionsPanel) }
        } else if optionsPanel.parent == nil {
            addChildWindow(optionsPanel, ordered: .above)
        }
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
            layoutBars()
        case .undo:
            canvas.undo()
        case .redo:
            canvas.redo()
        case .save:
            guard let img = canvas.export() else { return }
            History.add(img)
            if Settings.quickSave { Exporter.quickSave(img) } else { Exporter.save(img) { _ in } }
        case .confirm:
            guard let img = canvas.export() else { return }
            Exporter.deliver(img)
            closeEditor()
        case .beautify:
            guard let img = canvas.export() else { return }
            BeautifyWindow(image: img, scale: canvas.scale, near: frame, fromWindow: false).show()
        case .redact:
            runRedact()
        case .cancel:
            closeEditor()
        case .ocr:
            runOCR(translate: false)
        case .translate:
            runOCR(translate: true)
        case .pin, .longShot, .record, .loupe:
            break
        }
    }

    private func runRedact() {
        canvas.commitText()
        let img = canvas.image
        let size = canvas.bounds.size
        editorToolbar.setBusy(.redact, true)
        Task { @MainActor in
            let boxes = (try? await Redactor.findSensitive(in: img)) ?? []
            editorToolbar.setBusy(.redact, false)
            let rects = boxes.map {
                CGRect(x: $0.minX * size.width, y: (1 - $0.maxY) * size.height, width: $0.width * size.width, height: $0.height * size.height)
                    .insetBy(dx: -3, dy: -2)
            }
            if rects.isEmpty {
                Toast.show("没有发现手机号、邮箱、证件号、银行卡或密钥", symbol: "eye", near: frame.center)
            } else {
                canvas.marks.add(rects.map { Annotation(kind: .pixelate($0), color: .black, size: .medium) })
                Toast.show("已打码 \(rects.count) 处，可 ⌘Z 撤销", symbol: "eye.slash.fill", near: frame.center)
            }
        }
    }

    private func runOCR(translate: Bool) {
        OCRResultWindow.present(image: canvas.image, near: frame, translate: translate)
    }

    func closeEditor() {
        canvas.commitText()
        toolbarPanel.orderOut(nil)
        optionsPanel.orderOut(nil)
        orderOut(nil)
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver); self.moveObserver = nil }
        ImageEditorWindow.all.removeAll { $0 === self }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53:
            if canvas.marks.selected != nil { canvas.marks.deselect(); return }
            closeEditor(); return
        case 36, 76: handle(.confirm); return
        case 51, 117: canvas.marks.deleteSelected(); return
        case 123, 124, 125, 126:
            guard canvas.marks.selected != nil else { break }
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let d: [UInt16: CGPoint] = [123: CGPoint(x: -step, y: 0), 124: CGPoint(x: step, y: 0), 125: CGPoint(x: 0, y: step), 126: CGPoint(x: 0, y: -step)]
            canvas.marks.nudgeSelected(d[event.keyCode]!)
            return
        default: break
        }
        switch ShortcutAction.local(matching: event) {
        case .undo: canvas.undo(); return
        case .redo: canvas.redo(); return
        case .save: handle(.save); return
        case .confirm: handle(.confirm); return
        case .ocr: handle(.ocr); return
        case .translate: handle(.translate); return
        case .beautify: handle(.beautify); return
        case .redact: handle(.redact); return
        default: break
        }
        super.keyDown(with: event)
    }

    // 调试
    var debugCanvas: ImageCanvasView { canvas }
    var debugToolbarPanel: NSPanel { toolbarPanel }
    var debugOptionsPanel: NSPanel { optionsPanel }
    var debugImageCenterOffset: CGFloat {
        canvas.frame.midX - scroll.contentView.bounds.midX
    }
    func debugHandle(_ a: ToolbarAction) { handle(a) }
    func debugScroll(to y: CGFloat) {
        let maxY = max(0, canvas.bounds.height - scroll.contentView.bounds.height)
        var bounds = scroll.contentView.bounds
        bounds.origin.y = min(max(0, y), maxY)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// 背景拖动关闭后，保留明确的窗口移动区域，不与标注手势竞争。
final class ImageEditorTitlebar: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// 通过可视区域的原点居中窄图，保留画布坐标和导出尺寸。
final class CenteredImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let documentView, documentView.frame.width < rect.width {
            rect.origin.x = documentView.frame.midX - rect.width / 2
        }
        return rect
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scroll(to: constrainBoundsRect(bounds).origin)
    }
}

/// 可标注的图片画布（左上原点、pt）
final class ImageCanvasView: NSView {
    let image: CGImage
    let scale: CGFloat
    private let nsImage: NSImage
    private let renderer: AnnotationRenderer
    let marks = AnnotationLayer()

    private var textEditor: TextEditorView?
    private var textGlass: GlassPanelView?
    private var editingExistingText = false
    var tool: Tool = .none { didSet { if tool != .text { commitText() }; marks.deselect(); window?.invalidateCursorRects(for: self) } }
    var color: NSColor = Palette.colors[0] { didSet { textEditor?.strokeColor = color } }
    var strokeSize: StrokeSize = .medium { didSet { textEditor?.fontSize = strokeSize.fontSize } }
    var onAnnotationsChanged: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var canUndo: Bool { marks.canUndo || textEditor != nil }
    var canRedo: Bool { marks.canRedo }
    var annotations: [Annotation] { marks.items }

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        nsImage = NSImage(cgImage: image, size: size)
        renderer = AnnotationRenderer(source: image, bounds: CGRect(origin: .zero, size: size), scale: scale)
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        marks.onChange = { [weak self] in
            self?.needsDisplay = true
            self?.onAnnotationsChanged?()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 长图很高，只绘制需要刷新的那一块，避免每次滚动都重绘整张图
        let r = dirtyRect.intersection(bounds)
        guard !r.isEmpty else { return }
        // 画布以左上为原点，NSImage 的源矩形始终以左下为原点。
        // respectFlipped 只修正目标绘制方向，不转换源矩形；直接 from: r
        // 会让滚动重绘取到图像另一端，出现倒序、重复和断层。
        let sourceRect = CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
        ctx.interpolationQuality = .none
        nsImage.draw(in: r, from: sourceRect, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        ctx.interpolationQuality = .high
        marks.draw(with: renderer, clip: bounds, in: ctx)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .none ? .arrow : .crosshair)
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        if textEditor != nil { commitText(); return }
        switch marks.mouseDown(at: p, clip: bounds, tool: tool, color: color, size: strokeSize, clickCount: event.clickCount) {
        case .beginText: beginText(at: p)
        case .editText(let i): editText(at: i)
        case .handled, .ignored: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        marks.mouseDragged(to: convert(event.locationInWindow, from: nil), shift: event.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        marks.mouseUp()
    }

    // MARK: - 文字

    private func beginText(at p: CGPoint) {
        let fontSize = strokeSize.fontSize
        var origin = CGPoint(x: p.x - Annotation.textInset.width, y: p.y - fontSize * 0.7)
        origin.x = min(max(0, origin.x), bounds.width - fontSize)
        origin.y = min(max(0, origin.y), bounds.height - fontSize)
        openTextEditor(origin: origin, string: "", color: color, fontSize: fontSize)
    }

    private func editText(at i: Int) {
        let a = marks.extract(at: i)
        guard case .text(let origin, let string, let fontSize) = a.kind else { return }
        editingExistingText = true
        openTextEditor(origin: origin, string: string, color: a.color, fontSize: fontSize)
    }

    private func openTextEditor(origin: CGPoint, string: String, color: NSColor, fontSize: CGFloat) {
        let editor = TextEditorView(origin: origin, color: color, fontSize: fontSize)
        if !string.isEmpty { editor.string = string; editor.fit() }
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
                           color: editor.strokeColor, size: StrokeSize.nearest(fontSize: editor.fontSize))
        marks.add(a, recordUndo: !editingExistingText)
        editingExistingText = false
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
        marks.undo()
    }

    func redo() {
        commitText()
        marks.redo()
    }

    /// 导出：原图 + 标注，像素尺寸与原图一致
    func export() -> CGImage? {
        commitText()
        marks.deselect()
        return Exporter.render(image: image, scale: scale, annotations: marks.items, renderer: renderer)
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
