import Foundation
import Testing
@testable import Quail

@Suite("Catalog")
struct CatalogTests {
    private static func scratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A directory containing `catalog.json` works as a `Bundle` for
    /// resource lookup — same trick `ChipBandwidthTable` tests use.
    private static func locations(
        seed: String? = nil,
        directory: URL? = nil
    ) -> Catalog.Locations {
        let dir = directory ?? scratchDir()
        if let seed {
            try? seed.write(to: dir.appendingPathComponent("catalog.json"), atomically: true, encoding: .utf8)
        }
        // Unwrapping caveat: Bundle(url:) returns nil only for a
        // nonexistent path; scratchDir() always exists.
        return Catalog.Locations(bundle: Bundle(url: dir)!, directory: dir)
    }

    private static let seedJSON = """
    {
      "revision": 2,
      "asOf": "2026-09-01",
      "ramTiersGB": { "small": { "max": 24, "recommendParamsB": [0, 9] } },
      "chipBandwidthGBps": { "Apple M4 Pro": 273 },
      "families": [
        { "id": "alpha", "name": "Alpha", "paramsB": 8, "role": "general", "rank": 2,
          "license": "MIT",
          "variants": { "gguf": { "repo": "org/Alpha-GGUF", "quants": ["Q4_K_M", "Q8_0"], "default": "Q4_K_M" },
                        "mlx": { "repo": "mlx-community/Alpha-4bit" } } },
        { "id": "beta", "name": "Beta", "paramsB": 0.6, "role": "smoke-test", "rank": 99,
          "license": "Apache-2.0",
          "variants": { "gguf": { "repo": "org/Beta-GGUF", "quants": ["Q8_0"], "default": "Q8_0" } } }
      ]
    }
    """

    // MARK: - Bundled seed

    @Test("bundled decodes the seed document into families and metadata")
    func bundledDecodes() throws {
        let locations = Self.locations(seed: Self.seedJSON)

        let catalog = Catalog.bundled(in: locations.bundle)

        #expect(catalog.revision == 2)
        #expect(catalog.asOf == "2026-09-01")
        #expect(catalog.chipBandwidthGBps["Apple M4 Pro"] == 273)
        #expect(catalog.ramTiers["small"]?.maxGB == 24)
        #expect(catalog.ramTiers["small"]?.recommendedRange == (0.0 ... 9.0))
        #expect(catalog.families.count == 2)

        let alpha = try #require(catalog.families.first { $0.id == "alpha" })
        #expect(alpha.gguf?.repo == "org/Alpha-GGUF")
        #expect(alpha.gguf?.defaultQuant == "Q4_K_M")
        #expect(alpha.mlx?.repo == "mlx-community/Alpha-4bit")
        #expect(alpha.paramsB == 8)
        #expect(alpha.rank == 2)
        #expect(alpha.isCurated)

        // Beta has no MLX variant at all — nomic-embed-v1.5 in the real
        // seed is the same shape.
        let beta = try #require(catalog.families.first { $0.id == "beta" })
        #expect(beta.mlx == nil)
        #expect(beta.repo(for: .mlxSafetensors) == nil)
        #expect(beta.repo(for: .gguf) == "org/Beta-GGUF")
    }

    @Test("bundled returns an empty catalog when the resource is missing or malformed")
    func bundledTolerant() throws {
        let missing = try Catalog.Locations(
            bundle: #require(Bundle(url: Self.scratchDir())),
            directory: Self.scratchDir()
        )
        #expect(Catalog.bundled(in: missing.bundle).families.isEmpty)

        let broken = Self.locations(seed: "{ not json")
        #expect(Catalog.bundled(in: broken.bundle).families.isEmpty)
    }

    // MARK: - Merge

    @Test("current with no cache or user file is just the bundled seed")
    func currentBundledOnly() {
        let locations = Self.locations(seed: Self.seedJSON)
        let catalog = Catalog.current(locations: locations)
        #expect(catalog.revision == 2)
        #expect(catalog.families.map(\.id) == ["alpha", "beta"])
    }

    @Test("a cached refresh with a revision at or above the bundled one wins")
    func cacheWins() throws {
        let dir = Self.scratchDir()
        let locations = Self.locations(seed: Self.seedJSON, directory: dir)
        let document = Catalog.Document(
            revision: 2,
            asOf: "2026-09-15",
            ramTiersGB: [:],
            chipBandwidthGBps: [:],
            families: [.init(id: "gamma", name: "Gamma", variants: .init(gguf: nil, mlx: nil))]
        )
        try Catalog.saveRefreshCache(document, fetchedAt: .init(), to: locations.refreshCacheFile)

        let catalog = Catalog.current(locations: locations)

        #expect(catalog.families.map(\.id) == ["gamma"])
        #expect(catalog.asOf == "2026-09-15")
    }

    @Test("a cached refresh older than the bundled seed is ignored")
    func cacheStale() throws {
        let dir = Self.scratchDir()
        let locations = Self.locations(seed: Self.seedJSON, directory: dir) // revision 2
        let document = Catalog.Document(
            revision: 1,
            asOf: nil,
            ramTiersGB: [:],
            chipBandwidthGBps: [:],
            families: [.init(id: "gamma", name: "Gamma", variants: .init(gguf: nil, mlx: nil))]
        )
        try Catalog.saveRefreshCache(document, fetchedAt: .init(), to: locations.refreshCacheFile)

        let catalog = Catalog.current(locations: locations)

        #expect(catalog.families.contains { $0.id == "alpha" })
        #expect(!catalog.families.contains { $0.id == "gamma" })
    }

