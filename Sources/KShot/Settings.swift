import AppKit
import Carbon
import UniformTypeIdentifiers

/// 全局快捷键组合（Carbon 键码 + Carbon 修饰键）
struct HotKeyCombo: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let capture = HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | cmdKey))
    static let repeatRegion = HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | shiftKey | cmdKey))
    static let record = HotKeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | cmdKey))

    /// 形如 “⌃⇧⌘A” 的显示文字
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + HotKeyCombo.keyName(keyCode)
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

    private static func combo(_ key: String, _ def: HotKeyCombo) -> HotKeyCombo {
        guard let data = d.data(forKey: key), let c = try? JSONDecoder().decode(HotKeyCombo.self, from: data) else { return def }
        return c
    }
    private static func setCombo(_ key: String, _ c: HotKeyCombo) {
        d.set(try? JSONEncoder().encode(c), forKey: key)
        notify()
    }
    private static func notify() { NotificationCenter.default.post(name: changed, object: nil) }

    static var captureHotKey: HotKeyCombo {
        get { combo("hotkey.capture", .capture) }
        set { setCombo("hotkey.capture", newValue) }
    }
    static var repeatHotKey: HotKeyCombo {
        get { combo("hotkey.repeat", .repeatRegion) }
        set { setCombo("hotkey.repeat", newValue) }
    }
    static var recordHotKey: HotKeyCombo {
        get { combo("hotkey.record", .record) }
        set { setCombo("hotkey.record", newValue) }
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
        get { bool("showMagnifier", true) }
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
