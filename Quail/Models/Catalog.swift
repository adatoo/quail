import Foundation

/// The curated download list — a different concept from `StoreCatalog`
/// (the store's installed-models index): that one describes what's on
/// disk, this one describes what's available to download
/// (docs/ARCHITECTURE.md §6, "Catalog"). Same word "catalog" for two
/// files (`Resources/catalog.json` vs the store's own `catalog.json`),
/// hence the two distinct type names.
///
/// Assembled from three sources, newest-revision-wins between the first
/// two, appended last for the third:
/// 1. the bundled seed (`Resources/catalog.json`, shipped in the app),
/// 2. the weekly remote refresh cache (`catalog-refresh.json` under
///    Application Support, fetched by `CatalogRefresher` — only used if
///    its `revision` is at least the bundled one),
/// 3. user-added repo URLs (`user-catalog.json`, uncurated entries).
///
/// Between the curated families and the user's own come the MLX models from Rapid-MLX's catalog
/// (`RapidMLXCatalog`, ADR D-058), which aren't curated here but are checked to load in Quail server.
struct Catalog: Sendable, Equatable {
    /// One family row in the picker (ARCHITECTURE.md §6: "The picker
    /// shows one row per family with format badges"). Curated families
    /// carry full metadata; user-added ones (`isCurated == false`) only
    /// reliably carry `id`/`name`/the resolved variant — `paramsB`,
    /// `role`, `rank` and `license` are `nil` for them, since nothing
    /// without a human review or a Hub query knows them.
    struct Family: Sendable, Equatable, Identifiable, Hashable {
        let id: String
        var name: String
        var paramsB: Double?
        /// Active parameter count for MoE models (e.g. 3 for a 30B-A3B).
        var activeParamsB: Double?
        /// Raw string, not an enum ("general", "coding", "smoke-test",
        /// "embedding"): the remote catalog can add roles between app
        /// releases without breaking decoding — same reasoning as
        /// `ServedModel.Status.value`.
        var role: String?
        var rank: Int?
        var license: String?
        /// What the model is good for, as the catalog curates it — raw strings, like `role`, so a
        /// remote catalog can add one; `ModelStrength.strengths(of:)` reads them (ADR D-052).
        var strengths: [String] = []
        var gguf: GGUFVariant?
        var mlx: MLXVariant?
        var isCurated: Bool
        var addedAt: Date?
        /// Set for a model from Rapid-MLX's catalog (ADR D-058): its size and what the catalog says about it.
        var rapidMLX: RapidMLXCatalog.Model?
        /// The day the maker made the weights public (ADR D-070). Curated families only.
        var released: Date?
        /// The maker's own Hugging Face repo (`Qwen/Qwen3-8B`), as opposed to the quantized one Quail downloads.
        var modelCard: String?
        /// One line on what it's for, and any quirk worth knowing before downloading it.
        var summary: String?
        /// The `id` of a newer family from the same line that replaces this one.
        var supersededBy: String?
        /// Its rating on Arena's text leaderboard, when it's on it (ADR D-070).
        var arena: ArenaRating?
        /// Quail's own scores for its default download (ADR D-070).
        var quailScores: QuailScores?
        /// Why it has no Quail scores ("It always thinks…"), or a caveat shown beside them.
        var quailNote: String?

        /// A repo the user pasted, as opposed to one a catalog lists.
        var isUserAdded: Bool {
            !isCurated && rapidMLX == nil
        }

        /// The repo id this family would download from for `format`,
        /// whichever variant exists — user-added entries resolve to
        /// their single pasted repo.
        func repo(for format: ModelFormat) -> String? {
            switch format {
            case .gguf: gguf?.repo
            case .mlxSafetensors: mlx?.repo
            }
        }
    }

    /// A family's rating on Arena's text leaderboard with style control (arena.ai), from its CC BY 4.0
    /// dataset, `lmarena-ai/leaderboard-dataset`. `scripts/update-arena-ratings` refreshes these (ADR D-070).
    struct ArenaRating: Sendable, Equatable, Hashable {
        var rating: Int
        /// Half the width of the 95% confidence interval: ratings closer than this are a tie.
        var interval: Int
        var rank: Int
        /// How many models the leaderboard ranks.
        var outOf: Int
        var asOf: Date
    }

