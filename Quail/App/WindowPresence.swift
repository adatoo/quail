import AppKit

/// Keeps Quail's windows (Settings, Logs, Test) in front when you come back
/// to the Space they're on.
///
/// Quail is menu-bar-only (`LSUIElement`, an `.accessory` app), and macOS
/// doesn't restore an accessory app's window when you return to a Space:
/// switch desktops and back, and the app that was frontmost there covers
/// it — with no Dock icon or ⌘-Tab to bring it back (user-reported).
/// Becoming a `.regular` app while a window is open was tried and
/// rejected: a regular app's window can't join another app's full-screen
/// Space, so Settings opened over a full-screen terminal landed on the
/// desktop Space instead (`.fullScreenAuxiliary` is an accessory-app
/// privilege). So instead, on every Space change, each tracked window
/// that's on the now-active Space is ordered back to the front.
@MainActor
final class WindowPresence {
    static let shared = WindowPresence()

    private var windows: [ObjectIdentifier: WeakWindow] = [:]
    private var spaceObserver: NSObjectProtocol?

    private struct WeakWindow {
        weak var window: NSWindow?
    }

    /// Called as each Quail window is created (`WindowFrontier`).
    func track(_ window: NSWindow) {
        windows[ObjectIdentifier(window)] = WeakWindow(window: window)
        guard spaceObserver == nil else { return }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
    }

    private func spaceChanged() {
        windows = windows.filter { $0.value.window != nil }
        let returning = windows.values.compactMap(\.window).filter { $0.isVisible && $0.isOnActiveSpace }
        guard !returning.isEmpty else { return }
        // The Space's own frontmost app is re-ordered in as the switch
        // finishes; fronting on the very next turn loses to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            for window in returning where window.isVisible && window.isOnActiveSpace {
                window.orderFrontRegardless()
            }
        }
    }
}
