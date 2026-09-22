import Foundation

/// The decision logic behind the "Add model…" sheet, kept out of the
/// view so it's unit-testable: given a repo listing, what format is it,
/// what quant labels can be offered, and exactly which `HFFile`s a pick
/// resolves to. `ModelInstallController` then just installs a resolved
/// file list — this is the only place the curated catalog's *labels*
/// meet the Hub's *filenames*.
enum ModelAddPlan {
    /// Format-guess for a pasted (uncurated) repo: main `.gguf` files
    /// (not `mmproj-*` companions) make it a GGUF repo; a `config.json`
    /// plus any `.safetensors` makes it MLX. `nil` when it's neither —
    /// the sheet refuses with "not a model repo" rather than guessing
    /// worse. A repo carrying both (some GGUF repos ship conversion
    /// sources) is treated as GGUF, the more constrained read.
    static func format(guessing listing: HFRepo) -> ModelFormat? {
        if listing.files.contains(where: { isMainGGUF($0.localFilename) }) {
            return .gguf
        }
        let hasConfig = listing.files.contains { $0.localFilename == "config.json" }
        let hasSafetensors = listing.files.contains { $0.localFilename.hasSuffix(".safetensors") }
        if hasConfig, hasSafetensors {
            return .mlxSafetensors
        }
        return nil
    }

    /// The quant labels offered for a pasted GGUF listing — the trailing
    /// token of every main GGUF filename's shard-stripped stem, e.g.
    /// `Qwen3-0.6B-Q8_0.gguf` → `"Q8_0"`. (Curated families don't need
    /// this — they bring their own labels from the catalog.)
    static func quants(in listing: HFRepo) -> [String] {
        Set(listing.files.compactMap { file -> String? in
            guard isMainGGUF(file.localFilename) else { return nil }
            let stem = stemStrippingShard(file.localFilename)
            guard let cut = stem.lastIndex(where: { $0 == "-" || $0 == "." }), cut != stem.startIndex else {
                return stem
            }
            let token = stem[stem.index(after: cut)...]
            return token.isEmpty ? stem : String(token)
        }).sorted()
    }

    /// Everything a GGUF pick downloads: every main file whose stem
    /// carries `quant` (all parts of a split model included —
    /// llama.cpp's loader follows the shard manifest from the first, and
    /// `ModelStore.installedGGUFFiles` deliberately shows the router
    /// only that first part), plus the vision projector when the curated
    /// variant names one and the repo actually has it.
    static func ggufFiles(for listing: HFRepo, quant: String, mmproj: String?) -> [HFFile] {
        var files = listing.files
            .filter { isMainGGUF($0.localFilename) && matchesQuant(
                stem: stemStrippingShard($0.localFilename),
                quant: quant
            ) }
            .sorted { $0.localFilename < $1.localFilename }
        if let mmprojName = mmproj {
            let want = URL(fileURLWithPath: mmprojName).lastPathComponent
            if let companion = listing.files.first(where: { $0.localFilename == want }) {
                files.append(companion)
            }
        }
        return files
    }

    /// Everything an MLX model's directory needs — the whole listing
    /// minus the repo's VCS dotfiles. `mlx-lm`-style loaders ignore
    /// unknown files, but there's no reason to store `.gitattributes`
    /// (confirmed present in every repo checked, ~1.5 KB) in the store.
    static func mlxFiles(for listing: HFRepo) -> [HFFile] {
        listing.files
            .filter { !$0.localFilename.hasPrefix(".") }
            .sorted { $0.localFilename < $1.localFilename }
    }

    // MARK: - Filename matching

    /// Case-insensitive — confirmed necessary: `gpt-oss-20b-GGUF`'s
    /// catalog label "mxfp4" is `gpt-oss-20b-MXFP4.gguf` on disk.
    /// Requires a separator before the label, or an offered "Q8_0" would
    /// also match `...-IQ8_0.gguf` and download the wrong quantisation.
    static func matchesQuant(stem: String, quant: String) -> Bool {
        let s = stem.lowercased()
        let q = quant.lowercased()
        if s == q {
            return true
        }
        guard s.hasSuffix(q), s.count > q.count else { return false }
        let boundary = s[s.index(s.endIndex, offsetBy: -q.count - 1)]
        return boundary == "-" || boundary == "." || boundary == "_"
    }

    static func isMainGGUF(_ filename: String) -> Bool {
        filename.lowercased().hasSuffix(".gguf") && !filename.hasPrefix("mmproj-")
    }

    /// `X-Q4_K_M-00001-of-00002` → `X-Q4_K_M`, so a split model presents
    /// and matches as its base label. Only the exact llama.cpp
    /// five-digit `-NNNNN-of-NNNNN` suffix is stripped, so names like
    /// `Llama-3-8B` are untouched.
    static func stemStrippingShard(_ filename: String) -> String {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        guard let ofRange = stem.range(of: "-of-") else { return stem }
        let after = stem[ofRange.upperBound...]
        guard after.count == 5, after.allSatisfy(\.isNumber) else { return stem }
        let head = stem[..<ofRange.lowerBound]
        guard let dash = head.lastIndex(of: "-") else { return stem }
        let digits = head[head.index(after: dash)...]
        guard digits.count == 5, digits.allSatisfy(\.isNumber) else { return stem }
        return String(head[..<dash])
    }
}
