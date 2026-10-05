import AppKit

/// 菜单栏图标：与 App 图标一致的取景框四角 + 十字准星（模板图，自动适配深浅色菜单栏）
enum MenuBarIcon {
    /// 绘制参数（动画时逐帧变化）
    struct Pose: Equatable {
        /// 四角向内收的距离（pt，负数为向外张开）
        var cornerInset: CGFloat = 0
        /// 准星旋转角度（弧度）
        var crossAngle: CGFloat = 0
        /// 准星缩放
        var crossScale: CGFloat = 1
        /// 0 = 十字准星，1 = 实心圆点（录制中），中间值做过渡
        var dot: CGFloat = 0
        /// 中心元素的不透明度
        var centerAlpha: CGFloat = 1

        static let rest = Pose()
    }

    static func make(_ pose: Pose = .rest) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width
            let lw = s * 0.11
            let frame = rect.insetBy(dx: s * 0.14 + pose.cornerInset, dy: s * 0.14 + pose.cornerInset)
            let arm = (rect.width - s * 0.28) * 0.32
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineWidth(lw)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let corners: [(CGPoint, CGPoint, CGPoint)] = [
                (CGPoint(x: frame.minX, y: frame.maxY - arm), CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.minX + arm, y: frame.maxY)),
                (CGPoint(x: frame.maxX - arm, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY - arm)),
                (CGPoint(x: frame.maxX, y: frame.minY + arm), CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.maxX - arm, y: frame.minY)),
                (CGPoint(x: frame.minX + arm, y: frame.minY), CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.minX, y: frame.minY + arm)),
            ]
            for (a, b, c) in corners { ctx.move(to: a); ctx.addLine(to: b); ctx.addLine(to: c) }
            ctx.strokePath()

            // 中心：十字准星 ⇄ 实心圆点
            let c = CGPoint(x: rect.midX, y: rect.midY)
            ctx.saveGState()
            ctx.setAlpha(pose.centerAlpha)
            if pose.dot < 1 {
                ctx.saveGState()
                ctx.setAlpha(pose.centerAlpha * (1 - pose.dot))
                ctx.translateBy(x: c.x, y: c.y)
                ctx.rotate(by: pose.crossAngle)
                ctx.scaleBy(x: pose.crossScale, y: pose.crossScale)
                let a = s * 0.14
                ctx.move(to: CGPoint(x: -a, y: 0)); ctx.addLine(to: CGPoint(x: a, y: 0))
                ctx.move(to: CGPoint(x: 0, y: -a)); ctx.addLine(to: CGPoint(x: 0, y: a))
                ctx.strokePath()
                ctx.restoreGState()
            }
            if pose.dot > 0 {
                let r = s * 0.15 * pose.dot * pose.crossScale
                ctx.saveGState()
                ctx.setAlpha(pose.centerAlpha * pose.dot)
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ctx.restoreGState()
            }
            ctx.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// 菜单栏图标动画：平时静止，只在悬停、开始截图、截图完成、长截图 / 录屏进行中时播放。
@MainActor
final class MenuBarAnimator: NSObject {
    static let captureBegan = Notification.Name("KShotCaptureBegan")
    static let captureFinished = Notification.Name("KShotCaptureFinished")

    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    private var stateTimer: Timer?
    private var lastPose = MenuBarIcon.Pose.rest

    /// 一次性动画：开始时间、时长、按进度 t∈[0,1] 给出姿态
    private struct Transient { let start: Date; let duration: TimeInterval; let pose: (CGFloat) -> MenuBarIcon.Pose }
    private var transient: Transient?
    private enum Busy { case none, longShot, recording }
    private var busy = Busy.none
    private var busyStart = Date()

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// 调试：动画放慢倍数
    private let slow: Double = CommandLine.arguments.contains("--icon-demo") ? 6 : 1
    /// 调试：强制的进行中状态
    private var forcedBusy: Busy?

