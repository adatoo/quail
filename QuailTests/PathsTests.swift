import Foundation
import Testing
@testable import Quail

@Suite("Paths — models directory bookmark")
struct PathsTests {
    @Test("resolveModelsDirectory returns nil when there's no bookmark")
    func resolveReturnsNilWhenMissing() {
        #expect(Paths.resolveModelsDirectory(bookmark: nil) == nil)
    }

    @Test("resolveModelsDirectory returns nil for garbage bookmark data")
    func resolveReturnsNilForGarbageData() {
        #expect(Paths.resolveModelsDirectory(bookmark: Data("not a bookmark".utf8)) == nil)
    }

    @Test("makeModelsDirectoryBookmark then resolveModelsDirectory round-trips to the same folder")
    func makeThenResolveRoundTrips() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-paths-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let bookmark = try Paths.makeModelsDirectoryBookmark(for: folder)
        let resolved = try #require(Paths.resolveModelsDirectory(bookmark: bookmark))

        // Compare standardized paths, not URLs directly: resolving a
        // bookmark can return an equivalent but not byte-identical URL
        // (e.g. a resolved symlink in /var vs /private/var on macOS).
        #expect(resolved.standardizedFileURL.path == folder.standardizedFileURL.path)
    }
}
