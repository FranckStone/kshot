import AppKit
import ScreenCaptureKit
import VideoToolbox

/// 用 SCStream 连续抓取屏幕上的一个区域（最高 60 帧/秒），每帧在后台算好行签名后回调。
final class RegionStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "kshot.regionstream", qos: .userInteractive)
    private let captureQueue = DispatchQueue(label: "kshot.regionstream.capture", qos: .userInteractive)
    private let onFrame: @Sendable (ImageStitcher.Frame, TimeInterval) -> Void
    private var lastFrame: ImageStitcher.Frame?
    private struct Capture: @unchecked Sendable { let image: CGImage?; let capturedAt: TimeInterval }
    private var processor: LatestFrameProcessor<Capture>!

    /// localRect：屏幕局部坐标（左上原点、pt）；excludeOwnApp：排除整个 KShot（演示时只按窗口号排除面板）
    @MainActor
    init(screen: NSScreen, localRect: CGRect, excludingWindowIDs: Set<CGWindowID>, excludeOwnApp: Bool,
         onFrame: @escaping @Sendable (ImageStitcher.Frame, TimeInterval) -> Void) async throws {
        self.onFrame = onFrame
        super.init()
        processor = LatestFrameProcessor(queue: queue, merge: { old, new in
            // 静止通知不能覆盖尚未处理的新画面；该画面只是持续到更晚的时间戳。
            Capture(image: new.image ?? old.image, capturedAt: new.capturedAt)
        }) { [weak self] capture in
            guard let self else { return }
            if let image = capture.image {
                guard let frame = ImageStitcher.makeFrame(image) else { return }
                self.lastFrame = frame
                self.onFrame(frame, capture.capturedAt)
            } else if let frame = self.lastFrame {
                self.onFrame(frame, capture.capturedAt)
            }
        }
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        // 刚显示的提示窗口可能尚未出现在 WindowServer 的快照里，等待其注册后再建过滤器。
        for _ in 0..<4 {
            let availableIDs = Set(content.windows.map(\.windowID))
            if excludingWindowIDs.isSubset(of: availableIDs) { break }
            try await Task.sleep(for: .milliseconds(50))
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.noDisplays
        }
        let me = Bundle.main.bundleIdentifier ?? ""
        let pid = ProcessInfo.processInfo.processIdentifier
        let myApps = content.applications.filter { $0.processID == pid || (!me.isEmpty && $0.bundleIdentifier == me) }
        let excludedWindows = content.windows.filter {
            excludingWindowIDs.contains($0.windowID) || (excludeOwnApp && $0.owningApplication?.processID == pid)
        }
        let filter: SCContentFilter
        if excludeOwnApp, !myApps.isEmpty {
            filter = SCContentFilter(display: display, excludingApplications: myApps, exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        }
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.sourceRect = localRect
        config.width = Int((localRect.width * scale).rounded())
        config.height = Int((localRect.height * scale).rounded())
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 4
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        self.stream = stream
        Log.info("region stream started \(config.width)x\(config.height), exclude apps=\(myApps.count) windows=\(excludedWindows.count) requested=\(excludingWindowIDs.count)")
    }

    @MainActor
    func stop() {
        processor.stop()
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    func enqueue(_ body: @escaping @Sendable () -> Void) { processor.enqueue(body) }
    func perform<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T { await processor.perform(body) }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("region stream stopped with error: \(error)")
    }

    private var rawCounts: [Int: Int] = [:]
    private var lastCountLog = Date()

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !processor.isStopped else { return }
        if let att = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let st = att.first?[.status] as? Int {
            rawCounts[st, default: 0] += 1
            let total = rawCounts.values.reduce(0, +)
            if total % 20 == 0 || Date().timeIntervalSince(lastCountLog) > 1 {
                lastCountLog = Date()
                Log.info("region stream raw status counts \(rawCounts)")
            }
        }
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int else { return }
        let capturedAt = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard capturedAt.isFinite else { return }
        // idle 是捕获流确认画面没有变化；保留时间戳，供自动滚动确认本次事件的结果。
        if statusRaw == SCFrameStatus.idle.rawValue {
            processor.submit(Capture(image: nil, capturedAt: capturedAt))
            return
        }
        guard statusRaw == SCFrameStatus.complete.rawValue,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cg)
        guard let raw = cg else { return }
        // 必须拷贝到自己的内存：VT 生成的图像仍引用 ScreenCaptureKit 的缓冲池，
        // 拼接时保留的裁剪条带会一直占着这些缓冲，几帧后捕获流就会停止出帧。
        guard let image = Self.copyImage(raw) else { return }
        processor.submit(Capture(image: image, capturedAt: capturedAt))
    }

    /// 保留完整选区；接缝使用画面中部的像素，末屏底部不能永久裁掉。
    static func copyImage(_ raw: CGImage) -> CGImage? {
        let w = raw.width, h = raw.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(raw, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
