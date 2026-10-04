import Foundation

/// 简单的文件日志（~/Library/Logs/KShot.log），便于排查权限/抓屏问题。
enum Log {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("KShot.log")
    }()
    private static let queue = DispatchQueue(label: "kshot.log")

    static func info(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        NSLog("[KShot] %@", message)
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else {
                try? line.data(using: .utf8)?.write(to: url)
            }
        }
    }
}
