import Foundation

/// Which pipe a log line came from.
enum LogStream: Sendable, Equatable {
    case stdout
    case stderr
}

/// Ring buffer of the most recent log lines, plus an optional rotating file
/// writer. `ProcessSupervisor` feeds this via `append`; the Logs window
/// (docs/IMPLEMENTATION_PLAN.md Phase 1 step 9) reads `recentLines` for the
/// live tail and `fileURL` for "Reveal in Finder".
actor LogStore {
    struct Line: Sendable, Equatable {
        let timestamp: Date
        let stream: LogStream
        let text: String

        /// llama-server prefixes lines with a level letter after a leading
        /// timestamp/component, e.g. "...  I srv  llama_server: ...". Best
        /// effort: unrecognised formats just have no level (nil), never an
        /// error — this is a convenience for the Logs window's filter, not
        /// something callers should depend on being present.
        var level: Character? {
            for token in text.split(separator: " ") {
                if token.count == 1, "IWED".contains(token) {
                    return token.first
                }
            }
            return nil
        }
    }

    private let capacity: Int
    private var buffer: [Line] = []
    private let fileURL: URL?
    private let maxFileBytes: Int
    private let maxFiles: Int
    private var fileHandle: FileHandle?
    private var currentFileBytes = 0

    /// - Parameters:
    ///   - fileURL: where to also write lines, with rotation. `nil` (the
    ///     default) disables file writing entirely — used by tests that
    ///     only care about the in-memory ring buffer.
    init(capacity: Int = 2000, fileURL: URL? = nil, maxFileBytes: Int = 10 * 1024 * 1024, maxFiles: Int = 5) {
        self.capacity = capacity
        self.fileURL = fileURL
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
    }

    var recentLines: [Line] {
        buffer
    }

    func append(stream: LogStream, text: String) {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = Line(timestamp: Date(), stream: stream, text: String(rawLine))
            buffer.append(line)
            if buffer.count > capacity {
                buffer.removeFirst(buffer.count - capacity)
            }
            writeToFile(line)
        }
    }

    func clear() {
        buffer.removeAll()
    }

    private func writeToFile(_ line: Line) {
        guard let fileURL else { return }
        if fileHandle == nil {
            openFile(at: fileURL)
        }
        let prefix = line.stream == .stdout ? "out" : "err"
        let text = "\(line.timestamp.ISO8601Format()) [\(prefix)] \(line.text)\n"
        guard let data = text.data(using: .utf8) else { return }
        fileHandle?.write(data)
        currentFileBytes += data.count
        if currentFileBytes >= maxFileBytes {
            rotate(at: fileURL)
        }
    }

    private func openFile(at url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        currentFileBytes = (attrs?[.size] as? Int) ?? 0
    }

    /// Shifts `name.log` -> `name.1.log` -> ... -> `name.<maxFiles-1>.log`,
    /// dropping whatever was in the oldest slot, then starts a fresh file.
    private func rotate(at url: URL) {
        fileHandle?.closeFile()
        fileHandle = nil

        let fm = FileManager.default
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()

        func rotatedURL(_ index: Int) -> URL {
            dir.appendingPathComponent("\(base).\(index).\(ext)")
        }

        try? fm.removeItem(at: rotatedURL(maxFiles - 1))
        if maxFiles > 1 {
            for index in stride(from: maxFiles - 1, through: 1, by: -1) {
                let source = index == 1 ? url : rotatedURL(index - 1)
                try? fm.moveItem(at: source, to: rotatedURL(index))
            }
        }

        currentFileBytes = 0
        openFile(at: url)
    }
}
