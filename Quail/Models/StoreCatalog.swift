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
    var family: String? = nil
    var format: ModelFormat
    var bytes: Int64
    var sha256: String? = nil
    var sourceRepo: String? = nil
    var params: String? = nil
    var quant: String? = nil
    /// The "Automatic" context for this model on this Mac — recomputed by
    /// `ModelStore.refreshedCatalog` (`FitEstimator.automaticContextSize`,
    /// ADR D-020); `nil` when it can't be estimated.
    var contextSize: Int? = nil
    /// The user's choice from the Models pane's context picker; `nil`
    /// means Automatic. Never overwritten by a refresh.
    var userContextSize: Int? = nil
    /// The context the model was trained for, from its header — caps the
    /// picker's options.
    var trainedContext: Int? = nil
    var addedAt: Date

    /// What `presets.ini` gets as `ctx-size`.
    var effectiveContextSize: Int {
        userContextSize ?? contextSize ?? FitEstimator.defaultContextSize
    }
}

/// The store's installed-models index, `catalog.json`. A plain wrapper
/// (rather than a bare `[InstalledModel]`) so the file has room to grow a
/// schema version or other top-level metadata later without another
/// migration.
struct StoreCatalog: Sendable, Equatable, Codable {
    var entries: [InstalledModel] = []
}
