import Foundation
import Testing
@testable import Quail

@Suite("ModelStore")
struct ModelStoreTests {
    private func scratchStore() -> ModelStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-modelstore-tests-\(UUID().uuidString)", isDirectory: true)
        return ModelStore(rootURL: root)
    }

    @Test("ensureDirectoriesExist creates gguf, mlx and hf-cache")
    func ensureDirectoriesExistCreatesLayout() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        try store.ensureDirectoriesExist()

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: store.ggufDirectory.path))
        #expect(fm.fileExists(atPath: store.mlxDirectory.path))
        #expect(fm.fileExists(atPath: store.hfCacheDirectory.path))
    }

    @Test("ensureDirectoriesExist is safe to call repeatedly")
    func ensureDirectoriesExistIsIdempotent() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        try store.ensureDirectoriesExist()
        try store.ensureDirectoriesExist() // must not throw the second time
    }

    // MARK: - Catalog

    @Test("loadCatalog returns empty when catalog.json doesn't exist")
    func loadCatalogReturnsEmptyWhenMissing() {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        #expect(store.loadCatalog() == StoreCatalog())
    }

    @Test("loadCatalog returns empty when catalog.json is malformed")
    func loadCatalogReturnsEmptyWhenMalformed() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try store.ensureDirectoriesExist()
        try Data("not json".utf8).write(to: store.catalogFile)

        #expect(store.loadCatalog() == StoreCatalog())
    }

    @Test("saveCatalog then loadCatalog round-trips every field")
    func saveThenLoadRoundTrips() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        let entry = InstalledModel(
            id: "Qwen3-0.6B-Q8_0",
            family: "Qwen3",
            format: .gguf,
            bytes: 639_446_688,
            sha256: "abc123",
            sourceRepo: "Qwen/Qwen3-0.6B-GGUF",
            params: "0.6B",
            quant: "Q8_0",
            contextSize: 16384,
            addedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let catalog = StoreCatalog(entries: [entry])

        try store.saveCatalog(catalog)
        let loaded = store.loadCatalog()

        #expect(loaded == catalog)
    }

    // MARK: - installedGGUFFiles

    @Test("installedGGUFFiles lists .gguf files, excludes mmproj- companions, sorted by name")
    func installedGGUFFilesListsAndExcludesMmproj() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try store.ensureDirectoriesExist()

        for name in ["zebra.gguf", "alpha.gguf", "mmproj-alpha.gguf", "notes.txt"] {
            try Data().write(to: store.ggufDirectory.appendingPathComponent(name))
        }

        let files = store.installedGGUFFiles().map(\.lastPathComponent)
        #expect(files == ["alpha.gguf", "zebra.gguf"])
    }

    @Test("installedGGUFFiles returns empty when gguf/ doesn't exist yet")
    func installedGGUFFilesReturnsEmptyWhenDirectoryMissing() {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        #expect(store.installedGGUFFiles().isEmpty)
    }

    // MARK: - regeneratePresets

    @Test("regeneratePresets writes one section per installed GGUF, with sane defaults")
    func regeneratePresetsWritesDefaults() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try store.ensureDirectoriesExist()
        try Data().write(to: store.ggufDirectory.appendingPathComponent("Qwen3-0.6B-Q8_0.gguf"))

        try store.regeneratePresets(catalog: StoreCatalog())

        let ini = try String(contentsOf: store.presetsFile, encoding: .utf8)
        #expect(ini.contains("[Qwen3-0.6B-Q8_0]"))
        // Not a literal path comparison: contentsOfDirectory(at:) resolves
        // /var -> /private/var on macOS, so this only checks the file
        // ends up referenced by name, not that the two path strings match
        // byte for byte.
        #expect(ini.contains("model = "))
        #expect(ini.contains("Qwen3-0.6B-Q8_0.gguf"))
        #expect(ini.contains("n-gpu-layers = 99"))
        #expect(ini.contains("ctx-size = 8192")) // default, no catalog entry
    }

    @Test("regeneratePresets uses a catalog entry's contextSize when present")
    func regeneratePresetsUsesCatalogContextSize() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try store.ensureDirectoriesExist()
        try Data().write(to: store.ggufDirectory.appendingPathComponent("Qwen3-0.6B-Q8_0.gguf"))

        let entry = InstalledModel(
            id: "Qwen3-0.6B-Q8_0",
            family: nil,
            format: .gguf,
            bytes: 0,
            sha256: nil,
            sourceRepo: nil,
            params: nil,
            quant: nil,
            contextSize: 32768,
            addedAt: Date()
        )

        try store.regeneratePresets(catalog: StoreCatalog(entries: [entry]))

        let ini = try String(contentsOf: store.presetsFile, encoding: .utf8)
        #expect(ini.contains("ctx-size = 32768"))
    }

    @Test("regeneratePresets excludes mmproj- companions from having their own section")
    func regeneratePresetsExcludesMmproj() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try store.ensureDirectoriesExist()
        try Data().write(to: store.ggufDirectory.appendingPathComponent("gemma.gguf"))
        try Data().write(to: store.ggufDirectory.appendingPathComponent("mmproj-gemma.gguf"))

        try store.regeneratePresets(catalog: StoreCatalog())

        let ini = try String(contentsOf: store.presetsFile, encoding: .utf8)
        #expect(ini.contains("[gemma]"))
        #expect(!ini.contains("[mmproj-gemma]"))
    }

    @Test("regeneratePresets writes an empty file when there are no models yet")
    func regeneratePresetsWritesEmptyFileWithNoModels() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        try store.regeneratePresets(catalog: StoreCatalog())

        let ini = try String(contentsOf: store.presetsFile, encoding: .utf8)
        #expect(ini.isEmpty)
    }
}
