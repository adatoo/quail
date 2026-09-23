import Foundation
import Testing
@testable import Quail

/// Leftovers, the preset signature, and the folder watcher — all against a
/// real scratch store on disk.
@Suite("StoreHousekeeping", .timeLimit(.minutes(1)))
struct StoreHousekeepingTests {
    private func scratchStore() throws -> ModelStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-housekeeping-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ModelStore(rootURL: root)
        try store.ensureDirectoriesExist()
        return store
    }

    private func write(_ name: String, in dir: URL, bytes: Int = 4) throws {
        try Data(repeating: 1, count: bytes).write(to: dir.appendingPathComponent(name))
    }

    @Test("leftovers: unlinked and legacy projectors, and partial downloads except the active one")
    func leftovers() throws {
        let store = try scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try write("Vision.gguf", in: store.ggufDirectory)
        try write("mmproj-Vision.gguf", in: store.ggufDirectory) // linked: not a leftover
        try write("mmproj-Deleted.gguf", in: store.ggufDirectory, bytes: 10) // model gone
        try write("mmproj-F16.gguf", in: store.ggufDirectory, bytes: 20) // pre-naming-scheme
        for repo in ["org--Abandoned-GGUF", "org--Active-GGUF"] {
            let dir = store.partialDirectory.appendingPathComponent(repo, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try write("x.gguf.partial", in: dir, bytes: 30)
        }

        let found = store.leftovers(activeRepo: "org/Active-GGUF")

        #expect(found.map(\.title) == ["org/Abandoned-GGUF", "mmproj-F16.gguf", "mmproj-Deleted.gguf"])
        #expect(found.map(\.bytes) == [30, 20, 10])
        #expect(found.first?.kind == .partialDownload)
    }

    @Test("presetSignature records each model and whether it has a projector")
    func presetSignature() throws {
        let store = try scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try write("A.gguf", in: store.ggufDirectory)
        try write("B.gguf", in: store.ggufDirectory)
        try write("mmproj-B.gguf", in: store.ggufDirectory)
        #expect(store.presetSignature() == ["A", "B+mmproj"])
    }

    @Test("StoreWatcher reports a change once the folder settles")
    @MainActor
    func watcherFires() async throws {
        let store = try scratchStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let fired = LockedCount()
        let watcher = StoreWatcher(
            directories: [store.ggufDirectory],
            snapshot: { store.contentSnapshot() },
            settleInterval: .milliseconds(100),
            onSettled: { fired.increment() }
        )
        watcher.start()
        defer { watcher.stop() }

        try write("New.gguf", in: store.ggufDirectory)
        try write("Another.gguf", in: store.ggufDirectory)

        for _ in 0 ..< 50 where fired.value == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(fired.value == 1) // one burst, one reconcile
    }
}
