import Foundation
import Testing

/// Quail's own copies of mlx-swift-lm model files (ADR D-066) name the mlx-swift-lm pinned (a release, or a commit):
/// moving the pin fails this until each copy has been compared with its source at the new pin.
@Suite("MLX model copies")
struct MLXModelCopiesTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    @Test("every copied model file names the pinned mlx-swift-lm release")
    func pinned() throws {
        let project = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        let lines = project.components(separatedBy: "\n")
        let package = try #require(lines.firstIndex { $0.contains("url: https://github.com/ml-explore/mlx-swift-lm") })
        // A release (`exactVersion: 3.31.4`), or a commit (`revision:`, named by its first 9 characters).
        let pin = try #require(lines[package...].first { $0.contains("exactVersion:") || $0.contains("revision:") })
        let value = pin.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)
        let version = pin.contains("revision:") ? String(value.prefix(9)) : value
        let folder = Self.root.appendingPathComponent("QuailServer/MLX/Models")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            #expect(
                text.contains("mlx-swift-lm \(version),"),
                "\(file) doesn't name mlx-swift-lm \(version)"
            )
        }
    }
}
