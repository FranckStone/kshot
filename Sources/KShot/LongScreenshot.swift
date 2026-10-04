import AppKit
import ApplicationServices

/// 长截图（滚动截图）会话：自动向区域发送滚轮事件，逐帧抓取并拼接。
@MainActor
final class LongScreenshotSession {
    nonisolated(unsafe) static var current: LongScreenshotSession?

    private let screen: NSScreen
    private let region: CGRect          // 屏幕局部坐标（左上原点，pt）
    private let stitcher = ImageStitcher()
    private var panel: LongShotPanel!
    private var running = false
    private var frames = 0
    private var staticCount = 0
    private let autoScroll: Bool
    private var excluded: Set<CGWindowID> = []
    /// 调试：用自定义方式滚动（替代发送系统滚轮事件）
    var customScroller: ((CGFloat) -> Void)?
    /// 调试：完成后把结果写到这个路径
    var debugOutputURL: URL?
    /// 调试：完成回调
    var onFinish: ((CGImage) -> Void)?

    private var capturer: RegionCapturer?

    /// 每次滚动的距离（pt），取区域高度的 45%，保证帧间有足够重叠
    private var scrollStep: CGFloat { (region.height * 0.45).rounded() }

    init(screen: NSScreen, region: CGRect, forceAuto: Bool = false) {
        self.screen = screen
        self.region = region
        if forceAuto {
            autoScroll = true
        } else {
            // 需要“辅助功能”权限才能发送滚轮事件；没有时退化为手动滚动
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            autoScroll = AXIsProcessTrustedWithOptions(opts)
        }
    }

    func start() {
        LongScreenshotSession.current = self
        running = true
        let regionCocoa = screen.cocoaRect(fromLocal: region)
        panel = LongShotPanel(near: regionCocoa, screen: screen)
        panel.onFinish = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        excluded = [CGWindowID(panel.windowNumber)]
        panel.setStatus(autoScroll ? "正在自动滚动并拼接…" : "未授予“辅助功能”权限：请手动滚动内容，完成后点“完成”")
        Log.info("longshot start region=\(region) auto=\(autoScroll)")
        Task { @MainActor in await loop() }
    }

    private func loop() async {
        do {
            capturer = try await RegionCapturer(screen: screen, localRect: region, excludingWindowIDs: excluded)
        } catch {
            fail("抓屏失败：\(error.localizedDescription)")
            return
        }
        // 第一帧
        guard let first = await settledFrame() else { fail("抓屏失败"); return }
        _ = stitcher.push(frame: first)
        frames = 1
        panel.setProgress(frames: frames, height: stitcher.totalHeight)

        while running {
            if autoScroll {
                postScroll()
                try? await Task.sleep(for: .milliseconds(120))
            } else {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard running, let frame = await settledFrame() else { continue }
            let expected = Int(scrollStep * screen.backingScaleFactor)
            switch stitcher.push(frame: frame, expectedShift: autoScroll ? expected : 0) {
            case .appended(let rows):
                frames += 1
                staticCount = 0
                Log.info("longshot appended \(rows) px, total \(stitcher.totalHeight)")
                panel.setProgress(frames: frames, height: stitcher.totalHeight)
            case .unchanged:
                staticCount += 1
                if autoScroll && staticCount >= 2 {
                    Log.info("longshot reached bottom")
                    finish()
                }
            case .noMatch:
                staticCount = 0
                Log.info("longshot no match")
            }
        }
    }

    /// 每帧忽略底部的几个像素：区域贴着窗口底边时，窗口圆角/阴影会在每个接缝处留下痕迹
    private static let bottomTrimPx = 26

    /// 抓一帧并在后台算好行签名
    private func captureFrame() async -> ImageStitcher.Frame? {
        guard let capturer, let raw = try? await capturer.capture() else { return nil }
        let trim = Self.bottomTrimPx
        let img = raw.height > trim * 4 ? (raw.cropping(to: CGRect(x: 0, y: 0, width: raw.width, height: raw.height - trim)) ?? raw) : raw
        return await Task.detached(priority: .userInitiated) { ImageStitcher.makeFrame(img) }.value
    }

    /// 连续抓帧直到画面静止（滚动动画结束），最多等约 1.2 秒
    private func settledFrame() async -> ImageStitcher.Frame? {
        guard var last = await captureFrame() else { return nil }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(90))
            guard running, let next = await captureFrame() else { return last }
            if ImageStitcher.isSame(last, next) { return next }
            last = next
        }
        return last
    }

    /// 向区域中心发送向下滚动的滚轮事件
    private func postScroll() {
        if let customScroller { customScroller(scrollStep); return }
        let center = screen.cgPoint(fromLocal: region.center)
        let amount = Int32(scrollStep)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -amount, wheel2: 0, wheel3: 0) else { return }
        // 标记为连续（触控板式）像素滚动，应用会精确按像素量滚动而不是加速
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.location = center
        event.post(tap: .cghidEventTap)
    }

    private func finish() {
        guard running else { return }
        running = false
        panel.orderOut(nil)
        LongScreenshotSession.current = nil
        guard let image = stitcher.compose() else { fail("没有拼接出内容"); return }
        if let debugOutputURL, let data = Exporter.pngData(image) { try? data.write(to: debugOutputURL) }
        onFinish?(image)
        Exporter.copyToClipboard(image)
        let win = ImageEditorWindow(image: image, scale: screen.backingScaleFactor, screen: screen, title: "长截图")
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("longshot done: \(image.width)x\(image.height), frames=\(frames)")
    }

    private func cancel() {
        running = false
        panel.orderOut(nil)
        LongScreenshotSession.current = nil
        Log.info("longshot cancelled")
    }

    private func fail(_ message: String) {
        running = false
        panel.orderOut(nil)
        LongScreenshotSession.current = nil
        let alert = NSAlert()
        alert.messageText = "长截图失败"
        alert.informativeText = message
        alert.runModal()
    }
}