    /// Quail's own tests of a family's default download, answering without thinking (`task bench:scores`,
    /// `scripts/update-quail-scores`; ADR D-070). Percentages.
    struct QuailScores: Sendable, Equatable, Hashable {
        /// GSM8K, 8-shot chain of thought.
        var maths: Int
        /// MMLU-Pro, 5-shot chain of thought, 14 subjects.
        var knowledge: Int
        /// BFCL's function-calling categories together.
        var tools: Int
        var asOf: Date
    }

    struct GGUFVariant: Sendable, Equatable, Hashable {
        var repo: String
        /// Quant labels, e.g. ["Q4_K_M", "Q8_0"] — not filenames. The
        /// download flow matches case-insensitively against the repo's
        /// actual file list (`HFDownloader.listFiles`), confirmed
        /// necessary: `ggml-org/gpt-oss-20b-GGUF`'s "mxfp4" quant is
        /// `gpt-oss-20b-MXFP4.gguf` on disk, and unsloth puts variants
        /// like `nomic-embed-text-v1.5.f16.gguf` under the repo's own
        /// name rather than a bare `Q*.gguf`.
        var quants: [String]
        var defaultQuant: String?
        /// Optional vision-projector companion filename, paired by name
        /// per ARCHITECTURE.md §6.
        var mmproj: String?
    }

    struct MLXVariant: Sendable, Equatable, Hashable {
        var repo: String
        /// Checked to read images in Quail's MLX engine (a Qwen3.5-family model with its vision half,
        /// ADR D-047 amendment).
        var vision = false
    }

    struct RAMTier: Sendable, Equatable {
        var maxGB: Int
        /// [min, max] params-billions this tier recommends.
        var recommendParamsB: [Double]

        var recommendedRange: ClosedRange<Double>? {
            guard recommendParamsB.count == 2 else { return nil }
            return recommendParamsB[0] ... recommendParamsB[1]
        }
    }

    /// The smallest `ramTiers` entry whose `maxGB` covers `bytes` —
    /// ARCHITECTURE.md §7's "Three tiers: 16 GB machines see 4B–8B
    /// models, 32–48 GB see 14B–32B..." Falls back to the largest tier
    /// (by `maxGB`) for a machine bigger than every tier covers, so a
    /// 128 GB Mac still gets the "large" tier rather than nothing.
    /// `nil` only if `ramTiers` itself is empty (a malformed catalog).
    func tier(forMemoryBytes bytes: Int64) -> (name: String, tier: RAMTier)? {
        let gigabytes = Double(bytes) / 1_073_741_824
        let byMax = ramTiers.sorted { $0.value.maxGB < $1.value.maxGB }
        if let fits = byMax.first(where: { Double($0.value.maxGB) >= gigabytes }) {
            return (fits.key, fits.value)
        }
        return byMax.last.map { ($0.key, $0.value) }
    }

    /// One user-pasted repo URL's worth of entry, as persisted in
    /// `user-catalog.json`. `format` is `nil` until whatever added it
    /// (step 7's "Add model…" sheet, which queries the Hub before
    /// offering it) resolved which variant it fills.
    struct UserEntry: Sendable, Equatable, Codable {
        var repo: String
        var format: ModelFormat?
        var addedAt: Date
    }

    var revision: Int = 0
    var asOf: String?
    var ramTiers: [String: RAMTier] = [:]
    /// Refreshed along with the catalog, unlike
    /// `ChipBandwidthTable.loadFromBundle` which only ever sees the
    /// bundled copy — see that type. Nothing consumes the refreshed
    /// value yet; step 7's verdicts should prefer a loaded `Catalog`'s
    /// table over the bundle-only one.
    var chipBandwidthGBps: [String: Double] = [:]
    var families: [Family] = []
    /// Rapid-MLX's catalog, for its per-Mac picks; its models are already among `families`.
    var rapidMLX: RapidMLXCatalog?

    /// The JSON-file shape of `Resources/catalog.json` (and of whatever
    /// the remote refresh URL serves — same schema). `revision` is the
    /// only field `CatalogRefresher` compares between versions.
    struct Document: Sendable, Equatable, Codable {
        struct RawFamily: Sendable, Equatable, Codable {
            struct Variants: Sendable, Equatable, Codable {
                struct GGUF: Sendable, Equatable, Codable {
                    var repo: String
                    var quants: [String]
                    var `default`: String?
                    var mmproj: String?
                }