    @Test("a corrupt cache file degrades to the bundled seed")
    func cacheCorrupt() throws {
        let dir = Self.scratchDir()
        let locations = Self.locations(seed: Self.seedJSON, directory: dir)
        try Data("garbage".utf8).write(to: locations.refreshCacheFile)

        #expect(Catalog.current(locations: locations).families.count == 2)
    }

    @Test("user entries append as uncurated families, variants from resolved format")
    func userEntriesAppended() throws {
        let dir = Self.scratchDir()
        let locations = Self.locations(seed: Self.seedJSON, directory: dir)
        try Catalog.saveUserEntries(
            [
                .init(repo: "someone/New-GGUF", format: .gguf, addedAt: .init()),
                .init(repo: "someone/Unknown", format: nil, addedAt: .init()),
            ],
            to: locations.userEntriesFile
        )

        let catalog = Catalog.current(locations: locations)

        let new = try #require(catalog.families.first { $0.id == "someone/New-GGUF" })
        #expect(!new.isCurated)
        #expect(new.gguf?.repo == "someone/New-GGUF")
        #expect(new.mlx == nil)
        #expect(new.paramsB == nil)
        let unknown = try #require(catalog.families.first { $0.id == "someone/Unknown" })
        #expect(unknown.gguf == nil)
        #expect(unknown.mlx == nil)
        #expect(unknown.repo(for: .gguf) == nil)
    }

    @Test("a user entry already covered by a curated family is not duplicated")
    func userEntryDeduped() throws {
        let dir = Self.scratchDir()
        let locations = Self.locations(seed: Self.seedJSON, directory: dir)
        // "org/Alpha-GGUF" is alpha's gguf variant; "beta" is a family id.
        try Catalog.saveUserEntries(
            [
                .init(repo: "org/Alpha-GGUF", format: .gguf, addedAt: .init()),
                .init(repo: "beta", format: nil, addedAt: .init()),
            ],
            to: locations.userEntriesFile
        )

        let catalog = Catalog.current(locations: locations)

        #expect(catalog.families.count == 2)
        // swiftformat:disable:next preferKeyPath
        #expect(catalog.families.allSatisfy { $0.isCurated })
    }

    @Test("a corrupt user file degrades to no user entries")
    func userFileCorrupt() throws {
        let dir = Self.scratchDir()
        let locations = Self.locations(seed: Self.seedJSON, directory: dir)
        try Data("not json".utf8).write(to: locations.userEntriesFile)

        #expect(Catalog.current(locations: locations).families.count == 2)
    }

    @Test("user entries round-trip through save/load")
    func userEntriesRoundTrip() throws {
        let url = Self.scratchDir().appendingPathComponent("user-catalog.json")
        let entries = [
            Catalog.UserEntry(repo: "a/b", format: .mlxSafetensors, addedAt: Date(timeIntervalSince1970: 1000)),
            Catalog.UserEntry(repo: "c/d", format: nil, addedAt: Date(timeIntervalSince1970: 2000)),
        ]
        try Catalog.saveUserEntries(entries, to: url)
        #expect(Catalog.loadUserEntries(from: url) == entries)
    }

    // MARK: - The real shipped seed

    @Test("the real Resources/catalog.json decodes and is self-consistent")
    func realShippedSeedDecodes() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // QuailTests/
            .deletingLastPathComponent() // repo root
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Quail/Resources/catalog.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Catalog.Document.self, from: data)
        let catalog = document.catalog

        // 8-12 families per the plan; every repo id and quant filename in
        // it was verified against the live Hub API (see PR).
        #expect((8 ... 12).contains(catalog.families.count))
        #expect(catalog.ramTiers.keys.sorted() == ["large", "medium", "small"])
        #expect(catalog.chipBandwidthGBps["Apple M4 Pro"] == 273)

        for family in catalog.families {
            #expect(family.gguf != nil || family.mlx != nil, "\(family.id) has no variants")
            #expect(family.paramsB != nil, "\(family.id) missing paramsB")
            if let gguf = family.gguf {
                #expect(!gguf.quants.isEmpty)
                if let defaultQuant = gguf.defaultQuant {
                    #expect(
                        gguf.quants.contains(defaultQuant),
                        "\(family.id): default \(defaultQuant) not in \(gguf.quants)"
                    )
                }
            }
        }

        // Spot-checks against the values verified live:
        let qwen3 = try #require(catalog.families.first { $0.id == "qwen3-0.6b" })
        #expect(qwen3.gguf?.repo == "Qwen/Qwen3-0.6B-GGUF")
        #expect(qwen3.mlx?.repo == "mlx-community/Qwen3-0.6B-4bit")
        let coder = try #require(catalog.families.first { $0.id == "qwen3-30b-a3b" })
        #expect(coder.activeParamsB == 3)
        let embed = try #require(catalog.families.first { $0.id == "nomic-embed-v1.5" })
        #expect(embed.mlx == nil, "embedding family ships GGUF only")
        let gemma = try #require(catalog.families.first { $0.id == "gemma-3-12b" })
        #expect(gemma.gguf?.mmproj == "mmproj-F16.gguf")
    }
}
