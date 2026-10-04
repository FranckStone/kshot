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
        // 首次启动时主动触发一次权限检查，避免第一次截图时才弹窗
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
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

    // MARK: - 全局快捷键 ⌃⌘A（与微信一致）

    private func registerHotKey() {
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | cmdKey)) { [weak self] in
            self?.takeScreenshot()
        }
        if hotKey == nil {
            Log.info("注册快捷键 ⌃⌘A 失败，可能被其他应用（如微信）占用")
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
