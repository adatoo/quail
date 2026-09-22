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

    @Test("ensureDirectoriesExist creates gguf, mlx, hf-cache and .partial")
    func ensureDirectoriesExistCreatesLayout() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        try store.ensureDirectoriesExist()

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: store.ggufDirectory.path))
        #expect(fm.fileExists(atPath: store.mlxDirectory.path))
        #expect(fm.fileExists(atPath: store.hfCacheDirectory.path))
        #expect(fm.fileExists(atPath: store.partialDirectory.path))
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

    @Test("installedGGUFFiles keeps only the first shard of a split model")
    func installedGGUFFilesKeepsFirstShardOnly() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try store.ensureDirectoriesExist()
        for name in [
            "Big-00001-of-00002.gguf", "Big-00002-of-00002.gguf",
            "Whole.gguf", "Llama-3-8B.gguf", // "-8B" must not trip the shard match
        ] {
            try Data().write(to: store.ggufDirectory.appendingPathComponent(name))
        }

        let names = store.installedGGUFFiles().map(\.lastPathComponent)

        #expect(names.contains("Big-00001-of-00002.gguf"))
        #expect(!names.contains("Big-00002-of-00002.gguf"))
        #expect(names.contains("Whole.gguf"))
        #expect(names.contains("Llama-3-8B.gguf"))
    }

    // MARK: - refreshedCatalog

    /// A real, parseable GGUF fixture small enough to fabricate: llama
    /// arch, 1 layer, 1 KV head, embedding 8 / 1 head → d=8. Its full
    /// KV cache at the default 8,192 context is
    /// 2·1·1·8·2·8192 = 262,144 bytes — tiny on purpose, so fabricated
    /// device ceilings can put the same file comfortably into each fit
    /// verdict by weight size alone.
    private static func tinyGGUF() -> GGUFFixtureBuilder {
        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "llama")
        fixture.addUInt32("llama.block_count", 1)
        fixture.addUInt32("llama.attention.head_count", 1)
        fixture.addUInt32("llama.attention.head_count_kv", 1)
        fixture.addUInt32("llama.embedding_length", 8)
        return fixture
    }

    private static let comfortableDevice = DeviceInfo(
        chipName: "Apple M2",
        gpuWorkingSetCeilingBytes: 12_884_901_888 // 16 GB-class
    )

    @Test("refreshedCatalog adds a row for a hand-placed, fully parseable GGUF")
    func refreshAddsHandPlacedGGUF() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try store.ensureDirectoriesExist()
        let file = store.ggufDirectory.appendingPathComponent("Hand-Placed.gguf")
        try Self.tinyGGUF().write(to: file, minBytes: 1_048_576)

        let catalog = store.refreshedCatalog(
            device: Self.comfortableDevice,
            ggufRuntime: .llamaCpp,
            bandwidthTable: [:]
        )

        let row = try #require(catalog.entries.first)
        #expect(row.id == "Hand-Placed")
        #expect(row.format == .gguf)
        #expect(row.bytes == 1_048_576)
        // Comfortable leaves no per-row override — presets.ini's default
        // governs; only .tight writes a reduced context.
        #expect(row.contextSize == nil)
        #expect(row.sourceRepo == nil)
    }

    @Test("refreshedCatalog sets a tight model's reduced contextSize, and presets pick it up")
    func refreshSetsTightContextSize() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try store.ensureDirectoriesExist()
        try Self.tinyGGUF().write(to: store.ggufDirectory.appendingPathComponent("Tight.gguf"), minBytes: 1_048_576)
        // A fabricated ceiling that puts the model in .tight *below* the
        // default context. The fixture's KV cost is 2·1·1·8·2 = 32
        // bytes/token; setting ceiling = weights + 1.5 GB overhead +
        // 4096·32 makes 4096 the largest context that fits, and the
        // default 8192's need (1,501,310,720 bytes) exceed 70% of the
        // ceiling — so the verdict is tight(reduced: 4096).
        let tightDevice = DeviceInfo(
            chipName: "Apple M2",
            gpuWorkingSetCeilingBytes: 1_048_576 + 1_500_000_000 + 131_072
        )

        let catalog = store.refreshedCatalog(device: tightDevice, ggufRuntime: .llamaCpp, bandwidthTable: [:])

        let row = try #require(catalog.entries.first)
        #expect(row.contextSize == 4096)

        try store.saveCatalog(catalog)
        try store.regeneratePresets(catalog: catalog)
        let ini = try String(contentsOf: store.presetsFile, encoding: .utf8)
        #expect(ini.contains("ctx-size = 4096"))
    }

    @Test("a wontFit model keeps a nil contextSize rather than a fake working number")
    func wontFitKeepsContextSizeNil() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try store.ensureDirectoriesExist()
        try Self.tinyGGUF().write(to: store.ggufDirectory.appendingPathComponent("Huge.gguf"), minBytes: 1_048_576)
        let tinyDevice = DeviceInfo(chipName: "Apple M2", gpuWorkingSetCeilingBytes: 1_000_000)

        let catalog = store.refreshedCatalog(device: tinyDevice, ggufRuntime: .llamaCpp, bandwidthTable: [:])

        #expect(catalog.entries.first?.contextSize == nil)
    }

    @Test("refreshedCatalog keeps download fields, updates size, and re-verdicts")
    func refreshPreservesDownloadedFields() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try store.ensureDirectoriesExist()
        try Self.tinyGGUF().write(
            to: store.ggufDirectory.appendingPathComponent("Qwen3-0.6B-Q8_0.gguf"),
            minBytes: 1024
        )
        var catalog = StoreCatalog(entries: [
            InstalledModel(
                id: "Qwen3-0.6B-Q8_0",
                family: "qwen3-0.6b",
                format: .gguf,
                bytes: 999, // stale, from a since-resized file
                sha256: "abc",
                sourceRepo: "Qwen/Qwen3-0.6B-GGUF",
                quant: "Q8_0",
                contextSize: 4242, // stale tight value from a bigger-device day
                addedAt: Date(timeIntervalSince1970: 100)
            ),
        ])
        try store.saveCatalog(catalog)

        catalog = store.refreshedCatalog(device: Self.comfortableDevice, ggufRuntime: .llamaCpp, bandwidthTable: [:])

        let row = try #require(catalog.entries.first)
        #expect(row.family == "qwen3-0.6b")
        #expect(row.sha256 == "abc")
        #expect(row.sourceRepo == "Qwen/Qwen3-0.6B-GGUF")
        #expect(row.quant == "Q8_0")
        #expect(row.addedAt == Date(timeIntervalSince1970: 100))
        #expect(row.bytes == 1024) // re-measured
        #expect(row.contextSize == nil) // recomputed: comfortable now
    }

    @Test("refreshedCatalog drops rows whose file was deleted and adds rows for MLX dirs")
    func refreshAddsAndDropsRows() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try store.ensureDirectoriesExist()
        // One GGUF that exists, one catalog row whose file doesn't.
        try Self.tinyGGUF().write(to: store.ggufDirectory.appendingPathComponent("Exists.gguf"), minBytes: 100)
        try store.saveCatalog(StoreCatalog(entries: [
            InstalledModel(id: "Gone", format: .gguf, bytes: 5, addedAt: .init()),
        ]))
        // An MLX model directory, and a stray directory that isn't one.
        let mlxModel = store.mlxDirectory.appendingPathComponent("mlx-community--X-4bit", isDirectory: true)
        try FileManager.default.createDirectory(at: mlxModel, withIntermediateDirectories: true)
        let mlxConfig = #"{"model_type": "llama", "num_hidden_layers": 1, "num_key_value_heads": 1, "head_dim": 8}"#
            .data(using: .utf8)!
        try mlxConfig.write(to: mlxModel.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: 2048).write(to: mlxModel.appendingPathComponent("model.safetensors"))
        try FileManager.default.createDirectory(
            at: store.mlxDirectory.appendingPathComponent("NotAModel", isDirectory: true),
            withIntermediateDirectories: true
        )

        let catalog = store.refreshedCatalog(
            device: Self.comfortableDevice,
            ggufRuntime: .llamaCpp,
            bandwidthTable: [:]
        )

        #expect(catalog.entries.map(\.id) == ["Exists", "mlx-community--X-4bit"]) // sorted
        let mlx = try #require(catalog.entries.first { $0.id == "mlx-community--X-4bit" })
        #expect(mlx.format == .mlxSafetensors)
        // ~2 kB of weights on a 16 GB-class device is comfortably under
        // even a large context, so: no override. head_dim 8 × 1 layer ×
        // 1 kv head × 2 (bytes/elem) × 8192 = 131,072 bytes of KV cache —
        // parsed fine, which is the point of the fixture.
        #expect(mlx.contextSize == nil)
        #expect(mlx.bytes >= 2048)
    }

    @Test("an unparseable .gguf still gets a row (size only), never poisoning presets")
    func refreshToleratesUnparseableFile() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try store.ensureDirectoriesExist()
        try Data("not a gguf at all".utf8).write(to: store.ggufDirectory.appendingPathComponent("Junk.gguf"))

        let catalog = store.refreshedCatalog(
            device: Self.comfortableDevice,
            ggufRuntime: .llamaCpp,
            bandwidthTable: [:]
        )

        #expect(catalog.entries.count == 1)
        #expect(catalog.entries[0].id == "Junk")
        #expect(catalog.entries[0].bytes == 17)
        #expect(catalog.entries[0].contextSize == nil)
    }
}
