import AppKit
import UniformTypeIdentifiers

enum Exporter {
    /// 把选区裁出来并叠加标注，输出像素级 CGImage。
    static func render(shot: ScreenShot, selection: CGRect, annotations: [Annotation], renderer: AnnotationRenderer) -> CGImage? {
        let scale = shot.scale
        let sel = selection.standardized
        let pxW = Int((sel.width * scale).rounded())
        let pxH = Int((sel.height * scale).rounded())
        guard pxW > 0, pxH > 0 else { return nil }

        guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // 翻转为左上原点坐标系，并缩放到 pt 单位、平移到选区
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -sel.minX, y: -sel.minY)

        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        defer { NSGraphicsContext.restoreGraphicsState() }

        let screenSize = shot.screen.frame.size
        let base = NSImage(cgImage: shot.image, size: screenSize)
        ctx.interpolationQuality = .none
        base.draw(in: CGRect(origin: .zero, size: screenSize), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        ctx.interpolationQuality = .high
        renderer.draw(annotations, clip: sel, in: ctx)

        return ctx.makeImage()
    }

    static func pngData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    static func copyToClipboard(_ image: CGImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var items: [NSPasteboardWriting] = []
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        items.append(nsImage)
        pb.writeObjects(items)
        if let png = pngData(image) {
            pb.setData(png, forType: .png)
        }
    }

    static func defaultFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "截图 \(f.string(from: Date())).png"
    }

    /// 弹出保存面板（调用方需保证遮罩已隐藏）。
    @MainActor
    static func save(_ image: CGImage, completion: @escaping (Bool) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFileName()
        panel.canCreateDirectories = true
        panel.level = .modalPanel
        if let dir = UserDefaults.standard.url(forKey: "lastSaveDirectory") {
            panel.directoryURL = dir
        } else {
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url, let data = pngData(image) else {
                completion(false)
                return
            }
            do {
                try data.write(to: url)
                UserDefaults.standard.set(url.deletingLastPathComponent(), forKey: "lastSaveDirectory")
                completion(true)
            } catch {
                NSLog("保存失败: \(error)")
                completion(false)
            }
        }
    }
}
