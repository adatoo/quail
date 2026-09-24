import Foundation

/// The server's line logger: stderr always (the app's `LogStore` reads the
/// child's stderr) and, when `--log-file` is given, the same lines appended
/// to that file (what "Reveal in Finder" shows).
final class ServerLog: @unchecked Sendable {
    enum Level: String, Sendable {
        case info
        case warn
        case error
    }

    private let lock = NSLock()
    private let file: FileHandle?
    private let toStandardError: Bool

    init(fileURL: URL? = nil, toStandardError: Bool = true) {
        self.toStandardError = toStandardError
        if let fileURL {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            file = try? FileHandle(forWritingTo: fileURL)
            _ = try? file?.seekToEnd()
        } else {
            file = nil
        }
    }

    deinit {
        try? file?.close()
    }

    func log(_ level: Level, _ message: @autoclosure () -> String) {
        let line = "\(Date().formatted(.iso8601)) [\(level.rawValue)] \(message())\n"
        let data = Data(line.utf8)
        lock.lock()
        defer { lock.unlock() }
        if toStandardError {
            FileHandle.standardError.write(data)
        }
        try? file?.write(contentsOf: data)
    }
}
