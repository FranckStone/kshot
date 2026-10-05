import AppKit

/// 单块屏幕上的截图交互层：窗口识别、拖拽选区、把手、标注、工具条。
/// 坐标系：左上原点、y 向下（isFlipped），单位 pt。
final class OverlayView: NSView {
    private enum DragMode {
        case none
        case pending(CGPoint)                          // 已按下，尚未判断是点击还是拖拽
        case selecting(CGPoint)                        // 拖拽框选
        case moving(offset: CGPoint)                   // 拖动选区
        case resizing(Handle, orig: CGRect)            // 拖动把手
        case drawing                                   // 绘制 / 拖动编辑标注（交给 AnnotationLayer）
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
    private let marks = AnnotationLayer()
    /// 正在重新编辑的文字标注（提交时替换原标注，不额外记录撤销）
    private var editingExistingText = false
    /// 单击选中的窗口（未再调整选区时，可输出带阴影的透明窗口图）
    private var pickedWindow: WindowInfo?
    /// 鼠标位置（放大镜用）
    private var mousePoint: CGPoint?
    private var tool: Tool = .none
    private var color: NSColor = Palette.colors[0]
    private var strokeSize: StrokeSize = .medium

    private let toolbar = ToolbarView()
    private let options = OptionsView()
    private let sizeLabel = SizeLabelView()
    private let hoverFrame = GlassFrameView(tint: NSColor.accentGreen.withAlphaComponent(0.45))
    private let handleViews: [GlassPanelView] = Handle.all.map { _ in
        GlassPanelView(cornerRadius: OverlayView.handleRadius, tint: NSColor.accentGreen.withAlphaComponent(0.7), ringColor: .white, ringWidth: 1.5)
    }
    private var textEditor: TextEditorView?
    private var textGlass: GlassPanelView?
    private static let textGlassInset = CGSize(width: 8, height: 5)

    private static let dimAlpha: CGFloat = 0.42
    private static let fullScreenDimAlpha: CGFloat = 0.25
    private static let handleRadius: CGFloat = 7
    private static let handleHitSlop: CGFloat = 8
    /// macOS 窗口圆角
    private static let windowCornerRadius: CGFloat = 10

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// 应用未激活时第一下点击也要生效（否则只用来激活窗口）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Init

    init(frame: CGRect, shot: ScreenShot, windows: [WindowInfo], session: CaptureSession) {
        self.shot = shot
        self.screen = shot.screen
        self.windows = windows
        self.session = session
        self.baseImage = NSImage(cgImage: shot.image, size: frame.size)
        self.renderer = AnnotationRenderer(source: shot.image, bounds: CGRect(origin: .zero, size: frame.size), scale: shot.scale)
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
            // 选中了标注：直接修改它
            if self.marks.selected != nil { self.marks.updateSelected(color: color, size: size) }
        }
        marks.onChange = { [weak self] in
            guard let self else { return }
            self.updateToolbarState()
            self.needsDisplay = true
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
            marks.draw(with: renderer, clip: sel, in: ctx)
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

        // 4. 边框（悬停状态用玻璃框子视图，选区用细线）
        if let cut, let sel = selection, !isFullScreen(sel) {
            ctx.setStrokeColor(NSColor.accentGreen.cgColor)
            ctx.setLineWidth(1.5)
            // 线画在选区外侧；贴着屏幕边缘的那几条边改画在内侧，否则会落到屏幕外
            let outer = cut.insetBy(dx: -0.75, dy: -0.75)
            let line = outer.intersection(bounds.insetBy(dx: 0.75, dy: 0.75))
            ctx.stroke(line.isNull ? outer : line)
        }

        // 5. 放大镜
        if showsLoupe, let p = mousePoint {
            debugLoupeDraws += 1
            Loupe.draw(at: p, shot: shot, in: ctx, bounds: bounds)
        }
    }

