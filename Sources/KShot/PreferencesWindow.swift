import AppKit
import Carbon

/// 偏好设置窗口
@MainActor
final class PreferencesWindow: NSWindow {
    private static var shared: PreferencesWindow?

    static func show() {
        let w = shared ?? PreferencesWindow()
        shared = w
        w.reload()
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let captureRecorder = HotKeyRecorder(defaultCombo: .capture)
    private let repeatRecorder = HotKeyRecorder(defaultCombo: .repeatRegion)
    private let recordRecorder = HotKeyRecorder(defaultCombo: .record)
    private let hotKeyWarning = NSTextField(labelWithString: "")
    private let magnifier = NSButton(checkboxWithTitle: "选区时显示放大镜和颜色值", target: nil, action: nil)
    private let sound = NSButton(checkboxWithTitle: "截图完成时播放快门声", target: nil, action: nil)
    private let shadow = NSButton(checkboxWithTitle: "单击选中窗口后完成：输出带系统阴影的透明背景窗口图", target: nil, action: nil)
    private let cursor = NSButton(checkboxWithTitle: "录屏时录入鼠标指针", target: nil, action: nil)
    private let dirLabel = NSPathControl()
    private let nameField = NSTextField()
    private let formatPopup = NSPopUpButton()
    private let quickSave = NSButton(checkboxWithTitle: "⌘S 直接保存到默认位置，不弹出保存面板", target: nil, action: nil)
    private let autoSave = NSButton(checkboxWithTitle: "完成截图（复制到剪贴板）时同时自动保存一份", target: nil, action: nil)
    private let history = NSButton(checkboxWithTitle: "记录截图历史（菜单栏 › 最近截图）", target: nil, action: nil)
    private let historyLimit = NSPopUpButton()
    private let namePreview = NSTextField(labelWithString: "")

    private init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 560, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "KShot 偏好设置"
        isReleasedWhenClosed = false
        level = .floating

        for c in [magnifier, sound, shadow, cursor, quickSave, autoSave, history] {
            c.target = self
            c.action = #selector(changed)
        }
        for f in ImageFormat.allCases { formatPopup.addItem(withTitle: f.title) }
        formatPopup.target = self
        formatPopup.action = #selector(changed)
        for n in [10, 30, 50, 100, 200] { historyLimit.addItem(withTitle: "最多 \(n) 张"); historyLimit.lastItem?.tag = n }
        historyLimit.target = self
        historyLimit.action = #selector(changed)
        nameField.placeholderString = "截图 {date} {time}"
        nameField.target = self
        nameField.action = #selector(changed)
        nameField.delegate = self
        dirLabel.pathStyle = .standard
        dirLabel.isEditable = false
        dirLabel.backgroundColor = .clear
        hotKeyWarning.textColor = .systemRed
        hotKeyWarning.font = .systemFont(ofSize: 11)
        namePreview.textColor = .secondaryLabelColor
        namePreview.font = .systemFont(ofSize: 11)
        for r in [captureRecorder, repeatRecorder, recordRecorder] {
            r.onChange = { [weak self] in self?.changed() }
        }

        let choose = NSButton(title: "选择…", target: self, action: #selector(chooseDirectory))
        choose.bezelStyle = .rounded
        let dirRow = NSStackView(views: [dirLabel, choose])
        dirRow.spacing = 8
        dirLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dirLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        func header(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 13, weight: .semibold)
            return l
        }
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            return l
        }
        let empty = { NSView() }
        let grid = NSGridView(views: [
            [header("快捷键"), empty()],
            [label("截图"), captureRecorder],
            [label("截取上次区域"), repeatRecorder],
            [label("录屏 / 停止录屏"), recordRecorder],
            [empty(), hotKeyWarning],
            [header("截图"), empty()],
            [empty(), magnifier],
            [empty(), sound],
            [empty(), shadow],
            [empty(), cursor],
            [header("保存"), empty()],
            [label("默认位置"), dirRow],
            [label("文件名"), nameField],
            [empty(), namePreview],
            [label("格式"), formatPopup],
            [empty(), quickSave],
            [empty(), autoSave],
            [header("历史"), empty()],
            [empty(), history],
            [label("保留"), historyLimit],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 110
        for i in [0, 5, 10, 17] {
            grid.row(at: i).mergeCells(in: NSRange(location: 0, length: 2))
            grid.row(at: i).topPadding = i == 0 ? 0 : 10
            grid.cell(atColumnIndex: 0, rowIndex: i).xPlacement = .leading
        }
        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        grid.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        contentView = root
        setContentSize(root.fittingSize)
    }

    func reload() {
        captureRecorder.combo = Settings.captureHotKey
        repeatRecorder.combo = Settings.repeatHotKey
        recordRecorder.combo = Settings.recordHotKey
        magnifier.state = Settings.showMagnifier ? .on : .off
        sound.state = Settings.playSound ? .on : .off
        shadow.state = Settings.windowShadow ? .on : .off
        cursor.state = Settings.recordShowsCursor ? .on : .off
        dirLabel.url = Settings.saveDirectory
        nameField.stringValue = Settings.fileNameTemplate
        formatPopup.selectItem(at: ImageFormat.allCases.firstIndex(of: Settings.imageFormat) ?? 0)
        quickSave.state = Settings.quickSave ? .on : .off
        autoSave.state = Settings.autoSaveOnConfirm ? .on : .off
        history.state = Settings.historyEnabled ? .on : .off
        historyLimit.selectItem(withTag: Settings.historyLimit)
        if historyLimit.selectedItem == nil { historyLimit.selectItem(withTag: 30) }
        historyLimit.isEnabled = Settings.historyEnabled
        refreshHints()
    }

    private func refreshHints() {
        namePreview.stringValue = "示例：\(Settings.fileName(width: 1280, height: 720))    可用 {date} {time} {w} {h}"
        let failed = (NSApp.delegate as? AppDelegate)?.hotKeyFailures() ?? []
        let combos = [captureRecorder.combo, repeatRecorder.combo, recordRecorder.combo]
        if Set(combos.map(\.display)).count < combos.count {
            hotKeyWarning.stringValue = "有快捷键重复了"
        } else if !failed.isEmpty {
            hotKeyWarning.stringValue = "“\(failed.joined(separator: "、"))”的快捷键注册失败，可能被其他应用占用"
        } else {
            hotKeyWarning.stringValue = "点击后按下新的组合键；⌫ 恢复默认，Esc 取消"
            hotKeyWarning.textColor = .secondaryLabelColor
            return
        }
        hotKeyWarning.textColor = .systemRed
    }

    @objc private func changed() {
        Settings.captureHotKey = captureRecorder.combo
        Settings.repeatHotKey = repeatRecorder.combo
        Settings.recordHotKey = recordRecorder.combo
        Settings.showMagnifier = magnifier.state == .on
        Settings.playSound = sound.state == .on
        Settings.windowShadow = shadow.state == .on
        Settings.recordShowsCursor = cursor.state == .on
        let template = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        Settings.fileNameTemplate = template.isEmpty ? "截图 {date} {time}" : template
        Settings.imageFormat = ImageFormat.allCases[max(0, formatPopup.indexOfSelectedItem)]
        Settings.quickSave = quickSave.state == .on
        Settings.autoSaveOnConfirm = autoSave.state == .on
        Settings.historyEnabled = history.state == .on
        Settings.historyLimit = historyLimit.selectedItem?.tag ?? 30
        historyLimit.isEnabled = Settings.historyEnabled
        // 快捷键重新注册是同步的，注册完再刷新提示
        refreshHints()
    }

    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.saveDirectory
        panel.prompt = "选择"
        panel.beginSheetModal(for: self) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            Settings.saveDirectory = url
            self?.dirLabel.url = url
        }
    }
}