                struct MLX: Sendable, Equatable, Codable {
                    var repo: String
                    var vision: Bool?
                }

                var gguf: GGUF?
                var mlx: MLX?
            }

            var id: String
            var name: String
            var paramsB: Double?
            var activeParamsB: Double?
            var role: String?
            var rank: Int?
            var license: String?
            var strengths: [String]?
            var released: String?
            var modelCard: String?
            var summary: String?
            var supersededBy: String?
            var arena: RawArena?
            var quail: RawQuail?
            var variants: Variants
        }

        struct RawQuail: Sendable, Equatable, Codable {
            var maths: Int?
            var knowledge: Int?
            var tools: Int?
            var asOf: String?
            var note: String?
        }

        /// `name` is the model's name on the leaderboard, which the script looks up; the rest is what it found.
        struct RawArena: Sendable, Equatable, Codable {
            var name: String
            var rating: Int?
            var interval: Int?
            var rank: Int?
            var outOf: Int?
            var asOf: String?
        }

        /// `2026-08-05`, read as a calendar day in UTC.
        static func day(_ text: String?) -> Date? {
            guard let text else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            return formatter.date(from: text)
        }

        struct RawRAMTier: Sendable, Equatable, Codable {
            var max: Int
            var recommendParamsB: [Double]
        }

        var revision: Int
        var asOf: String?
        var ramTiersGB: [String: RawRAMTier]
        var chipBandwidthGBps: [String: Double]
        var families: [RawFamily]

        enum CodingKeys: String, CodingKey {
            case revision
            case asOf
            case ramTiersGB
            case chipBandwidthGBps
            case families
        }

        var catalog: Catalog {
            Catalog(
                revision: revision,
                asOf: asOf,
                ramTiers: ramTiersGB.mapValues { RAMTier(maxGB: $0.max, recommendParamsB: $0.recommendParamsB) },
                chipBandwidthGBps: chipBandwidthGBps,
                families: families.map { raw in
                    Family(
                        id: raw.id,
                        name: raw.name,
                        paramsB: raw.paramsB,
                        activeParamsB: raw.activeParamsB,
                        role: raw.role,
                        rank: raw.rank,
                        license: raw.license,
                        strengths: raw.strengths ?? [],
                        gguf: raw.variants.gguf.map { GGUFVariant(
                            repo: $0.repo,
                            quants: $0.quants,
                            defaultQuant: $0.default,
                            mmproj: $0.mmproj
                        ) },
                        mlx: raw.variants.mlx.map { MLXVariant(repo: $0.repo, vision: $0.vision ?? false) },
                        isCurated: true,
                        addedAt: nil,
                        released: Self.day(raw.released),
                        modelCard: raw.modelCard,
                        summary: raw.summary,
                        supersededBy: raw.supersededBy,
                        arena: raw.arena.flatMap { arena in
                            guard let rating = arena.rating, let rank = arena.rank, let outOf = arena.outOf,
                                  let asOf = Self.day(arena.asOf) else { return nil }
                            return ArenaRating(
                                rating: rating, interval: arena.interval ?? 0, rank: rank, outOf: outOf, asOf: asOf
                            )
                        },
                        quailScores: raw.quail.flatMap { quail in
                            guard let maths = quail.maths, let knowledge = quail.knowledge, let tools = quail.tools,
                                  let asOf = Self.day(quail.asOf) else { return nil }
                            return QuailScores(maths: maths, knowledge: knowledge, tools: tools, asOf: asOf)
                        },
                        quailNote: raw.quail?.note
                    )
                }
            )
        }
    }

    // MARK: - Locations

    /// The three places a `Catalog` draws from, kept together so every
    /// test can point them at a scratch directory instead of the real
    /// `~/Library/Application Support/Quail`.
    struct Locations: Sendable {
        var bundle: Bundle
        var refreshCacheFile: URL
        var userEntriesFile: URL
        /// The weekly refresh of Rapid-MLX's catalog (`mlx-models.json`).
        var rapidMLXRefreshFile: URL

