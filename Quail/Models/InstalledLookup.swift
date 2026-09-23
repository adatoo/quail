import Foundation

/// Which installed models belong to a catalog family, and at which quant —
/// so the Add-model sheet can mark what's already on disk and offer delete
/// instead of a second download. Pure, over `StoreCatalog` entries.
enum InstalledLookup {
    /// Entries of `family`, matched by (in order of trust): the family id
    /// recorded at download time, the repo it came from, or — for GGUFs
    /// placed by hand, which carry neither — an id that starts with the
    /// repo's model name (`Qwen/Qwen3-0.6B-GGUF` → `Qwen3-0.6B-…`).
    static func entries(for family: Catalog.Family, in installed: [InstalledModel]) -> [InstalledModel] {
        let repos = Set([family.gguf?.repo, family.mlx?.repo].compactMap(\.self))
        return installed.filter { entry in
            if let recorded = entry.family {
                return recorded == family.id
            }
            if let source = entry.sourceRepo {
                return repos.contains(source)
            }
            guard entry.format == .gguf, let stem = ggufStem(of: family) else { return false }
            return entry.id.lowercased().hasPrefix(stem.lowercased() + "-")
        }
    }

    /// The installed entry for one specific pick: a GGUF at `quant`, or
    /// the family's MLX variant.
    static func entry(
        for family: Catalog.Family,
        format: ModelFormat,
        quant: String?,
        in installed: [InstalledModel]
    ) -> InstalledModel? {
        entries(for: family, in: installed).first { entry in
            guard entry.format == format else { return false }
            guard format == .gguf, let quant else { return true }
            if let recorded = entry.quant {
                return recorded.caseInsensitiveCompare(quant) == .orderedSame
            }
            return ModelAddPlan.matchesQuant(stem: entry.id, quant: quant)
        }
    }

    /// A pasted (uncurated) repo's installed entry, by source repo.
    static func entry(
        forRepo repo: String,
        format: ModelFormat,
        quant: String?,
        in installed: [InstalledModel]
    ) -> InstalledModel? {
        installed.first { entry in
            guard entry.sourceRepo == repo, entry.format == format else { return false }
            guard format == .gguf, let quant else { return true }
            return ModelAddPlan.matchesQuant(stem: entry.id, quant: quant)
        }
    }

    /// `Qwen/Qwen3-0.6B-GGUF` → `Qwen3-0.6B`.
    private static func ggufStem(of family: Catalog.Family) -> String? {
        guard let repo = family.gguf?.repo, let name = repo.split(separator: "/").last else { return nil }
        let stem = String(name)
        return stem.lowercased().hasSuffix("-gguf") ? String(stem.dropLast(5)) : stem
    }
}
