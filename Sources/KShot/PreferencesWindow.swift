import AppKit
import Carbon
import SwiftUI

/// 设置窗口：左侧玻璃侧栏 + 右侧分组卡片（SwiftUI）
@MainActor
final class PreferencesWindow: NSWindow {
    enum Tab: String, CaseIterable, Identifiable {
        case general, permissions, save, shortcuts, history, about
        var id: Self { self }

        var title: String {
            switch self {
            case .general: return "通用"
            case .permissions: return "权限"
            case .save: return "保存"
            case .shortcuts: return "快捷键"
            case .history: return "历史"
            case .about: return "关于"
            }
        }

        var subtitle: String {
            switch self {
            case .general: return "截图、录屏与启动时的行为。"
            case .permissions: return "KShot 需要的系统权限。修改后回到这里即可看到最新状态。"
            case .save: return "截图保存到哪里、叫什么名字、用什么格式。"
            case .shortcuts: return "点击快捷键后按下新的组合键即可修改。"
            case .history: return "最近的截图会保留在菜单栏里，随时复制、钉图或再编辑。"
            case .about: return "轻量的 macOS 截图工具。"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .permissions: return "hand.raised.fill"
            case .save: return "folder.fill"
            case .shortcuts: return "command"
            case .history: return "clock.fill"
            case .about: return "info"
            }
        }

        var color: Color {
            switch self {
            case .general: return Color(white: 0.55)
            case .permissions: return .blue
            case .save: return .green
            case .shortcuts: return .indigo
            case .history: return .orange
            case .about: return .teal
            }
        }
    }

    private static var shared: PreferencesWindow?
    private let model = PrefsModel()

    static func show(tab: Tab? = nil) {
        let w = shared ?? PreferencesWindow()
        shared = w
        if let tab { w.model.page = tab }
        w.model.refresh()
        if !w.isVisible { w.center() }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init() {
        let size = CGSize(width: 780, height: 600)
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        title = "KShot 设置"
        isMovableByWindowBackground = true
        minSize = size
        isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SettingsView(model: model, window: self))
        host.sizingOptions = []   // 窗口尺寸固定，不跟随 SwiftUI 的理想尺寸
        contentView = host
        setFrame(CGRect(origin: .zero, size: size), display: false)
    }

    override func resignKey() {
        super.resignKey()
        model.stopRecording()
    }

    // 调试
    var debugModel: PrefsModel { model }
}

// MARK: - 数据

@MainActor
final class PrefsModel: ObservableObject {
    @Published var page: PreferencesWindow.Tab = .general
    @Published private(set) var recording: ShortcutAction?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    init() {
        // 设置变化（含快捷键重新注册）后刷新界面
        for name in [Settings.changed, History.changed, NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() { objectWillChange.send() }

    /// 读写 Settings 的绑定；写入后 Settings 会发通知，界面随之刷新
    func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: { set($0) })
    }

    // MARK: 快捷键

    /// 重复的组合键与注册失败的全局快捷键
    var conflicts: Set<ShortcutAction> {
        var owners: [HotKeyCombo: [ShortcutAction]] = [:]
        for a in ShortcutAction.allCases { if let c = a.combo { owners[c, default: []].append(a) } }
        var out = Set(owners.values.filter { $0.count > 1 }.joined())
        out.formUnion(failures)
        return out
    }

    var failures: [ShortcutAction] { (NSApp.delegate as? AppDelegate)?.hotKeyFailures() ?? [] }

    /// 冲突说明；没有问题时为 nil
    var conflictMessage: String? {
        var owners: [HotKeyCombo: [ShortcutAction]] = [:]
        for a in ShortcutAction.allCases { if let c = a.combo { owners[c, default: []].append(a) } }
        if let (c, d) = owners.first(where: { $0.value.count > 1 }) {
            return "\(c.display) 同时分给了“\(d.map(\.title).joined(separator: "”“"))”，全局快捷键会抢先生效。"
        }
        let failed = failures
        if !failed.isEmpty {
            return "“\(failed.map(\.title).joined(separator: "”“"))”的快捷键注册失败，可能被系统或其他应用占用。"
        }
        return nil
    }