/// 长截图进行中的控制面板（玻璃）
final class LongShotPanel: NSWindow {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    private let status = NSTextField(labelWithString: "")
    private let progress = NSTextField(labelWithString: "")

    init(near region: CGRect, screen: NSScreen) {
        let size = NSSize(width: 360, height: 92)
        // 放在区域下方；放不下就放上方；再不行放区域内底部
        var origin = CGPoint(x: region.midX - size.width / 2, y: region.minY - size.height - 12)
        let v = screen.visibleFrame
        if origin.y < v.minY { origin.y = region.maxY + 12 }
        if origin.y + size.height > v.maxY { origin.y = region.minY + 16 }
        origin.x = min(max(v.minX + 8, origin.x), v.maxX - size.width - 8)
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
        let backdrop = GlassBackdrop.make(cornerRadius: 16, content: content)
        backdrop.frame = root.bounds
        root.addSubview(backdrop)
        contentView = root

        let title = NSTextField(labelWithString: "长截图")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = CGRect(x: 16, y: size.height - 32, width: 100, height: 20)
        content.addSubview(title)

        progress.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        progress.textColor = .secondaryLabelColor
        progress.alignment = .right
        progress.frame = CGRect(x: size.width - 196, y: size.height - 31, width: 180, height: 18)
        content.addSubview(progress)

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.frame = CGRect(x: 16, y: size.height - 54, width: size.width - 32, height: 18)
        content.addSubview(status)

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelAction))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = CGRect(x: size.width - 176, y: 10, width: 76, height: 28)
        content.addSubview(cancel)

        let finish = NSButton(title: "完成", target: self, action: #selector(finishAction))
        finish.bezelStyle = .rounded
        finish.keyEquivalent = "\r"
        finish.frame = CGRect(x: size.width - 92, y: 10, width: 76, height: 28)
        if #available(macOS 26.0, *) { finish.bezelColor = .accentGreen }
        content.addSubview(finish)

        let hint = NSTextField(labelWithString: "⏎ 完成 · Esc 取消")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.frame = CGRect(x: 16, y: 15, width: 160, height: 16)
        content.addSubview(hint)
    }

    override var canBecomeKey: Bool { true }

    func setStatus(_ s: String) { status.stringValue = s }
    func setProgress(frames: Int, height: Int) { progress.stringValue = "已拼接 \(frames) 屏 · \(height) px" }

    @objc private func cancelAction() { onCancel?() }
    @objc private func finishAction() { onFinish?() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: onFinish?()
        default: super.keyDown(with: event)
        }
    }
}
