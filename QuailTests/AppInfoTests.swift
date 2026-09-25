import Foundation
import Testing
@testable import Quail

@Suite("AppInfo")
struct AppInfoTests {
    @Test("version reads from the bundle without crashing and is never empty")
    func versionIsNonEmpty() {
        #expect(!AppInfo.version.isEmpty)
    }

    @Test("the Quail scheme is not compiled as an App Store build")
    func developerIDSchemeIsNotAppStore() {
        #expect(AppInfo.isAppStoreBuild == false)
    }

    @Test("the display version is version and build, like `quail --version`")
    func displayVersion() {
        #expect(AppInfo.displayVersion == "\(AppInfo.version) (\(AppInfo.build))")
    }

    // MARK: Bundled files

    /// A bundle on disk with the given files in `Contents/Resources`.
    private func bundle(with files: [String: String]) throws -> (bundle: Bundle, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quail-about-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("Test.bundle/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for (name, text) in files {
            try text.write(to: resources.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let bundle = try #require(Bundle(url: root.appendingPathComponent("Test.bundle")))
        return (bundle, { try? FileManager.default.removeItem(at: root) })
    }

    @Test("the llama.cpp tag is read from the bundled pin, trimmed")
    func llamaTag() throws {
        let (bundle, cleanup) = try bundle(with: ["llama.version": "b11081\n"])
        defer { cleanup() }
        #expect(AppInfo.llamaCppTag(in: bundle) == "b11081")
    }

    @Test("a missing or empty pin file is no tag, not a crash")
    func llamaTagMissing() throws {
        let (empty, cleanupEmpty) = try bundle(with: [:])
        defer { cleanupEmpty() }
        #expect(AppInfo.llamaCppTag(in: empty) == nil)

        let (blank, cleanupBlank) = try bundle(with: ["llama.version": "  \n"])
        defer { cleanupBlank() }
        #expect(AppInfo.llamaCppTag(in: blank) == nil)
    }

    @Test("the llama.cpp licence text is read from the bundle, and absence is nil")
    func licence() throws {
        let (with, cleanupWith) = try bundle(with: ["LICENSE-llama.cpp": "MIT License\n\nCopyright (c) ggml authors"])
        defer { cleanupWith() }
        #expect(AppInfo.llamaCppLicence(in: with)?.hasPrefix("MIT License") == true)

        let (without, cleanupWithout) = try bundle(with: [:])
        defer { cleanupWithout() }
        #expect(AppInfo.llamaCppLicence(in: without) == nil)
    }

    @Test("the notices file is read from the bundle, and absence is nil")
    func notices() throws {
        let (with, cleanupWith) = try bundle(with: ["THIRD_PARTY_NOTICES.md": "# Third-party notices\n"])
        defer { cleanupWith() }
        #expect(AppInfo.thirdPartyNotices(in: with)?.hasPrefix("# Third-party notices") == true)

        let (without, cleanupWithout) = try bundle(with: [:])
        defer { cleanupWithout() }
        #expect(AppInfo.thirdPartyNotices(in: without) == nil)
    }

    // MARK: About

    private func facts(tag: String? = "b11081", asOf: String? = "2026-09-23") -> AboutFacts {
        AboutFacts(
            version: "0.5.0",
            build: "8",
            distribution: "Direct download",
            llamaCppTag: tag,
            catalogRevision: 3,
            catalogAsOf: asOf,
            macOS: "26.6.2"
        )
    }

    @Test("the rows read as they will on screen")
    func rows() {
        let facts = facts()
        #expect(facts.versionLine == "0.5.0 (8)")
        #expect(facts.llamaCppLine == "b11081")
        #expect(facts.catalogLine == "revision 3 · 2026-09-23")
    }

    @Test("what isn't known shows a dash or is left off, never a blank or a made-up value")
    func unknowns() {
        let facts = facts(tag: nil, asOf: nil)
        #expect(facts.llamaCppLine == "—")
        #expect(facts.catalogLine == "revision 3")
    }

    @Test("the bug-report text is exactly these lines")
    func summary() {
        #expect(facts().summary == """
        Quail 0.5.0 (8), Direct download
        llama.cpp b11081
        Catalog revision 3 · 2026-09-23
        macOS 26.6.2
        """)
    }

    @Test("facts gathered from the running app are complete")
    func current() {
        let facts = AboutFacts.current(catalog: Catalog())
        #expect(facts.version == AppInfo.version)
        #expect(facts.build == AppInfo.build)
        #expect(facts.distribution == AppInfo.distribution)
        #expect(facts.macOS.split(separator: ".").count == 3)
    }
}
