import Foundation
import Testing
@testable import QuailServerCore

@Suite("MLX vision")
struct MLXVisionTests {
    private func folder(config: [String: Any], processor: Bool) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mlxv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent("config.json"))
        if processor {
            try Data(#"{"merge_size":2}"#.utf8).write(to: dir.appendingPathComponent("preprocessor_config.json"))
        }
        return dir
    }

    @Test("a Qwen3.5-family folder with its vision half and processor reads images; others don't")
    func supports() throws {
        let vision: [String: Any] = ["model_type": "qwen3_5", "vision_config": ["depth": 1]]
        let yes = try folder(config: vision, processor: true)
        let noProcessor = try folder(config: vision, processor: false)
        let textOnly = try folder(config: ["model_type": "qwen3_5"], processor: true)
        let otherType = try folder(config: ["model_type": "llava", "vision_config": [:]], processor: true)
        defer { [yes, noProcessor, textOnly, otherType].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(MLXVision.supports(directory: yes))
        #expect(!MLXVision.supports(directory: noProcessor))
        #expect(!MLXVision.supports(directory: textOnly))
        #expect(!MLXVision.supports(directory: otherType))
        let gemma = try folder(config: ["model_type": "gemma4", "vision_config": [:]], processor: true)
        let unified = try folder(config: ["model_type": "gemma4_unified", "vision_config": [:]], processor: true)
        defer { [gemma, unified].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(MLXVision.supports(directory: gemma))
        #expect(!MLXVision.supports(directory: unified)) // Gemma 4 12B: no vision half in mlx-swift-lm

        // Discovery marks it, and it reads images as a model.
        let root = yes.deletingLastPathComponent()
        let entries = ModelDiscovery.discover(modelsDirectory: nil, mlxDirectory: root, presets: [])
        let entry = try #require(entries.first { $0.id == yes.lastPathComponent })
        #expect(entry.supportsImages)
        #expect(entries.first { $0.id == textOnly.lastPathComponent }?.supportsImages == false)
    }

    @Test("each image's pad token widens to its share of tokens, in order; a mismatch is refused")
    func expand() throws {
        let pad = 9
        #expect(try MLXVision.expand([1, 9, 2, 9, 3], padID: pad, counts: [3, 1]) == [1, 9, 9, 9, 2, 9, 3])
        #expect(throws: EngineError.self) { try MLXVision.expand([1, 9, 2], padID: pad, counts: [2, 2]) }
        #expect(try MLXVision.expand([1, 2], padID: pad, counts: []) == [1, 2])
        // Gemma 4: each image token becomes begin-of-image, its soft tokens, end-of-image.
        let run = [7, 9, 9, 9, 8]
        #expect(try MLXVision.expand([1, 9, 2], marker: 9, replacements: [run]) == [1, 7, 9, 9, 9, 8, 2])
        #expect(MLXVision.Family(modelType: "gemma4")?.placeholder == "<|image|>")
        #expect(MLXVision.Family(modelType: "qwen3_5_moe") == .qwen35)
    }
}
