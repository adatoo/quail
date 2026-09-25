import Foundation
import Testing

/// The dependency decision record (Config/third-party.json, ADR D-044) against what the project
/// actually resolves, so a package can't join the build unreviewed, and against the notices file the
/// app ships. `task notices:check` does the same against the packages' licence files in CI.
@Suite("Third-party notices")
struct ThirdPartyNoticesTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private static func json(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func resolvedIdentities() throws -> Set<String> {
        let resolved = try json("Quail.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let pins = try #require(resolved["pins"] as? [[String: Any]])
        return Set(pins.compactMap { $0["identity"] as? String })
    }

    @Test("every resolved Swift package is in the decision record, and every listed one is resolved")
    func recordMatchesResolved() throws {
        let listed = try #require(try Self.json("Config/third-party.json")["packages"] as? [String: Any])
        let resolved = try Self.resolvedIdentities()
        #expect(
            resolved.subtracting(listed.keys).isEmpty,
            "new packages need a decision in Config/third-party.json (ADR D-044): \(resolved.subtracting(listed.keys).sorted())"
        )
        #expect(
            Set(listed.keys).subtracting(resolved).isEmpty,
            "Config/third-party.json lists packages that are no longer resolved: \(Set(listed.keys).subtracting(resolved).sorted())"
        )
    }

    @Test("the notices file names every shipped package")
    func noticesNameThem() throws {
        let listed = try #require(try Self.json("Config/third-party.json")["packages"] as? [String: [String: Any]])
        let notices = try String(
            contentsOf: Self.root.appendingPathComponent("Quail/Resources/THIRD_PARTY_NOTICES.md"), encoding: .utf8
        )
        for (identity, info) in listed {
            let name = try #require(info["name"] as? String)
            let shipped = info["shipped"] as? Bool ?? false
            #expect(notices.contains("## \(name) ") == shipped, "\(identity): shipped \(shipped)")
        }
        #expect(notices.contains("## llama.cpp "))
    }
}