    func toggleRecording(_ a: ShortcutAction) {
        recording == a ? stopRecording() : startRecording(a)
    }

    func startRecording(_ a: ShortcutAction) {
        stopRecording()
        recording = a
        HotKey.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            // 本地事件监听总在主线程回调
            nonisolated(unsafe) let event = e
            guard let self else { return e }
            let consumed = MainActor.assumeIsolated { self.handle(event) }
            return consumed ? nil : e
        }
    }

    func stopRecording() {
        guard recording != nil else { return }
        recording = nil
        HotKey.suspended = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func reset(_ a: ShortcutAction) {
        stopRecording()
        Settings.setShortcut(a, a.defaultCombo)
    }

    func resetAll() {
        stopRecording()
        Settings.resetAllShortcuts()
    }

    private func handle(_ e: NSEvent) -> Bool {
        guard let a = recording else { return false }
        let flags = e.modifierFlags.intersection([.command, .control, .option, .shift])
        switch Int(e.keyCode) {
        case kVK_Escape:
            stopRecording()
            return true
        case kVK_Delete, kVK_ForwardDelete:
            stopRecording()
            Settings.setShortcut(a, nil)
            return true
        default:
            break
        }
        // 至少要有 ⌘ / ⌃ / ⌥ 之一，避免占用普通按键
        guard !flags.intersection([.command, .control, .option]).isEmpty else {
            NSSound.beep()
            return true
        }
        stopRecording()
        Settings.setShortcut(a, HotKeyCombo(event: e))   // 全局快捷键同步重新注册，随后界面刷新
        return true
    }
}

// MARK: - 根视图

private struct SettingsView: View {
    @ObservedObject var model: PrefsModel
    weak var window: NSWindow?

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 220)
                .padding(10)
            ScrollView {
                Group {
                    switch model.page {
                    case .general: GeneralPage(model: model)
                    case .permissions: PermissionsPage(model: model)
                    case .save: SavePage(model: model, window: window)
                    case .shortcuts: ShortcutsPage(model: model)
                    case .history: HistoryPage(model: model)
                    case .about: AboutPage()
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 28)
                .padding(.vertical, 22)
            }
            .id(model.page)   // 切换页面时回到顶部
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.groupedBackground)
        .ignoresSafeArea()
        .onChange(of: model.page) { _, _ in
            // 不让文件名输入框自动获得焦点，避免误输入
            DispatchQueue.main.async { window?.makeFirstResponder(nil) }
        }
        .onAppear { DispatchQueue.main.async { window?.makeFirstResponder(nil) } }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: PrefsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("KShot").font(.system(size: 15, weight: .semibold))
                    Text("设置").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 14)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            VStack(spacing: 2) {
                ForEach(PreferencesWindow.Tab.allCases) { t in
                    SidebarRow(tab: t, selected: model.page == t, badge: t == .permissions && !Permissions.screenRecording) { model.page = t }
                }
            }
            .padding(.horizontal, 8)
            Spacer()
        }
        .frame(maxHeight: .infinity)
        .glassPanel(cornerRadius: 22)
    }
}

private struct SidebarRow: View {
    let tab: PreferencesWindow.Tab
    let selected: Bool
    var badge = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: tab.symbol, color: tab.color, size: 24)
                Text(tab.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer()
                if badge {
                    // 缺少必需权限时的提醒
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(selected ? Color.white : Color.orange)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor : hovered ? Color.primary.opacity(0.06) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// iOS 设置风格的彩色圆角图标
private struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.12), radius: size * 0.04, y: size * 0.03)
    }
}

// MARK: - 分组卡片

/// 页面：竖排若干卡片
private struct Page<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 页面顶部的大图标卡片
private struct PageHeader: View {
    let tab: PreferencesWindow.Tab

