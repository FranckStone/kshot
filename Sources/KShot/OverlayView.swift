import AppKit

/// 选区边缘的 8 个把手
struct Handle: OptionSet, Hashable {
    let rawValue: Int
    static let left = Handle(rawValue: 1)
    static let right = Handle(rawValue: 2)
    static let top = Handle(rawValue: 4)
    static let bottom = Handle(rawValue: 8)

    static let all: [Handle] = [
        [.left, .top], [.top], [.right, .top],
        [.left], [.right],
        [.left, .bottom], [.bottom], [.right, .bottom],
    ]

    func point(in r: CGRect) -> CGPoint {
        let x: CGFloat = contains(.left) ? r.minX : (contains(.right) ? r.maxX : r.midX)
        let y: CGFloat = contains(.top) ? r.minY : (contains(.bottom) ? r.maxY : r.midY)
        return CGPoint(x: x, y: y)
    }
}

/// 单块屏幕上的截图交互层：窗口识别、拖拽选区、把手、标注、工具条。
/// 坐标系：左上原点、y 向下（isFlipped），单位 pt。
final class OverlayView: NSView {
    private enum DragMode {
        case none
        case pending(CGPoint)                          // 已按下，尚未判断是点击还是拖拽
        case selecting(CGPoint)                        // 拖拽框选
        case moving(offset: CGPoint)                   // 拖动选区
        case resizing(Handle, orig: CGRect)            // 拖动把手
        case drawing                                   // 绘制标注
    }

    // MARK: - 数据

    let shot: ScreenShot
    let screen: NSScreen
    private let windows: [WindowInfo]
    private unowned let session: CaptureSession
    private let baseImage: NSImage
    private let renderer: AnnotationRenderer

    private var selection: CGRect?
    private var hoverRect: CGRect?
    private var dragMode: DragMode = .none
    private var annotations: [Annotation] = []
    private var current: Annotation?
    private var tool: Tool = .none
    private var color: NSColor = Palette.colors[0]
    private var strokeSize: StrokeSize = .medium

    private let toolbar = ToolbarView()
    private let options = OptionsView()
    private let sizeLabel = SizeLabelView()
    private let hoverFrame = GlassFrameView(tint: NSColor.wechatGreen.withAlphaComponent(0.45))
    private let handleViews: [GlassPanelView] = Handle.all.map { _ in
        GlassPanelView(cornerRadius: OverlayView.handleRadius, tint: NSColor.wechatGreen.withAlphaComponent(0.7), ringColor: .white, ringWidth: 1.5)
    }
    private var textEditor: TextEditorView?
    private var textGlass: GlassPanelView?
    private static let textGlassInset = CGSize(width: 8, height: 5)

    private static let dimAlpha: CGFloat = 0.42
    private static let fullScreenDimAlpha: CGFloat = 0.25
    private static let handleRadius: CGFloat = 7
    private static let handleHitSlop: CGFloat = 8

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Init

