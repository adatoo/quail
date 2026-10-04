import Foundation
import Testing
@testable import Quail

@Suite("Tool versions for quail launch")
struct ToolVersionTests {
    @Test("reads the version from what --version prints")
    func parsing() {
        #expect(ToolVersion(parsing: "1.18.34")?.parts == [1, 18, 34])
        #expect(ToolVersion(parsing: "opencode v2.0.19\n")?.parts == [2, 0, 19])
        #expect(ToolVersion(parsing: "2.1.285 (Claude Code)")?.parts == [2, 1, 285])
        #expect(ToolVersion(parsing: "no digits here") == nil)
    }

    @Test("compares by each number, missing ones as zero")
    func comparing() throws {
        let v2 = try #require(ToolVersion(parsing: "2"))
        #expect(try #require(ToolVersion(parsing: "1.18.34")) < v2)
        #expect(try #require(ToolVersion(parsing: "2.0.0")) == v2)
        #expect(try #require(ToolVersion(parsing: "2.0.19")) > v2)
        #expect(try #require(ToolVersion(parsing: "10.0")) > v2)
    }

    @Test("the trailing arguments go on unless the installed version is known and too old")
    func allows() {
        // opencode 1.18.34 on the fresh-Mac check stopped at --standalone; 2.0.19 needs it.
        #expect(!ToolVersion.allows(installed: "1.18.34", minimum: "2"))
        #expect(ToolVersion.allows(installed: "opencode v2.0.19", minimum: "2"))
        #expect(ToolVersion.allows(installed: nil, minimum: "2"))
        #expect(ToolVersion.allows(installed: "weird", minimum: "2"))
        #expect(ToolVersion.allows(installed: "1.0", minimum: nil))
    }
}
