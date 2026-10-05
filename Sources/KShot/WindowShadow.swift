import AppKit
import ScreenCaptureKit

/// 单个窗口截图：带系统阴影、背景透明（单击选中窗口且开启“窗口阴影”时使用）
enum WindowShadow {
    /// windowLocalRect：窗口在所在屏幕的局部坐标（左上原点、pt），用于把标注对齐到窗口上
    @MainActor
    static func capture(window: WindowInfo, windowLocalRect: CGRect, annotations: [Annotation], renderer: AnnotationRenderer) async -> CGImage? {
        guard let raw = await captureRaw(windowID: window.id) else { return nil }
        guard let core = opaqueCore(of: raw), core.width > 4 else {
            Log.info("window shadow: 找不到窗口主体")
            return nil
        }
        // 窗口主体在图里的像素尺寸 / 窗口的 pt 尺寸 = 像素比例
        let s = core.width / max(1, window.bounds.width)
        let w = raw.width, h = raw.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(raw, in: CGRect(x: 0, y: 0, width: w, height: h))
        if !annotations.isEmpty {
            // 翻转成左上原点，单位 pt，并把窗口左上角对齐到主体左上角
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: core.minX / s - windowLocalRect.minX, y: core.minY / s - windowLocalRect.minY)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            renderer.draw(annotations, clip: windowLocalRect, in: ctx)
            NSGraphicsContext.restoreGraphicsState()
        }
        Log.info("window shadow: raw=\(w)x\(h) core=\(core) scale=\(s)")
        return ctx.makeImage()
    }

    /// 用 ScreenCaptureKit 抓单个窗口（含阴影、透明背景）
    @MainActor
    static func captureRaw(windowID: CGWindowID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scw = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: scw)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            let rect = filter.contentRect
            config.width = Int((rect.width * scale).rounded())
            config.height = Int((rect.height * scale).rounded())
            config.ignoreShadowsSingleWindow = false
            config.shouldBeOpaque = false
            config.showsCursor = false
            config.captureResolution = .best
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            Log.info("window shadow capture: contentRect=\(rect) scale=\(scale) image=\(img.width)x\(img.height)")
            return img
        } catch {
            Log.info("window shadow capture failed: \(error)")
            return nil
        }
    }

    /// 找出图中不透明的窗口主体（像素坐标，左上原点）：沿中线向内找第一个几乎不透明的像素
    static func opaqueCore(of image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        // 内存里第 0 行是图像顶部
        func alpha(_ x: Int, _ y: Int) -> UInt8 { buf[(y * w + x) * 4 + 3] }
        let threshold: UInt8 = 245
        let midY = h / 2, midX = w / 2
        guard let left = (0..<w).first(where: { alpha($0, midY) >= threshold }),
              let right = (0..<w).reversed().first(where: { alpha($0, midY) >= threshold }),
              let top = (0..<h).first(where: { alpha(midX, $0) >= threshold }),
              let bottom = (0..<h).reversed().first(where: { alpha(midX, $0) >= threshold }) else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
}
