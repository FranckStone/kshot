import AppKit
import Carbon
import CoreImage
import AVFoundation
import Darwin

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
        if let i = args.firstIndex(of: "--stitch-replay"), i + 1 < args.count {
            stitchReplay(args[i + 1]); return true
        }
        if args.contains("--redact-test") { redactTest(); return true }
        if args.contains("--beautify-test") { beautifyTest(); return true }
        if args.contains("--prefs-test") { prefsTest(); return true }
        if args.contains("--translation-prepare-test") { translationPrepareTest(); return true }
        if args.contains("--translation-download-test") { translationDownloadTest(); return true }
        if args.contains("--translation-window-test") { translationWindowTest(); return true }
        if args.contains("--translation-source-test") { translationSourceTest(); return true }
        if args.contains("--recognition-test") { recognitionTest(); return true }
        if args.contains("--translation-auto-test") { translationAutoTest(); return true }
        if args.contains("--translation-ai-settings-test") { translationAISettingsTest(); return true }
        if args.contains("--translation-stream-test") { translationStreamTest(); return true }
        if args.contains("--translation-engine-window-test") { translationEngineWindowTest(); return true }
        if args.contains("--translation-layout-test") { translationLayoutTest(); return true }
        if args.contains("--editor-test") { editorTest(); return true }
        if let i = args.firstIndex(of: "--editor-image"), i + 1 < args.count {
            editorImageTest(args[i + 1]); return true
        }
        if let i = args.firstIndex(of: "--record-test"), i + 1 < args.count { recordTest(args[i + 1]); return true }
        if args.contains("--shadow-test") { shadowTest(); return true }
        if args.contains("--history-test") { historyTest(); return true }
        if args.contains("--gif-test") { gifTest(); return true }
        return false
    }

    /// 重放故障现场保存的帧，检查重复失败是否还会触发昂贵的配准。
    static func stitchReplay(_ path: String) {
        Task.detached(priority: .userInitiated) {
            let dir = URL(fileURLWithPath: path)
            let urls = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let stitcher = ImageStitcher()
            var last: CGImage?
            for url in urls {
                guard let data = try? Data(contentsOf: url), let image = NSBitmapImageRep(data: data)?.cgImage else { continue }
                let start = ProcessInfo.processInfo.systemUptime
                let result = stitcher.push(image)
                Log.info(String(format: "replay %@ %@ %.1fms attempts=%d", url.lastPathComponent, String(describing: result),
                                (ProcessInfo.processInfo.systemUptime - start) * 1000, stitcher.matchingAttempts))
                last = image
            }
            if let last {
                let before = stitcher.matchingAttempts
                let start = ProcessInfo.processInfo.systemUptime
                for _ in 0..<20 { _ = stitcher.push(last) }
                Log.info(String(format: "replay repeated: %.1fms/20 frames extraAttempts=%d stripBytes=%d", (ProcessInfo.processInfo.systemUptime - start) * 1000,
                                stitcher.matchingAttempts - before, stitcher.debugStripStorageBytes))
            }
            await MainActor.run { NSApp.terminate(nil) }
        }
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

    /// 用已安装的语言验证真实系统会话，避免测试时下载额外语言包。
    static func translationPrepareTest() {
        PreferencesWindow.show(tab: .translation)
        guard let window = NSApp.windows.first(where: { $0 is PreferencesWindow }) as? PreferencesWindow else { return }
        Task { @MainActor in
            let source = TargetLanguage.all[2], target = TargetLanguage.all[0]
            guard await Translator.availability(from: source, to: target) == .installed else {
                Log.info("❌ translation prepare test requires installed English / Chinese packages")
                NSApp.terminate(nil)
                return
            }
            var finished = false
            let translator = window.debugModel.translation.translator
            Log.info("translation prepare test: settings window visible=\(window.isVisible)")
            translator.prepare(from: source, to: target) { result in
                finished = true
                switch result {
                case .success: Log.info("✅ translation prepare test passed")
                case .failure(let error): Log.info("❌ translation prepare test: \(error)")
                }
                switch result {
                case .success: Darwin.exit(EXIT_SUCCESS)
                case .failure: Darwin.exit(EXIT_FAILURE)
                }
            }
            try? await Task.sleep(for: .seconds(8))
            if !finished {
                Log.info("❌ translation prepare test timed out: system session did not complete")
                snapshot(window, "prefs-translation-prepare-timeout.png")
                Darwin.exit(EXIT_FAILURE)
            }
        }
    }

    /// 走设置页相同的下载入口，验证未安装语言的系统确认提示。
    static func translationDownloadTest() {
        PreferencesWindow.show(tab: .translation)
        guard let window = NSApp.windows.first(where: { $0 is PreferencesWindow }) as? PreferencesWindow else { return }
        Task { @MainActor in
            let model = window.debugModel.translation
            model.source = TargetLanguage.all[2]
            for target in TargetLanguage.all where target != model.source {
                if await Translator.availability(from: model.source, to: target) == .supported {
                    model.target = target
                    await model.refreshStatus()
                    Log.info("translation download test: \(model.pairID)")
                    model.download()
                    try? await Task.sleep(for: .seconds(3))
                    snapshot(window, "prefs-translation-download.png")
                    Log.info("translation download test: preparing=\(model.preparing), sheets=\(window.sheets.count), message=\(model.message ?? "nil")")
                    let presented = window.sheets.contains { $0.isVisible && $0.frame.width > 100 && $0.frame.height > 100 }
                    for sheet in window.sheets {
                        Log.info("translation download sheet: frame=\(sheet.frame), visible=\(sheet.isVisible), title=\(sheet.title)")
                        if let image = await WindowShadow.captureRaw(windowID: CGWindowID(sheet.windowNumber)) {
                            write(image, "prefs-translation-download-sheet.png")
                        }
                    }
                    Log.info(presented ? "✅ translation download confirmation presented" : "❌ translation download confirmation missing")
                    // 系统确认窗口打开时 terminate 会等待确认，测试专用进程直接退出以免留下弹窗。
                    Darwin.exit(presented ? EXIT_SUCCESS : EXIT_FAILURE)
                }
            }
            Log.info("translation download test: all offered languages already installed")
            NSApp.terminate(nil)
        }
    }

    /// 检查翻译结果、窄窗口与二维码操作共存时的真实布局。
    static func translationWindowTest() {
        let source = "让截图里的文字，更容易阅读。\n\n选择屏幕上的任意区域，KShot 会识别其中的文字，并翻译为你选择的语言。\n\n你可以直接修改原文，或复制译文到正在使用的应用。\n\n快捷操作\n⌘↩ 重新翻译\nEsc 关闭窗口"
        let window = OCRResultWindow(text: source, near: NSScreen.main?.visibleFrame ?? .zero, translation: true)
        window.setCodes(["https://github.com/FranckStone/kshot"])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            let target = TargetLanguage.defaultTarget(for: source)
            if await Translator.availability(from: TargetLanguage.all[0], to: target) == .installed {
                window.translateAction()
                for _ in 0..<50 {
                    if !window.translatedText.isEmpty { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            snapshot(window, "translation-window.png")
            if let image = await WindowShadow.captureRaw(windowID: CGWindowID(window.windowNumber)) {
                write(image, "translation-window-live.png")
            }
            window.setContentSize(NSSize(width: 640, height: 380))
            try? await Task.sleep(for: .milliseconds(300))
            snapshot(window, "translation-window-small.png")
            window.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(300))
            snapshot(window, "translation-window-dark.png")
            window.close()
            let ocr = OCRResultWindow(text: source, near: NSScreen.main?.visibleFrame ?? .zero)
            ocr.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(300))
            snapshot(ocr, "ocr-window-new.png")
            if await Translator.availability(from: TargetLanguage.all[0], to: target) == .installed {
                ocr.translateAction()
                for _ in 0..<50 {
                    if !ocr.translatedText.isEmpty { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                snapshot(ocr, "ocr-window-to-translation.png")
            }
            Log.info("✅ translation window layout check completed; translated=\(window.translatedText.count) chars")
            NSApp.terminate(nil)
        }
    }

    /// 很短的原文明确传入英语，绕过自动识别并验证实际译文。
    static func translationSourceTest() {
        let window = OCRResultWindow(text: "Hi", near: NSScreen.main?.visibleFrame ?? .zero, translation: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            let source = TargetLanguage.all[2], target = TargetLanguage.all[0]
            guard await Translator.availability(from: source, to: target) == .installed else {
                Log.info("❌ translation source test requires installed English / Chinese packages")
                Darwin.exit(EXIT_FAILURE)
            }
            window.debugTranslate(from: source, to: target)
            for _ in 0..<50 {
                if !window.translatedText.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            window.setContentSize(NSSize(width: 640, height: 380))
            try? await Task.sleep(for: .milliseconds(200))
            snapshot(window, "translation-source-short-text.png")
            let success = !window.translatedText.isEmpty && window.translatedText != window.text
            Log.info(success ? "✅ explicit source translated short text: \(window.translatedText)" : "❌ explicit source short text translation failed")
            Darwin.exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    /// 统一入口：文字与二维码同时识别；纯二维码不触发翻译。
    static func recognitionTest() {
        guard let image = sampleImage() else { Darwin.exit(EXIT_FAILURE) }
        Task { @MainActor in
            OCRResultWindow.present(image: image, near: NSScreen.main?.visibleFrame ?? .zero, translate: true)
            guard let mixed = OCRResultWindow.latest else { Darwin.exit(EXIT_FAILURE) }
            for _ in 0..<100 {
                if !mixed.text.isEmpty && !mixed.isTranslating { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let mixedOK = mixed.text.contains("https://github.com/FranckStone/kshot") && !mixed.translatedText.isEmpty
            snapshot(mixed, "recognition-text-and-code.png")
            mixed.close()

            let url = "https://github.com/FranckStone/kshot"
            guard let filter = CIFilter(name: "CIQRCodeGenerator") else { Darwin.exit(EXIT_FAILURE) }
            filter.setValue(Data(url.utf8), forKey: "inputMessage")
            guard let code = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
                  let qrImage = CIContext().createCGImage(code, from: code.extent) else { Darwin.exit(EXIT_FAILURE) }
            OCRResultWindow.present(image: qrImage, near: NSScreen.main?.visibleFrame ?? .zero, translate: true)
            guard let qr = OCRResultWindow.latest else { Darwin.exit(EXIT_FAILURE) }
            for _ in 0..<50 {
                if !qr.text.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let qrOK = qr.text == url && qr.translatedText.isEmpty
            snapshot(qr, "recognition-code-only.png")
            Log.info("\(mixedOK && qrOK ? "✅" : "❌") unified recognition: text+code+translation=\(mixedOK), code-only=\(qrOK)")
            Darwin.exit(mixedOK && qrOK ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    /// 验证实际 AI / Apple 译文保留原文的空行、换行、缩进和列表结构。
    static func translationLayoutTest() {
        let initial = TranslationEngineSelection.saved
        guard initial.provider != .system else { Darwin.exit(EXIT_FAILURE) }
        Task { @MainActor in
            let source = "# Setup guide\r\n\r\n  1.  Install the application.\r\n  2.  Restart the application.\r\n\r\n  - [x] Open the settings.\n  - Keep the window open.\n\nhttps://example.com\n123-456\n"
            let window = OCRResultWindow(text: source, near: NSScreen.main?.visibleFrame ?? .zero, translation: true)
            window.makeKeyAndOrderFront(nil)
            func lineBreaks(_ text: String) -> String { String(text.filter(\.isNewline)) }
            func sameLayout(_ translated: String) -> Bool {
                let a = TranslationTextLayout.split(source), b = TranslationTextLayout.split(translated)
                guard a.count == b.count else { return false }
                return zip(a, b).allSatisfy { original, result in
                    let lhs = TranslationTextLayout(original), rhs = TranslationTextLayout(result)
                    if lhs.isLiteral || TranslationLanguageDetector.sample(lhs.content).isEmpty { return original == result }
                    return lhs.prefix == rhs.prefix && lhs.suffix == rhs.suffix && !rhs.content.isEmpty
                }
            }
            window.debugTranslate(from: TargetLanguage.all[2], to: TargetLanguage.all[0])
            var streamOK = true
            var sawPartial = false
            for _ in 0..<3000 {
                if window.isTranslating, !window.translatedText.isEmpty {
                    streamOK = streamOK && lineBreaks(source).hasPrefix(lineBreaks(window.translatedText))
                    if !sawPartial { snapshot(window, "translation-layout-partial.png"); sawPartial = true }
                }
                if !window.isTranslating { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let aiOK = window.debugStatusText.contains("已翻译") && sameLayout(window.translatedText)
            snapshot(window, "translation-layout-ai.png")
            window.debugSelectEngine(TranslationEngineSelection(provider: .system, model: ""))
            for _ in 0..<3000 {
                if !window.isTranslating { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let systemOK = window.debugStatusText.contains("Apple 系统翻译 · 已翻译") && sameLayout(window.translatedText)
            snapshot(window, "translation-layout-system.png")
            window.close()
            initial.remember()
            let success = aiOK && systemOK && streamOK && sawPartial
            Log.info("\(success ? "✅" : "❌") translation layout: AI=\(aiOK), system=\(systemOK), streaming=\(streamOK && sawPartial)")
            Darwin.exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    /// 验证窗口内引擎/模型选择、记忆、窄窗口布局以及翻译中切换，结束时恢复原选择。
    static func translationEngineWindowTest() {
        let initial = TranslationEngineSelection.saved
        guard initial.provider == .ollama else { Darwin.exit(EXIT_FAILURE) }
        Task { @MainActor in
            let window = OCRResultWindow(text: "", near: NSScreen.main?.visibleFrame ?? .zero, translation: true)
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<100 {
                if window.debugModelNames.count > 1 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let listed = window.debugModelNames.contains(initial.model) && window.debugModelNames.count > 1
            let alternate = window.debugModelNames.first(where: { $0 != initial.model }) ?? "test-custom-model"
            snapshot(window, "translation-engine-ollama.png")
            window.setContentSize(NSSize(width: 640, height: 380))
            snapshot(window, "translation-engine-small.png")
            window.appearance = NSAppearance(named: .darkAqua)
            snapshot(window, "translation-engine-dark.png")
            window.appearance = NSAppearance(named: .aqua)
            window.debugSelectEngine(TranslationEngineSelection(provider: .deepseek, model: Settings.aiTranslationModel(for: .deepseek)))
            snapshot(window, "translation-engine-deepseek.png")
            window.debugSelectEngine(TranslationEngineSelection(provider: .system, model: ""))
            snapshot(window, "translation-engine-system.png")

            // 用空原文检查模型选择的记忆，不触发模型下载或翻译。
            window.debugSelectEngine(TranslationEngineSelection(provider: .ollama, model: alternate))
            let remembered = Settings.aiTranslationModel(for: .ollama) == alternate
            let other = OCRResultWindow(text: "", near: .zero, translation: true)
            let inherited = other.engineSelection.model == alternate
            window.debugSelectEngine(initial)
            let isolated = other.engineSelection.model == alternate
            other.close()

            window.setText("Please restart the application after installing the update. The translation appears while the model is generating it, so you can read it before the entire response is finished.")
            window.debugTranslate(from: TargetLanguage.all[2], to: TargetLanguage.all[0])
            for _ in 0..<1000 {
                if !window.translatedText.isEmpty || !window.isTranslating { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let switchedDuringStream = window.isTranslating && !window.translatedText.isEmpty
            window.debugSelectEngine(TranslationEngineSelection(provider: .system, model: ""))
            for _ in 0..<1000 {
                if !window.isTranslating { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let systemOK = window.debugStatusText.contains("Apple 系统翻译 · 已翻译")
            window.debugSelectEngine(initial)
            for _ in 0..<1000 {
                if !window.isTranslating { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let ollamaOK = window.debugStatusText.contains("Ollama · 已翻译")
            snapshot(window, "translation-engine-switched.png")
            window.close()
            initial.remember()
            let success = listed && remembered && inherited && isolated && switchedDuringStream && systemOK && ollamaOK
            Log.info("\(success ? "✅" : "❌") window engine: models=\(listed), remember=\(remembered), inherit=\(inherited), isolation=\(isolated), live-switch=\(switchedDuringStream), system=\(systemOK), ollama=\(ollamaOK)")
            Darwin.exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    /// 实测流式窗口的早期文字、完成、停止和重试，不修改翻译配置。
    static func translationStreamTest() {
        guard Settings.translationProvider != .system else { Darwin.exit(EXIT_FAILURE) }
        Task { @MainActor in
            let source = """
            Please translate this guide for the application.

            Select an area of the screen to capture the text. The original text and the translation appear side by side. You can resize the window, read the text, and copy the translation to another application.

            The translation should appear while the model is generating it. You do not need to wait for the entire response before reading. If you stop the translation, the words already generated remain available. You can retry the translation whenever you need.

            Keep links, numbers, and paragraph breaks unchanged. Please restart the application after installing the update.
            """
            let window = OCRResultWindow(text: source, near: NSScreen.main?.visibleFrame ?? .zero, translation: true)
            window.makeKeyAndOrderFront(nil)
            window.debugTranslateAutomatically(to: TargetLanguage.all[0])
            var earlyText: String?
            for _ in 0..<3000 {
                if window.isTranslating, !window.translatedText.isEmpty, earlyText == nil {
                    earlyText = window.translatedText
                    snapshot(window, "translation-stream-partial.png")
                }
                if !window.isTranslating { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let completed = earlyText.map { !$0.isEmpty && $0.count < window.translatedText.count } == true && !window.isTranslating
            snapshot(window, "translation-stream-complete.png")
            Log.info("\(completed ? "✅" : "❌") live streaming: early=\(earlyText?.count ?? 0), final=\(window.translatedText.count)")

            window.debugTranslateAutomatically(to: TargetLanguage.all[0])
            for _ in 0..<3000 {
                if !window.translatedText.isEmpty || !window.isTranslating { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let stoppedEarly = window.isTranslating && !window.translatedText.isEmpty
            window.translateAction() // 生成期间同一按钮执行停止。
            let stoppedText = window.translatedText
            try? await Task.sleep(for: .milliseconds(250))
            let stopped = stoppedEarly && !window.isTranslating && window.translatedText == stoppedText
            snapshot(window, "translation-stream-stopped.png")

            window.setText("Hello, please restart the application.")
            window.debugTranslateAutomatically(to: TargetLanguage.all[0])
            for _ in 0..<3000 {
                if !window.isTranslating { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let retried = !window.isTranslating && !window.translatedText.isEmpty && !window.translatedText.contains("Hello")
            snapshot(window, "translation-stream-retried.png")
            Log.info("\(stopped && retried ? "✅" : "❌") live streaming stop=\(stopped), retry=\(retried)")
            window.close()
            Darwin.exit(completed && stopped && retried ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    /// 默认仅修改草稿；--ai-model 验证本机服务，--enable-ai 在成功后保存并启用。
    static func translationAISettingsTest() {
        PreferencesWindow.show(tab: .translation)
        guard let window = NSApp.windows.first(where: { $0 is PreferencesWindow }) as? PreferencesWindow else {
            Darwin.exit(EXIT_FAILURE)
        }
        Task { @MainActor in
            let ai = window.debugModel.translation.ai
            ai.provider = .deepseek
            ai.apiKey = ""
            try? await Task.sleep(for: .milliseconds(300))
            snapshot(window, "prefs-translation-deepseek.png")
            ai.provider = .ollama
            try? await Task.sleep(for: .milliseconds(300))
            snapshot(window, "prefs-translation-ollama.png")
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--ai-model"), index + 1 < args.count {
                ai.model = args[index + 1]
                ai.baseURL = "http://localhost:11434"
                ai.refreshModels()
                for _ in 0..<100 where ai.working { try? await Task.sleep(for: .milliseconds(100)) }
                guard !ai.working, !ai.models.isEmpty else {
                    Log.info("❌ Ollama live model listing failed")
                    Darwin.exit(EXIT_FAILURE)
                }
                ai.testConnection()
                for _ in 0..<1800 where ai.working { try? await Task.sleep(for: .milliseconds(100)) }
                snapshot(window, "prefs-translation-ollama-connected.png")
                guard !ai.working, ai.message?.hasPrefix("连接成功") == true else {
                    Log.info("❌ Ollama live connection: \(ai.message ?? "nil")")
                    Darwin.exit(EXIT_FAILURE)
                }
                do {
                    let output = try await AITranslator().translate("Hello, please restart the application.\n这是原文中的中文。\nhttps://example.com", source: nil, target: TargetLanguage.all[0], excluding: ["https://example.com"], configuration: ai.configuration)
                    guard output.text.contains("https://example.com"), output.text.contains("这是原文中的中文。"),
                          !output.text.contains("Hello, please restart the application.") else { throw AITranslationError.invalidResponse }
                    Log.info("✅ Ollama live translation: \(output.text)")
                } catch {
                    Log.info("❌ Ollama live translation: \(error)")
                    Darwin.exit(EXIT_FAILURE)
                }
            }
            if args.contains("--enable-ai") {
                guard args.contains("--ai-model") else { Darwin.exit(EXIT_FAILURE) }
                ai.save()
                guard Settings.translationProvider == .ollama, Settings.aiTranslationModel(for: .ollama) == ai.model else {
                    Log.info("❌ AI translation configuration save failed")
                    Darwin.exit(EXIT_FAILURE)
                }
                Log.info("✅ enabled Ollama model: \(ai.model)")
            } else {
                Log.info("✅ AI translation settings rendered without changing saved configuration")
            }
            Darwin.exit(EXIT_SUCCESS)
        }
    }

    /// 已安装的中英语言包验证自动检测，技术内容、目标语言原文与混合段落均不应弹语言选择。
    static func translationAutoTest() {
        Task { @MainActor in
            let zh = TargetLanguage.all[0], en = TargetLanguage.all[2], ja = TargetLanguage.all[3]
            var cases: [(String, TargetLanguage, String?)] = [
                ("Hi", zh, nil),
                ("https://example.com\r\n123-456\r\nuser@example.com", zh, "https://example.com\r\n123-456\r\nuser@example.com"),
                ("This sentence is already in English.", en, "This sentence is already in English."),
                ("你好", zh, "你好"),
                ("檔案已儲存", zh, "档案已储存"),
                ("安装完成，请重新启动应用。\n\nInstall the package and restart the application.\nhttps://example.com\n123-456", zh, nil)
            ]
            if await Translator.availability(from: ja, to: zh) == .installed {
                cases.append(("这是中文原文。\nHello, please restart the application.\n注文内容を確認してください。", zh, nil))
                cases.append(("注文内容を確認してください。\n名前\n設定\n確認", zh, nil))
            }
            var success = true
            let window = OCRResultWindow(text: "", near: NSScreen.main?.visibleFrame ?? .zero, translation: true)
            window.makeKeyAndOrderFront(nil)
            for (index, item) in cases.enumerated() {
                // 复用窗口，同时验证连续翻译、相同语言会话重试和跨语言切换。
                window.setText(item.0)
                window.debugTranslateAutomatically(to: item.1)
                for _ in 0..<150 {
                    if !window.isTranslating { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let passed = !window.translatedText.isEmpty && (item.2.map { $0 == window.translatedText } ?? (window.translatedText != item.0))
                success = success && passed
                snapshot(window, "translation-auto-\(index).png")
                Log.info("\(passed ? "✅" : "❌") auto translation case \(index): \(window.translatedText.count) chars")
            }
            window.close()
            Darwin.exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
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

    /// 用真实长图验证原生编辑器在顶部、中部、底部及回滚后的显示。
    static func editorImageTest(_ path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let img = NSBitmapImageRep(data: data)?.cgImage, let screen = NSScreen.main else {
            Log.info("editor-image: 无法读取图片 \(path)")
            NSApp.terminate(nil)
            return
        }
        let w = ImageEditorWindow(image: img, scale: screen.backingScaleFactor, screen: screen, title: "长截图显示验证")
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 留下真实窗口，验证 WindowServer 分发的点击/拖动，而非直接调用画布回调。
        if CommandLine.arguments.contains("--interactive") {
            Log.info("editor-interactive windows: canvas=\(w.windowNumber) toolbar=\(w.debugToolbarPanel.windowNumber) options=\(w.debugOptionsPanel.windowNumber)")
            Log.info("editor-interactive frame=\(w.frame) toolbar=\(w.debugToolbarPanel.frame)")
            let refresh = w.debugCanvas.onAnnotationsChanged
            w.debugCanvas.onAnnotationsChanged = {
                refresh?()
                Log.info("editor-interactive tool=\(w.debugCanvas.tool) marks=\(w.debugCanvas.annotations.count) color=\(w.debugCanvas.color) frame=\(w.frame) toolbar=\(w.debugToolbarPanel.frame)")
            }
            return
        }
        Task { @MainActor in
            for (index, y) in [CGFloat(0), 400, 1000, 0].enumerated() {
                if index == 1 { w.setFrame(CGRect(origin: w.frame.origin, size: CGSize(width: 560, height: w.frame.height)), display: true) }
                if index == 2 {
                    w.setFrame(CGRect(origin: w.frame.origin, size: CGSize(width: 800, height: w.frame.height)), display: true)
                    w.debugHandle(.tool(.rect))
                }
                if index == 3 { w.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 8, y: w.frame.minY)) }
                w.debugScroll(to: y)
                try? await Task.sleep(for: .milliseconds(350))
                let shot = await WindowShadow.captureRaw(windowID: CGWindowID(w.windowNumber))
                write(shot, "longshot-editor-viewport-\(index).png")
                let toolbar = w.debugToolbarPanel
                let toolbarShot = await WindowShadow.captureRaw(windowID: CGWindowID(toolbar.windowNumber))
                write(toolbarShot, "longshot-editor-toolbar-\(index).png")
                // 合成区域抓屏，验证外置面板与窗口的距离以及窄窗口布局。
                var area = w.frame.union(toolbar.frame)
                if w.debugOptionsPanel.isVisible { area = area.union(w.debugOptionsPanel.frame) }
                area = area.insetBy(dx: -8, dy: -8).intersection(screen.frame)
                let local = CGRect(x: area.minX - screen.frame.minX, y: screen.frame.maxY - area.maxY, width: area.width, height: area.height)
                if let capturer = try? await RegionCapturer(screen: screen, localRect: local, excludingWindowIDs: [], excludeOwnApp: false) {
                    write(try? await capturer.capture(), "longshot-editor-layout-\(index).png")
                }
                Log.info("editor layout \(index): toolbarFits=\(screen.visibleFrame.contains(toolbar.frame)) toolbarWidth=\(toolbar.frame.width) windowWidth=\(w.frame.width) imageCenterOffset=\(w.debugImageCenterOffset)")
            }
            write(w.debugCanvas.export(), "longshot-editor-export.png")
            w.closeEditor()
            NSApp.terminate(nil)
        }
    }

    static func recordTest(_ spec: String) {
        let p = spec.split(separator: ",").compactMap { Double($0) }
        guard p.count == 4, let screen = NSScreen.main else { return }
        let rect = CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
        // 演示模式：铺一层示例桌面，便于生成不含隐私的录屏截图
        let demoMode = CommandLine.arguments.contains("--demo")
        if demoMode, let (shot, _) = DemoScene.make(for: screen) {
            let bg = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            bg.isReleasedWhenClosed = false
            let iv = NSImageView(frame: CGRect(origin: .zero, size: screen.frame.size))
            iv.image = NSImage(cgImage: shot.image, size: screen.frame.size)
            iv.imageScaling = .scaleAxesIndependently
            bg.contentView = iv
            bg.orderFrontRegardless()
        }
        // 录一个会动的示例窗口（演示模式直接录示例桌面）
        if !demoMode {
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
