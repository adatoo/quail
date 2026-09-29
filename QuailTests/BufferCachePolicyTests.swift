import Foundation
import Testing
@testable import QuailServerCore

@Suite("MLX buffer-cache policy")
struct BufferCachePolicyTests {
    private let gigabyte = 1 << 30

    /// The steps (1-based) at which `policy` says to clear, over `steps` steps, calling `finished` before the
    /// steps listed in `endings`.
    private func clears(over steps: Int, endings: Set<Int> = [], _ policy: inout BufferCachePolicy) -> [Int] {
        var at: [Int] = []
        for step in 1 ... steps {
            if endings.contains(step) {
                policy.finished()
            }
            if policy.step() {
                at.append(step)
            }
        }
        return at
    }

    @Test("the limit is 2 GB, a sixteenth of a smaller working set, and at least 512 MB")
    func limit() {
        #expect(BufferCachePolicy.limit(workingSet: 55 * gigabyte) == 2 * gigabyte)
        #expect(BufferCachePolicy.limit(workingSet: 16 * gigabyte) == gigabyte)
        #expect(BufferCachePolicy.limit(workingSet: 4 * gigabyte) == 512 << 20)
    }

    @Test("while requests run, the cache is cleared every 512 steps")
    func interval() {
        var policy = BufferCachePolicy()
        #expect(clears(over: 1100, &policy) == [512, 1024])
    }

    @Test("a request's end clears the cache 8 steps later, not at once, and restarts the count")
    func afterFinish() {
        var policy = BufferCachePolicy()
        #expect(clears(over: 620, endings: [100], &policy) == [107, 107 + 512])
    }

    @Test("several endings close together clear once")
    func endingsTogether() {
        var policy = BufferCachePolicy()
        #expect(clears(over: 200, endings: [100, 102, 104], &policy) == [107])
    }

    @Test("an ending just before the interval's clear is covered by it")
    func endingBeforeInterval() {
        var policy = BufferCachePolicy()
        #expect(clears(over: 530, endings: [510], &policy) == [512])
    }
}
