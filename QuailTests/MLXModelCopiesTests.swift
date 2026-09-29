import Foundation
import Testing

/// Quail's own copies of mlx-swift-lm model files (ADR D-066) say which release they came from, and that's the
/// release pinned: moving the pin fails this until each copy has been compared with its source in the new release.
@Suite("MLX model copies")
struct MLXModelCopiesTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    @Test("every copied model file names the pinned mlx-swift-lm release")
    func pinned() throws {
        let project = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        let lines = project.components(separatedBy: "\n")
        let package = try #require(lines.firstIndex { $0.contains("url: https://github.com/ml-explore/mlx-swift-lm") })
        let version = try #require(lines[package...].first { $0.contains("exactVersion:") })
            .components(separatedBy: "exactVersion:")[1].trimmingCharacters(in: .whitespaces)
        let folder = Self.root.appendingPathComponent("QuailServer/MLX/Models")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            #expect(
                text.contains("Adapted from mlx-swift-lm \(version),"),
                "\(file) doesn't name mlx-swift-lm \(version)"
            )
        }
    }
}