        init(bundle: Bundle, refreshCacheFile: URL, userEntriesFile: URL, rapidMLXRefreshFile: URL? = nil) {
            self.bundle = bundle
            self.refreshCacheFile = refreshCacheFile
            self.userEntriesFile = userEntriesFile
            self.rapidMLXRefreshFile = rapidMLXRefreshFile ?? refreshCacheFile.deletingLastPathComponent()
                .appendingPathComponent("mlx-models-refresh.json", isDirectory: false)
        }

        init(bundle: Bundle, directory: URL) {
            self.init(
                bundle: bundle,
                refreshCacheFile: directory.appendingPathComponent("catalog-refresh.json", isDirectory: false),
                userEntriesFile: directory.appendingPathComponent("user-catalog.json", isDirectory: false)
            )
        }

        static let `default` = Locations(bundle: .main, directory: Paths.applicationSupport)
    }

    // MARK: - Loading / merging

    /// The bundle seed decoded, or an empty catalog if it's missing or
    /// malformed (which should never happen for a shipped app, and
    /// doesn't in tests either, since `QuailTests` isn't hosted inside
    /// `Quail.app` — see `CatalogTests` for how the real shipped file is
    /// verified against this schema directly).
    static func bundled(in bundle: Bundle = .main) -> Catalog {
        guard let url = bundle.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let doc = try? decoder().decode(Document.self, from: data)
        else {
            return Catalog()
        }
        return doc.catalog
    }

    /// Bundled ⊕ refresh cache (if its revision wins) ⊕ user entries,
    /// de-duplicated so a user-pasted repo that's already a curated
    /// family's variant doesn't show up twice.
    static func current(locations: Locations = .default) -> Catalog {
        var result = bundled(in: locations.bundle)
        if let cached = loadRefreshCache(from: locations.refreshCacheFile),
           cached.revision >= result.revision
        {
            result = cached
        }
        // Rapid-MLX's models after the curated families, leaving out those a curated family already offers.
        if let rapid = RapidMLXCatalog.current(locations: locations) {
            result.rapidMLX = rapid
            let curatedRepos = Set(result.families.compactMap { $0.mlx?.repo.lowercased() })
            result.families += rapid.families.filter { !curatedRepos.contains($0.id.lowercased()) }
        }
        let userEntries = loadUserEntries(from: locations.userEntriesFile)
        for entry in userEntries {
            guard !result.families.contains(where: { family in
                family.id == entry.repo || family.gguf?.repo == entry.repo || family.mlx?.repo == entry.repo
            }) else { continue }
            result.families.append(family(for: entry))
        }
        return result
    }

    private static func family(for entry: UserEntry) -> Family {
        Family(
            id: entry.repo,
            name: entry.repo,
            gguf: entry.format == .gguf ? GGUFVariant(repo: entry.repo, quants: [], defaultQuant: nil) : nil,
            mlx: entry.format == .mlxSafetensors ? MLXVariant(repo: entry.repo) : nil,
            isCurated: false,
            addedAt: entry.addedAt
        )
    }

    // MARK: - Persistence helpers (all tolerant of missing/corrupt files)

    /// The on-disk envelope for the weekly refresh: what was fetched,
    /// and when. Stores the wire format (`Document`), not the value
    /// type — same file the remote URL itself would serve, so the
    /// schema lives in exactly one place.
    struct CachedRefresh: Sendable, Equatable, Codable {
        var fetchedAt: Date
        var document: Document
    }

    static func loadRefreshCache(from url: URL) -> Catalog? {
        guard let data = try? Data(contentsOf: url),
              let cached = try? decoder().decode(CachedRefresh.self, from: data)
        else { return nil }
        return cached.document.catalog
    }

    static func fetchedAtOfRefreshCache(at url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let cached = try? decoder().decode(CachedRefresh.self, from: data)
        else { return nil }
        return cached.fetchedAt
    }

    static func saveRefreshCache(_ document: Document, fetchedAt: Date, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cached = CachedRefresh(fetchedAt: fetchedAt, document: document)
        try encoder().encode(cached).write(to: url, options: .atomic)
    }

    static func loadUserEntries(from url: URL) -> [UserEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder().decode([UserEntry].self, from: data)) ?? []
    }

    static func saveUserEntries(_ entries: [UserEntry], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder().encode(entries).write(to: url, options: .atomic)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