    var body: some View {
        Card {
            VStack(spacing: 8) {
                IconTile(symbol: tab.symbol, color: tab.color, size: 56)
                Text(tab.title).font(.system(size: 20, weight: .bold))
                Text(tab.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 16)
        }
    }
}

/// 圆角分组卡片：可选的标题与说明
private struct Card<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let header {
                Text(header)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cardBackground))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 卡片里的一行：标题（可带说明）+ 右侧控件
private struct Row<Trailing: View>: View {
    let title: String
    var detail: String?
    var divider = true
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            if divider {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.leading, 14)
            }
        }
    }
}

private struct ToggleRow: View {
    let title: String
    var detail: String?
    var divider = true
    @Binding var isOn: Bool

    var body: some View {
        Row(title: title, detail: detail, divider: divider) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

// MARK: - 通用

private struct GeneralPage: View {
    @ObservedObject var model: PrefsModel

    var body: some View {
        Page {
            PageHeader(tab: .general)
            Card(header: "截图") {
                ToggleRow(title: "框选时显示放大镜", detail: "默认只在工具条点吸管按钮后显示",
                          isOn: model.bind({ Settings.showMagnifier }, { Settings.showMagnifier = $0 }))
                ToggleRow(title: "快门声", detail: "截图完成时播放",
                          isOn: model.bind({ Settings.playSound }, { Settings.playSound = $0 }))
                ToggleRow(title: "窗口截图带阴影", detail: "单击选中窗口后直接完成时，输出带系统阴影、背景透明的窗口图", divider: false,
                          isOn: model.bind({ Settings.windowShadow }, { Settings.windowShadow = $0 }))
            }
            Card(header: "录屏") {
                ToggleRow(title: "录入鼠标指针", divider: false,
                          isOn: model.bind({ Settings.recordShowsCursor }, { Settings.recordShowsCursor = $0 }))
            }
            Card(header: "启动") {
                // 每次读系统登录项的实际状态（用户也可能在系统设置里改）
                ToggleRow(title: "开机自动启动", detail: "登录后在菜单栏常驻；也可在“系统设置 › 通用 › 登录项与扩展”中管理", divider: false,
                          isOn: Binding(get: { LaunchAtLogin.isEnabled }, set: { on in
                              LaunchAtLogin.set(on)
                              model.refresh()
                          }))
            }
        }
    }
}

// MARK: - 保存

private struct SavePage: View {
    @ObservedObject var model: PrefsModel
    weak var window: NSWindow?
    @State private var template = Settings.fileNameTemplate

    var body: some View {
        let dir = Settings.saveDirectory
        Page {
            PageHeader(tab: .save)
            Card(header: "位置") {
                Row(title: "默认位置") {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: dir.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(FileManager.default.displayName(atPath: dir.path))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(dir.path)
                        Button("选择…", action: chooseDirectory)
                            .buttonBorderShape(.capsule)
                    }
                }
                ToggleRow(title: "保存时不弹出面板", detail: "按保存\(ShortcutAction.save.combo.map { "（\($0.display)）" } ?? "")直接存到默认位置",
                          isOn: model.bind({ Settings.quickSave }, { Settings.quickSave = $0 }))
                ToggleRow(title: "完成时自动保存", detail: "复制到剪贴板的同时，存一份到默认位置", divider: false,
                          isOn: model.bind({ Settings.autoSaveOnConfirm }, { Settings.autoSaveOnConfirm = $0 }))
            }
            VStack(alignment: .leading, spacing: 8) {
                Card(header: "文件") {
                    Row(title: "文件名") {
                        TextField("", text: $template, prompt: Text("截图 {date} {time}"))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .padding(.horizontal, 10)
                            .frame(width: 250, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
                            .onChange(of: template) { _, v in
                                let t = v.trimmingCharacters(in: .whitespaces)
                                Settings.fileNameTemplate = t.isEmpty ? "截图 {date} {time}" : t
                            }
                    }
                    Row(title: "格式", divider: false) {
                        Picker("", selection: model.bind({ Settings.imageFormat }, { Settings.imageFormat = $0 })) {
                            ForEach(ImageFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                HStack(spacing: 6) {
                    Text("插入")
                    ForEach(["{date}", "{time}", "{w}", "{h}"], id: \.self) { token in
                        Button(token) { template += (template.hasSuffix(" ") || template.isEmpty ? "" : " ") + token }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                    }
                    Spacer()
                    Text("示例：\(Settings.fileName(width: 1280, height: 720))")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.saveDirectory
        panel.prompt = "选择"
        let done: (NSApplication.ModalResponse) -> Void = { r in
            if r == .OK, let url = panel.url { Settings.saveDirectory = url }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
}

// MARK: - 快捷键

private struct ShortcutsPage: View {
    @ObservedObject var model: PrefsModel

    var body: some View {
        Page {
            PageHeader(tab: .shortcuts)
            if let msg = model.conflictMessage {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
            }
            Card(header: "全局", footer: "在任何应用中都可用。") {
                rows(ShortcutAction.globals)
            }
            Card(header: "截图时", footer: "选好区域后，或在图片编辑窗口中可用。") {
                rows(ShortcutAction.locals)
            }
            HStack {
                Text("修改时需包含 ⌘、⌃ 或 ⌥；⌫ 清除，Esc 取消。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全部恢复默认", action: model.resetAll)
                    .buttonBorderShape(.capsule)
            }
            .padding(.horizontal, 14)
        }
    }

    private func rows(_ actions: [ShortcutAction]) -> some View {
        ForEach(actions, id: \.self) { a in
            Row(title: a.title, divider: a != actions.last) { ShortcutField(model: model, action: a) }
        }
    }
}

/// 快捷键录制框：键帽样式显示组合键，点击后录制
private struct ShortcutField: View {
    @ObservedObject var model: PrefsModel
    let action: ShortcutAction

    var body: some View {
        let combo = action.combo
        let recording = model.recording == action
        let conflict = model.conflicts.contains(action)
        HStack(spacing: 8) {
            if combo != action.defaultCombo, !recording {
                Button { model.reset(action) } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("恢复默认（\(action.defaultCombo?.display ?? "未设置")）")
            }
            Button { model.toggleRecording(action) } label: {
                HStack(spacing: 3) {
                    if recording {
                        Text("按下快捷键…").foregroundStyle(Color.accentColor)
                    } else if let combo {
                        ForEach(Array(combo.parts.enumerated()), id: \.offset) { _, p in
                            KeyCap(text: p, alert: conflict)
                        }
                    } else {
                        Text("未设置").foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .frame(minWidth: 116, minHeight: 28)
                .padding(.horizontal, 4)
                .background {
                    Capsule().fill(recording ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
                }
                .overlay {
                    Capsule().strokeBorder(recording ? Color.accentColor : conflict ? Color.red.opacity(0.85) : .clear, lineWidth: 1.5)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct KeyCap: View {
    let text: String
    var alert = false

    var body: some View {
        Text(text)
            .foregroundStyle(alert ? Color.red : Color.primary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.keyCap)
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.8)
            }
    }
}

// MARK: - 历史

private struct HistoryPage: View {
    @ObservedObject var model: PrefsModel
    @State private var confirmClear = false

    var body: some View {
        let count = History.items().count
        Page {
            PageHeader(tab: .history)
            Card {
                ToggleRow(title: "记录截图历史", detail: "在 菜单栏 › 最近截图 中查看",
                          isOn: model.bind({ Settings.historyEnabled }, { Settings.historyEnabled = $0 }))
                Row(title: "保留", divider: false) {
                    Picker("", selection: model.bind({ Settings.historyLimit }, { Settings.historyLimit = $0 })) {
                        ForEach([10, 30, 50, 100, 200], id: \.self) { Text("最多 \($0) 张").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!Settings.historyEnabled)
                }
            }
            Card(header: "已保存") {
                Row(title: "截图数量") {
                    Text("\(count) 张").foregroundStyle(.secondary)
                }
                Row(title: "历史文件夹", divider: false) {
                    HStack(spacing: 8) {
                        Button("在访达中打开") { NSWorkspace.shared.open(History.directory) }
                        Button("清空…", role: .destructive) { confirmClear = true }
                            .disabled(count == 0)
                    }
                    .buttonBorderShape(.capsule)
                }
            }
        }
        .confirmationDialog("清空全部截图历史？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { History.clear() }
        } message: {
            Text("历史文件夹里的截图会被删除，无法恢复。")
        }
    }
}

// MARK: - 权限

/// 系统权限状态与跳转
enum Permissions {
    /// 调试参数 --fake-no-permission 模拟未授权，用于核对界面
    static var screenRecording: Bool { !CommandLine.arguments.contains("--fake-no-permission") && CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    /// 屏幕录制授权后要重启进程才生效
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

private struct PermissionsPage: View {
    @ObservedObject var model: PrefsModel

    var body: some View {
        let screen = Permissions.screenRecording
        let ax = Permissions.accessibility
        Page {
            PageHeader(tab: .permissions)
            Card(header: "必需", footer: screen ? nil : "在“系统设置 › 隐私与安全性 › 录屏与系统录音”中打开 KShot，然后重新启动 KShot。") {
                Row(title: "屏幕录制", detail: "截图、长截图、录屏都需要") {
                    StatusBadge(ok: screen)
                }
                Row(title: "系统设置", divider: !screen) {
                    Button("打开录屏与系统录音…", action: Permissions.openScreenRecordingSettings)
                }
                if !screen {
                    Row(title: "已经打开了权限？", detail: "macOS 要求重新启动应用后才会生效", divider: false) {
                        Button("重新启动 KShot", action: Permissions.relaunch)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            Card(header: "可选") {
                Row(title: "辅助功能", detail: "长截图的“自动滚动”需要；不打开也可以自己滚动截图") {
                    StatusBadge(ok: ax, offText: "未打开", offColor: .secondary)
                }
                Row(title: "系统设置", divider: false) {
                    Button("打开辅助功能…", action: Permissions.openAccessibilitySettings)
                }
            }
        }
    }
}

private struct StatusBadge: View {
    let ok: Bool
    var offText = "未允许"
    var offColor: Color = .orange

    var body: some View {
        Label(ok ? "已允许" : offText, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ok ? Color.green : offColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill((ok ? Color.green : offColor).opacity(0.12)))
    }
}

// MARK: - 关于

private struct AboutPage: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        Page {
            Card {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 80, height: 80)
                    Text("KShot").font(.system(size: 20, weight: .bold))
                    Text("版本 \(version)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            Card {
                Row(title: "软件更新") {
                    Button("检查更新…") { updater.checkForUpdates() }
                        .buttonBorderShape(.capsule)
                        .disabled(!updater.canCheckForUpdates)
                }
                Row(title: "自动检查更新", detail: "每天检查一次，有新版时可直接下载安装。") {
                    Toggle("自动检查更新", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.setAutomaticChecks($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                Row(title: "上次检查", divider: false) {
                    if let date = updater.lastCheckDate {
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("尚未检查").foregroundStyle(.secondary)
                    }
                }
            }
            Card {
                Row(title: "源代码") {
                    Link("github.com/FranckStone/kshot", destination: URL(string: "https://github.com/FranckStone/kshot")!)
                }
                Row(title: "日志", divider: false) {
                    Button("在访达中显示") {
                        NSWorkspace.shared.open(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs"))
                    }
                    .buttonBorderShape(.capsule)
                }
            }
        }
    }
}

// MARK: - 玻璃与配色

private extension Color {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    /// 分组底色：浅色偏灰，让白色卡片浮出来
    static let groupedBackground = dynamic(light: NSColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1), dark: NSColor(white: 0.10, alpha: 1))
    static let cardBackground = dynamic(light: .white, dark: NSColor(white: 0.17, alpha: 1))
    static let keyCap = dynamic(light: .white, dark: NSColor(white: 0.32, alpha: 1))
}

private extension View {
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
