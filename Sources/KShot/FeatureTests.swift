import AppKit
import Carbon
import CoreImage
import AVFoundation

/// 调试参数触发的功能自测，结果写到 ~/Library/Logs/KShot-selftest/
@MainActor
enum FeatureTests {
    nonisolated static let dir: URL = {
        let d = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/KShot-selftest")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func write(_ img: CGImage?, _ name: String) {
        guard let img, let data = Exporter.pngData(img) else { Log.info("❌ \(name): 没有图片"); return }
        try? data.write(to: dir.appendingPathComponent(name))
        Log.info("wrote \(name) \(img.width)x\(img.height)")
    }

    /// 把窗口内容渲染成 PNG（玻璃效果在离屏渲染里不可见，只用于核对布局）
    static func snapshot(_ w: NSWindow, _ name: String) {
        guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        // 白底，便于查看
        let out = NSImage(size: v.bounds.size)
        out.lockFocus()
        NSColor(white: 0.93, alpha: 1).setFill()
        v.bounds.fill()
        rep.draw(in: v.bounds)
        out.unlockFocus()
        if let cg = out.cgImage(forProposedRect: nil, context: nil, hints: nil) { write(cg, name) }
    }

    /// 合成一张带敏感信息和二维码的示例图
    static func sampleImage() -> CGImage? {
        let size = CGSize(width: 900, height: 520)
        let scale: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor(white: 0.15, alpha: 1)]
        let lines = [
            "订单联系人：张三  手机 138 1234 5678",
            "邮箱：zhangsan.test@example.com",
            "身份证号：110101199003078515",
            "银行卡：6222 0212 3456 7890 128",
            "API Key: sk-proj-4fT9aQ2xLmN8vR7cK1bZ",
            "备注：下午三点前送达，谢谢",
        ]
        for (i, l) in lines.enumerated() {
            NSAttributedString(string: l, attributes: attrs).draw(at: CGPoint(x: 40, y: 40 + CGFloat(i) * 52))
        }
        // 二维码
        if let f = CIFilter(name: "CIQRCodeGenerator") {
            f.setValue("https://github.com/FranckStone/kshot".data(using: .utf8), forKey: "inputMessage")
            f.setValue("M", forKey: "inputCorrectionLevel")
            if let ci = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
               let cg = CIContext().createCGImage(ci, from: ci.extent) {
                NSImage(cgImage: cg, size: NSSize(width: 180, height: 180)).draw(in: CGRect(x: 690, y: 320, width: 180, height: 180),
                                                                                 from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                                                                                 hints: [.interpolation: NSImageInterpolation.none.rawValue])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--redact-test") { redactTest(); return true }
        if args.contains("--beautify-test") { beautifyTest(); return true }
        if args.contains("--prefs-test") { prefsTest(); return true }
        if args.contains("--editor-test") { editorTest(); return true }
        if let i = args.firstIndex(of: "--record-test"), i + 1 < args.count { recordTest(args[i + 1]); return true }
        if args.contains("--shadow-test") { shadowTest(); return true }
        if args.contains("--history-test") { historyTest(); return true }
        if args.contains("--gif-test") { gifTest(); return true }
        return false
    }

    /// 自动打码 + 二维码识别
    static func redactTest() {
        guard let img = sampleImage() else { return }
        write(img, "redact-source.png")
        Task { @MainActor in
            let codes = await TextRecognizer.detectCodes(img)
            Log.info("qr codes: \(codes)")
            let boxes = (try? await Redactor.findSensitive(in: img)) ?? []
            Log.info("redact boxes: \(boxes.count)")
            let size = CGSize(width: 900, height: 520)
            let renderer = AnnotationRenderer(source: img, bounds: CGRect(origin: .zero, size: size), scale: 2)
            let rects = boxes.map {
                CGRect(x: $0.minX * size.width, y: (1 - $0.maxY) * size.height, width: $0.width * size.width, height: $0.height * size.height).insetBy(dx: -3, dy: -2)
            }
            let anns = rects.map { Annotation(kind: .pixelate($0), color: .black, size: .medium) }
            write(Exporter.render(image: img, scale: 2, annotations: anns, renderer: renderer), "redact-result.png")
            // 弹出识别结果窗口（含二维码）
            OCRResultWindow.present(image: img, near: NSScreen.main?.visibleFrame ?? .zero, translate: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if let w = OCRResultWindow.latest {
                    Log.info("ocr window text: \(w.text.replacingOccurrences(of: "\n", with: " | "))")
                    snapshot(w, "ocr-window.png")
                }
                NSApp.terminate(nil)
            }
        }
    }

    static func beautifyTest() {
        guard let img = sampleImage() else { return }
        let w = BeautifyWindow(image: img, scale: 2, near: NSScreen.main?.visibleFrame ?? .zero, fromWindow: false)
        w.show()
        w.debugSetStyle(background: 0, padding: 64, radius: 12, shadow: true)
        write(w.debugOutput, "beautify-gradient.png")
        w.debugSetStyle(background: Beautifier.backgrounds.count - 1, padding: 40, radius: 12, shadow: true)
        write(w.debugOutput, "beautify-transparent.png")
        w.debugSetStyle(background: 2, padding: 64, radius: 12, shadow: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            snapshot(w, "beautify-window.png")
            NSApp.terminate(nil)
        }
    }

    static func prefsTest() {
        shortcutTest()
        // 逐页抓真实窗口（含玻璃效果）；抓不到（锁屏等）时退回离屏快照
        var steps: [(PreferencesWindow.Tab, String?)] = PreferencesWindow.Tab.allCases.map { ($0, nil) }
        steps += [(.general, "light"), (.shortcuts, "light"), (.shortcuts, "recording"), (.general, "hover")]
        func next() {
            guard !steps.isEmpty else { NSApp.terminate(nil); return }
            let (tab, variant) = steps.removeFirst()
            if variant == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
            PreferencesWindow.show(tab: tab)
            guard let w = NSApp.windows.first(where: { $0 is PreferencesWindow }) as? PreferencesWindow else { return }
            if variant == "recording" { w.debugModel.startRecording(.repeatRegion) }
            if variant == "hover" {
                // 把鼠标移到窗口按钮上，抓悬停状态（抓完移回原处）
                let old = NSEvent.mouseLocation
                CGWarpMouseCursorPosition(CGPoint(x: w.frame.minX + 55, y: NSScreen.primaryHeight - (w.frame.maxY - 32)))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { CGWarpMouseCursorPosition(CGPoint(x: old.x, y: NSScreen.primaryHeight - old.y)) }
            }
            let name = "prefs-\(tab.rawValue)\(variant.map { "-\($0)" } ?? "").png"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                Task { @MainActor in
                    if let img = await WindowShadow.captureRaw(windowID: CGWindowID(w.windowNumber)) {
                        write(img, name)
                    } else {
                        snapshot(w, name)
                    }
                    w.debugModel.stopRecording()
                    next()
                }
            }
        }
        next()
    }

