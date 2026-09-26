import Darwin
import Foundation

/// The `quail chat` prompt: line editing and history (↑/↓ for earlier messages, ←/→, Ctrl-A/E, Ctrl-R
/// search) through the system's libedit, the library behind `sqlite3`'s and `python3`'s prompts.
/// Loaded with `dlopen` rather than linked, so the CLI needs no build setting for it; if it can't be
/// found, the prompt falls back to a plain `readLine()`.
///
/// Earlier messages are kept across chats in `Application Support/Quail/chat-history` (only this user
/// can read it, the last 500), as `ollama run` keeps its own. The conversations themselves are not
/// saved (ADR D-021).
final class LineEditor {
    private typealias ReadLine = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias AddHistory = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias HistoryFile = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias Stifle = @convention(c) (Int32) -> Void

    private let readline: ReadLine?
    private let addHistory: AddHistory?
    private let writeHistory: HistoryFile?
    private let historyFile: URL?
    private var last: String?

    static let historyLimit: Int32 = 500

    init(historyFile: URL? = LineEditor.defaultHistoryFile) {
        self.historyFile = historyFile
        guard let handle = dlopen("/usr/lib/libedit.3.dylib", RTLD_NOW) ?? dlopen("libedit.dylib", RTLD_NOW),
              let read = dlsym(handle, "readline"), let add = dlsym(handle, "add_history")
        else {
            (readline, addHistory, writeHistory) = (nil, nil, nil)
            return
        }
        readline = unsafeBitCast(read, to: ReadLine.self)
        addHistory = unsafeBitCast(add, to: AddHistory.self)
        writeHistory = dlsym(handle, "write_history").map { unsafeBitCast($0, to: HistoryFile.self) }
        if let stifle = dlsym(handle, "stifle_history") {
            unsafeBitCast(stifle, to: Stifle.self)(Self.historyLimit)
        }
        if let historyFile, let readHistory = dlsym(handle, "read_history") {
            _ = unsafeBitCast(readHistory, to: HistoryFile.self)(historyFile.path)
        }
    }

    /// `Application Support/Quail/chat-history`, beside the control socket (so a Debug copy of the app
    /// with `QUAIL_DATA_ROOT` keeps its own).
    static var defaultHistoryFile: URL {
        ControlPaths.socketURL.deletingLastPathComponent().appendingPathComponent("chat-history")
    }

    /// One line from the user, without its newline; `nil` at end of input (Ctrl-D).
    func read(prompt: String) -> String? {
        guard let readline else {
            print(prompt, terminator: "")
            fflush(stdout)
            return readLine()
        }
        guard let raw = readline(prompt) else { return nil }
        defer { free(raw) }
        return String(cString: raw)
    }

    /// Adds a sent line to the history (not blanks, and not the same line twice running) and saves it.
    func remember(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != last, let addHistory else { return }
        last = trimmed
        _ = addHistory(trimmed)
        guard let historyFile, let writeHistory else { return }
        try? FileManager.default.createDirectory(
            at: historyFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        _ = writeHistory(historyFile.path)
        chmod(historyFile.path, 0o600) // what was typed to a model is nobody else's business
    }
}
