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
    private var regionOutline: LongShotRegionWindow?
    private var running = false
    private var frames = 0
    private var autoScroll = false
    private var excluded: Set<CGWindowID> = []
    private var lastHint = ""

    /// 调试：用自定义方式滚动（替代发送系统滚轮事件）
    var customScroller: (@MainActor (CGFloat) -> Void)?
    /// 调试：完成后把结果写到这个路径
    var debugOutputURL: URL?
    /// 调试：完成回调
    var onFinish: ((CGImage) -> Void)?
    /// 调试：演示脚本在自动暂停后模拟按下完成。
    var onAutoPause: (() -> Void)?

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
        let outline = LongShotRegionWindow(region: regionCocoa)
        regionOutline = outline
        outline.orderFrontRegardless()
        panel = LongShotPanel(near: regionCocoa, screen: screen)
        panel.onFinish = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onToggleAuto = { [weak self] in self?.toggleAuto() }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        excluded = [CGWindowID(panel.windowNumber), CGWindowID(outline.windowNumber)]
        panel.setAuto(autoScroll)
        panel.setStatus("在区域内用触控板或滚轮向下滚动，内容会实时拼接到预览里")
        Log.info("longshot start region=\(region) auto=\(autoScroll)")
        startTask = Task { @MainActor in await loop() }
    }

    private func toggleAuto() {
        guard running else { return }
        if !autoScroll {
            // 自动滚动需要“辅助功能”权限来发送滚轮事件
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            guard customScroller != nil || AXIsProcessTrustedWithOptions(opts) else {
                panel.setStatus("自动滚动需要在“系统设置 › 隐私与安全性 › 辅助功能”里勾选 KShot，勾选后再点一次")
                return
            }
        }
        setAuto(!autoScroll)
        panel.setStatus(autoScroll ? "正在自动滚动…画面静止时暂停，按回车完成" : "已切回手动：请自己滚动内容")
    }

    private var stream: RegionStream?
    private var autoTimer: Timer?
    private var autoProgress = LongShotAutoScroll()
    private var startTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var dumpNoMatchBudget = 12

    private func loop() async {
        do {
            let newStream = try await RegionStream(screen: screen, localRect: region, excludingWindowIDs: excluded,
                                                   excludeOwnApp: customScroller == nil) { [weak self] frame, capturedAt in
                self?.process(frame, capturedAt: capturedAt)
            }
            stream = newStream
            guard running else { newStream.stop(); return }
            setAuto(autoScroll)
        } catch {
            guard running else { return }
            fail("抓屏失败：\(error.localizedDescription)")
            return
        }
        // 静止或抓帧停顿时只暂停自动滚动，保留会话让用户继续或完成。
        autoTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, self.autoScroll else { return }
                switch self.autoProgress.next(at: ProcessInfo.processInfo.systemUptime) {
                case .scroll:
                    self.postScroll()
                case .pauseStationary:
                    self.setAuto(false)
                    self.hint("画面已停止变化，已暂停自动滚动；可继续滚动或按回车完成")
                    self.onAutoPause?()
                case .pauseStalled:
                    self.setAuto(false)
                    self.hint("未收到滚动后的画面，已暂停自动滚动；可重试或按回车完成")
                    self.onAutoPause?()
                case .wait:
                    break
                }
            }
        }
    }

    /// 捕获队列上的状态（只在 RegionStream 的回调队列里读写）
    nonisolated(unsafe) private var workerAuto = false
    nonisolated(unsafe) private var workerExpected = 0
    nonisolated(unsafe) private var workerFrames = 0
    nonisolated(unsafe) private var workerNoMatch = 0

    /// 在捕获队列上拼接并生成缩略图（不占主线程），每次成功拼接即更新预览。
    nonisolated(unsafe) private var procTotal = 0.0
    nonisolated(unsafe) private var procCount = 0
    nonisolated(unsafe) private var sourceCounts: [String: Int] = [:]

    nonisolated private func process(_ frame: ImageStitcher.Frame, capturedAt: TimeInterval) {
        let t0 = Date()
        defer {
            procTotal += Date().timeIntervalSince(t0); procCount += 1
            sourceCounts[stitcher.lastDiagnostics.reason, default: 0] += 1
        }
        let outcome: ImageStitcher.Outcome
        if workerFrames == 0 {
            outcome = stitcher.push(frame: frame)
        } else {
            outcome = stitcher.push(frame: frame, expectedShift: workerAuto ? workerExpected : 0)
        }
        do {
            // 逐帧记录，便于事后定位拼接错误（unchanged 太多，不记）
            let shouldLog: Bool
            switch outcome {
            case .unchanged: shouldLog = false
            case .noMatch: shouldLog = workerNoMatch == 0 || workerNoMatch % 60 == 0
            default: shouldLog = true
            }
            if shouldLog {
                let d = stitcher.lastDiagnostics
                Log.info("frame \(outcome) shift=\(d.shift) rough=\(String(format: "%.1f", d.rough)) diff=\(String(format: "%.2f", d.score)) src=\(d.reason) \(stitcher.debugState)")
            }
        }
        var preview: CGImage?
        switch outcome {
        case .appended:
            workerFrames += 1
            workerNoMatch = 0
            preview = stitcher.preview()
        case .noMatch:
            workerNoMatch += 1
        default:
            workerNoMatch = 0
            break
        }
        let total = stitcher.previewHeight
        let diag = stitcher.lastDiagnostics
        let noMatch = workerNoMatch
        let image = frame.image
        Task { @MainActor in self.apply(outcome, total: total, diag: diag, noMatch: noMatch, preview: preview, image: image, capturedAt: capturedAt) }
    }

    private func apply(_ outcome: ImageStitcher.Outcome, total: Int, diag: ImageStitcher.Diagnostics, noMatch: Int, preview: CGImage?, image: CGImage, capturedAt: TimeInterval) {
        guard running else { return }
        if autoScroll {
            let observation: LongShotAutoScroll.Observation
            switch outcome {
            case .unchanged: observation = .unchanged
            case .noMatch: observation = .unmatched
            default: observation = .moved
            }
            autoProgress.observe(observation, capturedAt: capturedAt)
        }
        switch outcome {
        case .appended(let rows):
            frames += 1
            if frames <= 3 || frames % 10 == 0 { dump(image) }
            if frames % 5 == 0 || rows > 200 {
                Log.info("longshot appended \(rows) px (score \(String(format: "%.2f", diag.score)), header \(diag.header), footer \(diag.footer)), total \(total)")
            }
            hint("")
            panel.setProgress(frames: frames, height: total)
            if let preview { panel.setPreview(preview, scale: screen.backingScaleFactor) }
        case .unchanged:
            break
        case .scrolledUp:
            hint("往回滚了，继续向下滚动即可")
        case .noMatch:
            let threshold = autoScroll ? 3 : 8
            guard noMatch >= threshold else { return }
            if noMatch == threshold, dumpNoMatchBudget > 0 { dumpNoMatchBudget -= 1; dump(image) }
            if noMatch <= threshold + 2 || noMatch % 60 == 0 {
                Log.info("longshot no match x\(noMatch): \(diag.reason) shift \(diag.shift) score \(String(format: "%.2f", diag.score)) halves \(String(format: "%.2f/%.2f", diag.halves.0, diag.halves.1))")
            }
            hint(autoScroll ? "画面变化太大，已暂停自动滚动" : "滚得太快，接不上了：请往回滚一点再继续")
            if autoScroll { setAuto(false) }
        }
    }

    private func setAuto(_ on: Bool) {
        autoScroll = on
        autoProgress.begin(at: ProcessInfo.processInfo.systemUptime)
        let expected = Int(scrollStep * screen.backingScaleFactor)
        if let stream {
            stream.enqueue { self.workerAuto = on; self.workerExpected = expected }
        } else {
            workerAuto = on
            workerExpected = expected
        }
        panel.setAuto(on)
    }

    private func hint(_ s: String) {
        guard s != lastHint else { return }
        lastHint = s
        if !s.isEmpty { panel.setStatus(s) }
        else if !autoScroll { panel.setStatus("继续向下滚动；完成后按回车") }
    }

    private func dump(_ image: CGImage) {
        dumpIndex += 1
        let url = dumpDir.appendingPathComponent(String(format: "frame-%02d.png", dumpIndex))
        Task.detached(priority: .background) {
            if let data = Exporter.pngData(image) { try? data.write(to: url) }
        }
    }

    /// 停止捕获（保留 stream 对象以便之后在其队列上合成结果）
    private func stopStream() {
        regionOutline?.orderOut(nil)
        regionOutline = nil
        autoTimer?.invalidate()
        autoTimer = nil
        stream?.stop()
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
        let activeStream = stream
        let startup = startTask
        stopStream()
        panel.setStatus("正在合成长截图…可点取消")
        let outputURL = debugOutputURL
        let resultURL = dumpDir.appendingPathComponent("result.png")
        finishTask = Task { @MainActor in
            defer {
                finishTask = nil
                stream = nil
                if LongScreenshotSession.current === self { LongScreenshotSession.current = nil }
            }
            let compose: @Sendable () -> (CGImage?, Data?, String) = {
                let image = self.stitcher.compose()
                let data = image.flatMap { Exporter.pngData($0) }
                if let data {
                    if let outputURL { try? data.write(to: outputURL) }
                    try? data.write(to: resultURL)
                }
                let stats = String(format: "avg %.1fms over %d frames, sources %@", self.procTotal / Double(max(1, self.procCount)) * 1000, self.procCount, self.sourceCounts.description)
                return (image, data, stats)
            }
            let result: (CGImage?, Data?, String)
            if activeStream == nil { await startup?.value }
            if let finalStream = activeStream ?? stream { result = await finalStream.perform(compose) }
            else { result = await Task.detached(priority: .userInitiated, operation: compose).value }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
            guard let image = result.0 else { fail("没有拼接出内容"); return }
            onFinish?(image)
            Exporter.copyToClipboard(image, preencodedPNG: result.1)
            let win = ImageEditorWindow(image: image, scale: screen.backingScaleFactor, screen: screen, title: "长截图")
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Log.info("longshot done: \(image.width)x\(image.height), frames=\(frames), \(result.2)")
        }
    }

    func debugFinish() { finish() }
    var debugPanelWindowID: CGWindowID { CGWindowID(panel.windowNumber) }

    private func cancel() {
        guard running || finishTask != nil else { return }
        running = false
        finishTask?.cancel()
        startTask?.cancel()
        stopStream()
        panel.orderOut(nil)
        if LongScreenshotSession.current === self { LongScreenshotSession.current = nil }
        Log.info("longshot cancelled")
    }

    private func fail(_ message: String) {
        running = false
        stopStream()
        panel.orderOut(nil)
        LongScreenshotSession.current = nil
        let alert = NSAlert()
        alert.messageText = "长截图失败"
        alert.informativeText = message
        alert.runModal()
    }
}

/// 捕获范围提示：透明且穿透鼠标，滚轮和点击仍交给下方应用。
final class LongShotRegionWindow: NSWindow {
    init(region: CGRect) {
        // 红线放在选区外侧，线与内容之间留 1pt，避免窗口过滤延迟时混进截图。
        let frame = region.insetBy(dx: -3, dy: -3)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let outline = NSView(frame: CGRect(origin: .zero, size: frame.size))
        outline.wantsLayer = true
        outline.layer?.borderColor = NSColor.systemRed.cgColor
        outline.layer?.borderWidth = 2
        contentView = outline
        setFrame(frame, display: false)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
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
