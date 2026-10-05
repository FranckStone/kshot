import AppKit
import ScreenCaptureKit
import VideoToolbox

/// 用 SCStream 连续抓取屏幕上的一个区域（最高 60 帧/秒），每帧在后台算好行签名后回调。
final class RegionStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "kshot.regionstream", qos: .userInteractive)
    private let onFrame: @Sendable (ImageStitcher.Frame) -> Void
    private let trimBottom: Int
    private var busy = false

    /// localRect：屏幕局部坐标（左上原点、pt）；excludeOwnApp：排除整个 KShot（演示时只按窗口号排除面板）
    @MainActor
    init(screen: NSScreen, localRect: CGRect, excludingWindowIDs: Set<CGWindowID>, excludeOwnApp: Bool,
         trimBottom: Int, onFrame: @escaping @Sendable (ImageStitcher.Frame) -> Void) async throws {
        self.onFrame = onFrame
        self.trimBottom = trimBottom
        super.init()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.noDisplays
        }
        let me = Bundle.main.bundleIdentifier ?? ""
        let myApps = content.applications.filter { $0.bundleIdentifier == me }
        let filter: SCContentFilter
        if excludeOwnApp, !myApps.isEmpty {
            filter = SCContentFilter(display: display, excludingApplications: myApps, exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { excludingWindowIDs.contains($0.windowID) })
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
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.info("region stream started \(config.width)x\(config.height), exclude apps=\(myApps.count)")
    }

    private var stopped = false

    func stop() {
        queue.sync { stopped = true }
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    /// 在回调队列上同步执行
    func queueSync(_ body: () -> Void) { queue.sync(execute: body) }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("region stream stopped with error: \(error)")
    }

    private var rawCounts: [Int: Int] = [:]
    private var lastCountLog = Date()

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if let att = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let st = att.first?[.status] as? Int {
            rawCounts[st, default: 0] += 1
            let total = rawCounts.values.reduce(0, +)
            if total % 20 == 0 || Date().timeIntervalSince(lastCountLog) > 1 {
                lastCountLog = Date()
                Log.info("region stream raw status counts \(rawCounts) busy=\(busy)")
            }
        }
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard !stopped else { return }
        // 处理不过来时丢帧，保证始终处理最新的画面
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cg)
        guard let raw = cg else { return }
        // 必须拷贝到自己的内存：VT 生成的图像仍引用 ScreenCaptureKit 的缓冲池，
        // 拼接时保留的裁剪条带会一直占着这些缓冲，几帧后捕获流就会停止出帧。
        let w = raw.width
        let h = raw.height > trimBottom * 4 ? raw.height - trimBottom : raw.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // 只画上面 h 行（CG 坐标左下原点：把原图向下平移 trim 行）
        ctx.draw(raw, in: CGRect(x: 0, y: h - raw.height, width: w, height: raw.height))
        guard let image = ctx.makeImage() else { return }
        guard let frame = ImageStitcher.makeFrame(image) else { return }
        onFrame(frame)
    }
}
