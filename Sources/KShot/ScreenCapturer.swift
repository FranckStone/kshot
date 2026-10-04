import AppKit
import ScreenCaptureKit

struct ScreenShot {
    let screen: NSScreen
    let image: CGImage
    var scale: CGFloat { screen.backingScaleFactor }
}

enum CaptureError: LocalizedError {
    case noDisplays
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplays: return "没有找到可用的显示器"
        case .permissionDenied: return "KShot 需要“屏幕录制”权限才能截图"
        }
    }
}

enum ScreenCapturer {
    /// 对所有显示器各截一张全屏图（不含鼠标）。
    @MainActor
    static func captureAll() async throws -> [ScreenShot] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            let nsError = error as NSError
            if nsError.domain == SCStreamErrorDomain,
               nsError.code == SCStreamError.Code.userDeclined.rawValue {
                throw CaptureError.permissionDenied
            }
            throw error
        }

        var shots: [ScreenShot] = []
        for screen in NSScreen.screens {
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            config.captureResolution = .best
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            Log.info("capturing display \(display.displayID) \(config.width)x\(config.height)")
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            Log.info("captured \(image.width)x\(image.height)")
            shots.append(ScreenShot(screen: screen, image: image))
        }
        guard !shots.isEmpty else { throw CaptureError.noDisplays }
        return shots
    }
}
