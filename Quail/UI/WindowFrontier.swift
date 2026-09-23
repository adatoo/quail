import AppKit
import SwiftUI

/// Makes the window hosting this view appear where the user is. Attached
/// (as a background) to the root of every window Quail opens — Settings,
/// Logs, Test.
///
/// Quail is menu-bar-only (`LSUIElement`), so on macOS 14+ it can't force
/// activation, and a new window is placed on the desktop Space — invisible
/// when the frontmost app is full-screen (user-reported; confirmed via the
/// window server: the Settings window existed but was offscreen). Setting
/// `.moveToActiveSpace` + `.fullScreenAuxiliary` *after* the window was
/// shown only worked sometimes; doing it here, as the view joins the
/// window — before or as it's first ordered in — is reliable, and
/// `orderFrontRegardless()` brings it forward without needing activation.
struct WindowFrontier: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        FrontingView()
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class FrontingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
            WindowPresence.shared.track(window)
            DispatchQueue.main.async {
                window.orderFrontRegardless()
                window.makeKey()
            }
        }
    }
}

extension View {
    /// See `WindowFrontier`.
    func opensInFront() -> some View {
        background(WindowFrontier().frame(width: 0, height: 0))
    }
}
