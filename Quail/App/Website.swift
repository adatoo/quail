import Foundation
import SwiftUI

/// Where the app's links go (ADR D-062): the website and its docs, when `Info.plist`'s `QuailWebsiteURL` is set,
/// and the GitHub repository, always. The website address is one plist key so a new domain is a one-line change;
/// empty or missing, every website link is hidden and Help falls back to the README.
enum Website {
    static let repository = URL(string: "https://github.com/adatoo/quail")!
    static let releaseNotes = URL(string: "https://github.com/adatoo/quail/releases")!
    /// GitHub's template chooser, which offers the repository's bug report and feature request forms.
    static let newIssue = URL(string: "https://github.com/adatoo/quail/issues/new/choose")!
    static let readme = URL(string: "https://github.com/adatoo/quail#readme")!

    /// The pages of the website's docs the app links to. The site must have each (`scripts/check-site` checks the
    /// site's own links; `WebsiteTests` checks this list against `website/docs`).
    enum DocsPage: String, CaseIterable {
        case gettingStarted = "getting-started"
        case models
        case connect
        case network
        case power
        case benchmark
        case cli
        case troubleshooting
        case privacy
    }

    /// `Info.plist`'s `QuailWebsiteURL`, as a folder URL; `nil` if unset, empty or not an http(s) URL.
    static func base(in bundle: Bundle = .main) -> URL? {
        guard let text = (bundle.object(forInfoDictionaryKey: "QuailWebsiteURL") as? String)?
            .trimmingCharacters(in: .whitespaces), !text.isEmpty,
            let url = URL(string: text.hasSuffix("/") ? text : text + "/"),
            url.scheme == "https" || url.scheme == "http", url.host() != nil
        else { return nil }
        return url
    }

    /// `<base>docs/<page>.html#<section>`, or `nil` without a website.
    static func docsURL(_ page: DocsPage, section: String? = nil, base: URL?) -> URL? {
        guard let base else { return nil }
        var url = base.appendingPathComponent("docs").appendingPathComponent(page.rawValue + ".html")
        if let section, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.fragment = section
            url = components.url ?? url
        }
        return url
    }

    /// Quail Help: the docs' getting-started page, or the README without a website.
    static func help(base: URL?) -> URL {
        docsURL(.gettingStarted, base: base) ?? readme
    }
}

extension EnvironmentValues {
    /// The website the Quail window's links point at — `Website.base()` in the app; snapshots set their own.
    @Entry var websiteBase: URL? = Website.base()
}

/// "Learn more" beside a short caption, opening a docs page; nothing without a website (ADR D-062).
struct LearnMoreLink: View {
    let page: Website.DocsPage
    var section: String?

    @Environment(\.websiteBase) private var base

    init(_ page: Website.DocsPage, section: String? = nil) {
        self.page = page
        self.section = section
    }

    var body: some View {
        if let url = Website.docsURL(page, section: section, base: base) {
            Link("Learn more", destination: url)
                .font(.caption)
                .help(url.absoluteString)
        }
    }
}
