import AppKit
import Combine
import Sparkle

/// Sparkle 负责 HTTPS 下载、签名验证、替换应用及重启；偏好也由 Sparkle 保存。
@MainActor
final class AppUpdater: NSObject, ObservableObject, NSMenuItemValidation, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var lastCheckDate: Date?
    private var started = false
    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .assign(to: &$lastCheckDate)
    }

    func start() {
        guard !started else { return }
        started = true
        controller.startUpdater()
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        start()
        guard canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(sender)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        !started || canCheckForUpdates
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.info("发现更新 \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Log.info("更新检测或安装失败: \(error)")
    }
}
