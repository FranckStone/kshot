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

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = MenuBarIcon.make()
            button.toolTip = "KShot 截图  ⌃⌘A"
        }

        let menu = NSMenu()
        let shot = NSMenuItem(title: "截图", action: #selector(takeScreenshot), keyEquivalent: "a")
        shot.keyEquivalentModifierMask = [.control, .command]
        shot.target = self
        menu.addItem(shot)
        menu.addItem(.separator())

        let perm = NSMenuItem(title: "屏幕录制权限…", action: #selector(openPrivacySettings), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)

        launchAtLoginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.delegate = self

        let quit = NSMenuItem(title: "退出 KShot", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    // MARK: - 全局快捷键 ⌃⌘A

    private func registerHotKey() {
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | cmdKey)) { [weak self] in
            self?.takeScreenshot()
        }
        if hotKey == nil {
            Log.info("注册快捷键 ⌃⌘A 失败，可能被其他应用占用")
        } else {
            Log.info("快捷键 ⌃⌘A 注册成功")
        }
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
    }
}
