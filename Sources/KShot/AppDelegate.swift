import AppKit
import Carbon
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var launchAtLoginItem: NSMenuItem!

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
            button.image = MenuBarIcon.make()
            button.toolTip = "KShot 截图  \(Settings.captureHotKey.display)"
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

        item("偏好设置…", #selector(openPreferences), key: ",")
        item("屏幕录制权限…", #selector(openPrivacySettings))
        launchAtLoginItem = item("开机自动启动", #selector(toggleLaunchAtLogin))
        menu.addItem(.separator())
        menu.delegate = self
        item("退出 KShot", #selector(quit), key: "q")
        statusItem.menu = menu
        refreshHotKeyTitles()
    }

    /// 菜单项上显示当前快捷键
    private func refreshHotKeyTitles() {
        func apply(_ mi: NSMenuItem, _ c: HotKeyCombo) {
            let name = HotKeyCombo.keyName(c.keyCode)
            if name.count == 1 {
                mi.keyEquivalent = name.lowercased()
                var m: NSEvent.ModifierFlags = []
                if c.modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
                if c.modifiers & UInt32(optionKey) != 0 { m.insert(.option) }
                if c.modifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
                if c.modifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
                mi.keyEquivalentModifierMask = m
            } else {
                mi.keyEquivalent = ""
            }
        }
        apply(captureItem, Settings.captureHotKey)
        apply(repeatItem, Settings.repeatHotKey)
        apply(recordItem, Settings.recordHotKey)
        statusItem.button?.toolTip = "KShot 截图  \(Settings.captureHotKey.display)"
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
        add("恢复所有钉图可点击", #selector(restorePinClicks), enabled: PinWindow.hasClickThrough)
        add("关闭所有钉图", #selector(closePins), enabled: count > 0)
    }

    @objc private func togglePins() { PinWindow.setAllHidden(!PinWindow.allHidden) }
    @objc private func restorePinClicks() { PinWindow.restoreAllClicks() }
    @objc private func closePins() { PinWindow.closeAll() }

    // MARK: - 全局快捷键

    private var repeatHotKey: HotKey?
    private var recordHotKey: HotKey?
    private var registered: [HotKeyCombo] = []

    private func registerHotKey() {
        let combos = [Settings.captureHotKey, Settings.repeatHotKey, Settings.recordHotKey]
        guard combos != registered else { return }
        registered = combos
        hotKey = nil
        repeatHotKey = nil
        recordHotKey = nil
        hotKey = HotKey(keyCode: combos[0].keyCode, modifiers: combos[0].modifiers) { [weak self] in self?.takeScreenshot() }
        repeatHotKey = HotKey(keyCode: combos[1].keyCode, modifiers: combos[1].modifiers) { [weak self] in self?.captureLastRegion() }
        recordHotKey = HotKey(keyCode: combos[2].keyCode, modifiers: combos[2].modifiers) { [weak self] in self?.toggleRecording() }
        for (name, ok, c) in [("截图", hotKey != nil, combos[0]), ("截取上次区域", repeatHotKey != nil, combos[1]), ("录屏", recordHotKey != nil, combos[2])] {
            Log.info(ok ? "快捷键 \(c.display)（\(name)）注册成功" : "注册快捷键 \(c.display)（\(name)）失败，可能被其他应用占用")
        }
        if statusItem != nil { refreshHotKeyTitles() }
    }

    /// 偏好设置里的快捷键是否注册成功
    func hotKeyFailures() -> [String] {
        var out: [String] = []
        if hotKey == nil { out.append("截图") }
        if repeatHotKey == nil { out.append("截取上次区域") }
        if recordHotKey == nil { out.append("录屏") }
        return out
    }

    // MARK: - 开机自动启动

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

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

    @objc private func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            UserDefaults.standard.set(true, forKey: "didSetupLaunchAtLogin")
        } catch {
            Log.info("切换开机自动启动失败: \(error)")
            let alert = NSAlert()
            alert.messageText = "无法修改开机自动启动"
            alert.informativeText = error.localizedDescription + "\n\n可在“系统设置 › 通用 › 登录项与扩展”中手动添加 KShot。"
            alert.runModal()
        }
        refreshLaunchAtLoginItem()
    }

    private func refreshLaunchAtLoginItem() {
        launchAtLoginItem.state = isLaunchAtLoginEnabled ? .on : .off
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

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshLaunchAtLoginItem()
        refreshPinsMenu()
        recordItem.title = ScreenRecorder.isRecording ? "停止录屏" : "录屏"
    }
}
