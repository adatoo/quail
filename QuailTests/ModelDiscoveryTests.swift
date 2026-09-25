import Foundation
import Testing
@testable import QuailServerCore

@Suite("Presets and model discovery")
struct ModelDiscoveryTests {
    /// A scratch store: `gguf/`, `mlx/`, torn down by the test.
    private struct Store {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quail-discovery-\(UUID().uuidString)")
        var gguf: URL {
            root.appendingPathComponent("gguf")
        }

        var mlx: URL {
            root.appendingPathComponent("mlx")
        }

        init() throws {
            try FileManager.default.createDirectory(at: gguf, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: mlx, withIntermediateDirectories: true)
        }

        func touch(_ name: String) throws {
            try Data().write(to: gguf.appendingPathComponent(name))
        }

        func mlxModel(_ name: String, withConfig: Bool = true) throws {
            let directory = mlx.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if withConfig {
                try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Presets

    @Test("reads what ModelStore.regeneratePresets writes")
    func parsesGeneratedPresets() {
        let ini = """
        [Qwen3-8B-Q4_K_M]
        model = /store/gguf/Qwen3-8B-Q4_K_M.gguf
        n-gpu-layers = 99
        ctx-size = 8192
        load-on-startup = true

        [Gemma-4B]
        model = /store/gguf/Gemma-4B.gguf
        n-gpu-layers = 99
        ctx-size = 4096
        mmproj = /store/gguf/mmproj-Gemma-4B.gguf
        """
        let presets = PresetsFile.parse(ini)
        #expect(presets.map(\.id) == ["Qwen3-8B-Q4_K_M", "Gemma-4B"])
        #expect(presets[0].int("ctx-size") == 8192)
        #expect(presets[0].bool("load-on-startup") == true)
        #expect(presets[0].string("model") == "/store/gguf/Qwen3-8B-Q4_K_M.gguf")
        #expect(presets[1].bool("load-on-startup") == nil)
        #expect(presets[1].string("mmproj") == "/store/gguf/mmproj-Gemma-4B.gguf")
    }

    @Test("comments, blank lines and a [*] defaults section")
    func commentsAndDefaults() {
        let presets = PresetsFile.parse("""
        ; a comment
        # another
        [*]
        n-gpu-layers = 50
        ctx-size = 2048

        [a]
        ctx-size = 8192
        """)
        #expect(presets.map(\.id) == ["a"])
        #expect(presets[0].int("ctx-size") == 8192)
        #expect(presets[0].int("n-gpu-layers") == 50)
    }

    @Test("a value may contain '=' and surrounding spaces are trimmed")
    func equalsInValue() {
        let presets = PresetsFile.parse("[a]\n  model  =  /path/with=equals.gguf  \n")
        #expect(presets[0].string("model") == "/path/with=equals.gguf")
    }

    @Test("a missing file is no presets, not an error")
    func missingFile() {
        #expect(PresetsFile.load(URL(fileURLWithPath: "/nonexistent/presets.ini")).isEmpty)
    }

    // MARK: Discovery

    @Test("lists .gguf files and MLX directories, skipping projectors and stray folders")
    func scans() throws {
        let store = try Store()
        defer { store.remove() }
        try store.touch("B-Q8.gguf")
        try store.touch("A-Q4.GGUF")
        try store.touch("mmproj-A-Q4.gguf")
        try store.touch("notes.txt")
        try store.mlxModel("owner--repo")
        try store.mlxModel("half-downloaded", withConfig: false)

        let entries = ModelDiscovery.discover(modelsDirectory: store.gguf, mlxDirectory: store.mlx, presets: [])

        #expect(entries.map(\.id) == ["A-Q4", "B-Q8", "owner--repo"])
        #expect(entries.map(\.kind) == [.gguf, .gguf, .mlx])
        // The projector next to a model is attached to it, not listed.
        #expect(entries[0].projector?.lastPathComponent == "mmproj-A-Q4.gguf")
        #expect(entries[1].projector == nil)
    }

    @Test("presets set context, GPU layers and load-on-startup on a scanned model")
    func presetsOverlay() throws {
        let store = try Store()
        defer { store.remove() }
        try store.touch("A.gguf")
        let presets = PresetsFile.parse("[A]\nctx-size = 4096\nn-gpu-layers = 12\nload-on-startup = true\n")

        let entry = try #require(ModelDiscovery.discover(
            modelsDirectory: store.gguf, mlxDirectory: nil, presets: presets
        ).first)

        #expect(entry.contextSize == 4096)
        #expect(entry.gpuLayers == 12)
        #expect(entry.loadOnStartup)
        #expect(entry.path.lastPathComponent == "A.gguf")
    }

    @Test("a preset's parallel (or np) sets a model's slots, and isn't reported as ignored")
    func presetParallel() throws {
        let store = try Store()
        defer { store.remove() }
        try store.touch("A.gguf")
        try store.touch("B.gguf")
        let presets = PresetsFile.parse("[A]\nparallel = 4\n\n[B]\nnp = 2\n")
        let entries = ModelDiscovery.discover(modelsDirectory: store.gguf, mlxDirectory: nil, presets: presets)
        #expect(entries.map(\.parallel) == [4, 2])
        #expect(entries.flatMap(\.ignoredPresetKeys).isEmpty)
    }

    @Test("a preset naming a model outside the folder is listed; one naming nothing is dropped")
    func presetOnly() {
        let presets = PresetsFile.parse("[Elsewhere]\nmodel = /somewhere/else.gguf\n\n[Ghost]\nctx-size = 1\n")
        let entries = ModelDiscovery.discover(modelsDirectory: nil, mlxDirectory: nil, presets: presets)
        #expect(entries.map(\.id) == ["Elsewhere"])
        #expect(entries[0].path.path == "/somewhere/else.gguf")
        #expect(entries[0].kind == .gguf)
    }

    @Test("preset keys the server doesn't implement are reported, not silently dropped")
    func ignoredKeys() throws {
        let store = try Store()
        defer { store.remove() }
        try store.touch("A.gguf")
        let presets = PresetsFile.parse("[A]\nctx-size = 4096\nflash-attn = on\nrope-scale = 2\n")

        let entry = try #require(ModelDiscovery.discover(
            modelsDirectory: store.gguf, mlxDirectory: nil, presets: presets
        ).first)

        #expect(entry.ignoredPresetKeys == ["flash-attn", "rope-scale"])
    }

    @Test("a missing folder is an empty list")
    func missingFolders() {
        let nowhere = URL(fileURLWithPath: "/nonexistent/quail")
        #expect(ModelDiscovery.discover(modelsDirectory: nowhere, mlxDirectory: nowhere, presets: []).isEmpty)
    }
}
