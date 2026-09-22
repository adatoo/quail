import Foundation
import Testing
@testable import Quail

@Suite("LogStore")
struct LogStoreTests {
    @Test("appending splits multi-line text and preserves order")
    func splitsMultilineText() async {
        let store = LogStore()
        await store.append(stream: .stdout, text: "line one\nline two\nline three")
        let lines = await store.recentLines
        #expect(lines.map(\.text) == ["line one", "line two", "line three"])
        #expect(lines.allSatisfy { $0.stream == .stdout })
    }

    @Test("ring buffer evicts oldest lines beyond capacity")
    func evictsBeyondCapacity() async {
        let store = LogStore(capacity: 3)
        for i in 1 ... 5 {
            await store.append(stream: .stdout, text: "line \(i)")
        }
        let lines = await store.recentLines
        #expect(lines.map(\.text) == ["line 3", "line 4", "line 5"])
    }

    @Test("level is parsed from an llama-server-style prefix")
    func parsesLevel() async {
        let store = LogStore()
        await store.append(
            stream: .stdout,
            text: "0.00.061.964 I srv  llama_server: listening on http://127.0.0.1:8080"
        )
        await store.append(stream: .stderr, text: "0.00.061.953 W srv  llama_server: security: no API key is set")
        let lines = await store.recentLines
        #expect(lines[0].level == "I")
        #expect(lines[1].level == "W")
    }

    @Test("level is nil for lines with no recognisable prefix")
    func levelIsNilWhenUnrecognised() async {
        let store = LogStore()
        await store.append(stream: .stdout, text: "just some plain text")
        let lines = await store.recentLines
        #expect(lines[0].level == nil)
    }

    @Test("writes to a file and rotates once the size threshold is exceeded")
    func rotatesFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("llamaCpp.log")
        // Tiny threshold so a handful of short lines trigger a rotation.
        let store = LogStore(fileURL: fileURL, maxFileBytes: 100, maxFiles: 3)

        for i in 1 ... 20 {
            await store.append(stream: .stdout, text: "line number \(i) with some padding text")
        }

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: fileURL.path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("llamaCpp.1.log").path))
    }

    @Test("clear empties the ring buffer")
    func clearEmptiesBuffer() async {
        let store = LogStore()
        await store.append(stream: .stdout, text: "one line")
        await store.clear()
        let lines = await store.recentLines
        #expect(lines.isEmpty)
    }
}
