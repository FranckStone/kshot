import AppKit

/// 覆盖整块屏幕的无边框窗口
final class OverlayWindow: NSWindow {
    let overlayView: OverlayView

    init(shot: ScreenShot, windows: [WindowInfo], session: CaptureSession) {
        let frame = shot.screen.frame
        overlayView = OverlayView(frame: CGRect(origin: .zero, size: frame.size), shot: shot, windows: windows, session: session)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = CommandLine.arguments.contains("--low-level") ? .floating : .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = overlayView
        disableCursorRects()
        // 副屏：确保窗口正好盖住这块屏幕（不让系统把位置挪到主屏范围内）
        setFrame(frame, display: false)
    }

    /// 不让系统调整遮罩窗口的位置 / 大小（副屏在主屏上方或尺寸不同时，默认会被“修正”）
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
