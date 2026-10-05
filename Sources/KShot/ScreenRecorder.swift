import AppKit
import AVFoundation
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 区域录屏：SCStream → AVAssetWriter（H.264 MP4），可选导出 GIF
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Format: Int { case mp4, gif }

    @MainActor static var current: ScreenRecorder?
    @MainActor static var isRecording: Bool { current != nil }

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "kshot.recorder", qos: .userInitiated)
    private var sessionStarted = false
    private var stopped = false
    private(set) var frameCount = 0
    private let tempURL: URL
    private let pixelSize: CGSize

    @MainActor private var panel: RecordingPanel?
    @MainActor private var border: RecordingBorder?
    @MainActor private var startDate = Date()
    @MainActor private var tick: Timer?
    @MainActor var format: Format = Format(rawValue: UserDefaults.standard.integer(forKey: "record.format")) ?? .mp4 {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "record.format") }
    }
    /// 调试：结束后回调输出文件
    @MainActor var onFinished: ((URL?) -> Void)?

    private init(pixelSize: CGSize) {
        self.pixelSize = pixelSize
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("KShot-\(UUID().uuidString).mp4")
        super.init()
    }

    /// region：屏幕局部坐标（左上原点，pt）
    @MainActor
    @discardableResult
    static func start(screen: NSScreen, region: CGRect) -> ScreenRecorder? {
        guard current == nil else { return nil }
        let scale = screen.backingScaleFactor
        // H.264 要求宽高为偶数
        let pw = max(2, Int(region.width * scale) / 2 * 2)
        let ph = max(2, Int(region.height * scale) / 2 * 2)
        let rect = CGRect(x: region.minX, y: region.minY, width: CGFloat(pw) / scale, height: CGFloat(ph) / scale)
        let rec = ScreenRecorder(pixelSize: CGSize(width: pw, height: ph))
        current = rec
        let cocoa = screen.cocoaRect(fromLocal: rect)
        rec.border = RecordingBorder(around: cocoa)
        rec.border?.orderFrontRegardless()
        rec.panel = RecordingPanel(near: cocoa, screen: screen, recorder: rec)
        rec.panel?.orderFrontRegardless()
        Task { @MainActor in
            do {
                try await rec.begin(screen: screen, rect: rect)
                rec.startDate = Date()
                rec.tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                    Task { @MainActor in rec.panel?.setElapsed(Date().timeIntervalSince(rec.startDate)) }
                }
            } catch {
                Log.info("record start failed: \(error)")
                rec.teardownUI()
                current = nil
                Toast.show("录屏失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            }
        }
        return rec
    }

    @MainActor
    private func begin(screen: NSScreen, rect: CGRect) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw CaptureError.noDisplays }
        let me = Bundle.main.bundleIdentifier ?? ""
        let myApps = content.applications.filter { $0.bundleIdentifier == me }
        let filter = SCContentFilter(display: display, excludingApplications: myApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        config.showsCursor = Settings.recordShowsCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6

        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
        let bitrate = max(2_000_000, Int(pixelSize.width * pixelSize.height * 30 * 0.12))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw NSError(domain: "KShot", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建视频文件"]) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "KShot", code: 2) }
        self.writer = writer
        self.input = input

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.info("recording started \(Int(pixelSize.width))x\(Int(pixelSize.height)) -> \(tempURL.lastPathComponent)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, let writer, let input,
              let att = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int, raw == SCFrameStatus.complete.rawValue else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData, input.append(sampleBuffer) {
            frameCount += 1
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("recording stream stopped: \(error)")
        Task { @MainActor in self.stop(cancel: false) }
    }

    @MainActor
    private func teardownUI() {
        tick?.invalidate()
        tick = nil
        panel?.orderOut(nil)
        border?.orderOut(nil)
        panel = nil
        border = nil
    }

    /// 停止录制；cancel 时丢弃文件
    @MainActor
    func stop(cancel: Bool) {
        guard ScreenRecorder.current === self else { return }
        ScreenRecorder.current = nil
        teardownUI()
        let format = self.format
        let s = stream
        stream = nil
        Task { @MainActor in
            try? await s?.stopCapture()
            let ok: Bool = await withCheckedContinuation { cont in
                queue.async {
                    self.stopped = true
                    guard let writer = self.writer, self.sessionStarted else { cont.resume(returning: false); return }
                    self.input?.markAsFinished()
                    writer.finishWriting { cont.resume(returning: writer.status == .completed) }
                }
            }
            Log.info("recording stopped ok=\(ok) frames=\(frameCount) cancel=\(cancel)")
            guard ok, !cancel else {
                try? FileManager.default.removeItem(at: tempURL)
                if !cancel { Toast.show("没有录到画面", symbol: "exclamationmark.triangle.fill") }
                onFinished?(nil)
                return
            }
            await deliver(format: format)
        }
    }

    @MainActor
    private func deliver(format: Format) async {
        let dir = Settings.saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = Settings.fileName(ext: "x").replacingOccurrences(of: "截图", with: "录屏")
        let name = (base as NSString).deletingPathExtension
        var out: URL
        if format == .gif {
            out = Settings.uniqueURL(in: dir, name: name + ".gif")
            Toast.show("正在生成 GIF…", symbol: "hourglass", duration: 30)
            let ok = await GIFExporter.export(video: tempURL, to: out, fps: 12, maxWidth: 960)
            try? FileManager.default.removeItem(at: tempURL)
            guard ok else {
                Toast.show("GIF 生成失败", symbol: "exclamationmark.triangle.fill")
                onFinished?(nil)
                return
            }
        } else {
            out = Settings.uniqueURL(in: dir, name: name + ".mp4")
            do { try FileManager.default.moveItem(at: tempURL, to: out) } catch {
                Toast.show("保存录屏失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
                onFinished?(nil)
                return
            }
        }
        // 把文件放到剪贴板，可以直接粘贴到聊天 / 邮件里
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([out as NSURL])
        Shutter.play()
        Toast.show("录屏已保存：\(out.lastPathComponent)（文件已复制）", symbol: "film.fill", duration: 3)
        Log.info("recording saved \(out.path)")
        onFinished?(out)
    }
}

/// 把 MP4 转成循环播放的 GIF
enum GIFExporter {
    static func export(video: URL, to out: URL, fps: Double, maxWidth: CGFloat) async -> Bool {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration) else { return false }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds > 0 else { return false }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        let count = max(1, Int(seconds * fps))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else { return false }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary
        for i in 0..<count {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let (img, _) = try? await gen.image(at: t) {
                CGImageDestinationAddImage(dest, img, frameProps)
            }
        }
        return CGImageDestinationFinalize(dest)
    }
}

/// 录制区域外围的红色虚线框（不挡鼠标）
final class RecordingBorder: NSWindow {
    init(around rect: CGRect) {
        let inset: CGFloat = 3
        super.init(contentRect: rect.insetBy(dx: -inset, dy: -inset), styleMask: .borderless, backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = BorderView(frame: CGRect(origin: .zero, size: frame.size))
    }

    private final class BorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor(hex: 0xFA5151).setStroke()
            path.stroke()
        }
    }
}

/// 录制中的玻璃控制条：红点 + 计时 + 格式 + 停止 / 取消
final class RecordingPanel: NSPanel {
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let dot = NSView()
    private weak var recorder: ScreenRecorder?

    @MainActor
    init(near region: CGRect, screen: NSScreen, recorder: ScreenRecorder) {
        self.recorder = recorder
        let size = NSSize(width: 300, height: 44)
        let v = screen.visibleFrame
        var origin = CGPoint(x: region.midX - size.width / 2, y: region.minY - size.height - 12)
        if origin.y < v.minY + 8 { origin.y = region.maxY + 12 }
        if origin.y + size.height > v.maxY - 8 { origin.y = region.minY + 16 }
        origin.x = min(max(v.minX + 8, origin.x), v.maxX - size.width - 8)
        super.init(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        let content = NSView(frame: root.bounds)
        let backdrop = GlassBackdrop.make(cornerRadius: size.height / 2, content: content)
        backdrop.frame = root.bounds
        root.addSubview(backdrop)
        contentView = root

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(hex: 0xFA5151).cgColor
        dot.layer?.cornerRadius = 5
        dot.frame = CGRect(x: 18, y: (size.height - 10) / 2, width: 10, height: 10)
        content.addSubview(dot)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.frame = CGRect(x: 36, y: (size.height - 18) / 2, width: 60, height: 18)
        content.addSubview(timeLabel)

        let seg = NSSegmentedControl(labels: ["MP4", "GIF"], trackingMode: .selectOne, target: self, action: #selector(formatChanged(_:)))
        seg.selectedSegment = recorder.format.rawValue
        seg.controlSize = .small
        seg.frame = CGRect(x: 100, y: (size.height - 22) / 2, width: 96, height: 22)
        content.addSubview(seg)

        let stop = ToolButton(symbol: "stop.fill", tip: "停止并保存  ⌃⌘R", role: .prominent)
        stop.frame.origin = CGPoint(x: size.width - 6 - ToolbarView.buttonSize * 2 - 4, y: (size.height - ToolbarView.buttonSize) / 2)
        stop.target = self
        stop.action = #selector(stopPressed)
        content.addSubview(stop)
        let cancel = ToolButton(symbol: "xmark", tip: "取消录屏", role: .destructive)
        cancel.frame.origin = CGPoint(x: size.width - 6 - ToolbarView.buttonSize, y: (size.height - ToolbarView.buttonSize) / 2)
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        content.addSubview(cancel)
    }

    @MainActor
    func setElapsed(_ t: TimeInterval) {
        let s = Int(t)
        timeLabel.stringValue = String(format: "%02d:%02d", s / 60, s % 60)
        dot.alphaValue = Int(t * 2) % 2 == 0 ? 1 : 0.3
    }

    @objc private func formatChanged(_ sender: NSSegmentedControl) {
        MainActor.assumeIsolated { recorder?.format = ScreenRecorder.Format(rawValue: sender.selectedSegment) ?? .mp4 }
    }

    @objc private func stopPressed() { MainActor.assumeIsolated { recorder?.stop(cancel: false) } }
    @objc private func cancelPressed() { MainActor.assumeIsolated { recorder?.stop(cancel: true) } }
}
