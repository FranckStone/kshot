import AppKit
import ApplicationServices

/// 长截图（滚动截图）会话：用户自己滚动（或可选自动滚动），程序持续抓帧并实时拼接、预览。
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
    private var noMatchCount = 0
    private var autoScroll = false
    private var excluded: Set<CGWindowID> = []
    private var capturer: RegionCapturer?
    private var lastHint = ""

    /// 调试：用自定义方式滚动（替代发送系统滚轮事件）
    var customScroller: (@MainActor (CGFloat) -> Void)?
    /// 调试：完成后把结果写到这个路径
    var debugOutputURL: URL?
    /// 调试：完成回调
    var onFinish: ((CGImage) -> Void)?

    /// 每帧保存到 ~/Library/Logs/KShot-longshot/，便于排查拼接问题
    private let dumpDir: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/KShot-longshot")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var dumpIndex = 0

    /// 自动滚动时每次的距离（pt）：区域高度的 30%，重叠充足
    private var scrollStep: CGFloat { (region.height * 0.3).rounded() }

    init(screen: NSScreen, region: CGRect, forceAuto: Bool = false) {
        self.screen = screen
        self.region = region
        autoScroll = forceAuto
    }

    func start() {
        LongScreenshotSession.current = self
        running = true
        let regionCocoa = screen.cocoaRect(fromLocal: region)
        panel = LongShotPanel(near: regionCocoa, screen: screen)
        panel.onFinish = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onToggleAuto = { [weak self] in self?.toggleAuto() }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        excluded = [CGWindowID(panel.windowNumber)]
        panel.setAuto(autoScroll)
        panel.setStatus("在区域内用触控板或滚轮向下滚动，内容会实时拼接到预览里")
        Log.info("longshot start region=\(region) auto=\(autoScroll)")
        Task { @MainActor in await loop() }
    }

    private func toggleAuto() {
        if !autoScroll {
            // 自动滚动需要“辅助功能”权限来发送滚轮事件
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            guard customScroller != nil || AXIsProcessTrustedWithOptions(opts) else {
                panel.setStatus("自动滚动需要在“系统设置 › 隐私与安全性 › 辅助功能”里勾选 KShot，勾选后再点一次")
                return
            }
        }
        autoScroll.toggle()
        staticCount = 0
        panel.setAuto(autoScroll)
        panel.setStatus(autoScroll ? "正在自动滚动…到底后自动停止，也可随时按回车完成" : "已切回手动：请自己滚动内容")
    }

    private func loop() async {
        do {
            capturer = try await RegionCapturer(screen: screen, localRect: region, excludingWindowIDs: excluded)
        } catch {
            fail("抓屏失败：\(error.localizedDescription)")
            return
        }
        guard let first = await captureFrame() else { fail("抓屏失败"); return }
        dump(first.image)
        _ = stitcher.push(frame: first)
        frames = 1
        updatePanel()

        while running {
            if autoScroll {
                postScroll()
                try? await Task.sleep(for: .milliseconds(160))
            } else {
                // 手动模式尽量高帧率，快速滑动也能接上
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard running, let frame = await captureFrame() else { continue }
            let expected = autoScroll ? Int(scrollStep * screen.backingScaleFactor) : 0
            switch stitcher.push(frame: frame, expectedShift: expected) {
            case .appended(let rows):
                frames += 1
                staticCount = 0
                noMatchCount = 0
                dump(frame.image)
                let d = stitcher.lastDiagnostics
                Log.info("longshot appended \(rows) px (score \(String(format: "%.2f", d.score)), header \(d.header), footer \(d.footer)), total \(stitcher.totalHeight)")
                hint("")
                updatePanel()
            case .unchanged:
                staticCount += 1
                if autoScroll && staticCount >= 3 {
                    Log.info("longshot reached bottom")
                    finish()
                }
            case .scrolledUp:
                hint("往回滚了，继续向下滚动即可")
            case .noMatch:
                staticCount = 0
                noMatchCount += 1
                // 偶尔一帧接不上多半是渲染中的撕裂画面，连续多帧才提示
                guard noMatchCount >= (autoScroll ? 3 : 6) else { continue }
                dump(frame.image)
                let d = stitcher.lastDiagnostics
                if noMatchCount <= 8 || noMatchCount % 50 == 0 {
                    Log.info("longshot no match x\(noMatchCount): \(d.reason) shift \(d.shift) score \(String(format: "%.2f", d.score)) halves \(String(format: "%.2f/%.2f", d.halves.0, d.halves.1)) header \(d.header) footer \(d.footer)")
                }
                hint(autoScroll ? "画面变化太大，已暂停自动滚动" : "滚得太快，接不上了：请往回滚一点再继续")
                if autoScroll { autoScroll = false; panel.setAuto(false) }
            }
        }
    }

    private func hint(_ s: String) {
        guard s != lastHint else { return }
        lastHint = s
        if !s.isEmpty { panel.setStatus(s) }
        else if !autoScroll { panel.setStatus("继续向下滚动；完成后按回车") }
    }

    private func updatePanel() {
        panel.setProgress(frames: frames, height: stitcher.totalHeight)
        if let preview = stitcher.preview(minHeight: Int(region.height * screen.backingScaleFactor * 1.5)) {
            panel.setPreview(preview, scale: screen.backingScaleFactor)
        }
    }

    /// 每帧忽略底部的几个像素：区域贴着窗口底边时，窗口圆角/阴影会在每个接缝处留下痕迹
    private static let bottomTrimPx = 26

    private func captureFrame() async -> ImageStitcher.Frame? {
        guard let capturer, let raw = try? await capturer.capture() else { return nil }
        let trim = Self.bottomTrimPx
        let img = raw.height > trim * 4 ? (raw.cropping(to: CGRect(x: 0, y: 0, width: raw.width, height: raw.height - trim)) ?? raw) : raw
        return await Task.detached(priority: .userInitiated) { ImageStitcher.makeFrame(img) }.value
    }

    private func dump(_ image: CGImage) {
        dumpIndex += 1
        let url = dumpDir.appendingPathComponent(String(format: "frame-%02d.png", dumpIndex))
        Task.detached(priority: .background) {
            if let data = Exporter.pngData(image) { try? data.write(to: url) }
        }
    }

    /// 向区域中心发送向下滚动的滚轮事件（连续像素滚动，应用按精确像素量滚动、不做动画）
    private func postScroll() {
        if let customScroller { customScroller(scrollStep); return }
        let center = screen.cgPoint(fromLocal: region.center)
        let amount = Int32(scrollStep)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -amount, wheel2: 0, wheel3: 0) else { return }
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
        if let data = Exporter.pngData(image) { try? data.write(to: dumpDir.appendingPathComponent("result.png")) }
        onFinish?(image)
        Exporter.copyToClipboard(image)
        let win = ImageEditorWindow(image: image, scale: screen.backingScaleFactor, screen: screen, title: "长截图")
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("longshot done: \(image.width)x\(image.height), frames=\(frames)")
    }

    func debugFinish() { finish() }

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

