import AppKit

/// 一次截图会话：负责抓屏、创建每个屏幕的遮罩窗口、协调跨屏状态与收尾。
@MainActor
final class CaptureSession {
    static let shared = CaptureSession()

    private(set) var windows: [OverlayWindow] = []
    private var previousApp: NSRunningApplication?
    private var starting = false

    /// 当前正在进行选区/编辑的遮罩（其他屏幕的遮罩在此期间不响应悬停）
    weak var activeOverlay: OverlayView?

    var isActive: Bool { !windows.isEmpty || starting }

    /// 本次会话要预先选中的区域（截取上次区域）
    private var preset: Settings.Region?
    /// 本次会话完成选区后直接开始录屏（录屏快捷键）
    private(set) var recordIntent = false
    private var countdown: CountdownHUD?

    /// 延时截图：倒计时结束后再开始（倒计时提示框不会被截进去）
    func begin(delay seconds: Int) {
        guard !isActive, countdown == nil else { return }
        let hud = CountdownHUD(seconds: seconds) { [weak self] in
            self?.countdown = nil
            // 等提示框真正消失后再抓屏
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.begin() }
        }
        countdown = hud
        hud.start()
    }

    /// 截取上次区域：直接选中上次完成截图时的选区
    func beginWithLastRegion() {
        guard let r = Settings.lastRegion else {
            Toast.show("还没有上次的截图区域", symbol: "exclamationmark.circle.fill")
            return
        }
        preset = r
        begin()
    }

    /// 录屏：先选区，回车 / 双击后开始录制
    func beginRecording() {
        if ScreenRecorder.isRecording {
            ScreenRecorder.current?.stop(cancel: false)
            return
        }
        recordIntent = true
        begin()
    }

    func begin() {
        guard !isActive else { return }
        starting = true
        Log.info("begin capture, preflight=\(CGPreflightScreenCaptureAccess())")
        previousApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            defer { starting = false }
            do {
                if CommandLine.arguments.contains("--demo"), let screen = NSScreen.main,
                   let (shot, wins) = DemoScene.make(for: screen) {
                    present(shots: [shot], windows: wins)
                    return
                }
                let shots = try await ScreenCapturer.captureAll()
                let wins = WindowFinder.onScreenWindows()
                Log.info("captured \(shots.count) screens, \(wins.count) windows")
                present(shots: shots, windows: wins)
            } catch {
                Log.info("capture failed: \(error)")
                preset = nil
                recordIntent = false
                presentError(error)
            }
        }
    }

    private func present(shots: [ScreenShot], windows wins: [WindowInfo]) {
        for shot in shots {
            let w = OverlayWindow(shot: shot, windows: wins, session: self)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.orderFrontRegardless() }

        let mouse = NSEvent.mouseLocation
        let target = windows.first { $0.frame.contains(mouse) } ?? windows.first
        Log.info("presented \(windows.count) overlays, key=\(String(describing: target?.frame))")
        target?.makeKeyAndOrderFront(nil)
        target?.makeFirstResponder(target?.overlayView)
        NSCursor.crosshair.set()
        // 让鼠标所在屏幕立刻显示悬停高亮
        target?.overlayView.refreshHover()
        if let preset, let w = windows.first(where: { $0.overlayView.screen.displayID == preset.displayID }) {
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(w.overlayView)
            w.overlayView.preselect(preset.rect)
        }
        preset = nil
        if recordIntent {
            Toast.show("选择要录制的区域，按回车开始录屏", symbol: "record.circle")
        }
        if CommandLine.arguments.contains("--dump") { startDebugDump() }
        if CommandLine.arguments.contains("--selftest"), let ov = target?.overlayView {
            selfTest = SelfTest.standard(on: ov)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.selfTest?.run() }
        }
    }

    // MARK: - 调试：定期把遮罩渲染成 PNG

    private var dumpTimer: Timer?
    private var selfTest: SelfTest?

    private func startDebugDump() {
        dumpTimer?.invalidate()
        dumpTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.dumpOverlay() }
        }
    }

    private func dumpOverlay() {
        guard let view = activeOverlay ?? windows.first?.overlayView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/KShot-overlay.png")
        try? data.write(to: url)
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "截图失败"
        alert.informativeText = error.localizedDescription
        if case CaptureError.permissionDenied = error {
            alert.informativeText += "\n\n请在“系统设置 › 隐私与安全性 › 屏幕录制”中勾选 KShot，然后重试。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// 隐藏所有遮罩但保留会话（用于弹出保存面板）
    func hideOverlays() {
        for w in windows { w.orderOut(nil) }
    }

    /// 结束会话
    func end(restoreFocus: Bool = true) {
        Log.info("session end (windows=\(windows.count))")
        for w in windows {
            w.overlayView.tearDown()
            w.orderOut(nil)
        }
        windows.removeAll()
        activeOverlay = nil
        recordIntent = false
        preset = nil
        dumpTimer?.invalidate()
        dumpTimer = nil
        NSCursor.arrow.set()
        if restoreFocus {
            previousApp?.activate()
        }
        previousApp = nil
    }

    func cancel() { end() }

    /// 让某个屏幕的遮罩成为键盘焦点
    func focus(_ overlay: OverlayView) {
        guard let w = overlay.window else { return }
        if !w.isKeyWindow { w.makeKey() }
        w.makeFirstResponder(overlay)
    }

    func canHover(_ overlay: OverlayView) -> Bool {
        activeOverlay == nil || activeOverlay === overlay
    }
}

/// 延时截图的倒计时提示（玻璃圆角方块，屏幕中间）
@MainActor
final class CountdownHUD {
    private var remaining: Int
    private let done: () -> Void
    private var window: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?

    init(seconds: Int, done: @escaping () -> Void) {
        remaining = seconds
        self.done = done
    }

    func start() {
        let size = NSSize(width: 120, height: 120)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let v = screen?.frame ?? .zero
        let w = NSPanel(contentRect: CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = .statusBar
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.hasShadow = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        let content = NSView(frame: root.bounds)
        label.font = .monospacedDigitSystemFont(ofSize: 56, weight: .bold)
        label.alignment = .center
        label.frame = CGRect(x: 0, y: 30, width: size.width, height: 66)
        content.addSubview(label)
        let hint = NSTextField(labelWithString: "秒后截图")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.frame = CGRect(x: 0, y: 14, width: size.width, height: 16)
        content.addSubview(hint)
        let backdrop = GlassBackdrop.make(cornerRadius: 28, content: content)
        backdrop.frame = root.bounds
        root.addSubview(backdrop)
        w.contentView = root
        w.orderFrontRegardless()
        window = w
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
    }

    private func update() { label.stringValue = "\(remaining)" }

    private func step() {
        remaining -= 1
        if remaining <= 0 {
            timer?.invalidate()
            window?.orderOut(nil)
            window = nil
            done()
        } else {
            update()
        }
    }
}
