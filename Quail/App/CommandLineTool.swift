import Foundation

/// "Install quail Command": a symlink from `~/.local/bin/quail` to the
/// CLI inside this app (`Contents/Helpers/quail`) — no admin password,
/// unlike /usr/local/bin. The symlink follows the app, so updating
/// Quail updates the command.
enum CommandLineTool {
    static var linkURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/quail")
    }

    static var bundledURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/quail")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var isInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)) != nil
    }

    static func install() -> String {
        guard let target = bundledURL else { return "This build of Quail doesn't include the quail command." }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: linkURL.path)) != nil || fm
                .fileExists(atPath: linkURL.path)
            {
                try fm.removeItem(at: linkURL)
            }
            try fm.createSymbolicLink(at: linkURL, withDestinationURL: target)
        } catch {
            return "Couldn't install: \(error.localizedDescription)"
        }
        return "Installed at ~/.local/bin/quail. If your shell can't find it, add ~/.local/bin to your PATH."
    }

    static func uninstall() -> String {
        do {
            try FileManager.default.removeItem(at: linkURL)
            return "Removed ~/.local/bin/quail."
        } catch {
            return "Couldn't remove it: \(error.localizedDescription)"
        }
    }
}