/// 长截图进行中的控制面板（玻璃）：实时预览 + 状态 + 自动/手动切换
final class LongShotPanel: NSWindow {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleAuto: (() -> Void)?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSTextField(labelWithString: "")
    private let preview = NSImageView()
    private var autoButton: NSButton!
    private static let size = NSSize(width: 300, height: 440)

    init(near region: CGRect, screen: NSScreen) {
        let size = LongShotPanel.size
        // 放在区域右侧；放不下就放左侧；再不行就贴屏幕右边
        let v = screen.visibleFrame
        var origin = CGPoint(x: region.maxX + 16, y: region.maxY - size.height)
        if origin.x + size.width > v.maxX { origin.x = region.minX - size.width - 16 }
        if origin.x < v.minX { origin.x = v.maxX - size.width - 8 }
        origin.y = min(max(v.minY + 8, origin.y), v.maxY - size.height - 8)
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

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignBottom
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8
        preview.layer?.masksToBounds = true
        preview.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        preview.frame = CGRect(x: 16, y: 112, width: size.width - 32, height: size.height - 160)
        content.addSubview(preview)

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.frame = CGRect(x: 16, y: 54, width: size.width - 32, height: 50)
        content.addSubview(status)

        autoButton = NSButton(title: "自动滚动", target: self, action: #selector(toggleAuto))
        autoButton.bezelStyle = .rounded
        autoButton.setButtonType(.pushOnPushOff)
        autoButton.frame = CGRect(x: 16, y: 14, width: 92, height: 28)
        content.addSubview(autoButton)

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelAction))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = CGRect(x: size.width - 164, y: 14, width: 70, height: 28)
        content.addSubview(cancel)

        let finish = NSButton(title: "完成", target: self, action: #selector(finishAction))
        finish.bezelStyle = .rounded
        finish.keyEquivalent = "\r"
        finish.frame = CGRect(x: size.width - 86, y: 14, width: 70, height: 28)
        if #available(macOS 26.0, *) { finish.bezelColor = .accentGreen }
        content.addSubview(finish)
    }

    override var canBecomeKey: Bool { true }

    func setStatus(_ s: String) { status.stringValue = s }
    func setProgress(frames: Int, height: Int) { progress.stringValue = "已拼接 \(frames) 屏 · \(height) px" }
    func setAuto(_ on: Bool) { autoButton.state = on ? .on : .off }
    func setPreview(_ image: CGImage, scale: CGFloat) {
        preview.image = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    @objc private func toggleAuto() { onToggleAuto?() }
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
