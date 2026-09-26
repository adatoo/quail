import Foundation
import Observation
import os

/// The observable download state `ModelStore`'s UI (docs/IMPLEMENTATION_
/// PLAN.md Phase 2 step 7's Models pane and "Add model…" sheet) binds to.
/// One download runs at a time (`HFDownloader` fetches one file at a time, and a second transfer would
/// only share the bandwidth); more are queued and start in order as each one ends — finished, failed or
/// cancelled.
///
/// A thin state machine, deliberately: every real failure mode (gated
/// repo, checksum mismatch, transport error) arrives as an
/// `HFDownloadError` through the event stream and is surfaced as
/// `failed(message)` — never thrown across the `@MainActor` boundary, so
/// a view can't crash on an unhandled async throw mid-render.
@MainActor
@Observable
final class ModelInstallController {
    enum Phase: Sendable, Equatable {
        case idle
        /// A download is in flight. `bytesWritten`/`totalBytes` are
        /// cumulative across all files in the task (e.g. an MLX repo's
        /// ~11 files), so the progress bar doesn't reset at file
        /// boundaries.
        case downloading(bytesWritten: Int64, totalBytes: Int64, currentFile: String)
        /// Terminal; the row is already in `ModelStore`'s catalog. Kept
        /// observable (rather than just back to `.idle`) so a sheet can
        /// show "Installed" until it's dismissed.
        case installed(modelID: String)
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle

    /// What's being/best downloaded, for labelling the row/sheet: repo,
    /// destination format, and (for GGUF) the quant picked.
    struct Target: Sendable, Equatable {
        var repo: String
        var format: ModelFormat
        var quant: String?
    }

    private(set) var target: Target?

    /// A download waiting its turn.
    struct Job: Identifiable, Sendable, Equatable {
        let id = UUID()
        var target: Target
        var files: [HFFile]
        var family: String?
    }

    /// Waiting downloads, in the order they'll start. The running one is `target`.
    private(set) var queue: [Job] = []

    /// How recent downloads ended, newest last (what a caller that queued one reads back).
    struct Outcome: Sendable, Equatable {
        var target: Target
        var installedID: String?
        var failure: String?
    }

    private(set) var recent: [Outcome] = []

    /// Bumped each time a model is installed, so a view can reload even when the next queued download has
    /// already replaced the `.installed` phase.
    private(set) var installedCount = 0

    let downloader: HFDownloader
    /// Swappable rather than fixed at init: relocating the store (step 7)
    /// repoints `AppState.modelStore`, and this has to follow — it writes
    /// the installed row and regenerates presets against it.
    var modelStore: ModelStore

    private var task: Task<Void, Never>?

    init(downloader: HFDownloader = HFDownloader(), modelStore: ModelStore) {
        self.downloader = downloader
        self.modelStore = modelStore
    }

    var isDownloading: Bool {
        if case .downloading = phase {
            return true
        }
        return false
    }

    /// Where a download stands: running, waiting, or neither.
    enum Standing: Equatable {
        case downloading
        case queued
    }

    func standing(of candidate: Target) -> Standing? {
        if isDownloading, target == candidate {
            return .downloading
        }
        return queue.contains { $0.target == candidate } ? .queued : nil
    }

    /// Starts downloading `files` from `repo` into the store, or queues it behind the running download.
    /// Returns the driving `Task` when it starts now (tests and `quail pull` await it; the observed state is
    /// `phase`, not the task's result), `nil` when it was queued, is already running or queued, or has no
    /// files. Resumes transparently: files already partially in `ModelStore.partialDirectory` continue from
    /// their existing bytes (ADR D-015).
    @discardableResult
    func install(
        repo: String,
        files: [HFFile],
        format: ModelFormat,
        quant: String? = nil,
        family: String? = nil
    ) -> Task<Void, Never>? {
        let wanted = Target(repo: repo, format: format, quant: quant)
        guard !files.isEmpty, standing(of: wanted) == nil else { return nil }
        if isDownloading {
            queue.append(Job(target: wanted, files: files, family: family))
            return nil
        }
        return start(Job(target: wanted, files: files, family: family))
    }

    /// Takes a waiting download off the queue.
    func removeQueued(_ id: Job.ID) {
        queue.removeAll { $0.id == id }
    }

    private func startNext() {
        guard !isDownloading, !queue.isEmpty else { return }
        start(queue.removeFirst())
    }

    @discardableResult
    private func start(_ job: Job) -> Task<Void, Never> {
        let (repo, files, format, quant, family) = (
            job.target.repo,
            job.files,
            job.target.format,
            job.target.quant,
            job.family
        )
        target = job.target
        phase = .downloading(
            bytesWritten: 0,
            totalBytes: files.reduce(0) { $0 + $1.sizeBytes },
            currentFile: files[0].localFilename
        )

        let destination = destinationDirectory(for: format, repo: repo)
        let partial = modelStore.partialDirectory

        task = Task {
            var failure: HFDownloadError?
            var finished = false
            let totalBytes = files.reduce(Int64(0)) { $0 + $1.sizeBytes }

            let stream = await downloader.install(
                repo: repo, files: files,
                destinationDirectory: destination, partialDirectory: partial
            )
            for await event in stream {
                switch event {
                case let .progress(p):
                    guard case .downloading = phase else { continue }
                    phase = .downloading(
                        bytesWritten: Self.cumulativeBytesWritten(
                            files: files,
                            current: p.file,
                            writtenForCurrent: p.bytesWritten
                        ),
                        totalBytes: totalBytes,
                        currentFile: p.file.localFilename
                    )
                case .fileCompleted:
                    break
                case .finished:
                    finished = true
                case let .failed(error):
                    failure = error
                }
            }

            // cancel() already reset the phase (and started the next one), and the downloader left the
            // partial bytes in place for a future resume.
            guard !Task.isCancelled else { return }
            if finished {
                recordInstalledRow(
                    repo: repo,
                    format: format,
                    quant: quant,
                    family: family,
                    destination: destination,
                    files: files
                )
            } else if let failure {
                phase = .failed(message: Self.describe(failure))
                remember(Outcome(target: job.target, failure: Self.describe(failure)))
                Logger(subsystem: "com.datoos.quail", category: "Install")
                    .error("install of \(repo, privacy: .public) failed: \(Self.describe(failure), privacy: .public)")
            }
            startNext()
        }
        return task!
    }

