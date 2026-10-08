import AppKit
import Carbon
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var iconAnimator: MenuBarAnimator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        registerHotKey()
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKey() }
        }
        Log.info("启动 \(Bundle.main.bundlePath)，录屏权限=\(CGPreflightScreenCaptureAccess())")
        setupLaunchAtLoginDefault()
        TextRecognizer.warmUp()
        // 首次启动时主动触发一次权限检查，避免第一次截图时才弹窗
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        // 调试：N 秒后用系统 screencapture 抓一张真实屏幕（包含本应用的遮罩窗口）
        if let i = CommandLine.arguments.firstIndex(of: "--snap-after"), i + 2 < CommandLine.arguments.count,
           let sec = Double(CommandLine.arguments[i + 1]) {
            let path = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", path]
                try? p.run()
                p.waitUntilExit()
                Log.info("snap-after wrote \(path) status=\(p.terminationStatus)")
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--icon-sheet"), i + 1 < CommandLine.arguments.count {
            MenuBarAnimator.renderSheet(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--vision-probe") {
            StitchProbe.run()
            NSApp.terminate(nil)
            return
        }
        if FeatureTests.runIfRequested() { return }
        if CommandLine.arguments.contains("--stitch-test") {
            StitchTest.run()
            NSApp.terminate(nil)
            return
        }
        // 调试用：把整屏抓成 PNG 后退出
        if let i = CommandLine.arguments.firstIndex(of: "--capture-screen"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            Task { @MainActor in
                if let shot = try? await ScreenCapturer.captureAll().first, let data = Exporter.pngData(shot.image) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--longshot-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { LongShotDemo.run() }
            return
        }
        // 调试用：直接对主屏上的区域 x,y,w,h（pt，左上原点）启动长截图
        if let i = CommandLine.arguments.firstIndex(of: "--longshot"), i + 1 < CommandLine.arguments.count {
            let parts = CommandLine.arguments[i + 1].split(separator: ",").compactMap { Double($0) }
            if parts.count == 4, let screen = NSScreen.screens.first {
                let region = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    LongScreenshotSession(screen: screen, region: region).start()
                }
            }
            return
        }
        // 调试用：打开正式安装包的设置，核对系统标题栏和控件样式。
        if CommandLine.arguments.contains("--preferences") {
            AppUpdater.shared.start()
            DispatchQueue.main.async { PreferencesWindow.show() }
            return
        }
        AppUpdater.shared.start()
        if CommandLine.arguments.contains("--check-updates") {
            AppUpdater.shared.checkForUpdates()
        }
        // 调试用：启动后立刻截图
        if CommandLine.arguments.contains("--shoot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.takeScreenshot() }
        }
    }

    // MARK: - 菜单栏

    private var captureItem: NSMenuItem!
    private var repeatItem: NSMenuItem!
    private var recordItem: NSMenuItem!
    private var pinsItem: NSMenuItem!
    private let historyMenu = HistoryMenu()

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            iconAnimator = MenuBarAnimator(button: button)
            if CommandLine.arguments.contains("--icon-demo") { iconAnimator?.runDemo() }
        }

        let menu = NSMenu()
        @discardableResult func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.target = self
            menu.addItem(mi)
            return mi
        }
        captureItem = item("截图", #selector(takeScreenshot))
        repeatItem = item("截取上次区域", #selector(captureLastRegion))
        let delay = NSMenuItem(title: "延时截图", action: nil, keyEquivalent: "")
        let delayMenu = NSMenu()
        for sec in [3, 5, 10] {
            let mi = NSMenuItem(title: "\(sec) 秒后", action: #selector(delayedScreenshot(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = sec
            delayMenu.addItem(mi)
            if sec == ShortcutAction.delaySeconds { delayItem = mi }
        }
        delay.submenu = delayMenu
        menu.addItem(delay)
        recordItem = item("录屏", #selector(toggleRecording))
        menu.addItem(.separator())

        let history = NSMenuItem(title: "最近截图", action: nil, keyEquivalent: "")
        history.submenu = historyMenu.menu
        menu.addItem(history)
        pinsItem = NSMenuItem(title: "钉图", action: nil, keyEquivalent: "")
        pinsItem.submenu = NSMenu()
        menu.addItem(pinsItem)
        menu.addItem(.separator())

        item("设置…", #selector(openPreferences), key: ",")
        let updates = item("检查更新…", #selector(AppUpdater.checkForUpdates(_:)))
        updates.target = AppUpdater.shared
        menu.addItem(.separator())
        menu.delegate = self
        item("退出 KShot", #selector(quit), key: "q")
        statusItem.menu = menu
        refreshHotKeyTitles()
    }

    private var delayItem: NSMenuItem?

    /// 菜单项上显示当前快捷键
    private func applyShortcut(_ mi: NSMenuItem, _ a: ShortcutAction) {
        if let k = a.combo?.menuKeyEquivalent {
            mi.keyEquivalent = k.key
            mi.keyEquivalentModifierMask = k.mask
        } else {
            mi.keyEquivalent = ""
        }
    }

    private func refreshHotKeyTitles() {
        applyShortcut(captureItem, .capture)
        applyShortcut(repeatItem, .repeatRegion)
        applyShortcut(recordItem, .record)
        if let delayItem { applyShortcut(delayItem, .delayCapture) }
        statusItem.button?.toolTip = "KShot 截图" + ShortcutAction.capture.tipSuffix
    }

    private func refreshPinsMenu() {
        let menu = pinsItem.submenu!
        menu.removeAllItems()
        let count = PinWindow.count
        pinsItem.title = count == 0 ? "钉图" : "钉图（\(count)）"
        func add(_ t: String, _ sel: Selector, enabled: Bool) {
            let mi = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            mi.target = self
            mi.isEnabled = enabled
            menu.addItem(mi)
        }
        menu.autoenablesItems = false
        add(PinWindow.allHidden ? "显示所有钉图" : "隐藏所有钉图", #selector(togglePins), enabled: count > 0)
        applyShortcut(menu.items.last!, .togglePins)
        add("恢复所有钉图可点击", #selector(restorePinClicks), enabled: PinWindow.hasClickThrough)
        add("关闭所有钉图", #selector(closePins), enabled: count > 0)
    }

    @objc private func togglePins() { PinWindow.setAllHidden(!PinWindow.allHidden) }
    @objc private func restorePinClicks() { PinWindow.restoreAllClicks() }
    @objc private func closePins() { PinWindow.closeAll() }

    // MARK: - 全局快捷键

    private var hotKeys: [ShortcutAction: HotKey] = [:]
    private var registered: [ShortcutAction: HotKeyCombo]?

    private func registerHotKey() {
        var combos: [ShortcutAction: HotKeyCombo] = [:]
        for a in ShortcutAction.globals { combos[a] = a.combo }
        guard combos != registered else { return }
        registered = combos
        hotKeys = [:]   // 先全部注销，避免互换两个快捷键时注册冲突
        for a in ShortcutAction.globals {
            guard let c = combos[a] else { continue }
            if let hk = HotKey(keyCode: c.keyCode, modifiers: c.modifiers, handler: { [weak self] in self?.perform(a) }) {
                hotKeys[a] = hk
                Log.info("快捷键 \(c.display)（\(a.title)）注册成功")
            } else {
                Log.info("注册快捷键 \(c.display)（\(a.title)）失败，可能被其他应用占用")
            }
        }
        if statusItem != nil { refreshHotKeyTitles() }
    }

    private func perform(_ a: ShortcutAction) {
        switch a {
        case .capture: takeScreenshot()
        case .repeatRegion: captureLastRegion()
        case .delayCapture: CaptureSession.shared.begin(delay: ShortcutAction.delaySeconds)
        case .record: toggleRecording()
        case .togglePins: if PinWindow.count > 0 { togglePins() }
        default: break
        }
    }

    /// 已设置但注册失败的全局快捷键
    func hotKeyFailures() -> [ShortcutAction] {
        ShortcutAction.globals.filter { $0.combo != nil && hotKeys[$0] == nil }
    }

    // MARK: - 开机自动启动

    /// 首次从 /Applications 启动时默认打开开机自启
    private func setupLaunchAtLoginDefault() {
        let key = "didSetupLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
            Log.info("已注册开机自动启动")
        } catch {
            Log.info("注册开机自动启动失败: \(error)")
        }
    }

    // MARK: - Actions

    @objc func takeScreenshot() {
        CaptureSession.shared.begin()
    }

    @objc func captureLastRegion() {
        CaptureSession.shared.beginWithLastRegion()
    }

    @objc private func delayedScreenshot(_ sender: NSMenuItem) {
        CaptureSession.shared.begin(delay: sender.tag)
    }

    @objc func toggleRecording() {
        CaptureSession.shared.beginRecording()
    }

    @objc private func openPreferences() {
        PreferencesWindow.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshPinsMenu()
        recordItem.title = ScreenRecorder.isRecording ? "停止录屏" : "录屏"
    }
}

/// 开机自动启动（登录项）
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            UserDefaults.standard.set(true, forKey: "didSetupLaunchAtLogin")
        } catch {
            Log.info("切换开机自动启动失败: \(error)")
            let alert = NSAlert()
            alert.messageText = "无法修改开机自动启动"
            alert.informativeText = error.localizedDescription + "\n\n可在“系统设置 › 通用 › 登录项与扩展”中手动添加 KShot。"
            alert.runModal()
        }
    }
}
