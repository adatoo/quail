import Foundation
import Testing
@testable import Quail

/// The app's links to the website (ADR D-062).
@Suite("Website")
struct WebsiteTests {
    private func bundle(websiteURL: String?) throws -> (Bundle, () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-website-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Contents"), withIntermediateDirectories: true
        )
        var info: [String: Any] = ["CFBundleIdentifier": "test.\(UUID().uuidString)"]
        info["QuailWebsiteURL"] = websiteURL
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Contents/Info.plist"))
        return try (#require(Bundle(url: dir)), { try? FileManager.default.removeItem(at: dir) })
    }

    @Test("the website address comes from Info.plist; unset, empty or not a web address means none")
    func base() throws {
        for (value, expected) in [
            ("https://adatoo.github.io/quail/", "https://adatoo.github.io/quail/"),
            ("https://adatoo.github.io/quail", "https://adatoo.github.io/quail/"),
            (" https://quail.example ", "https://quail.example/"),
        ] {
            let (bundle, cleanup) = try bundle(websiteURL: value)
            defer { cleanup() }
            #expect(Website.base(in: bundle)?.absoluteString == expected, "\(value)")
        }
        for value in [nil, "", "   ", "file:///tmp/site", "not a url"] as [String?] {
            let (bundle, cleanup) = try bundle(websiteURL: value)
            defer { cleanup() }
            #expect(Website.base(in: bundle) == nil, "\(value ?? "nil")")
        }
    }

    @Test("docs links: page and section under the site; none without a site; Help falls back to the README")
    func docsURL() throws {
        let base = try #require(URL(string: "https://adatoo.github.io/quail/"))
        #expect(Website.docsURL(.power, base: base)?.absoluteString
            == "https://adatoo.github.io/quail/docs/power.html")
        #expect(Website.docsURL(.network, section: "key", base: base)?.absoluteString
            == "https://adatoo.github.io/quail/docs/network.html#key")
        #expect(Website.docsURL(.cli, base: nil) == nil)
        #expect(Website.help(base: base).absoluteString == "https://adatoo.github.io/quail/docs/getting-started.html")
        #expect(Website.help(base: nil) == Website.readme)
    }

    /// The repository's website folder, when this checkout has one.
    private static let docsFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("website/docs", isDirectory: true)

    @Test(
        "every docs page the app links to exists in website/docs",
        .enabled(if: FileManager.default.fileExists(atPath: docsFolder.path))
    )
    func docsPagesExist() {
        for page in Website.DocsPage.allCases {
            let file = Self.docsFolder.appendingPathComponent(page.rawValue + ".html")
            #expect(FileManager.default.fileExists(atPath: file.path), "\(page.rawValue).html")
        }
    }
}
