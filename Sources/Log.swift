import Foundation

/// 统一日志：写 ~/Library/Logs/MenuBarManager-V3/app.log，超过上限轮转成 app.log.old。
/// 格式：[HH:mm:ss.SSS][级别][模块] 消息
enum Log {
    enum Level: Int, Comparable {
        case debug = 0, info, warn, error

        var tag: String {
            switch self {
            case .debug: return "DEBUG"
            case .info: return "INFO"
            case .warn: return "WARN"
            case .error: return "ERROR"
            }
        }

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// 排查问题时改成 .debug 重新编译
    static var minLevel: Level = .debug

    private static let maxBytes: UInt64 = 10_000_000
    private static let queue = DispatchQueue(label: "mbm.v3.log")

    static let directory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MenuBarManager-V3", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var fileURL: URL { directory.appendingPathComponent("app.log") }
    private static var oldFileURL: URL { directory.appendingPathComponent("app.log.old") }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func debug(_ module: String, _ msg: @autoclosure () -> String) { write(.debug, module, msg) }
    static func info(_ module: String, _ msg: @autoclosure () -> String) { write(.info, module, msg) }
    static func warn(_ module: String, _ msg: @autoclosure () -> String) { write(.warn, module, msg) }
    static func error(_ module: String, _ msg: @autoclosure () -> String) { write(.error, module, msg) }

    private static func write(_ level: Level, _ module: String, _ msg: () -> String) {
        guard level >= minLevel else { return }
        let line = "[\(formatter.string(from: Date()))][\(level.tag)][\(module)] \(msg())\n"
        if level >= .warn {
            FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
        }
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64, size > maxBytes {
            try? fm.removeItem(at: oldFileURL)
            try? fm.moveItem(at: fileURL, to: oldFileURL)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