    private func remember(_ outcome: Outcome) {
        recent.append(outcome)
        if recent.count > 10 {
            recent.removeFirst(recent.count - 10)
        }
    }

    /// Clears a finished (`.installed`/`.failed`) phase back to `.idle` once
    /// the user has seen it — called when the Add-model sheet opens or its
    /// selection changes. Found by live testing: the terminal phase used to
    /// persist, so the next time the sheet opened it still said
    /// "Installed · Done" with no Download button for anything else.
    func acknowledgeFinished() {
        switch phase {
        case .installed, .failed:
            phase = .idle
            target = nil
        case .idle, .downloading:
            break
        }
    }

    /// Stops the transfer; partial bytes stay under `.partial/` for a
    /// later resume, and the phase resets to idle so the UI returns to a
    /// normal state rather than a stuck "cancelled" one.
    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        target = nil
        startNext()
    }

    /// The per-format store location (docs/ARCHITECTURE.md §6): GGUFs
    /// land flat in `gguf/`; an MLX repo becomes one directory under
    /// `mlx/`, named after the repo with `/` replaced by `--`.
    private func destinationDirectory(for format: ModelFormat, repo: String) -> URL {
        switch format {
        case .gguf:
            modelStore.ggufDirectory
        case .mlxSafetensors:
            modelStore.mlxDirectory.appendingPathComponent(
                repo.replacingOccurrences(of: "/", with: "--"),
                isDirectory: true
            )
        }
    }

    /// Upserts the `StoreCatalog` row for a finished download, then
    /// regenerates `presets.ini` (a new GGUF on disk is a new preset
    /// section — see `ModelStore.regeneratePresets`). Download-only
    /// fields (`sourceRepo`, `sha256`, `quant`) are written here;
    /// size/`contextSize` are left for the disk-driven
    /// `refreshedCatalog` to own, so there's exactly one source for each.
    private func recordInstalledRow(
        repo: String,
        format: ModelFormat,
        quant: String?,
        family: String?,
        destination: URL,
        files: [HFFile]
    ) {
        var catalog = modelStore.loadCatalog()
        let id: String = switch format {
        case .gguf:
            URL(fileURLWithPath: files[0].localFilename).deletingPathExtension().lastPathComponent
        case .mlxSafetensors:
            destination.lastPathComponent
        }
        if let index = catalog.entries.firstIndex(where: { $0.id == id }) {
            catalog.entries[index].sourceRepo = repo
            catalog.entries[index].quant = quant
            catalog.entries[index].family = family
        } else {
            catalog.entries.append(
                InstalledModel(
                    id: id,
                    family: family,
                    format: format,
                    bytes: 0,
                    sourceRepo: repo,
                    quant: quant,
                    addedAt: .init()
                )
            )
        }
        try? modelStore.saveCatalog(catalog)
        // presets.ini describes GGUF router entries only — an MLX
        // install can't change it, and regenerating would rewrite the
        // file (with identical content) for no reason.
        if format == .gguf {
            try? modelStore.regeneratePresets(catalog: catalog)
        }
        phase = .installed(modelID: id)
        installedCount += 1
        remember(Outcome(target: Target(repo: repo, format: format, quant: quant), installedID: id))
        Logger(subsystem: "com.datoos.quail", category: "Install").notice("installed \(id, privacy: .public)")
    }

    /// Per-file progress → cumulative bytes across the whole task: add
    /// what every earlier file (in the download order `files` is given)
    /// already contributed in full. A progress bar that reset at each
    /// file boundary reads as a stalled download on a multi-file MLX
    /// repo's ~11 files.
    static func cumulativeBytesWritten(files: [HFFile], current: HFFile, writtenForCurrent: Int64) -> Int64 {
        let doneBefore = files.prefix { $0.remotePath != current.remotePath }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
        return doneBefore + writtenForCurrent
    }

    /// What every download, listing and `quail pull` says with no connection (ADR D-051).
    nonisolated static let offlineMessage =
        "no internet connection — adding models needs one; installed models work as normal, and a download resumes where it stopped"

    nonisolated static func describe(_ error: HFDownloadError) -> String {
        switch error {
        case .invalidRepoID: "invalid repo id"
        case .gatedRepoRequiresToken: "this repo is gated — add your Hugging Face token in Settings"
        case let .httpStatus(code): "HTTP \(code)"
        case .invalidResponse: "invalid response"
        case let .checksumMismatch(file, _, _): "checksum mismatch for \(file)"
        case let .decoding(detail): "decoding error: \(detail)"
        case .offline: offlineMessage
        }
    }
}