    /// 选区阶段（悬停 / 框选 / 拖把手）显示放大镜
    private var showsLoupe: Bool {
        guard textEditor == nil else { return false }
        if let p = mousePoint, !toolbar.isHidden, toolbar.frame.contains(p) { return false }
        if let p = mousePoint, !options.isHidden, options.frame.contains(p) { return false }
        // 选好区域后，由工具条上的放大镜按钮打开
        if loupeOn, selection != nil, case .none = dragMode { return true }
        // 选区阶段（悬停 / 框选 / 拖把手）：偏好设置里打开才显示
        guard Settings.showMagnifier else { return false }
        switch dragMode {
        case .selecting, .resizing, .pending: return true
        case .none: return selection == nil && session.canHover(self)
        default: return false
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
        let hr = handleRect(for: sel)
        for (i, h) in Handle.all.enumerated() {
            let p = h.point(in: hr)
            let f = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            if handleViews[i].frame != f { handleViews[i].frame = f }
            handleViews[i].isHidden = false
        }
    }

    private func updateHoverFrame() {
        let rect: CGRect
        if let sel = selection {
            // 整屏选中：沿用贴合屏幕圆角的玻璃框（细绿线会落到屏幕外看不见）
            guard isFullScreen(sel) else { hoverFrame.isHidden = true; return }
            rect = bounds
        } else if let h = hoverRect {
            rect = h
        } else {
            hoverFrame.isHidden = true
            return
        }
        let t = GlassFrameView.thickness
        let isFullScreen = self.isFullScreen(rect)
        // 整屏时玻璃框贴在屏幕边缘内侧，并用屏幕角的弧度；窗口时略大于窗口圆角
        let f = isFullScreen ? bounds : rect.insetBy(dx: -t, dy: -t)
        let radius: CGFloat = isFullScreen ? screen.physicalCornerRadius : OverlayView.windowCornerRadius + t
        if hoverFrame.frame != f || hoverFrame.cornerRadius != radius {
            hoverFrame.frame = f
            hoverFrame.cornerRadius = radius
            hoverFrame.needsLayout = true
        }
        hoverFrame.isHidden = false
    }

    /// 选区（或悬停区域）是否基本等于整块屏幕
    private func isFullScreen(_ r: CGRect) -> Bool {
        abs(r.minX - bounds.minX) < 2 && abs(r.minY - bounds.minY) < 2 &&
            abs(r.maxX - bounds.maxX) < 2 && abs(r.maxY - bounds.maxY) < 2
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
        guard selection != nil, tool == .none, textEditor == nil, marks.selected == nil else { return false }
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
        // 一进入截图就在鼠标当前位置显示放大镜（不用先动一下鼠标）
        mousePoint = p
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
        mousePoint = nil
        if case .none = dragMode, selection == nil {
            hoverRect = nil
        }
        needsDisplay = true
    }

    /// 工具条上的“放大镜取色”是否打开
    private var loupeOn = false

    /// 调试计数
    var debugMoveCount = 0
    var debugLoupeDraws = 0

    override func mouseMoved(with event: NSEvent) {
        let p = location(event)
        debugMoveCount += 1
        mousePoint = p
        if showsLoupe || selection == nil { needsDisplay = true }
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

        // 放大镜取色：单击复制颜色，不结束截图
        if loupeOn {
            copyColor(at: p, rgb: event.modifierFlags.contains(.shift), endSession: false)
            return
        }

        // 无工具时选区把手优先
        if tool == .none, marks.selected == nil, let h = handle(at: p, in: sel) {
            dragMode = .resizing(h, orig: sel)
            pickedWindow = nil
            layoutChrome()
            return
        }

        // 标注：选中/拖动/缩放已有标注，或用当前工具绘制
        switch marks.mouseDown(at: p, clip: sel, tool: tool, color: color, size: strokeSize, clickCount: event.clickCount) {
        case .handled:
            dragMode = .drawing
            layoutChrome()
            return
        case .beginText:
            beginTextEditing(at: p)
            return
        case .editText(let i):
            editText(at: i)
            return
        case .ignored:
            break
        }

        // 双击选区内：完成
        if event.clickCount == 2, tool == .none, sel.contains(p) {
            confirm()
            return
        }

        if tool != .none { return }

        if sel.contains(p) {
            dragMode = .moving(offset: CGPoint(x: p.x - sel.minX, y: p.y - sel.minY))
            NSCursor.closedHand.set()
            layoutChrome()
            return
        }
        // 点在选区外且尚未标注：重新框选
        if marks.isEmpty {
            selection = nil
            dragMode = .pending(p)
            layoutChrome()
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = location(event).clamped(to: bounds)
        mousePoint = p
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
            if r.clamped(to: bounds) != sel { pickedWindow = nil }
            selection = r.clamped(to: bounds)
            needsDisplay = true
        case .resizing(let h, let orig):
            selection = orig.resized(handle: h, to: p)
            needsDisplay = true
        case .drawing:
            marks.mouseDragged(to: location(event), shift: event.modifierFlags.contains(.shift))
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = location(event).clamped(to: bounds)
        switch dragMode {
        case .pending:
            // 单击：选中鼠标下的窗口
            session.activeOverlay = self
            selection = windowRect(atLocal: p)
            pickedWindow = WindowFinder.topWindow(at: screen.cgPoint(fromLocal: p), in: windows)
            hoverRect = nil
        case .selecting(let anchor):
            let r = CGRect(p1: anchor, p2: p)
            if r.width < 4 || r.height < 4 {
                selection = windowRect(atLocal: p)
                pickedWindow = WindowFinder.topWindow(at: screen.cgPoint(fromLocal: p), in: windows)
            } else {
                selection = r.integral.intersection(bounds)
                pickedWindow = nil
            }
            hoverRect = nil
        case .moving, .resizing:
            if let sel = selection { selection = sel.integral.intersection(bounds) }
        case .drawing:
            marks.mouseUp()
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
            // 回到悬停识别状态
            selection = nil
            pickedWindow = nil
            marks.removeAll()
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
        case 53: // Esc：先取消选中的标注，再退出
            if target.marks.selected != nil { target.marks.deselect(); target.layoutChrome(); return }
            session.cancel()
            return
        case 36, 76: // Return / Enter
            target.confirm()
            return
        case 51, 117: // Delete：删除选中的标注
            if target.marks.selected != nil { target.marks.deleteSelected(); target.layoutChrome() }
            return
        default:
            break
        }
        if flags.contains(.command) {
            switch chars.lowercased() {
            case "z": flags.contains(.shift) ? target.redo() : target.undo(); return
            case "s": target.save(); return
            case "c": target.confirm(); return
            case "p": target.pin(); return
            case "k": target.longShot(); return
            case "t": target.recognizeText(); return
            case "l": target.recognizeText(thenTranslate: true); return
            case "r": target.record(); return
            case "b": target.beautify(); return
            case "e": target.redact(); return
            default: break
            }
            return
        }
        // C / ⇧C：复制放大镜下的颜色（HEX / RGB）
        if chars.lowercased() == "c", target.showsLoupe, let p = target.mousePoint {
            target.copyColor(at: p, rgb: flags.contains(.shift), endSession: !target.loupeOn)
            return
        }
        // 方向键：移动选中的标注，或微调选区
        if target.marks.selected != nil, [123, 124, 125, 126].contains(Int(event.keyCode)) {
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let d: CGPoint
            switch event.keyCode {
            case 123: d = CGPoint(x: -step, y: 0)
            case 124: d = CGPoint(x: step, y: 0)
            case 125: d = CGPoint(x: 0, y: step)
            default: d = CGPoint(x: 0, y: -step)
            }
            target.marks.nudgeSelected(d)
            return
        }
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
        // 让 ⌘Z/⌘S/⌘C/⌘P 等不触发系统提示音
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift], let c = event.charactersIgnoringModifiers?.lowercased(),
           ["z", "s", "c", "p", "t", "l", "k", "r", "b", "e"].contains(c) {
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
        pickedWindow = nil
        layoutChrome()
        needsDisplay = true
    }

    // MARK: - 选区几何

    /// 把手所在的矩形：选区贴着屏幕边缘时向内收，保证把手完整可见、不被屏幕圆角挡住
    private func handleRect(for sel: CGRect) -> CGRect {
        let m = OverlayView.handleRadius + 4
        let inner = bounds.insetBy(dx: m, dy: m)
        let r = CGRect(x: max(sel.minX, inner.minX), y: max(sel.minY, inner.minY),
                       width: 0, height: 0)
        let maxX = min(sel.maxX, inner.maxX), maxY = min(sel.maxY, inner.maxY)
        guard maxX > r.minX, maxY > r.minY else { return sel }
        return CGRect(x: r.minX, y: r.minY, width: maxX - r.minX, height: maxY - r.minY)
    }

    private func handle(at p: CGPoint, in sel: CGRect) -> Handle? {
        let hr = handleRect(for: sel)
        for h in Handle.all where h.point(in: hr).distance(to: p) <= OverlayView.handleHitSlop {
            return h
        }
        return nil
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
        if loupeOn, selection != nil {
            NSCursor.crosshair.set()
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
        if case .drawing = dragMode { return }
        if selection != nil, let c = marks.cursor(at: p, tool: tool) {
            c.set()
            return
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

    private func beginTextEditing(at p: CGPoint) {
        guard let sel = selection else { return }
        let fontSize = strokeSize.fontSize
        var origin = CGPoint(x: p.x - Annotation.textInset.width, y: p.y - fontSize * 0.7)
        origin.x = min(max(sel.minX, origin.x), sel.maxX - fontSize)
        origin.y = min(max(sel.minY, origin.y), sel.maxY - fontSize)
        openTextEditor(origin: origin, string: "", color: color, fontSize: fontSize)
    }

    /// 双击已有文字标注：取出来重新编辑
    private func editText(at i: Int) {
        let a = marks.extract(at: i)
        guard case .text(let origin, let string, let fontSize) = a.kind else { return }
        editingExistingText = true
        strokeSize = StrokeSize.nearest(fontSize: fontSize)
        color = a.color
        options.size = strokeSize
        options.color = color
        openTextEditor(origin: origin, string: string, color: a.color, fontSize: fontSize)
    }

    private func openTextEditor(origin: CGPoint, string: String, color: NSColor, fontSize: CGFloat) {
        let editor = TextEditorView(origin: origin, color: color, fontSize: fontSize)
        if !string.isEmpty { editor.string = string; editor.fit() }
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
        marks.add(a, recordUndo: !editingExistingText)
        editingExistingText = false
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
        marks.undo()
        layoutChrome()
    }

    private func redo() {
        commitText()
        marks.redo()
        layoutChrome()
    }

    // MARK: - 工具条

    private func handle(_ action: ToolbarAction) {
        switch action {
        case .tool(let t):
            commitText()
            tool = (tool == t) ? .none : t
            setLoupe(false)
            marks.deselect()
            updateToolbarState()
            layoutChrome()
            needsDisplay = true
        case .undo: undo()
        case .redo: redo()
        case .pin: pin()
        case .longShot: longShot()
        case .record: record()
        case .beautify: beautify()
        case .ocr: recognizeText()
        case .translate: recognizeText(thenTranslate: true)
        case .redact: redact()
        case .loupe:
            commitText()
            setLoupe(!loupeOn)
            if loupeOn { tool = .none; marks.deselect() }
            updateToolbarState()
            layoutChrome()
            if let w = window { mousePoint = convert(w.mouseLocationOutsideOfEventStream, from: nil) }
            needsDisplay = true
        case .save: save()
        case .cancel: session.cancel()
        case .confirm: confirm()
        }
    }

    private func setLoupe(_ on: Bool) {
        loupeOn = on
        toolbar.setLoupeActive(on)
        needsDisplay = true
    }

    private func updateToolbarState() {
        toolbar.setSelectedTool(tool)
        toolbar.setUndoEnabled(marks.canUndo || textEditor != nil)
        toolbar.setRedoEnabled(marks.canRedo)
        // 选中标注时，选项面板显示它的颜色与粗细
        if let a = marks.selected {
            options.size = a.size
            if a.usesColor { options.color = a.color }
        }
        if !marks.isDragging, case .none = dragMode, selection != nil {
            let wantOptions = tool != .none || marks.selected != nil
            if options.isHidden == wantOptions { layoutChrome() }
        }
    }

    private func layoutChrome() {
        guard let sel = selection, case .none = dragMode else {
            toolbar.isHidden = true
            options.isHidden = true
            return
        }
        toolbar.isHidden = false
        options.isHidden = (tool == .none && marks.selected == nil)

        let gap: CGFloat = 8
        let optionsExtra: CGFloat = options.isHidden ? 0 : OptionsView.height + 6
        var tf = toolbar.frame
        var of = options.frame
        if sel.maxY + gap + tf.height + optionsExtra <= bounds.maxY - 4 {
            // 1. 选区下方，右对齐；选项面板在工具条下方
            tf.origin.x = min(max(bounds.minX + 4, sel.maxX - tf.width), bounds.maxX - tf.width - 4)
            tf.origin.y = sel.maxY + gap
            of.origin.y = tf.maxY + 6
        } else if sel.minY - gap - tf.height - optionsExtra >= bounds.minY + 4 {
            // 2. 选区上方，右对齐；选项面板在工具条上方
            tf.origin.x = min(max(bounds.minX + 4, sel.maxX - tf.width), bounds.maxX - tf.width - 4)
            tf.origin.y = sel.minY - gap - tf.height
            of.origin.y = tf.minY - 6 - of.height
        } else {
            // 3. 选区内部（整屏 / 接近整屏）：水平居中贴近底部，选项面板在工具条上方，更显眼
            let bottomMargin: CGFloat = 28
            tf.origin.x = sel.midX - tf.width / 2
            tf.origin.y = sel.maxY - bottomMargin - tf.height
            of.origin.y = tf.minY - 6 - of.height
        }
        tf.origin.x = min(max(bounds.minX + 4, tf.origin.x), bounds.maxX - tf.width - 4)
        toolbar.frame = tf
        of.origin.x = min(max(bounds.minX + 4, tf.midX - of.width / 2), bounds.maxX - of.width - 4)
        options.frame = of
        toolbar.needsDisplay = true
        options.needsDisplay = true
    }

    // MARK: - 输出

    private func renderImage() -> CGImage? {
        commitText()
        guard let sel = selection else { return nil }
        marks.deselect()
        Settings.lastRegion = Settings.Region(displayID: screen.displayID, rect: sel)
        return Exporter.render(shot: shot, selection: sel, annotations: marks.items, renderer: renderer)
    }

    private func confirm() {
        // 通过录屏快捷键进来的：回车 / 双击开始录制
        if session.recordIntent { record(); return }
        guard let img = renderImage() else { return }
        // 单击选中的窗口且开启了“窗口阴影”：重新抓取该窗口（带系统阴影、透明背景）再叠加标注
        if Settings.windowShadow, let w = pickedWindow, !CommandLine.arguments.contains("--demo") {
            let items = marks.items
            let windowLocal = screen.localRect(fromCG: w.bounds)
            let renderer = renderer
            session.end()
            Task { @MainActor in
                let out = await WindowShadow.capture(window: w, windowLocalRect: windowLocal, annotations: items, renderer: renderer) ?? img
                Exporter.deliver(out)
            }
            return
        }
        session.end()
        Exporter.deliver(img)
    }

    private func save() {
        guard let img = renderImage() else { return }
        Shutter.play()
        History.add(img)
        if Settings.quickSave {
            session.end()
            Exporter.quickSave(img)
            return
        }
        session.hideOverlays()
        Exporter.save(img) { [session] _ in
            session.end()
        }
    }

    /// 复制放大镜下的颜色并结束截图
    private func copyColor(at p: CGPoint, rgb: Bool, endSession: Bool = true) {
        guard let c = Loupe.color(at: p, shot: shot) else { return }
        let text = rgb ? "rgb(\(c.rgbText))" : c.hex
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if endSession { session.end() }
        Toast.show("已复制颜色 \(text)", symbol: "eyedropper")
    }

    /// 由“截取上次区域”调用：直接选中给定区域
    func preselect(_ r: CGRect) {
        let rect = r.intersection(bounds)
        guard rect.width >= 4, rect.height >= 4 else { return }
        session.activeOverlay = self
        selection = rect
        hoverRect = nil
        dragMode = .none
        updateToolbarState()
        layoutChrome()
        needsDisplay = true
    }

    /// 美化：带背景、内边距、圆角、阴影导出
    private func beautify() {
        guard let img = renderImage() else { return }
        let frame = screen.cocoaRect(fromLocal: selection ?? .zero)
        let fromWindow = pickedWindow != nil
        session.end(restoreFocus: false)
        BeautifyWindow(image: img, scale: shot.scale, near: frame, fromWindow: fromWindow).show()
    }

    /// 录屏：把选区交给录屏会话
    private func record() {
        commitText()
        guard let sel = selection?.integral else { return }
        let scr = screen
        Settings.lastRegion = Settings.Region(displayID: screen.displayID, rect: sel)
        session.end(restoreFocus: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            ScreenRecorder.start(screen: scr, region: sel)
        }
    }

    /// 自动打码：识别选区内的敏感信息，盖上马赛克（可撤销）
    private func redact() {
        commitText()
        guard let sel = selection,
              let img = Exporter.render(shot: shot, selection: sel, annotations: [], renderer: renderer) else { return }
        toolbar.setBusy(.redact, true)
        Task { @MainActor in
            let boxes = (try? await Redactor.findSensitive(in: img)) ?? []
            toolbar.setBusy(.redact, false)
            guard selection == sel else { return }
            let rects = boxes.map { b in
                // 归一化（左下原点）→ 选区内局部坐标，四周留一点余量
                CGRect(x: sel.minX + b.minX * sel.width, y: sel.minY + (1 - b.maxY) * sel.height,
                       width: b.width * sel.width, height: b.height * sel.height).insetBy(dx: -3, dy: -2)
            }
            if rects.isEmpty {
                Toast.show("没有发现手机号、邮箱、证件号、银行卡或密钥", symbol: "eye", near: screen.cocoaRect(fromLocal: sel).center)
            } else {
                marks.add(rects.map { Annotation(kind: .pixelate($0), color: .black, size: .medium) })
                Toast.show("已打码 \(rects.count) 处，可 ⌘Z 撤销", symbol: "eye.slash.fill", near: screen.cocoaRect(fromLocal: sel).center)
            }
        }
    }

    /// 提取选区内的文字（用原始截图，不含标注）
    private func recognizeText(thenTranslate: Bool = false) {
        commitText()
        guard let sel = selection,
              let img = Exporter.render(shot: shot, selection: sel, annotations: [], renderer: renderer) else { return }
        let frame = screen.cocoaRect(fromLocal: sel)
        session.end(restoreFocus: false)
        OCRResultWindow.present(image: img, near: frame, translate: thenTranslate)
    }

    /// 长截图：隐藏遮罩后对选区自动滚动并拼接
    private func longShot() {
        commitText()
        guard let sel = selection?.integral else { return }
        let scr = screen
        session.end(restoreFocus: true)
        // 等遮罩真正消失后再开始抓第一帧
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            LongScreenshotSession(screen: scr, region: sel).start()
        }
    }

    private func pin() {
        guard let sel = selection, let img = renderImage() else { return }
        let frame = screen.cocoaRect(fromLocal: sel)
        History.add(img)
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
              let img = Exporter.render(shot: shot, selection: sel, annotations: marks.items, renderer: renderer),
              let data = Exporter.pngData(img) else { return }
        try? data.write(to: url)
    }

    var debugSelection: CGRect? { selection }
    var debugHover: String { "hover=\(String(describing: hoverRect)) frameHidden=\(hoverFrame.isHidden) frame=\(hoverFrame.frame)" }
    var debugToolbarFrame: CGRect { toolbar.frame }
    var debugOptionsFrame: CGRect? { options.isHidden ? nil : options.frame }
    var debugAnnotationCount: Int { marks.items.count }

    func debugSnapshot(to url: URL) {
        // 手动合成：先画自己，再把每个可见子视图各自缓存后贴上去（显示器休眠时 cacheDisplay 整体渲染不可靠）
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds), let gc = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let ctx = gc.cgContext
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(bounds)
        for v in subviews where !v.isHidden && v.alphaValue > 0 {
            guard let sub = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: sub)
            sub.draw(in: v.frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

@MainActor
final class SelfTest {
    static var demoBackdrop: NSWindow?

    /// 演示模式：铺一层示例桌面窗口，避免抓屏时带上真实桌面内容
    static func showDemoBackdrop(for o: OverlayView) {
        let bg = NSWindow(contentRect: o.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        bg.level = .normal
        bg.isReleasedWhenClosed = false
        let iv = NSImageView(frame: CGRect(origin: .zero, size: o.screen.frame.size))
        iv.image = NSImage(cgImage: o.shot.image, size: o.screen.frame.size)
        iv.imageScaling = .scaleAxesIndependently
        bg.contentView = iv
        bg.orderFront(nil)
        demoBackdrop = bg
    }
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
                do {
                    if let shot = try await ScreenCapturer.captureAll().first, let data = Exporter.pngData(shot.image) {
                        try? data.write(to: url)
                        Log.info("screen captured to \(url.path)")
                    }
                } catch {
                    Log.info("pause capture failed: \(error)")
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
        if CommandLine.arguments.contains("--edge-test") {
            t.add("fullscreen-select") { o.debugClick(at: CGPoint(x: 60, y: 300)) }
            return t
        }
        if CommandLine.arguments.contains("--loupe-test") {
            t.add("loupe-on") {
                o.debugAction(.loupe)
                o.debugMove(to: CGPoint(x: c.x + 60, y: c.y - 40))
            }
            t.add("loupe-move") { o.debugMove(to: CGPoint(x: c.x - 120, y: c.y + 80)) }
            t.add("loupe-off") { o.debugAction(.loupe); o.debugMove(to: CGPoint(x: c.x - 100, y: c.y + 90)) }
            return t
        }
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
        t.add("tool-line") { o.debugAction(.tool(.line)); o.debugOptions(size: .medium, color: Palette.colors[5]) }
        t.add("draw-line") {
            guard let s = o.debugSelection else { return }
            o.debugDrag([CGPoint(x: s.maxX - 200, y: s.minY + 30), CGPoint(x: s.maxX - 120, y: s.minY + 60), CGPoint(x: s.maxX - 40, y: s.minY + 90)])
        }
        t.add("tool-highlighter") { o.debugAction(.tool(.highlighter)); o.debugOptions(size: .medium, color: Palette.colors[2]) }
        t.add("draw-highlighter") {
            guard let s = o.debugSelection else { return }
            o.debugDrag([CGPoint(x: s.minX + 230, y: s.minY + 230), CGPoint(x: s.minX + 330, y: s.minY + 232), CGPoint(x: s.minX + 430, y: s.minY + 231)])
        }
        t.add("tool-blur") { o.debugAction(.tool(.blur)) }
        t.add("draw-blur") {
            guard let s = o.debugSelection else { return }
            o.debugDrag([CGPoint(x: s.maxX - 260, y: s.maxY - 140), CGPoint(x: s.maxX - 160, y: s.maxY - 90), CGPoint(x: s.maxX - 60, y: s.maxY - 40)])
        }
        t.add("tool-step") { o.debugAction(.tool(.step)); o.debugOptions(size: .medium, color: Palette.colors[0]) }
        t.add("draw-steps") {
            guard let s = o.debugSelection else { return }
            for i in 0..<3 { o.debugClick(at: CGPoint(x: s.maxX - 300 + CGFloat(i) * 50, y: s.minY + 150)) }
        }
        t.add("select-rect") {
            o.debugAction(.tool(.step)) // 关掉工具
            guard let s = o.debugSelection else { return }
            o.debugClick(at: CGPoint(x: s.minX + 20, y: s.minY + 60)) // 矩形左边框
        }
        t.add("move-rect") {
            guard let s = o.debugSelection else { return }
            o.debugDrag([CGPoint(x: s.minX + 20, y: s.minY + 60), CGPoint(x: s.minX + 40, y: s.minY + 80), CGPoint(x: s.minX + 60, y: s.minY + 100)])
        }
        t.add("recolor-rect") { o.debugOptions(size: .large, color: Palette.colors[4]) }
        t.add("undo-recolor") { o.debugAction(.undo) }
        t.add("redo-recolor") { o.debugAction(.redo) }
        t.add("tool-text") { o.debugAction(.tool(.text)); o.debugOptions(size: .large, color: Palette.colors[0]) }
        t.add("text-begin") {
            guard let s = o.debugSelection else { return }
            o.debugClick(at: CGPoint(x: s.minX + 60, y: s.maxY - 220))
            o.debugTypeText("KShot 截图标注")
        }
        t.add("text-commit") { o.debugCommitText() }
        t.add("text-reedit") {
            guard let s = o.debugSelection else { return }
            o.debugClick(at: CGPoint(x: s.minX + 70, y: s.maxY - 215), clicks: 2)
            o.debugTypeText("（已修改）")
        }
        t.add("text-recommit") { o.debugCommitText() }
        t.add("undo") { o.debugAction(.undo) }
        t.add("redo") { o.debugAction(.redo) }
        t.add("tool-off") { o.debugAction(.tool(.mosaic)); o.debugAction(.tool(.mosaic)) }
        t.add("export-annotated") {
            o.debugExport(to: t.dir.appendingPathComponent("export-annotated.png"))
        }
        t.add("right-click-reset") { o.debugRightClick(at: c) }
        t.add("hover-after-reset") { o.debugMove(to: CGPoint(x: 60, y: 300)) }
        t.add("click-fullscreen") {
            o.debugClick(at: CGPoint(x: 60, y: 300))
            if o.debugSelection != o.bounds { Log.info("❌ 点击整屏后未选中整屏: \(String(describing: o.debugSelection))") }
            o.debugAction(.tool(.rect))
        }
        t.add("reset-again") { o.debugRightClick(at: CGPoint(x: 60, y: 300)); o.debugMove(to: CGPoint(x: 60, y: 300)) }
        t.add("drag-select") {
            o.debugDrag([CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 350), CGPoint(x: 700, y: 620)])
        }
        t.add("nudge-right") { o.debugKey(code: 124, chars: "") }
        if CommandLine.arguments.contains("--ocr-test") || CommandLine.arguments.contains("--translate-test") {
            let translate = CommandLine.arguments.contains("--translate-test")
            t.add(translate ? "translate" : "ocr") {
                if CommandLine.arguments.contains("--demo") { SelfTest.showDemoBackdrop(for: o) }
                o.debugAction(translate ? .translate : .ocr)
                let url = t.dir.appendingPathComponent("screen.png")
                DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                    Task { @MainActor in
                        Log.info("ocr text: \(OCRResultWindow.latest?.text.replacingOccurrences(of: "\n", with: " | ") ?? "nil")")
                        if translate { Log.info("translated: \(OCRResultWindow.latest?.translatedText.replacingOccurrences(of: "\n", with: " | ") ?? "nil")") }
                        if let shot = try? await ScreenCapturer.captureAll().first, let data = Exporter.pngData(shot.image) {
                            try? data.write(to: url)
                            Log.info("ocr screen captured")
                        }
                    }
                }
            }
            return t
        }
        if CommandLine.arguments.contains("--pin-test") {
            t.add("pin") {
                // 演示模式下先铺一层示例桌面，避免抓到真实桌面内容
                if CommandLine.arguments.contains("--demo") { SelfTest.showDemoBackdrop(for: o) }
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
