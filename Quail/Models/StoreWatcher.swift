import Dispatch
import Foundation

/// Watches the store's `gguf/` and `mlx/` folders so changes made outside
/// Quail — deleting or dropping a model in Finder — show up without a
/// Reload click. A directory's file descriptor reports entries being
/// added, removed or renamed; after one, the watcher waits until the
/// folders' contents stop changing (a multi-GB copy grows for minutes
/// without further directory events), then calls `onSettled` once.
@MainActor
final class StoreWatcher {
    private let directories: [URL]
    private let snapshot: @Sendable () -> [String: Int64]
    private let onSettled: @MainActor () async -> Void
    private let settleInterval: Duration
    private let maxChecks: Int

    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: Task<Void, Never>?

    /// - Parameters:
    ///   - snapshot: names → sizes of the watched contents; "settled" means
    ///     two consecutive snapshots `settleInterval` apart are equal.
    ///   - maxChecks: gives up waiting (and reconciles anyway) after this
    ///     many intervals — 400 × 1.5 s is 10 minutes of a growing copy.
    init(
        directories: [URL],
        snapshot: @escaping @Sendable () -> [String: Int64],
        settleInterval: Duration = .milliseconds(1500),
        maxChecks: Int = 400,
        onSettled: @escaping @MainActor () async -> Void
    ) {
        self.directories = directories
        self.snapshot = snapshot
        self.settleInterval = settleInterval
        self.maxChecks = maxChecks
        self.onSettled = onSettled
    }

    func start() {
        stop()
        for directory in directories {
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.changed() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources = []
        pending?.cancel()
        pending = nil
    }

    /// Restarts the settle wait on every event, so a burst (an MLX folder
    /// of ~11 files) produces one reconcile, not eleven.
    private func changed() {
        pending?.cancel()
        let snapshot = snapshot
        let interval = settleInterval
        let maxChecks = maxChecks
        pending = Task { [weak self] in
            var last = await Task.detached { snapshot() }.value
            for _ in 0 ..< maxChecks {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                let now = await Task.detached { snapshot() }.value
                if now == last {
                    break
                }
                last = now
            }
            guard !Task.isCancelled else { return }
            await self?.onSettled()
        }
    }
}
