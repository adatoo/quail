import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Quail

@Suite("Third-party licences sheet")
struct NoticesDocumentTests {
    private static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Quail/Resources/THIRD_PARTY_NOTICES.md")

    @Test("the generated notices read as a heading, the table of components, then a section per component")
    func parsesTheRealFile() throws {
        let blocks = try NoticesDocument.parse(String(contentsOf: Self.file, encoding: .utf8))
        #expect(blocks.first == .heading(level: 1, text: "Third-party notices"))
        guard case let .table(header, rows) = try #require(blocks.first {
            if case .table = $0 {
                true
            } else {
                false
            }
        })
        else { return }
        #expect(header == ["Component", "Version", "Licence", "Shipped in"])
        #expect(rows.count >= 10 && rows.allSatisfy { $0.count == 4 })
        #expect(!rows.contains { $0.first?.hasPrefix("---") == true })
        let sections = blocks.filter {
            if case .heading(2, _) = $0 {
                true
            } else {
                false
            }
        }
        let texts = blocks.filter {
            if case .preformatted = $0 {
                true
            } else {
                false
            }
        }
        // A section per component, and the shared licence texts (Apache-2.0 once, and so on) after them.
        #expect(sections.count >= rows.count)
        #expect(texts.count >= 4)
        #expect(!sections.contains {
            if case let .heading(_, text) = $0 {
                text.hasSuffix("#")
            } else {
                false
            }
        })
    }

    @Test("small cases: hard breaks, an unclosed fence, a table rule")
    func smallCases() {
        let blocks = NoticesDocument
            .parse("# T\n\nline one  \nline two\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n```text\nMIT\n")
        #expect(blocks == [
            .heading(level: 1, text: "T"),
            .paragraph("line one\nline two"),
            .table(header: ["a", "b"], rows: [["1", "2"]]),
            .preformatted("MIT"),
        ])
    }

    @Test("links in a paragraph are links")
    func links() {
        let text = NoticesBlockView.inline("https://github.com/mattt/EventSource\nLicence: MIT")
        #expect(text.runs.contains { $0.link?.absoluteString == "https://github.com/mattt/EventSource" })
    }

    /// Renders the first blocks to a PNG for a look, when `QUAIL_TEST_SNAPSHOT_DIR` is set.
    @MainActor
    @Test("snapshot for review", .enabled(if: ProcessInfo.processInfo.environment["QUAIL_TEST_SNAPSHOT_DIR"] != nil))
    func snapshot() throws {
        let blocks = try NoticesDocument.parse(String(contentsOf: Self.file, encoding: .utf8))
        let view = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.prefix(10).enumerated()), id: \.offset) { _, block in NoticesBlockView(block: block) }
        }
        .padding(12).frame(width: 696).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let dir = try #require(ProcessInfo.processInfo.environment["QUAIL_TEST_SNAPSHOT_DIR"])
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("licences.png"))
    }
}
