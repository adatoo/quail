import Foundation

/// What the menu's chat item does. llama.cpp's own web UI is a real chat
/// page (D-001: link to the runtime's UI); a runtime without one gets a
/// hand-off to `quail run` instead of a menu item that silently does
/// nothing — Quail doesn't ship a chat window of its own.
enum ChatEntry: Equatable {
    case browser(URL)
    case terminal(command: String)

    static func resolve(webUI: URL?, model: String?) -> ChatEntry {
        if let webUI {
            return .browser(webUI)
        }
        return .terminal(command: command(model: model))
    }

    /// `quail run [model]` — the model is optional: the CLI falls back to
    /// the default model.
    static func command(model: String?) -> String {
        guard let model, !model.isEmpty else { return "quail run" }
        return "quail run \(shellQuoted(model))"
    }

    private static func shellQuoted(_ text: String) -> String {
        let safe = text.allSatisfy { $0.isLetter || $0.isNumber || "._-:/".contains($0) }
        guard !safe else { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var menuTitle: String {
        switch self {
        case .browser: "Open Chat in Browser"
        case .terminal: "Copy Terminal Chat Command"
        }
    }
}