    /// 快捷键的存取与匹配（结束时还原用户原来的设置）
    static func shortcutTest() {
        let saved = ShortcutAction.allCases.map { ($0, $0.combo) }
        defer { for (a, c) in saved { Settings.setShortcut(a, c, notify: false) } }
        func key(_ code: Int, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code))!
        }
        Settings.resetAllShortcuts()
        var ok = true
        func check(_ cond: Bool, _ what: String) { if !cond { ok = false; Log.info("❌ shortcut: \(what)") } }
        check(ShortcutAction.local(matching: key(kVK_ANSI_S, .command)) == .save, "⌘S → 保存")
        check(ShortcutAction.local(matching: key(kVK_ANSI_Z, [.command, .shift])) == .redo, "⇧⌘Z → 重做")
        check(ShortcutAction.local(matching: key(kVK_ANSI_S, [.command, .shift])) == nil, "⇧⌘S 不匹配")
        Settings.setShortcut(.save, HotKeyCombo(kVK_ANSI_S, optionKey | cmdKey))
        check(ShortcutAction.local(matching: key(kVK_ANSI_S, .command)) == nil, "改键后 ⌘S 不再保存")
        check(ShortcutAction.local(matching: key(kVK_ANSI_S, [.command, .option])) == .save, "⌥⌘S → 保存")
        Settings.setShortcut(.pin, nil)
        check(ShortcutAction.pin.combo == nil, "清除后为未设置")
        check(ShortcutAction.local(matching: key(kVK_ANSI_P, .command)) == nil, "清除后 ⌘P 无效")
        Settings.resetAllShortcuts()
        check(ShortcutAction.pin.combo == ShortcutAction.pin.defaultCombo, "恢复默认")
        Log.info(ok ? "✅ shortcut test passed" : "❌ shortcut test failed")
    }

    /// 编辑窗口：画几个新工具，选中并移动一个，导出
    static func editorTest() {
        guard let img = sampleImage(), let screen = NSScreen.main else { return }
        let w = ImageEditorWindow(image: img, scale: 2, screen: screen, title: "测试")
        w.makeKeyAndOrderFront(nil)
        let c = w.debugCanvas
        w.debugHandle(.tool(.step))
        c.debugDrag([CGPoint(x: 20, y: 30)])
        c.debugDrag([CGPoint(x: 20, y: 82)])
        w.debugHandle(.tool(.highlighter))
        c.color = Palette.colors[2]
        c.debugDrag([CGPoint(x: 40, y: 300), CGPoint(x: 200, y: 301), CGPoint(x: 330, y: 300)])
        w.debugHandle(.tool(.blur))
        c.debugDrag([CGPoint(x: 680, y: 310), CGPoint(x: 800, y: 400), CGPoint(x: 880, y: 510)])
        w.debugHandle(.tool(.rect))
        c.color = Palette.colors[0]
        c.debugDrag([CGPoint(x: 30, y: 140), CGPoint(x: 200, y: 170), CGPoint(x: 460, y: 190)])
        w.debugHandle(.tool(.rect)) // 关掉工具
        c.debugDrag([CGPoint(x: 30, y: 160), CGPoint(x: 50, y: 170), CGPoint(x: 60, y: 175)]) // 拖动矩形
        Log.info("editor annotations=\(c.annotations.count) undo=\(c.canUndo) redo=\(c.canRedo)")
        w.debugHandle(.undo)
        Log.info("after undo redo=\(c.canRedo)")
        w.debugHandle(.redo)
        write(c.export(), "editor-export.png")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }

    static func recordTest(_ spec: String) {
        let p = spec.split(separator: ",").compactMap { Double($0) }
        guard p.count == 4, let screen = NSScreen.main else { return }
        let rect = CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
        // 录一个会动的示例窗口
        let demo = NSWindow(contentRect: screen.cocoaRect(fromLocal: rect), styleMask: .borderless, backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: "0")
        label.font = .monospacedDigitSystemFont(ofSize: 80, weight: .bold)
        label.frame = CGRect(x: 20, y: 20, width: rect.width - 40, height: 100)
        demo.contentView?.addSubview(label)
        demo.backgroundColor = .white
        demo.level = .floating
        demo.orderFrontRegardless()
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { n += 1; label.stringValue = "\(n)" }
        }
        guard let rec = ScreenRecorder.start(screen: screen, region: rect) else { return }
        rec.format = CommandLine.arguments.contains("--gif") ? .gif : .mp4
        rec.onFinished = { url in
            Log.info("record test finished: \(url?.path ?? "nil") frames=\(rec.frameCount)")
            NSApp.terminate(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { rec.stop(cancel: false) }
    }

    /// 窗口阴影：对自己弹出的一个普通窗口抓图
    static func shadowTest() {
        let w = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 480, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "窗口阴影测试"
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let id = CGWindowID(w.windowNumber)
            let cg = CGRect(x: w.frame.minX, y: NSScreen.primaryHeight - w.frame.maxY, width: w.frame.width, height: w.frame.height)
            let info = WindowInfo(id: id, bounds: cg, pid: getpid(), ownerName: "KShot")
            let screen = w.screen ?? NSScreen.main!
            let local = screen.localRect(fromCG: cg)
            Task { @MainActor in
                guard let shot = try? await ScreenCapturer.captureAll().first else { Log.info("❌ shadow test: 抓屏失败"); NSApp.terminate(nil); return }
                let renderer = AnnotationRenderer(source: shot.image, bounds: CGRect(origin: .zero, size: screen.frame.size), scale: shot.scale)
                let ann = Annotation(kind: .rect(local.insetBy(dx: 60, dy: 80)), color: Palette.colors[0], size: .medium)
                write(await WindowShadow.capture(window: info, windowLocalRect: local, annotations: [ann], renderer: renderer), "window-shadow.png")
                NSApp.terminate(nil)
            }
        }
    }

    static func historyTest() {
        guard let img = sampleImage() else { return }
        History.add(img)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let items = History.items()
            Log.info("history items=\(items.count) first=\(items.first?.url.lastPathComponent ?? "-") size=\(items.first?.pixelSize ?? .zero) thumb=\(FileManager.default.fileExists(atPath: items.first?.thumbURL.path ?? ""))")
            let menu = HistoryMenu()
            menu.menuNeedsUpdate(menu.menu)
            Log.info("history menu items=\(menu.menu.items.map(\.title))")
            NSApp.terminate(nil)
        }
    }

    /// 用合成帧写一段 MP4（与录屏相同的编码参数），再转 GIF
    static func gifTest() {
        let url = dir.appendingPathComponent("gif-test.mp4")
        try? FileManager.default.removeItem(at: url)
        let w = 640, h = 360
        Task.detached {
            do {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
                ])
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                ])
                writer.add(input)
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)
                for i in 0..<30 {
                    while !input.isReadyForMoreMediaData { usleep(2000) }
                    var pb: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
                    guard let pb else { continue }
                    CVPixelBufferLockBaseAddress(pb, [])
                    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                    ctx.setFillColor(CGColor(red: 0.03, green: 0.76, blue: 0.38, alpha: 1))
                    ctx.fillEllipse(in: CGRect(x: 20 + i * 18, y: 130, width: 100, height: 100))
                    CVPixelBufferUnlockBaseAddress(pb, [])
                    adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
                }
                input.markAsFinished()
                await writer.finishWriting()
                let gif = dir.appendingPathComponent("gif-test.gif")
                try? FileManager.default.removeItem(at: gif)
                let ok = await GIFExporter.export(video: url, to: gif, fps: 12, maxWidth: 480)
                let size = (try? FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? Int) ?? 0
                var frames = 0
                if let src = CGImageSourceCreateWithURL(gif as CFURL, nil) { frames = CGImageSourceGetCount(src) }
                Log.info("gif test: mp4 status=\(writer.status.rawValue) gif ok=\(ok) bytes=\(size) frames=\(frames)")
            } catch {
                Log.info("❌ gif test: \(error)")
            }
            await MainActor.run { NSApp.terminate(nil) }
        }
    }
}