extension PreferencesWindow: NSTextFieldDelegate {
    nonisolated func controlTextDidChange(_ obj: Notification) {
        MainActor.assumeIsolated { changed() }
    }
}

/// 快捷键录制按钮
@MainActor
final class HotKeyRecorder: NSButton {
    var combo: HotKeyCombo { didSet { refresh() } }
    var onChange: (() -> Void)?
    private let defaultCombo: HotKeyCombo
    private var monitor: Any?
    private var recording = false { didSet { refresh() } }

    init(defaultCombo: HotKeyCombo) {
        self.defaultCombo = defaultCombo
        combo = defaultCombo
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(toggle)
        widthAnchor.constraint(equalToConstant: 160).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        title = recording ? "请按下快捷键…" : combo.display
    }

    @objc private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        HotKey.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            // 本地事件监听总在主线程回调
            nonisolated(unsafe) let event = e
            guard let self else { return e }
            let consumed = MainActor.assumeIsolated { self.handle(event) }
            return consumed ? nil : e
        }
    }

    private func stop() {
        recording = false
        HotKey.suspended = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .control, .option, .shift])
        switch Int(e.keyCode) {
        case kVK_Escape:
            stop()
            return true
        case kVK_Delete, kVK_ForwardDelete:
            combo = defaultCombo
            stop()
            onChange?()
            return true
        default:
            break
        }
        // 至少要有 ⌘ / ⌃ / ⌥ 之一，避免占用普通按键
        guard !flags.intersection([.command, .control, .option]).isEmpty else {
            NSSound.beep()
            return true
        }
        combo = HotKeyCombo(keyCode: UInt32(e.keyCode), modifiers: HotKeyCombo.carbonModifiers(flags))
        stop()
        onChange?()
        return true
    }
}
