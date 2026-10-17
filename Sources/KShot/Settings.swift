import AppKit
import Carbon
import UniformTypeIdentifiers

/// 快捷键组合（Carbon 键码 + Carbon 修饰键）
struct HotKeyCombo: Equatable, Hashable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(_ key: Int, _ mods: Int) {
        self.init(keyCode: UInt32(key), modifiers: UInt32(mods))
    }

    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), modifiers: HotKeyCombo.carbonModifiers(event.modifierFlags))
    }

    func matches(_ event: NSEvent) -> Bool {
        UInt32(event.keyCode) == keyCode && HotKeyCombo.carbonModifiers(event.modifierFlags) == modifiers
    }

    /// 菜单项的 keyEquivalent（只支持单字符键）
    var menuKeyEquivalent: (key: String, mask: NSEvent.ModifierFlags)? {
        let name = HotKeyCombo.keyName(keyCode)
        guard name.count == 1 else { return nil }
        var m: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { m.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
        return (name.lowercased(), m)
    }

    /// 形如 “⌃⇧⌘A” 的显示文字
    var display: String { parts.joined() }

    /// 逐个按键：["⌃", "⇧", "⌘", "A"]
    var parts: [String] {
        var p: [String] = []
        if modifiers & UInt32(controlKey) != 0 { p.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { p.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { p.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { p.append("⌘") }
        return p + [HotKeyCombo.keyName(keyCode)]
    }

    /// NSEvent 修饰键 → Carbon 修饰键
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "空格", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let s = special[Int(code)] { return s }
        // 用当前键盘布局把键码翻译成字符
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// 可在偏好设置里自定义快捷键的操作
enum ShortcutAction: String, CaseIterable {
    // 全局（任何应用中可用）
    case capture, repeatRegion, delayCapture, record, togglePins
    // 截图时（选区或编辑窗口中可用）
    case confirm, save, pin, longShot, recordRegion, beautify, ocr, translate, redact, undo, redo

    static let globals: [ShortcutAction] = [.capture, .repeatRegion, .delayCapture, .record, .togglePins]
    static let locals: [ShortcutAction] = [.confirm, .save, .pin, .longShot, .recordRegion, .beautify, .ocr, .translate, .redact, .undo, .redo]

    /// 全局“延时截图”快捷键的延时秒数
    static let delaySeconds = 5

    var isGlobal: Bool { ShortcutAction.globals.contains(self) }

    var title: String {
        switch self {
        case .capture: return "截图"
        case .repeatRegion: return "截取上次区域"
        case .delayCapture: return "延时 \(ShortcutAction.delaySeconds) 秒截图"
        case .record: return "录屏 / 停止录屏"
        case .togglePins: return "显示 / 隐藏钉图"
        case .confirm: return "完成（复制）"
        case .save: return "保存"
        case .pin: return "钉在屏幕上"
        case .longShot: return "长截图"
        case .recordRegion: return "录制选区"
        case .beautify: return "美化"
        case .ocr: return "识别与翻译（文字 / 二维码）"
        case .translate: return "识别与翻译（备用快捷键）"
        case .redact: return "自动打码"
        case .undo: return "撤销"
        case .redo: return "重做"
        }
    }

    var defaultCombo: HotKeyCombo? {
        switch self {
        case .capture: return HotKeyCombo(kVK_ANSI_A, controlKey | cmdKey)
        case .repeatRegion: return HotKeyCombo(kVK_ANSI_A, controlKey | shiftKey | cmdKey)
        case .delayCapture, .togglePins: return nil
        case .record: return HotKeyCombo(kVK_ANSI_R, controlKey | cmdKey)
        case .confirm: return HotKeyCombo(kVK_ANSI_C, cmdKey)
        case .save: return HotKeyCombo(kVK_ANSI_S, cmdKey)
        case .pin: return HotKeyCombo(kVK_ANSI_P, cmdKey)
        case .longShot: return HotKeyCombo(kVK_ANSI_K, cmdKey)
        case .recordRegion: return HotKeyCombo(kVK_ANSI_R, cmdKey)
        case .beautify: return HotKeyCombo(kVK_ANSI_B, cmdKey)
        case .ocr: return HotKeyCombo(kVK_ANSI_T, cmdKey)
        case .translate: return HotKeyCombo(kVK_ANSI_L, cmdKey)
        case .redact: return HotKeyCombo(kVK_ANSI_E, cmdKey)
        case .undo: return HotKeyCombo(kVK_ANSI_Z, cmdKey)
        case .redo: return HotKeyCombo(kVK_ANSI_Z, shiftKey | cmdKey)
        }
    }

    /// UserDefaults 键名（前三个沿用旧版本的键）
    fileprivate var storageKey: String {
        switch self {
        case .capture: return "hotkey.capture"
        case .repeatRegion: return "hotkey.repeat"
        case .record: return "hotkey.record"
        default: return "hotkey.\(rawValue)"
        }
    }

    /// 当前快捷键，nil 表示未设置
    var combo: HotKeyCombo? { Settings.shortcut(self) }

    /// 工具条提示里的快捷键后缀，如 “  ⌘S”
    var tipSuffix: String { combo.map { "  " + $0.display } ?? "" }

    /// 截图时按下的键对应哪个操作
    static func local(matching event: NSEvent) -> ShortcutAction? {
        locals.first { $0.combo?.matches(event) == true }
    }
}

enum ImageFormat: String, CaseIterable {
    case png, jpeg, heic

    var title: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }

    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }
}

/// 用户偏好（UserDefaults），改动后发 Settings.changed 通知
enum Settings {
    static let changed = Notification.Name("KShotSettingsChanged")
    private static let d = UserDefaults.standard

    private static func notify() { NotificationCenter.default.post(name: changed, object: nil) }

    // MARK: - 快捷键

    static func shortcut(_ a: ShortcutAction) -> HotKeyCombo? {
        // 存的是 JSON：组合键或 null（用户清除）；没存过用默认值
        guard let data = d.data(forKey: a.storageKey) else { return a.defaultCombo }
        do {
            return try JSONDecoder().decode(HotKeyCombo?.self, from: data)
        } catch {
            return a.defaultCombo
        }
    }

    static func setShortcut(_ a: ShortcutAction, _ c: HotKeyCombo?, notify post: Bool = true) {
        if c == a.defaultCombo {
            d.removeObject(forKey: a.storageKey)
        } else {
            d.set(try? JSONEncoder().encode(c), forKey: a.storageKey)
        }
        if post { notify() }
    }

    static func resetAllShortcuts() {
        for a in ShortcutAction.allCases { setShortcut(a, a.defaultCombo, notify: false) }
        notify()
    }

    /// nil 表示沿用自动选择：中文译英，其他译中。
    static var translationTarget: TargetLanguage? {
        get {
            let identifier = d.string(forKey: "translationTarget")
            return TargetLanguage.all.first { $0.identifier == identifier }
        }
        set {
            if let newValue { d.set(newValue.identifier, forKey: "translationTarget") }
            else { d.removeObject(forKey: "translationTarget") }
            notify()
        }
    }

    static var translationProvider: TranslationProvider {
        get { TranslationProvider(rawValue: d.string(forKey: "translationProvider") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "translationProvider"); notify() }
    }

    static func aiTranslationURL(for provider: TranslationProvider) -> String {
        d.string(forKey: "translation.\(provider.rawValue).url") ?? provider.defaultURL
    }

    static func aiTranslationModel(for provider: TranslationProvider) -> String {
        d.string(forKey: "translation.\(provider.rawValue).model") ?? provider.defaultModel
    }

    static func saveAITranslation(provider: TranslationProvider, url: String, model: String) {
        d.set(url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "translation.\(provider.rawValue).url")
        d.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "translation.\(provider.rawValue).model")
        translationProvider = provider
    }

    /// 默认保存目录
    static var saveDirectory: URL {
        get {
            d.url(forKey: "saveDirectory")
                ?? d.url(forKey: "lastSaveDirectory")
                ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        set { d.set(newValue, forKey: "saveDirectory"); notify() }
    }

    /// 文件名模板：{date} {time} {w} {h}
    static var fileNameTemplate: String {
        get { d.string(forKey: "fileNameTemplate") ?? "截图 {date} {time}" }
        set { d.set(newValue, forKey: "fileNameTemplate"); notify() }
    }

    static var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "") ?? .png }
        set { d.set(newValue.rawValue, forKey: "imageFormat"); notify() }
    }

    private static func bool(_ key: String, _ def: Bool) -> Bool {
        d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }
    private static func setBool(_ key: String, _ v: Bool) { d.set(v, forKey: key); notify() }

    /// ⌘S 不弹保存面板，直接存到默认目录
    static var quickSave: Bool {
        get { bool("quickSave", false) }
        set { setBool("quickSave", newValue) }
    }
    /// 完成截图（复制到剪贴板）时同时自动保存一份到默认目录
    static var autoSaveOnConfirm: Bool {
        get { bool("autoSaveOnConfirm", false) }
        set { setBool("autoSaveOnConfirm", newValue) }
    }
    /// 截图完成时播放快门声
    static var playSound: Bool {
        get { bool("playSound", false) }
        set { setBool("playSound", newValue) }
    }
    /// 单击选中窗口后直接完成时，输出带系统阴影的透明背景窗口图
    static var windowShadow: Bool {
        get { bool("windowShadow", false) }
        set { setBool("windowShadow", newValue) }
    }
    /// 选区时显示放大镜与颜色
    static var showMagnifier: Bool {
        get { bool("showMagnifier", false) }
        set { setBool("showMagnifier", newValue) }
    }
    /// 记录截图历史
    static var historyEnabled: Bool {
        get { bool("historyEnabled", true) }
        set { setBool("historyEnabled", newValue) }
    }
    static var historyLimit: Int {
        get { d.object(forKey: "historyLimit") == nil ? 30 : max(1, d.integer(forKey: "historyLimit")) }
        set { d.set(newValue, forKey: "historyLimit"); notify() }
    }

    /// 录屏时同时录制鼠标指针
    static var recordShowsCursor: Bool {
        get { bool("recordShowsCursor", true) }
        set { setBool("recordShowsCursor", newValue) }
    }

    // MARK: - 上次选区

    struct Region: Codable {
        var displayID: UInt32
        var rect: CGRect   // 屏幕局部坐标（左上原点，pt）
    }

    static var lastRegion: Region? {
        get {
            guard let data = d.data(forKey: "lastRegion") else { return nil }
            return try? JSONDecoder().decode(Region.self, from: data)
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "lastRegion") }
    }

    // MARK: - 文件名

    static func fileName(width: Int? = nil, height: Int? = nil, ext: String? = nil) -> String {
        let date = Date()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter()
        tf.dateFormat = "HH.mm.ss"
        var name = fileNameTemplate
            .replacingOccurrences(of: "{date}", with: df.string(from: date))
            .replacingOccurrences(of: "{time}", with: tf.string(from: date))
            .replacingOccurrences(of: "{w}", with: width.map(String.init) ?? "")
            .replacingOccurrences(of: "{h}", with: height.map(String.init) ?? "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "截图" }
        return name + "." + (ext ?? imageFormat.fileExtension)
    }

    /// 在目录里找一个不重名的文件路径
    static func uniqueURL(in dir: URL, name: String) -> URL {
        var url = dir.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(i).\(ext)")
            i += 1
        }
        return url
    }
}

/// 快门声
enum Shutter {
    private static let sound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true)
    }()

    static func play() {
        guard Settings.playSound else { return }
        sound?.stop()
        sound?.play()
    }
}