    init(button: NSStatusBarButton) {
        self.button = button
        super.init()
        button.image = MenuBarIcon.make()
        button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        let nc = NotificationCenter.default
        // 开始截图时遮罩会盖住菜单栏，所以“咔嚓”动画放在截图完成（复制 / 保存）时播放
        nc.addObserver(forName: Self.captureFinished, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playCaptured() }
        }
        // 长截图 / 录屏状态：低频轮询，变化时开始或停止循环动画
        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollBusy() }
        }
    }

    // MARK: - 触发

    @objc func mouseEntered(with event: NSEvent) {
        guard !reduceMotion, transient == nil else { return }
        transient = Transient(start: Date(), duration: 0.5 * slow) { Self.spinPose($0) }
        run()
    }
    @objc func mouseExited(with event: NSEvent) {}

    /// 快门：四角向内收再弹回，准星转 90°
    func playShutter() {
        guard !reduceMotion else { return }
        transient = Transient(start: Date(), duration: 0.5) { t in
            var p = MenuBarIcon.Pose.rest
            let squeeze = sin(min(1, t / 0.45) * .pi)            // 0→1→0
            p.cornerInset = 2.2 * squeeze - 0.6 * Self.springTail(t)
            p.crossAngle = .pi / 2 * Self.easeOutBack(t)
            p.crossScale = 1 - 0.25 * squeeze
            return p
        }
        run()
    }

    /// 截图完成：先快门收缩（0–0.5），再准星弹一下（0.5–1）
    func playCaptured() {
        guard !reduceMotion else { return }
        transient = Transient(start: Date(), duration: 0.95 * slow) { t in
            if t < 0.5 { return Self.shutterPose(t / 0.5) }
            return Self.popPose((t - 0.5) / 0.5)
        }
        run()
    }

    static func shutterPose(_ t: CGFloat) -> MenuBarIcon.Pose {
        var p = MenuBarIcon.Pose.rest
        let squeeze = sin(min(1, t / 0.7) * .pi)
        p.cornerInset = 0.8 * squeeze
        p.crossAngle = .pi / 2 * easeOutBack(t)
        p.crossScale = 1 - 0.2 * squeeze
        return p
    }

    static func popPose(_ t: CGFloat) -> MenuBarIcon.Pose {
        var p = MenuBarIcon.Pose.rest
        let pop = sin(t * .pi) * (1 - t * 0.3)
        p.crossScale = 1 + 0.3 * pop
        p.cornerInset = -0.6 * pop
        return p
    }

    /// 悬停：准星顺滑转 90°（停下时仍是“+”）
    static func spinPose(_ t: CGFloat) -> MenuBarIcon.Pose {
        var p = MenuBarIcon.Pose.rest
        p.crossAngle = .pi / 2 * easeOutBack(t)
        return p
    }

    /// 完成：准星放大弹一下，四角略微张开
    func playDone() {
        guard !reduceMotion else { return }
        transient = Transient(start: Date(), duration: 0.55) { t in
            var p = MenuBarIcon.Pose.rest
            let pop = sin(t * .pi) * (1 - t * 0.3)
            p.crossScale = 1 + 0.55 * pop
            p.cornerInset = -0.9 * pop
            return p
        }
        run()
    }

    private func pollBusy() {
        let now: Busy = forcedBusy ?? (ScreenRecorder.isRecording ? .recording : (LongScreenshotSession.current != nil ? .longShot : .none))
        guard now != busy else { return }
        busy = now
        busyStart = Date()
        run()
    }

    // MARK: - 逐帧

    private func run() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        var pose = MenuBarIcon.Pose.rest
        var animating = false


        // 进行中的循环动画
        let e = CGFloat(Date().timeIntervalSince(busyStart))
        switch busy {
        case .longShot:
            if !reduceMotion {
                pose.cornerInset = 0.9 * (1 - cos(e * 2 * .pi / 1.2)) / 2      // 四角呼吸
                pose.crossAngle += e * 2 * .pi / 2.4                            // 准星慢转
                animating = true
            }
        case .recording:
            pose.dot = 1
            if !reduceMotion {
                pose.centerAlpha = 0.45 + 0.55 * (1 + cos(e * 2 * .pi / 1.4)) / 2  // 圆点闪烁
                animating = true
            }
        case .none:
            break
        }

        // 一次性动画叠加在最上层
        if let tr = transient {
            let t = CGFloat(Date().timeIntervalSince(tr.start) / tr.duration)
            if t >= 1 {
                transient = nil
            } else {
                let p = tr.pose(t)
                pose.cornerInset += p.cornerInset
                pose.crossAngle += p.crossAngle
                pose.crossScale *= p.crossScale
                animating = true
            }
        }

        if pose != lastPose {
            lastPose = pose
            button?.image = MenuBarIcon.make(pose)
        }
        if !animating {
            timer?.invalidate()
            timer = nil
        }
    }

    private static func easeOutBack(_ t: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }

    /// 收缩结束后轻微回弹（0.45 之后的阻尼振荡）
    private static func springTail(_ t: CGFloat) -> CGFloat {
        guard t > 0.45 else { return 0 }
        let u = (t - 0.45) / 0.55
        return sin(u * .pi * 2) * (1 - u)
    }

    /// 调试：依次播放 悬停 → 截图完成 → 长截图 → 录屏，每段之间停 1 秒
    func runDemo() {
        let steps: [(Double, () -> Void)] = [
            (1, { self.mouseEntered(with: NSEvent()) }),
            (5, { self.playCaptured() }),
            (12, { self.forcedBusy = .longShot; self.pollBusy() }),
            (18, { self.forcedBusy = Busy.none; self.pollBusy() }),
            (19, { self.forcedBusy = .recording; self.pollBusy() }),
            (25, { self.forcedBusy = Busy.none; self.pollBusy() }),
        ]
        for (at, f) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { MainActor.assumeIsolated { Log.info("icon-demo step at \(at)s"); f() } }
        }
    }

    // MARK: - 调试：把各个状态渲染成一张图

    static func renderSheet(to url: URL) {
        let poses: [(String, MenuBarIcon.Pose)] = {
            var list: [(String, MenuBarIcon.Pose)] = [("静止", .rest)]
            for t in [0.3, 0.6] as [CGFloat] { list.append(("悬停 \(Int(t * 100))%", spinPose(t))) }
            for t in [0.2, 0.35, 0.5, 0.8] as [CGFloat] { list.append(("快门 \(Int(t * 100))%", shutterPose(t))) }
            for t in [0.3, 0.5] as [CGFloat] { list.append(("弹出 \(Int(t * 100))%", popPose(t))) }
            var l = MenuBarIcon.Pose.rest; l.cornerInset = 0.9; l.crossAngle = .pi / 3; list.append(("长截图", l))
            var r = MenuBarIcon.Pose.rest; r.dot = 1; list.append(("录屏", r))
            var r2 = r; r2.centerAlpha = 0.45; list.append(("录屏暗", r2))
            return list
        }()
        let scale: CGFloat = 6, cell: CGFloat = 18 * scale, pad: CGFloat = 24, labelH: CGFloat = 26
        let w = pad + CGFloat(poses.count) * (cell + pad)
        let h = cell + pad * 2 + labelH
        let img = NSImage(size: NSSize(width: w, height: h * 2), flipped: false) { _ in
            for (row, dark) in [false, true].enumerated() {
                let y0 = CGFloat(1 - row) * h
                (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                CGRect(x: 0, y: y0, width: w, height: h).fill()
                for (i, (name, pose)) in poses.enumerated() {
                    let x = pad + CGFloat(i) * (cell + pad)
                    let icon = MenuBarIcon.make(pose)
                    let tinted = NSImage(size: icon.size, flipped: false) { r in
                        icon.draw(in: r)
                        (dark ? NSColor.white : NSColor.black).set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: CGRect(x: x, y: y0 + pad + labelH, width: cell, height: cell))
                    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: dark ? NSColor.white : NSColor.black]
                    let str = NSAttributedString(string: name, attributes: attrs)
                    str.draw(at: CGPoint(x: x + (cell - str.size().width) / 2, y: y0 + 8))
                }
            }
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
