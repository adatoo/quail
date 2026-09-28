import SwiftUI

/// A page of the Quail window. See `AppState.mainPage` for why it is steerable from outside the view.
enum MainPage: String, CaseIterable, Hashable, Identifiable {
    case server
    case models
    case connect
    case benchmark
    case general
    case about

    var id: String {
        rawValue
    }

    /// The sidebar's two groups: what you do with Quail, then Quail itself (ADR D-061).
    static let work: [MainPage] = [.server, .models, .connect, .benchmark]
    static let app: [MainPage] = [.general, .about]

    var title: String {
        switch self {
        case .server: "Server"
        case .models: "Models"
        case .connect: "Connect"
        case .benchmark: "Benchmark"
        case .general: "General"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .server: "server.rack"
        case .models: "shippingbox"
        case .connect: "cable.connector"
        case .benchmark: "gauge.with.dots.needle.67percent"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }
}

/// The Quail window (ADR D-061): a sidebar of pages grouped by task — the server, its models, connecting tools
/// and benchmarking them, then Quail's own settings and About. It replaced six Settings tabs that mixed
/// preferences, work surfaces and a facts page, and spread the server's settings over three of them.
///
/// A `Window` scene rather than `Settings`: it has live status, tests and benchmark runs, so it is the app's
/// main window, and a `Window` can be resized, so every page fills the detail column and scrolls instead of the
/// whole window sizing itself to each tab.
struct MainWindow: View {
    let appState: AppState
    /// `nil` where no updater runs (previews and tests).
    var updateSettings: UpdateSettings?

    static let id = "main"

    var body: some View {
        NavigationSplitView {
            MainSidebar(appState: appState)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            page(appState.mainPage)
                .frame(minWidth: 820, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
                .navigationTitle(appState.mainPage.title)
        }
        .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder private func page(_ page: MainPage) -> some View {
        switch page {
        case .server: ServerPane(appState: appState)
        case .models: ModelsPane(appState: appState)
        case .connect: ConnectPane(appState: appState)
        case .benchmark: BenchmarkPane(appState: appState)
        case .general: GeneralPage(appState: appState, updateSettings: updateSettings)
        case .about: AboutPage(appState: appState)
        }
    }
}

/// The Quail window's sidebar: the work pages, then Quail's own.
struct MainSidebar: View {
    let appState: AppState

    var body: some View {
        List(selection: Binding<MainPage?>(
            get: { appState.mainPage },
            set: { page in
                if let page {
                    appState.mainPage = page
                }
            }
        )) {
            Section {
                ForEach(MainPage.work) { row($0) }
            }
            Section {
                ForEach(MainPage.app) { row($0) }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ page: MainPage) -> some View {
        Label {
            HStack {
                Text(page.title)
                Spacer()
                // The server's state at a glance, in the menu bar icon's colours.
                if page == .server {
                    Circle()
                        .fill(appState.statusColor)
                        .frame(width: 7, height: 7)
                        .help(appState.statusLabel)
                }
            }
        } icon: {
            Image(systemName: page.systemImage)
        }
        .tag(page)
    }
}

/// ⌘, while a Quail window is key. Quail has no menu bar of its own (`LSUIElement`), but key equivalents still
/// reach the app's commands; the menu bar menu's own Settings… item covers ⌘, while that menu is open.
struct OpenMainWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Quail") {
            bringToFront(id: MainWindow.id) { openWindow(id: MainWindow.id) }
        }
        .keyboardShortcut(",")
    }
}
