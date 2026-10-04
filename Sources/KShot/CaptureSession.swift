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

    func begin() {
        guard !isActive else { return }
        starting = true
        Log.info("begin capture, preflight=\(CGPreflightScreenCaptureAccess())")
        previousApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            defer { starting = false }
            do {
                let shots = try await ScreenCapturer.captureAll()
                let wins = WindowFinder.onScreenWindows()
                Log.info("captured \(shots.count) screens, \(wins.count) windows")
                present(shots: shots, windows: wins)
            } catch {
                Log.info("capture failed: \(error)")
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
