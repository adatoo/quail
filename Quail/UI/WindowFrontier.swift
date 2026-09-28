import AppKit
import SwiftUI

/// Makes the window hosting this view appear where the user is. Attached
/// (as a background) to the root of every window Quail opens — the Quail
/// window, Logs, Test, Activity.
///
/// Quail is menu-bar-only (`LSUIElement`), so on macOS 14+ it can't force
/// activation, and a new window is placed on the desktop Space — invisible
/// when the frontmost app is full-screen (user-reported; confirmed via the
/// window server: the window existed but was offscreen). Setting
/// `.moveToActiveSpace` + `.fullScreenAuxiliary` *after* the window was
/// shown only worked sometimes; doing it here, as the view joins the
/// window — before or as it's first ordered in — is reliable, and
/// `orderFrontRegardless()` brings it forward without needing activation.
struct WindowFrontier: NSViewRepresentable {
    /// The scene's id, so `bringToFront(id:)` can find this window again.
    var id: String?

    func makeNSView(context _: Context) -> NSView {
        FrontingView(id: id)
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class FrontingView: NSView {
        let id: String?

        init(id: String?) {
            self.id = id
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
            // A menu bar app's windows shouldn't reopen by themselves after a relaunch or a login; the Settings
            // scene never did, and a `Window` scene otherwise would (`.restorationBehavior` needs macOS 15).
            window.isRestorable = false
            WindowPresence.shared.track(window, id: id)
            DispatchQueue.main.async {
                window.orderFrontRegardless()
                window.makeKey()
            }
        }
    }
}

extension View {
    /// See `WindowFrontier`. `id` is the scene's, for `bringToFront(id:)`.
    func opensInFront(id: String? = nil) -> some View {
        background(WindowFrontier(id: id).frame(width: 0, height: 0))
    }
}

/// Opens a window *in front*. Quail is a menu-bar-only app (`LSUIElement`);
/// on macOS 14+ `NSApp.activate()` is only a request the frontmost app may
/// decline, so the Quail window, Logs and Test used to open behind other apps
/// or on another Space (user-reported; confirmed via the window server — the
/// window existed but wasn't onscreen, because the frontmost app was
/// full-screen on its own Space). After opening, each visible Quail window is
/// allowed onto the current (possibly full-screen) Space and ordered front
/// regardless of activation, and the one asked for is made key: the window
/// registered under `id` when there is one, otherwise the newest.
@MainActor
func bringToFront(id: String? = nil, _ open: () -> Void) {
    let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
    NSApp.activate()
    open()
    // SwiftUI shows the window a few run-loop turns later, so poll
    // briefly for it rather than acting on the very next turn.
    Task { @MainActor in
        for _ in 0 ..< 20 {
            let visible = NSApp.windows
                .filter { $0.isVisible && $0.canBecomeKey && ($0.level == .normal || $0.level == .floating) }
            let opened = visible.filter { !before.contains(ObjectIdentifier($0)) }
            let wanted = id.flatMap { WindowPresence.shared.window(id: $0) }.flatMap { $0.isVisible ? $0 : nil }
            if let target = wanted ?? opened.last ?? (id == nil ? visible.last : nil) {
                for window in visible {
                    // .fullScreenAuxiliary: may appear on a full-screen
                    // app's Space — otherwise, with e.g. a full-screen
                    // terminal in front, the window opens on the desktop
                    // Space and seems to vanish (the user-reported case).
                    window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
                }
                target.orderFrontRegardless()
                target.makeKey()
                NSApp.activate()
                if wanted != nil || !opened.isEmpty {
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
