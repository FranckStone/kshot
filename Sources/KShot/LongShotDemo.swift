import AppKit

/// --longshot-demo：弹一个可滚动的示例窗口，对它跑完整的长截图流程，结果写到 ~/Library/Logs/KShot-selftest/longshot.png
@MainActor
enum LongShotDemo {
    nonisolated(unsafe) static var window: NSWindow?

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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let session = LongScreenshotSession(screen: screen, region: region, forceAuto: true)
            session.customScroller = { step in
                let clip = scroll.contentView
                let maxY = max(0, doc.bounds.height - clip.bounds.height)
                let y = min(maxY, clip.bounds.origin.y + step)
                clip.scroll(to: CGPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(clip)
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
            }
            session.start()
        }
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
