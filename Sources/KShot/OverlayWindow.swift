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
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
