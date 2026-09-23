import Foundation

/// One file within a Hugging Face repo, as the Hub API's `?blobs=true`
/// listing describes it (`siblings[]`). docs/ARCHITECTURE.md §6:
/// "GET /api/models/{repo} for the file list and sizes ... the LFS sha256
/// verified on completion."
struct HFFile: Sendable, Equatable {
    /// The path exactly as the Hub reports it (`rfilename`) — may include
    /// a subdirectory. Confirmed against real quant repos
    /// (`unsloth/gemma-3-27b-it-GGUF`, `ggml-org/...`): BF16 variants are
    /// often listed as `BF16/gemma-3-27b-it-BF16-00001-of-00002.gguf`.
    var remotePath: String
    var sizeBytes: Int64
    /// Present only for LFS-tracked files — real model weights,
    /// tokenizer binaries, and similar. Confirmed against a real MLX repo
    /// (`mlx-community/Qwen2.5-7B-Instruct-4bit`) that only
    /// `model.safetensors` is LFS-tracked; `config.json`, `tokenizer.json`,
    /// `vocab.json`, `merges.txt` etc. have no checksum at all, so
    /// verification for those can only ever be size-only.
    var sha256: String?
    /// Saves the file under this name instead — used for a vision
    /// projector, which every repo calls `mmproj-F16.gguf`: two vision
    /// models in the flat `gguf/` folder would overwrite each other's.
    /// See `ModelStore.projectorFilename(forModelID:)`.
    var localNameOverride: String?

    /// What Quail actually writes to disk: `remotePath` flattened to its
    /// last path component (or `localNameOverride`). Router-mode
    /// llama-server's flat directory scan of `gguf/` would never see a
    /// file preserved under a subdirectory, and MLX directories
    /// (ARCHITECTURE.md §6) are flat too.
    var localFilename: String {
        localNameOverride ?? URL(fileURLWithPath: remotePath).lastPathComponent
    }
}

/// The file listing for one Hugging Face repo — the result of
/// `HFDownloader.listFiles`.
struct HFRepo: Sendable, Equatable {
    var id: String
    var files: [HFFile]
}

/// Progress for one file within an in-progress `HFDownloader.install` call.
struct HFDownloadProgress: Sendable, Equatable {
    var file: HFFile
    var bytesWritten: Int64
    var totalBytes: Int64
}

/// Emitted by `HFDownloader.install`'s `AsyncStream` as a (possibly
/// multi-file, e.g. a full MLX model directory) download proceeds.
enum HFDownloadEvent: Sendable, Equatable {
    case progress(HFDownloadProgress)
    case fileCompleted(HFFile)
    /// Every file in the call verified and moved into
    /// `destinationDirectory`. Terminal event on success.
    case finished(destinationDirectory: URL)
    /// Terminal event on failure — `install`'s `AsyncStream` finishes
    /// immediately after. Whatever's in `.partial/` is left as-is for a
    /// later resume, except for `checksumMismatch`, which deletes just
    /// that one file's partial bytes (see `HFDownloader.install`'s doc
    /// comment).
    case failed(HFDownloadError)
}

enum HFDownloadError: Error, Sendable, Equatable {
    case invalidRepoID
    /// The Hub returned 401 on `resolve/main/...` — confirmed against a
    /// real gated repo (`meta-llama/Llama-3.1-8B-Instruct`) that the
    /// listing endpoint still succeeds (200) while resolve doesn't, so
    /// this is only ever detected at download time, not listing time.
    case gatedRepoRequiresToken
    case httpStatus(Int)
    case invalidResponse
    case checksumMismatch(file: String, expected: String, actual: String)
    case decoding(String)
}