    init(frame: CGRect, shot: ScreenShot, windows: [WindowInfo], session: CaptureSession) {
        self.shot = shot
        self.screen = shot.screen
        self.windows = windows
        self.session = session
        self.baseImage = NSImage(cgImage: shot.image, size: frame.size)
        let block = Int(8 * shot.scale)
        self.renderer = AnnotationRenderer(
            mosaicImage: AnnotationRenderer.makeMosaicSource(from: shot.image, blockPixels: block),
            screenBounds: CGRect(origin: .zero, size: frame.size)
        )
        super.init(frame: frame)

        toolbar.isHidden = true
        options.isHidden = true
        sizeLabel.isHidden = true
        hoverFrame.isHidden = true
        addSubview(hoverFrame)
        for h in handleViews {
            h.isHidden = true
            h.frame = CGRect(x: 0, y: 0, width: OverlayView.handleRadius * 2, height: OverlayView.handleRadius * 2)
            addSubview(h)
        }
        addSubview(sizeLabel)
        addSubview(toolbar)
        addSubview(options)
        toolbar.onAction = { [weak self] action in self?.handle(action) }
        options.onChange = { [weak self] size, color in
            guard let self else { return }
            if let size { self.strokeSize = size; self.textEditor?.fontSize = size.fontSize }
            if let color { self.color = color; self.textEditor?.strokeColor = color }
        }
        options.size = strokeSize
        options.color = color
        updateToolbarState()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    func tearDown() {
        textEditor?.removeFromSuperview()
        textGlass?.removeFromSuperview()
        textEditor = nil
        textGlass = nil
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. 冻结的屏幕画面
        ctx.interpolationQuality = .none
        baseImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        ctx.interpolationQuality = .high

        // 2. 标注（裁剪到选区内）
        if let sel = selection {
            var list = annotations
            if let current { list.append(current) }
            renderer.draw(list, clip: sel, in: ctx)
        }

        // 3. 遮罩：选区/悬停窗口以外的部分压暗；悬停到整屏时整体轻微压暗，提示处于截图状态
        let cut = selection ?? hoverRect
        let fullScreenHover = selection == nil && hoverRect == bounds
        ctx.saveGState()
        if let cut, !fullScreenHover {
            ctx.addRect(bounds)
            ctx.addRect(cut)
            ctx.clip(using: .evenOdd)
        }
        ctx.setFillColor(NSColor(white: 0, alpha: fullScreenHover ? OverlayView.fullScreenDimAlpha : OverlayView.dimAlpha).cgColor)
        ctx.fill(bounds)
        ctx.restoreGState()

        guard let cut else { return }

        // 4. 边框（悬停状态用玻璃框子视图，选区用细线）
        if selection != nil {
            ctx.setStrokeColor(NSColor.wechatGreen.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(cut.insetBy(dx: -0.75, dy: -0.75))
        }

    }

    /// 绘制前同步尺寸标签与悬停玻璃框（子视图）。
    /// 不能挂在 needsDisplay 的属性观察器里：改子视图 frame 会再次触发父视图 needsDisplay，重入后 AppKit 会丢掉这次重绘。
    override func viewWillDraw() {
        super.viewWillDraw()
        updateSizeLabel()
        updateHoverFrame()
        updateHandles()
    }

    /// 把手：8 个带白色描边的小玻璃圆点
    private func updateHandles() {
        guard showsHandles, let sel = selection else {
            handleViews.forEach { $0.isHidden = true }
            return
        }
        let r = OverlayView.handleRadius
        for (i, h) in Handle.all.enumerated() {
            let p = h.point(in: sel)
            let f = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            if handleViews[i].frame != f { handleViews[i].frame = f }
            handleViews[i].isHidden = false
        }
    }

    private func updateHoverFrame() {
        guard selection == nil, let rect = hoverRect else {
            hoverFrame.isHidden = true
            return
        }
        let t = GlassFrameView.thickness
        // 整屏时玻璃框贴在屏幕边缘内侧
        let f = rect == bounds ? bounds : rect.insetBy(dx: -t, dy: -t)
        if hoverFrame.frame != f {
            hoverFrame.frame = f
            hoverFrame.needsLayout = true
        }
        hoverFrame.isHidden = false
    }

    private func updateSizeLabel() {
        guard let rect = selection ?? hoverRect else {
            sizeLabel.isHidden = true
            return
        }
        let scale = shot.scale
        let size = sizeLabel.setText("\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))")
        let gap: CGFloat = selection == nil ? GlassFrameView.thickness + 6 : 6
        var origin = CGPoint(x: rect.minX, y: rect.minY - size.height - gap)
        if origin.y < bounds.minY + 2 {
            let inset: CGFloat = (selection == nil && rect == bounds) ? GlassFrameView.thickness + 6 : 6
            origin.y = rect.minY + inset
            origin.x = rect.minX + inset
        }
        origin.x = min(max(bounds.minX + 2, origin.x), bounds.maxX - size.width - 2)
        sizeLabel.frame = CGRect(origin: origin, size: size)
        sizeLabel.isHidden = false
    }

    private var showsHandles: Bool {
        guard selection != nil, tool == .none, textEditor == nil else { return false }
        switch dragMode {
        case .selecting, .pending, .drawing: return false
        default: return true
        }
    }

    // MARK: - 窗口识别

    /// 鼠标所在位置最前面的窗口在本屏的矩形；没有窗口则返回整屏。
    private func windowRect(atLocal p: CGPoint) -> CGRect {
        let cg = screen.cgPoint(fromLocal: p)
        if let w = WindowFinder.topWindow(at: cg, in: windows) {
            let r = screen.localRect(fromCG: w.bounds).intersection(bounds).integral
            if r.width >= 4, r.height >= 4 { return r }
        }
        return bounds
    }

    /// 根据当前鼠标位置刷新悬停高亮
    func refreshHover() {
        guard selection == nil, session.canHover(self) else { return }
        guard let win = window else { return }
        let p = convert(win.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(p) else { return }
        hoverRect = windowRect(atLocal: p)
        updateCursor(at: p)
        needsDisplay = true
    }

    // MARK: - 鼠标

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseEntered(with event: NSEvent) {
        guard session.canHover(self) else { return }
        if selection == nil { session.focus(self) }
        refreshHover()
    }

    override func mouseExited(with event: NSEvent) {
        if case .none = dragMode, selection == nil {
            hoverRect = nil
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = location(event)
        if selection == nil {
            guard session.canHover(self) else { return }
            hoverRect = windowRect(atLocal: p)
            needsDisplay = true
        }
        updateCursor(at: p)
    }

    override func mouseDown(with event: NSEvent) {
        guard session.canHover(self) else { return }
        let p = location(event)
        session.focus(self)

        if textEditor != nil {
            commitText()
            return
        }

        guard let sel = selection else {
            dragMode = .pending(p)
            return
        }

        // 双击选区内：完成
        if event.clickCount == 2, tool == .none, sel.contains(p) {
            confirm()
            return
        }

        if tool != .none {
            guard sel.contains(p) else { return }
            if tool == .text {
                beginTextEditing(at: p)
                return
            }
            current = makeAnnotation(at: p.clamped(to: sel))
            dragMode = .drawing
            layoutChrome()
            needsDisplay = true
            return
        }

        if let h = handle(at: p, in: sel) {
            dragMode = .resizing(h, orig: sel)
            layoutChrome()
            return
        }
        if sel.contains(p) {
            dragMode = .moving(offset: CGPoint(x: p.x - sel.minX, y: p.y - sel.minY))
            NSCursor.closedHand.set()
            layoutChrome()
            return
        }
        // 点在选区外且尚未标注：重新框选
        if annotations.isEmpty {
            selection = nil
            dragMode = .pending(p)
            layoutChrome()
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = location(event).clamped(to: bounds)
        switch dragMode {
        case .pending(let anchor):
            if anchor.distance(to: p) > 3 {
                dragMode = .selecting(anchor)
                session.activeOverlay = self
                hoverRect = nil
                selection = CGRect(p1: anchor, p2: p)
                needsDisplay = true
            }
        case .selecting(let anchor):
            selection = CGRect(p1: anchor, p2: p)
            needsDisplay = true
        case .moving(let offset):
            guard let sel = selection else { return }
            var r = sel
            r.origin = CGPoint(x: p.x - offset.x, y: p.y - offset.y)
            selection = r.clamped(to: bounds)
            needsDisplay = true
        case .resizing(let h, let orig):
            selection = resized(orig, handle: h, to: p)
            needsDisplay = true
        case .drawing:
            guard var a = current, let sel = selection else { return }
            let q = p.clamped(to: sel)
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
        case .none:
            break
        }
    }

    private var startPoint: CGPoint = .zero

    override func mouseUp(with event: NSEvent) {
        let p = location(event).clamped(to: bounds)
        switch dragMode {
        case .pending:
            // 单击：选中鼠标下的窗口
            session.activeOverlay = self
            selection = windowRect(atLocal: p)
            hoverRect = nil
        case .selecting(let anchor):
            let r = CGRect(p1: anchor, p2: p)
            if r.width < 4 || r.height < 4 {
                selection = windowRect(atLocal: p)
            } else {
                selection = r.integral.intersection(bounds)
            }
            hoverRect = nil
        case .moving, .resizing:
            if let sel = selection { selection = sel.integral.intersection(bounds) }
        case .drawing:
            if let a = current, !a.isDegenerate { annotations.append(a) }
            current = nil
        case .none:
            break
        }
        dragMode = .none
        updateToolbarState()
        layoutChrome()
        updateCursor(at: p)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if textEditor != nil {
            commitText()
            return
        }
        if selection != nil {
            // 回到悬停识别状态（与微信一致）
            selection = nil
            annotations.removeAll()
            current = nil
            tool = .none
            dragMode = .none
            session.activeOverlay = nil
            updateToolbarState()
            layoutChrome()
            refreshHover()
            needsDisplay = true
        } else {
            session.cancel()
        }
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        let target = session.activeOverlay ?? self

        switch event.keyCode {
        case 53: // Esc
            session.cancel()
            return
        case 36, 76: // Return / Enter
            target.confirm()
            return
        default:
            break
        }
        if flags.contains(.command) {
            switch chars {
            case "z": target.undo(); return
            case "s": target.save(); return
            case "c": target.confirm(); return
            case "p": target.pin(); return
            default: break
            }
        }
        // 方向键微调选区
        if target.selection != nil, [123, 124, 125, 126].contains(Int(event.keyCode)) {
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            var d = CGPoint.zero
            switch event.keyCode {
            case 123: d.x = -step
            case 124: d.x = step
            case 125: d.y = step
            case 126: d.y = -step
            default: break
            }
            target.nudge(d)
            return
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 让 ⌘Z/⌘S/⌘C/⌘P 不触发系统提示音
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let c = event.charactersIgnoringModifiers, ["z", "s", "c", "p"].contains(c) {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func nudge(_ d: CGPoint) {
        guard var r = selection else { return }
        r.origin.x += d.x
        r.origin.y += d.y
        selection = r.clamped(to: bounds)
        layoutChrome()
        needsDisplay = true
    }

    // MARK: - 选区几何

    private func handle(at p: CGPoint, in sel: CGRect) -> Handle? {
        for h in Handle.all where h.point(in: sel).distance(to: p) <= OverlayView.handleHitSlop {
            return h
        }
        return nil
    }

    private func resized(_ orig: CGRect, handle h: Handle, to p: CGPoint) -> CGRect {
        var minX = orig.minX, maxX = orig.maxX, minY = orig.minY, maxY = orig.maxY
        if h.contains(.left) { minX = min(p.x, orig.maxX); maxX = max(p.x, orig.maxX) }
        if h.contains(.right) { minX = min(p.x, orig.minX); maxX = max(p.x, orig.minX) }
        if h.contains(.top) { minY = min(p.y, orig.maxY); maxY = max(p.y, orig.maxY) }
        if h.contains(.bottom) { minY = min(p.y, orig.minY); maxY = max(p.y, orig.minY) }
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    private func updateCursor(at p: CGPoint) {
        if !toolbar.isHidden && toolbar.frame.contains(p) || !options.isHidden && options.frame.contains(p) {
            NSCursor.arrow.set()
            return
        }
        if let ed = textEditor, ed.frame.contains(p) {
            NSCursor.iBeam.set()
            return
        }
        switch dragMode {
        case .moving:
            NSCursor.closedHand.set()
            return
        case .resizing(let h, _):
            resizeCursor(for: h).set()
            return
        default:
            break
        }
        if let sel = selection, tool == .none {
            if let h = handle(at: p, in: sel) {
                resizeCursor(for: h).set()
            } else if sel.contains(p) {
                NSCursor.openHand.set()
            } else {
                NSCursor.crosshair.set()
            }
            return
        }
        NSCursor.crosshair.set()
    }

    private func resizeCursor(for h: Handle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let pos: NSCursor.FrameResizePosition
            switch h {
            case [.left, .top]: pos = .topLeft
            case [.top]: pos = .top
            case [.right, .top]: pos = .topRight
            case [.left]: pos = .left
            case [.right]: pos = .right
            case [.left, .bottom]: pos = .bottomLeft
            case [.bottom]: pos = .bottom
            default: pos = .bottomRight
            }
            return NSCursor.frameResize(position: pos, directions: .all)
        }
        if h == [.left] || h == [.right] { return .resizeLeftRight }
        if h == [.top] || h == [.bottom] { return .resizeUpDown }
        return .crosshair
    }

    // MARK: - 标注

    private func makeAnnotation(at p: CGPoint) -> Annotation {
        startPoint = p
        let kind: Annotation.Kind
        switch tool {
        case .rect: kind = .rect(CGRect(origin: p, size: .zero))
        case .ellipse: kind = .ellipse(CGRect(origin: p, size: .zero))
        case .arrow: kind = .arrow(from: p, to: p)
        case .pen: kind = .pen([p])
        case .mosaic: kind = .mosaic([p])
        case .text, .none: kind = .pen([p])
        }
        return Annotation(kind: kind, color: color, size: strokeSize)
    }

    private func beginTextEditing(at p: CGPoint) {
        guard let sel = selection else { return }
        let fontSize = strokeSize.fontSize
        var origin = CGPoint(x: p.x - Annotation.textInset.width, y: p.y - fontSize * 0.7)
        origin.x = min(max(sel.minX, origin.x), sel.maxX - fontSize)
        origin.y = min(max(sel.minY, origin.y), sel.maxY - fontSize)
        let editor = TextEditorView(origin: origin, color: color, fontSize: fontSize)
        editor.onCommit = { [weak self] in self?.commitText() }
        let glass = GlassPanelView(cornerRadius: 10)
        glass.frame = editor.frame.insetBy(dx: -OverlayView.textGlassInset.width, dy: -OverlayView.textGlassInset.height)
        editor.onFrameChange = { [weak glass] f in
            glass?.frame = f.insetBy(dx: -OverlayView.textGlassInset.width, dy: -OverlayView.textGlassInset.height)
        }
        addSubview(glass)
        addSubview(editor)
        textEditor = editor
        textGlass = glass
        window?.makeFirstResponder(editor)
        needsDisplay = true
    }

    private func commitText() {
        guard let editor = textEditor else { return }
        let a = Annotation(kind: .text(origin: editor.frame.origin, string: editor.string, fontSize: editor.fontSize),
                           color: editor.strokeColor, size: strokeSize)
        if !a.isDegenerate { annotations.append(a) }
        editor.removeFromSuperview()
        textGlass?.removeFromSuperview()
        textEditor = nil
        textGlass = nil
        window?.makeFirstResponder(self)
        updateToolbarState()
        needsDisplay = true
    }

    private func undo() {
        if textEditor != nil {
            commitText()
        }
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        updateToolbarState()
        needsDisplay = true
    }

    // MARK: - 工具条

    private func handle(_ action: ToolbarAction) {
        switch action {
        case .tool(let t):
            commitText()
            tool = (tool == t) ? .none : t
            updateToolbarState()
            layoutChrome()
            needsDisplay = true
        case .undo: undo()
        case .pin: pin()
        case .save: save()
        case .cancel: session.cancel()
        case .confirm: confirm()
        }
    }

    private func updateToolbarState() {
        toolbar.setSelectedTool(tool)
        toolbar.setUndoEnabled(!annotations.isEmpty || textEditor != nil)
    }

    private func layoutChrome() {
        guard let sel = selection, case .none = dragMode else {
            toolbar.isHidden = true
            options.isHidden = true
            return
        }
        toolbar.isHidden = false
        options.isHidden = (tool == .none)

        let gap: CGFloat = 8
        let optionsExtra: CGFloat = options.isHidden ? 0 : OptionsView.height + 6
        var tf = toolbar.frame
        tf.origin.x = min(max(bounds.minX + 4, sel.maxX - tf.width), bounds.maxX - tf.width - 4)
        var below = true
        if sel.maxY + gap + tf.height + optionsExtra <= bounds.maxY - 4 {
            tf.origin.y = sel.maxY + gap
        } else if sel.minY - gap - tf.height - optionsExtra >= bounds.minY + 4 {
            tf.origin.y = sel.minY - gap - tf.height
            below = false
        } else {
            tf.origin.y = sel.maxY - gap - tf.height - optionsExtra
        }
        toolbar.frame = tf

        var of = options.frame
        of.origin.x = min(max(bounds.minX + 4, tf.maxX - of.width), bounds.maxX - of.width - 4)
        of.origin.y = below ? tf.maxY + 6 : tf.minY - 6 - of.height
        options.frame = of
        toolbar.needsDisplay = true
        options.needsDisplay = true
    }

    // MARK: - 输出

    private func renderImage() -> CGImage? {
        commitText()
        guard let sel = selection else { return nil }
        return Exporter.render(shot: shot, selection: sel, annotations: annotations, renderer: renderer)
    }

    private func confirm() {
        guard let img = renderImage() else { return }
        Exporter.copyToClipboard(img)
        session.end()
    }

    private func save() {
        guard let img = renderImage() else { return }
        session.hideOverlays()
        Exporter.save(img) { [session] _ in
            session.end()
        }
    }

    private func pin() {
        guard let sel = selection, let img = renderImage() else { return }
        let frame = screen.cocoaRect(fromLocal: sel)
        session.end(restoreFocus: false)
        let pinWindow = PinWindow(image: img, frame: frame)
        pinWindow.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 自测脚本（--selftest）：合成事件驱动交互并逐步导出 PNG

extension OverlayView {
    private func windowPoint(_ p: CGPoint) -> CGPoint {
        // 局部(左上原点) → 窗口坐标(左下原点)
        CGPoint(x: p.x, y: bounds.height - p.y)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at p: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: windowPoint(p), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func debugMove(to p: CGPoint) { mouseMoved(with: mouseEvent(.mouseMoved, at: p)) }

    /// 经过窗口的事件分发（含命中测试），和真实点击一致
    private func send(_ e: NSEvent) { window?.sendEvent(e) }

    func debugClick(at p: CGPoint, clicks: Int = 1) {
        send(mouseEvent(.leftMouseDown, at: p, clicks: clicks))
        send(mouseEvent(.leftMouseUp, at: p, clicks: clicks))
    }

    func debugRightClick(at p: CGPoint) { send(mouseEvent(.rightMouseDown, at: p)) }

    func debugDrag(_ pts: [CGPoint]) {
        guard let first = pts.first, let last = pts.last else { return }
        send(mouseEvent(.leftMouseDown, at: first))
        for p in pts.dropFirst() { send(mouseEvent(.leftMouseDragged, at: p)) }
        send(mouseEvent(.leftMouseUp, at: last))
    }

    func debugAction(_ a: ToolbarAction) { handle(a) }
    func debugOptions(size: StrokeSize?, color: NSColor?) { options.onChange?(size, color) }

    func debugTypeText(_ s: String) {
        textEditor?.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func debugCommitText() { commitText() }

    func debugKey(code: UInt16, chars: String, cmd: Bool = false) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: cmd ? [.command] : [], timestamp: 0,
                                 windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars,
                                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        keyDown(with: e)
    }

    func debugExport(to url: URL) {
        guard let sel = selection,
              let img = Exporter.render(shot: shot, selection: sel, annotations: annotations, renderer: renderer),
              let data = Exporter.pngData(img) else { return }
        try? data.write(to: url)
    }

    var debugSelection: CGRect? { selection }
    var debugHover: String { "hover=\(String(describing: hoverRect)) frameHidden=\(hoverFrame.isHidden) frame=\(hoverFrame.frame)" }
    var debugToolbarFrame: CGRect { toolbar.frame }
    var debugOptionsFrame: CGRect? { options.isHidden ? nil : options.frame }
    var debugAnnotationCount: Int { annotations.count }

    func debugSnapshot(to url: URL) {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

@MainActor
final class SelfTest {
    static var demoBackdrop: NSWindow?
    private var steps: [(String, () -> Void)] = []
    let dir: URL
    private var index = 0
    private let overlay: OverlayView

    init(overlay: OverlayView) {
        self.overlay = overlay
        dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/KShot-selftest")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func add(_ name: String, _ body: @escaping () -> Void) { steps.append((name, body)) }

    func run() {
        if let i = CommandLine.arguments.firstIndex(of: "--pause-at"), i + 1 < CommandLine.arguments.count,
           let n = Int(CommandLine.arguments[i + 1]), index >= n {
            Log.info("selftest paused at step \(n)")
            // 用 ScreenCaptureKit 抓一张真实合成后的屏幕（包含玻璃效果），便于核对外观
            let url = dir.appendingPathComponent("screen.png")
            Task { @MainActor in
                if let shot = try? await ScreenCapturer.captureAll().first, let data = Exporter.pngData(shot.image) {
                    try? data.write(to: url)
                    Log.info("screen captured to \(url.path)")
                }
            }
            return
        }
        guard index < steps.count else {
            Log.info("selftest done")
            return
        }
        let (name, body) = steps[index]
        body()
        overlay.layoutSubtreeIfNeeded()
        overlay.displayIfNeeded()
        let file = dir.appendingPathComponent(String(format: "%02d-%@.png", index + 1, name))
        overlay.debugSnapshot(to: file)
        Log.info("selftest step \(index + 1) \(name): \(overlay.debugHover) selection=\(String(describing: overlay.debugSelection)) toolbar=\(overlay.debugToolbarFrame) options=\(String(describing: overlay.debugOptionsFrame)) annotations=\(overlay.debugAnnotationCount)")
        index += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in run() }
    }

    static func standard(on overlay: OverlayView) -> SelfTest {
        let t = SelfTest(overlay: overlay)
        let o = overlay
        let b = overlay.bounds
        let c = CGPoint(x: b.midX, y: b.midY)
        t.add("hover") { o.debugMove(to: c) }
        t.add("click-window") { o.debugClick(at: c) }
        t.add("move-selection") {
            guard let s = o.debugSelection else { return }
            let from = CGPoint(x: s.midX, y: s.midY)
            o.debugDrag([from, CGPoint(x: from.x + 20, y: from.y + 15), CGPoint(x: from.x + 40, y: from.y + 30)])
        }
        t.add("resize-br") {
            guard let s = o.debugSelection else { return }
            let h = CGPoint(x: s.maxX, y: s.maxY)
            o.debugDrag([h, CGPoint(x: h.x - 30, y: h.y - 20), CGPoint(x: h.x - 60, y: h.y - 40)])
        }
        t.add("resize-top") {
            guard let s = o.debugSelection else { return }
            let h = CGPoint(x: s.midX, y: s.minY)
            o.debugDrag([h, CGPoint(x: h.x, y: h.y - 20), CGPoint(x: h.x, y: h.y - 40)])
        }
        t.add("tool-rect") { o.debugAction(.tool(.rect)) }
        t.add("draw-rect") {
            guard let s = o.debugSelection else { return }
            o.debugDrag([CGPoint(x: s.minX + 20, y: s.minY + 20), CGPoint(x: s.minX + 120, y: s.minY + 60), CGPoint(x: s.minX + 180, y: s.minY + 110)])
        }
        t.add("tool-ellipse-blue-large") { o.debugAction(.tool(.ellipse)); o.debugOptions(size: .large, color: Palette.colors[4]) }
        t.add("draw-ellipse") {
            guard let s = o.debugSelection else { return }
            o.debugDrag([CGPoint(x: s.minX + 200, y: s.minY + 20), CGPoint(x: s.minX + 300, y: s.minY + 80), CGPoint(x: s.minX + 340, y: s.minY + 120)])
        }
        t.add("tool-arrow") { o.debugAction(.tool(.arrow)); o.debugOptions(size: .medium, color: Palette.colors[0]) }
        t.add("draw-arrow") {
            guard let s = o.debugSelection else { return }
            o.debugDrag([CGPoint(x: s.minX + 40, y: s.maxY - 40), CGPoint(x: s.minX + 150, y: s.maxY - 100), CGPoint(x: s.minX + 260, y: s.maxY - 160)])
        }
        t.add("tool-pen") { o.debugAction(.tool(.pen)); o.debugOptions(size: nil, color: Palette.colors[3]) }
        t.add("draw-pen") {
            guard let s = o.debugSelection else { return }
            var pts: [CGPoint] = []
            for i in 0...30 {
                let x = s.minX + 60 + CGFloat(i) * 8
                let y = s.midY + sin(CGFloat(i) / 3) * 30
                pts.append(CGPoint(x: x, y: y))
            }
            o.debugDrag(pts)
        }
        t.add("tool-mosaic") { o.debugAction(.tool(.mosaic)); o.debugOptions(size: .large, color: nil) }
        t.add("draw-mosaic") {
            guard let s = o.debugSelection else { return }
            o.debugDrag([CGPoint(x: s.minX + 40, y: s.minY + 160), CGPoint(x: s.minX + 200, y: s.minY + 170), CGPoint(x: s.minX + 360, y: s.minY + 180)])
        }
        t.add("tool-text") { o.debugAction(.tool(.text)); o.debugOptions(size: .large, color: Palette.colors[0]) }
        t.add("text-begin") {
            guard let s = o.debugSelection else { return }
            o.debugClick(at: CGPoint(x: s.minX + 60, y: s.maxY - 220))
            o.debugTypeText("微信风格截图 KShot")
        }
        t.add("text-commit") { o.debugCommitText() }
        t.add("undo") { o.debugAction(.undo) }
        t.add("tool-off") { o.debugAction(.tool(.mosaic)); o.debugAction(.tool(.mosaic)) }
        t.add("export-annotated") {
            o.debugExport(to: t.dir.appendingPathComponent("export-annotated.png"))
        }
        t.add("right-click-reset") { o.debugRightClick(at: c) }
        t.add("hover-after-reset") { o.debugMove(to: CGPoint(x: 60, y: 300)) }
        t.add("click-fullscreen") {
            o.debugClick(at: CGPoint(x: 60, y: 300))
            if o.debugSelection != o.bounds { Log.info("❌ 点击整屏后未选中整屏: \(String(describing: o.debugSelection))") }
        }
        t.add("reset-again") { o.debugRightClick(at: CGPoint(x: 60, y: 300)); o.debugMove(to: CGPoint(x: 60, y: 300)) }
        t.add("drag-select") {
            o.debugDrag([CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 350), CGPoint(x: 700, y: 620)])
        }
        t.add("nudge-right") { o.debugKey(code: 124, chars: "") }
        if CommandLine.arguments.contains("--pin-test") {
            t.add("pin") {
                // 演示模式下先铺一层示例桌面，避免抓到真实桌面内容
                if CommandLine.arguments.contains("--demo") {
                    let bg = NSWindow(contentRect: o.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    bg.level = .normal
                    bg.isReleasedWhenClosed = false
                    let iv = NSImageView(frame: CGRect(origin: .zero, size: o.screen.frame.size))
                    iv.image = NSImage(cgImage: o.shot.image, size: o.screen.frame.size)
                    iv.imageScaling = .scaleAxesIndependently
                    bg.contentView = iv
                    bg.orderFront(nil)
                    SelfTest.demoBackdrop = bg
                }
                o.debugAction(.pin)
                if CommandLine.arguments.contains("--demo"), let pin = PinWindow.latest {
                    // 挪开一点，让钉住的图片和底下的示例桌面区分开
                    pin.setFrameOrigin(CGPoint(x: pin.frame.minX + 260, y: pin.frame.minY - 140))
                }
                let url = t.dir.appendingPathComponent("screen.png")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    Task { @MainActor in
                        if let shot = try? await ScreenCapturer.captureAll().first, let data = Exporter.pngData(shot.image) {
                            try? data.write(to: url)
                            Log.info("pin screen captured")
                        }
                    }
                }
            }
            return t
        }
        t.add("confirm") {
            o.debugKey(code: 36, chars: "\r")
            // 把剪贴板里的图片写出来核对
            if let data = NSPasteboard.general.data(forType: .png) {
                let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/KShot-selftest/clipboard.png")
                try? data.write(to: url)
                Log.info("clipboard png bytes=\(data.count)")
            } else {
                Log.info("clipboard has no png")
            }
        }
        return t
    }
}
