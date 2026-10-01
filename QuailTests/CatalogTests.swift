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

    // MARK: - Rapid-MLX's catalog (ADR D-058)

    @Test("the real Resources/mlx-models.json decodes, and its models become MLX-only rows")
    func realRapidMLXCatalogDecodes() throws {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Quail/Resources/mlx-models.json"))
        let rapid = try #require(RapidMLXCatalog.decode(data))
        #expect(rapid.source.license == "Apache-2.0")
        #expect(rapid.models.count > 50)
        #expect(Set(rapid.models.map(\.repo)).count == rapid.models.count, "a repo is listed twice")
        for tier in rapid.recommendations {
            for pick in tier.picks {
                #expect(rapid.models.contains { $0.repo == pick.repo }, "pick \(pick.alias) isn't a listed model")
            }
        }
        let families = rapid.families
        #expect(families.allSatisfy { $0.gguf == nil && $0.mlx != nil && !$0.isCurated && !$0.isUserAdded })
    }

    @Test("parameter counts come from Rapid-MLX aliases")
    func rapidMLXParameters() {
        #expect(RapidMLXCatalog.parameters(in: "qwen3.6-35b-a3b-4bit") == 35)
        #expect(RapidMLXCatalog.activeParameters(in: "qwen3.6-35b-a3b-4bit") == 3)
        #expect(RapidMLXCatalog.parameters(in: "gemma-4-e4b-4bit") == 4)
        #expect(RapidMLXCatalog.parameters(in: "lfm2.5-1.2b-4bit") == 1.2)
        #expect(RapidMLXCatalog.parameters(in: "qwen3-coder-next-4bit") == nil)
    }

    @Test("Catalog.current adds Rapid-MLX's models after the curated ones, without repeating a curated repo")
    func currentAddsRapidMLX() throws {
        let dir = Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let locations = Self.locations(seed: Self.seedJSON, directory: dir)
        let rapid = """
        {"schemaVersion": 1, "revision": 3, "source": {"name": "Rapid-MLX", "version": "0.14.3",
         "license": "Apache-2.0", "url": "u"},
         "models": [
          {"alias": "alpha-8b-4bit", "repo": "mlx-community/Alpha-4bit", "modelType": "qwen3", "moe": false,
           "vision": false, "reasoning": false},
          {"alias": "gamma-4b-4bit", "repo": "mlx-community/Gamma-4bit", "modelType": "qwen3", "sizeBytes": 2000,
           "moe": false, "vision": false, "reasoning": true}],
         "recommendations": []}
        """
        try rapid.write(to: dir.appendingPathComponent("mlx-models.json"), atomically: true, encoding: .utf8)
        let catalog = Catalog.current(locations: locations)
        #expect(catalog.families.filter { $0.mlx?.repo == "mlx-community/Alpha-4bit" }.count == 1)
        let gamma = try #require(catalog.families.last)
        #expect(gamma.id == "mlx-community/Gamma-4bit")
        #expect(gamma.rapidMLX?.sizeBytes == 2000)
        #expect(gamma.paramsB == 4)
        #expect(catalog.rapidMLX?.revision == 3)
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

        // Every repo id and quant filename in it was verified against the live Hub API when its
        // revision added it (the catalog's own notes say how each was checked).
        #expect(catalog.families.count >= 17)
        #expect(Set(catalog.families.map(\.id)).count == catalog.families.count, "family ids must be unique")
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
        let moe = try #require(catalog.families.first { $0.id == "qwen3.6-35b-a3b" })
        #expect(moe.activeParamsB == 3)
        let embed = try #require(catalog.families.first { $0.id == "nomic-embed-v1.5" })
        #expect(embed.mlx == nil, "embedding family ships GGUF only")
        let gemma = try #require(catalog.families.first { $0.id == "gemma-4-12b" })
        #expect(gemma.gguf?.mmproj == "mmproj-F16.gguf")
        let qwen35 = try #require(catalog.families.first { $0.id == "qwen3.5-9b" })
        // bartowski's, not unsloth's: unsloth's template turns thinking off unless a request asks for it.
        #expect(qwen35.gguf?.repo == "bartowski/Qwen_Qwen3.5-9B-GGUF")
        #expect(qwen35.gguf?.mmproj == "mmproj-Qwen_Qwen3.5-9B-f16.gguf")
        // The same repo Rapid-MLX lists, so Add Model shows it once (Catalog.current drops the duplicate).
        #expect(qwen35.mlx?.repo == "mlx-community/Qwen3.5-9B-4bit")
        #expect(qwen35.mlx?.vision == true)
        // Revision 8, Bonsai (ADR D-069). 1-bit Bonsai is GGUF only: MLX 0.32 has no 1-bit quantization.
        let bonsai = try #require(catalog.families.first { $0.id == "bonsai-8b" })
        #expect(bonsai.gguf?.repo == "prism-ml/Bonsai-8B-gguf")
        #expect(bonsai.gguf?.quants == ["Q1_0"])
        #expect(bonsai.mlx == nil)
        // Ternary Bonsai offers the 64-weight-block files llama.cpp reads, never PrismML's Q2_0 (128-weight blocks)
        // or PQ2_0, which need its fork. The 27B's is named differently.
        let ternary8 = try #require(catalog.families.first { $0.id == "ternary-bonsai-8b" })
        #expect(ternary8.gguf?.quants == ["Q2_0_g64"])
        let ternary = try #require(catalog.families.first { $0.id == "ternary-bonsai-27b" })
        #expect(ternary.gguf?.quants == ["Q2_g64"])
        #expect(ternary.gguf?.mmproj == "Ternary-Bonsai-27B-mmproj-Q8_0.gguf")
        #expect(ternary.mlx?.repo == "prism-ml/Ternary-Bonsai-27B-mlx-2bit")
        #expect(ternary.mlx?.vision == true)
        // Bonsai 2 runs on MLX only, through Quail's copy of mlx-swift-lm #630 (Models/PrismHadamard.swift).
        let bonsai2 = try #require(catalog.families.first { $0.id == "bonsai-2-27b" })
        #expect(bonsai2.gguf == nil)
        #expect(bonsai2.mlx?.repo == "prism-ml/Ternary-Bonsai-2-27B-mlx-2bit")
        let granite = try #require(catalog.families.first { $0.id == "granite-4.2-8b" })
        #expect(granite.mlx?.repo == "ibm-granite/granite-4.2-8b-q4-mlx")
        let ornith = try #require(catalog.families.first { $0.id == "ornith-1.5-9b" })
        #expect(ornith.gguf?.mmproj == "mmproj-Ornith-1.5-9B-BF16.gguf")
        // Ornith's own MLX 4-bit leaves the vision tower out.
        #expect(ornith.mlx?.vision == false)
    }
}
