import Foundation

/// One installed model — a row in the store's `catalog.json` index
/// (docs/ARCHITECTURE.md §6: "index: id, family, format, bytes, sha,
/// source repo, params, quant, added"). This is Quail's own record of
/// what it downloaded and knows about; it is not what makes a model
/// servable — llama-server's own directory scan of `gguf/` does that
/// independently, so a model placed by hand with no catalog entry still
/// works (docs/IMPLEMENTATION_PLAN.md Phase 1's "Done when").
///
/// Not to be confused with the curated-download-list `Catalog` (Phase 2
/// step 6, `Resources/catalog.json`) — that one describes what's
/// available to download; this one describes what's already on disk. Two
/// different concepts that both happen to be called "catalog" in
/// ARCHITECTURE.md, hence the more specific type names here.
struct InstalledModel: Sendable, Equatable, Codable, Identifiable {
    /// The alias router-mode llama-server derives and lists at `/models`
    /// for a GGUF (its filename without extension), or the directory name
    /// for an MLX model.
    let id: String
    var family: String?
    var format: ModelFormat
    var bytes: Int64
    var sha256: String?
    var sourceRepo: String?
    var params: String?
    var quant: String?
    /// The context length Quail has decided this model should run at —
    /// `nil` until Phase 2 step 4's `FitEstimator` sets one; `ModelStore`
    /// falls back to a fixed default in `presets.ini` until then.
    var contextSize: Int?
    var addedAt: Date
}

/// The store's installed-models index, `catalog.json`. A plain wrapper
/// (rather than a bare `[InstalledModel]`) so the file has room to grow a
/// schema version or other top-level metadata later without another
/// migration.
struct StoreCatalog: Sendable, Equatable, Codable {
    var entries: [InstalledModel] = []
}
