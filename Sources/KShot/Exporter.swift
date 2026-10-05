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

    /// 对任意图片叠加标注（标注坐标为 pt，图片 pt 尺寸 = 像素 / scale）
    static func render(image: CGImage, scale: CGFloat, annotations: [Annotation], renderer: AnnotationRenderer) -> CGImage? {
        let pxW = image.width, pxH = image.height
        guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: scale, y: scale)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        defer { NSGraphicsContext.restoreGraphicsState() }
        let size = CGSize(width: CGFloat(pxW) / scale, height: CGFloat(pxH) / scale)
        ctx.interpolationQuality = .none
        NSImage(cgImage: image, size: size).draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        ctx.interpolationQuality = .high
        renderer.draw(annotations, clip: CGRect(origin: .zero, size: size), in: ctx)
        return ctx.makeImage()
    }

    static func pngData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    static func copyToClipboard(_ image: CGImage) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Notification.Name("KShotCaptureFinished"), object: nil) }
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

    /// 按格式编码（PNG / JPEG / HEIC）
    static func encode(_ image: CGImage, format: ImageFormat = Settings.imageFormat) -> Data? {
        if format == .png { return pngData(image) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// 完成截图的统一出口：复制到剪贴板、按设置自动保存、记入历史、快门声
    @MainActor
    static func deliver(_ image: CGImage) {
        copyToClipboard(image)
        Shutter.play()
        History.add(image)
        if Settings.autoSaveOnConfirm { quickSave(image, toast: false) }
    }

    /// 不弹面板，直接存到默认目录
    @MainActor
    @discardableResult
    static func quickSave(_ image: CGImage, toast: Bool = true) -> URL? {
        let dir = Settings.saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = Settings.uniqueURL(in: dir, name: Settings.fileName(width: image.width, height: image.height))
        guard let data = encode(image) else { return nil }
        do {
            try data.write(to: url)
            if toast { Toast.show("已保存到 \(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)", symbol: "square.and.arrow.down.fill") }
            return url
        } catch {
            Log.info("保存失败: \(error)")
            if toast { Toast.show("保存失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle.fill") }
            return nil
        }
    }

    /// 弹出保存面板（调用方需保证遮罩已隐藏）。
    @MainActor
    static func save(_ image: CGImage, completion: @escaping (Bool) -> Void) {
        let format = Settings.imageFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = Settings.fileName(width: image.width, height: image.height)
        panel.canCreateDirectories = true
        panel.level = .modalPanel
        panel.directoryURL = UserDefaults.standard.url(forKey: "lastSaveDirectory") ?? Settings.saveDirectory
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url, let data = encode(image, format: format) else {
                completion(false)
                return
            }
            do {
                try data.write(to: url)
                UserDefaults.standard.set(url.deletingLastPathComponent(), forKey: "lastSaveDirectory")
                NotificationCenter.default.post(name: Notification.Name("KShotCaptureFinished"), object: nil)
                completion(true)
            } catch {
                NSLog("保存失败: \(error)")
                completion(false)
            }
        }
    }
}
