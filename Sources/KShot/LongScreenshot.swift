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

    /// 每次滚动的距离（pt），取区域高度的一半，保证帧间有足够重叠
    private var scrollStep: CGFloat { (region.height * 0.5).rounded() }

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
        // 第一帧
        guard let first = await capture() else { fail("抓屏失败"); return }
        _ = stitcher.push(first)
        frames = 1
        panel.setProgress(frames: frames, height: stitcher.totalHeight)

        while running {
            if autoScroll {
                postScroll()
                try? await Task.sleep(for: .milliseconds(450))
            } else {
                try? await Task.sleep(for: .milliseconds(350))
            }
            guard running, let img = await capture() else { continue }
            let expected = Int(scrollStep * screen.backingScaleFactor)
            switch stitcher.push(img, expectedShift: autoScroll ? expected : 0) {
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

    private func capture() async -> CGImage? {
        guard let img = try? await ScreenCapturer.captureRegion(screen: screen, localRect: region, excludingWindowIDs: excluded) else { return nil }
        let trim = Self.bottomTrimPx
        guard img.height > trim * 4 else { return img }
        return img.cropping(to: CGRect(x: 0, y: 0, width: img.width, height: img.height - trim))
    }

    /// 向区域中心发送向下滚动的滚轮事件
    private func postScroll() {
        if let customScroller { customScroller(scrollStep); return }
        let center = screen.cgPoint(fromLocal: region.center)
        let amount = Int32(scrollStep)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -amount, wheel2: 0, wheel3: 0) else { return }
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
        let win = LongShotResultWindow(image: image, screen: screen)
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

/// 长截图结果窗口：可滚动预览 + 复制 / 保存 / 钉住 / 关闭
final class LongShotResultWindow: NSWindow {
    private let cgImage: CGImage
    nonisolated(unsafe) private static var all: [LongShotResultWindow] = []

    init(image: CGImage, screen: NSScreen) {
        cgImage = image
        let scale = screen.backingScaleFactor
        let imgPt = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let v = screen.visibleFrame
        let width = min(imgPt.width + 40, v.width * 0.85)
        let height = min(imgPt.height + 96, v.height * 0.88)
        let size = NSSize(width: width, height: height)
        let origin = CGPoint(x: v.midX - width / 2, y: v.midY - height / 2)
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
        let backdrop = GlassBackdrop.make(cornerRadius: 18, content: content)
        backdrop.frame = root.bounds
        root.addSubview(backdrop)
        contentView = root

        let title = NSTextField(labelWithString: "长截图  \(image.width) × \(image.height)")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = CGRect(x: 20, y: size.height - 36, width: 400, height: 20)
        content.addSubview(title)

        let scroll = NSScrollView(frame: CGRect(x: 16, y: 52, width: size.width - 32, height: size.height - 100))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.masksToBounds = true
        let imageView = NSImageView(frame: CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: imgPt.height * (scroll.contentSize.width / imgPt.width)))
        imageView.image = NSImage(cgImage: image, size: imgPt)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTop
        scroll.documentView = imageView
        content.addSubview(scroll)

        func button(_ title: String, _ action: Selector, x: CGFloat, width: CGFloat = 76) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.frame = CGRect(x: x, y: 12, width: width, height: 28)
            content.addSubview(b)
            return b
        }
        let close = button("关闭", #selector(closeWindow), x: size.width - 268)
        close.keyEquivalent = "\u{1b}"
        _ = button("保存…", #selector(save), x: size.width - 184)
        let copy = button("复制", #selector(copyImage), x: size.width - 100)
        copy.keyEquivalent = "\r"
        if #available(macOS 26.0, *) { copy.bezelColor = .accentGreen }

        let hint = NSTextField(labelWithString: "已复制到剪贴板 · ⏎ 再次复制 · ⌘S 保存 · Esc 关闭")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.frame = CGRect(x: 20, y: 17, width: 340, height: 16)
        content.addSubview(hint)

        LongShotResultWindow.all.append(self)
    }

    override var canBecomeKey: Bool { true }

    @objc private func copyImage() { Exporter.copyToClipboard(cgImage) }
    @objc private func save() { Exporter.save(cgImage) { _ in } }
    @objc private func closeWindow() {
        orderOut(nil)
        LongShotResultWindow.all.removeAll { $0 === self }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closeWindow(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" { save(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copyImage(); return }
        super.keyDown(with: event)
    }
}
