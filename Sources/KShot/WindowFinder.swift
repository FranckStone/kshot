import AppKit

/// 屏幕上可见窗口的信息，bounds 为全局 CG 坐标（原点在主屏左上角）。
struct WindowInfo {
    let id: CGWindowID
    let bounds: CGRect
    let pid: pid_t
    let ownerName: String
}

enum WindowFinder {
    /// 按从前到后的顺序返回当前屏幕上的普通窗口（排除自身、菜单栏、Dock、桌面元素）。
    static func onScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let myPid = getpid()
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPid,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 24, bounds.height >= 24
            else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            return WindowInfo(id: id, bounds: bounds, pid: pid, ownerName: owner)
        }
    }

    /// 返回全局 CG 坐标点下最前面的窗口。
    static func topWindow(at cgPoint: CGPoint, in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.bounds.contains(cgPoint) }
    }
}
