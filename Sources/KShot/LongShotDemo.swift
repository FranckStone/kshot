import AppKit

/// --longshot-demo：弹一个可滚动的示例窗口，对它跑完整的长截图流程，结果写到 ~/Library/Logs/KShot-selftest/longshot.png
@MainActor
enum LongShotDemo {
    nonisolated(unsafe) static var window: NSWindow?
    nonisolated(unsafe) static var backdrop: NSWindow?

    static func run() {
        guard let screen = NSScreen.screens.first else { return }
        let size = NSSize(width: 720, height: 480)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2 + 80, width: size.width, height: size.height)
        let win = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "长截图示例内容"
        win.level = .floating
        win.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true
        let doc = TallContentView(frame: CGRect(x: 0, y: 0, width: size.width, height: 2600))
        scroll.documentView = doc
        win.contentView = scroll
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win

        // 内容区在屏幕上的局部坐标（左上原点）
        let contentCocoa = win.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        let region = CGRect(x: contentCocoa.minX - screen.frame.minX,
                            y: screen.frame.maxY - contentCocoa.maxY,
                            width: contentCocoa.width, height: contentCocoa.height).integral
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/KShot-selftest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let manual = CommandLine.arguments.contains("--manual")
        func scrollBy(_ step: CGFloat) {
            let clip = scroll.contentView
            let maxY = max(0, doc.bounds.height - clip.bounds.height)
            let y = max(0, min(maxY, clip.bounds.origin.y + step))
            clip.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated {
            let session = LongScreenshotSession(screen: screen, region: region, forceAuto: !manual)
            session.customScroller = { step in scrollBy(step) }
            if manual {
                // 模拟人手滚动：步长不一、偶尔往回滚、速度忽快忽慢，滚到底后按“完成”
                let steps: [CGFloat] = [60, 90, 120, 40, -70, 150, 200, 80, 30, 220, 110, -40, 180, 90, 200, 220, 120, 160, 80, 200, 150, 100, 90, 60, 120, 150, 100]
                var i = 0
                @MainActor func next() {
                    guard i < steps.count else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { session.debugFinish() } }
                        return
                    }
                    scrollBy(steps[i]); i += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int.random(in: 120...260))) { MainActor.assumeIsolated { next() } }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { next() } }
            }
            session.debugOutputURL = dir.appendingPathComponent("longshot.png")
            session.onFinish = { result in
                // 真值：把整个文档视图直接渲染出来，和拼接结果逐像素比对（采样列避开右侧滚动条）
                guard let rep = doc.bitmapImageRepForCachingDisplay(in: doc.bounds) else { return }
                doc.cacheDisplay(in: doc.bounds, to: rep)
                guard let truth = rep.cgImage,
                      let fa = ImageStitcher.makeFrame(result), let fb = ImageStitcher.makeFrame(truth) else { return }
                let rows = min(fa.rows.count, fb.rows.count)
                var total = 0, n = 0, worstRow = 0, worst = 0
                for y in 0..<rows {
                    var rowDiff = 0
                    for c in 0..<fa.rows[y].count { rowDiff += abs(Int(fa.rows[y][c]) - Int(fb.rows[y][c])) }
                    total += rowDiff; n += fa.rows[y].count
                    if rowDiff > worst { worst = rowDiff; worstRow = y }
                }
                Log.info(String(format: "longshot-demo verify: result %dx%d truth %dx%d meanDiff=%.3f worstRow=%d (rowDiff=%d)",
                                result.width, result.height, truth.width, truth.height, Double(total) / Double(max(1, n)), worstRow, worst))
                // 在编辑器里画几笔，然后抓屏看看效果
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard let editor = ImageEditorWindow.latest else { return }
                    editor.debugHandle(.tool(.rect))
                    editor.debugCanvas.debugDrag([CGPoint(x: 40, y: 60), CGPoint(x: 200, y: 120), CGPoint(x: 320, y: 180)])
                    editor.debugHandle(.tool(.arrow))
                    editor.debugCanvas.debugDrag([CGPoint(x: 400, y: 300), CGPoint(x: 500, y: 200), CGPoint(x: 600, y: 90)])
                    editor.debugHandle(.tool(.mosaic))
                    editor.debugCanvas.debugDrag([CGPoint(x: 60, y: 260), CGPoint(x: 200, y: 270), CGPoint(x: 360, y: 280)])
                    // 中性背景，避免抓屏带上真实桌面
                    let bg = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    bg.level = .normal
                    bg.isReleasedWhenClosed = false
                    bg.backgroundColor = NSColor(hex: 0x2C4A6B)
                    bg.orderFront(nil)
                    window?.orderOut(nil)
                    backdrop = bg
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        if let shot = try? await ScreenCapturer.captureAll().first, let data = Exporter.pngData(shot.image) {
                            try? data.write(to: dir.appendingPathComponent("editor.png"))
                        }
                        if let out = editor.debugCanvas.export(), let data = Exporter.pngData(out) {
                            try? data.write(to: dir.appendingPathComponent("editor-export.png"))
                        }
                        Log.info("longshot-demo editor captured")
                    }
                }
            }
            session.start()
        } }
    }
}

/// 很长的示例内容：每 40pt 一行行号 + 随机色块，有纹理便于验证拼接
final class TallContentView: NSView {
    override var isFlipped: Bool { true }
    private var blocks: [(CGRect, NSColor)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<120 {
            let r = CGRect(x: CGFloat.random(in: 120...(frame.width - 140), using: &rng), y: CGFloat.random(in: 0...(frame.height - 30), using: &rng),
                           width: CGFloat.random(in: 30...120, using: &rng), height: CGFloat.random(in: 10...28, using: &rng))
            blocks.append((r, NSColor(hue: CGFloat.random(in: 0...1, using: &rng), saturation: 0.6, brightness: 0.9, alpha: 1)))
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        for (r, c) in blocks { c.setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill() }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.black]
        var y: CGFloat = 8
        var n = 1
        while y < bounds.height {
            NSAttributedString(string: String(format: "第 %03d 行  y=%.0f", n, y), attributes: attrs).draw(at: CGPoint(x: 16, y: y))
            NSColor(white: 0.9, alpha: 1).setFill(); CGRect(x: 0, y: y + 30, width: bounds.width, height: 1).fill()
            y += 40; n += 1
        }
    }
}
