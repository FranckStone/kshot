import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 截图历史：每次完成 / 保存 / 钉住都在 ~/Library/Application Support/KShot/History 留一份 PNG 和缩略图
enum History {
    static let changed = Notification.Name("KShotHistoryChanged")
    private static let queue = DispatchQueue(label: "kshot.history", qos: .utility)

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KShot/History")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    struct Item {
        let url: URL
        let thumbURL: URL
        let date: Date
        let pixelSize: CGSize
    }

    static func add(_ image: CGImage) {
        guard Settings.historyEnabled else { return }
        let limit = Settings.historyLimit
        queue.async {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let base = f.string(from: Date())
            let url = directory.appendingPathComponent(base + ".png")
            guard let data = Exporter.pngData(image) else { return }
            try? data.write(to: url)
            if let thumb = thumbnail(of: image, maxPixel: 240), let td = Exporter.pngData(thumb) {
                try? td.write(to: directory.appendingPathComponent(base + ".thumb.png"))
            }
            prune(limit: limit)
            DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
        }
    }

    static func thumbnail(of image: CGImage, maxPixel: Int) -> CGImage? {
        let s = min(1, CGFloat(maxPixel) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * s)), h = max(1, Int(CGFloat(image.height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 最新的在前
    static func items() -> [Item] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        return files
            .filter { $0.pathExtension == "png" && !$0.lastPathComponent.hasSuffix(".thumb.png") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { url in
                let thumb = url.deletingPathExtension().appendingPathExtension("thumb.png")
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                var size = CGSize.zero
                if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                    size = CGSize(width: props[kCGImagePropertyPixelWidth] as? Int ?? 0, height: props[kCGImagePropertyPixelHeight] as? Int ?? 0)
                }
                return Item(url: url, thumbURL: thumb, date: date, pixelSize: size)
            }
    }

    static func load(_ item: Item) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(item.url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func prune(limit: Int) {
        for item in items().dropFirst(limit) {
            try? FileManager.default.removeItem(at: item.url)
            try? FileManager.default.removeItem(at: item.thumbURL)
        }
    }

    static func clear() {
        for item in items() {
            try? FileManager.default.removeItem(at: item.url)
            try? FileManager.default.removeItem(at: item.thumbURL)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// 菜单栏“最近截图”子菜单
@MainActor
final class HistoryMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "最近截图")
    private var items: [History.Item] = []

    override init() {
        super.init()
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        items = History.items()
        if !Settings.historyEnabled {
            menu.addItem(withTitle: "截图历史已关闭（可在偏好设置中打开）", action: nil, keyEquivalent: "").isEnabled = false
        } else if items.isEmpty {
            menu.addItem(withTitle: "还没有截图", action: nil, keyEquivalent: "").isEnabled = false
        }
        let tf = DateFormatter()
        tf.dateFormat = "M月d日 HH:mm:ss"
        for (i, item) in items.prefix(15).enumerated() {
            let title = "\(tf.string(from: item.date))   \(Int(item.pixelSize.width)) × \(Int(item.pixelSize.height))"
            let mi = NSMenuItem(title: title, action: #selector(copyItem(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.toolTip = "单击复制；子菜单里可以钉住、编辑、在 Finder 中显示"
            if let thumb = NSImage(contentsOf: item.thumbURL) {
                let h: CGFloat = 36
                let w = min(72, max(24, thumb.size.width / max(1, thumb.size.height) * h))
                thumb.size = NSSize(width: w, height: h)
                mi.image = thumb
            }
            let sub = NSMenu()
            func add(_ t: String, _ sel: Selector) {
                let x = NSMenuItem(title: t, action: sel, keyEquivalent: "")
                x.target = self
                x.tag = i
                sub.addItem(x)
            }
            add("复制", #selector(copyItem(_:)))
            add("钉在屏幕上", #selector(pinItem(_:)))
            add("标注编辑…", #selector(editItem(_:)))
            add("另存为…", #selector(saveItem(_:)))
            add("在 Finder 中显示", #selector(revealItem(_:)))
            mi.submenu = sub
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "打开历史文件夹", action: #selector(openFolder), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let clear = NSMenuItem(title: "清空历史", action: #selector(clearAll), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !items.isEmpty
        menu.addItem(clear)
    }

    private func item(_ sender: NSMenuItem) -> (History.Item, CGImage)? {
        guard sender.tag < items.count, let img = History.load(items[sender.tag]) else { return nil }
        return (items[sender.tag], img)
    }

    @objc private func copyItem(_ sender: NSMenuItem) {
        guard let (_, img) = item(sender) else { return }
        Exporter.copyToClipboard(img)
        Toast.show("已复制到剪贴板")
    }

    @objc private func pinItem(_ sender: NSMenuItem) {
        guard let (_, img) = item(sender), let screen = NSScreen.main else { return }
        let s = screen.backingScaleFactor
        let size = CGSize(width: CGFloat(img.width) / s, height: CGFloat(img.height) / s)
        let v = screen.visibleFrame
        let fit = min(1, v.width * 0.8 / size.width, v.height * 0.8 / size.height)
        let r = CGRect(x: v.midX - size.width * fit / 2, y: v.midY - size.height * fit / 2, width: size.width * fit, height: size.height * fit)
        PinWindow(image: img, frame: r).makeKeyAndOrderFront(nil)
    }

    @objc private func editItem(_ sender: NSMenuItem) {
        guard let (_, img) = item(sender), let screen = NSScreen.main else { return }
        let w = ImageEditorWindow(image: img, scale: screen.backingScaleFactor, screen: screen, title: "截图")
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func saveItem(_ sender: NSMenuItem) {
        guard let (_, img) = item(sender) else { return }
        Exporter.save(img) { _ in }
    }

    @objc private func revealItem(_ sender: NSMenuItem) {
        guard sender.tag < items.count else { return }
        NSWorkspace.shared.activateFileViewerSelecting([items[sender.tag].url])
    }

    @objc private func openFolder() { NSWorkspace.shared.open(History.directory) }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "清空截图历史？"
        alert.informativeText = "会删除 \(items.count) 张历史截图，无法恢复。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { History.clear() }
    }
}
