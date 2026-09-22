import Foundation
import Testing
@testable import Quail

@Suite("ModelAddPlan")
struct ModelAddPlanTests {
    private static func hfFile(_ path: String, size: Int64 = 10) -> HFFile {
        HFFile(remotePath: path, sizeBytes: size, sha256: nil)
    }

    // MARK: - format guessing

    @Test("a listing with a main GGUF is GGUF even alongside companions")
    func ggufDetected() {
        let listing = HFRepo(id: "r", files: [Self.hfFile("model-Q4_K_M.gguf"), Self.hfFile("mmproj-model-F16.gguf")])
        #expect(ModelAddPlan.format(guessing: listing) == .gguf)
    }

    @Test("config.json + safetensors is MLX")
    func mlxDetected() {
        let listing = HFRepo(id: "r", files: [Self.hfFile("config.json"), Self.hfFile("model.safetensors")])
        #expect(ModelAddPlan.format(guessing: listing) == .mlxSafetensors)
    }

    @Test("a repo that's neither gets no guess")
    func neitherFormat() {
        let listing = HFRepo(id: "r", files: [Self.hfFile("README.md"), Self.hfFile("vocab.json")])
        #expect(ModelAddPlan.format(guessing: listing) == nil)
    }

    @Test("a config.json with no safetensors is not MLX")
    func configAloneIsNotMLX() {
        let listing = HFRepo(id: "r", files: [Self.hfFile("config.json"), Self.hfFile("README.md")])
        #expect(ModelAddPlan.format(guessing: listing) == nil)
    }

    // MARK: - quant extraction & matching

    @Test("quants come from main GGUF filenames' trailing token")
    func quantExtraction() {
        let listing = HFRepo(id: "r", files: [
            Self.hfFile("Qwen3-0.6B-Q8_0.gguf"),
            Self.hfFile("Qwen3-0.6B-Q4_K_M.gguf"),
            Self.hfFile("mmproj-Qwen3-0.6B-F16.gguf"),
            Self.hfFile("README.md"),
        ])
        #expect(ModelAddPlan.quants(in: listing) == ["Q4_K_M", "Q8_0"])
    }

    @Test("sharded files collapse onto their base quant")
    func shardsCollapse() {
        let listing = HFRepo(id: "r", files: [
            Self.hfFile("Big-BF16-00001-of-00002.gguf"),
            Self.hfFile("Big-BF16-00002-of-00002.gguf"),
        ])
        #expect(ModelAddPlan.quants(in: listing) == ["BF16"])
    }

    @Test("matchesQuant is case-insensitive (catalog 'mxfp4' vs disk 'MXFP4')")
    func matchesQuantIsCaseInsensitive() {
        #expect(ModelAddPlan.matchesQuant(stem: "gpt-oss-20b-MXFP4", quant: "mxfp4"))
    }

    @Test("matchesQuant refuses suffix matches without a separator (IQ8_0 must not answer to Q8_0)")
    func matchesQuantNeedsBoundary() {
        #expect(!ModelAddPlan.matchesQuant(stem: "Meta-Llama-3.1-8B-Instruct-IQ8_0", quant: "Q8_0"))
        #expect(ModelAddPlan.matchesQuant(stem: "Meta-Llama-3.1-8B-Instruct-Q8_0", quant: "Q8_0"))
        // The dot separator real nomic filenames use:
        #expect(ModelAddPlan.matchesQuant(stem: "nomic-embed-text-v1.5.f16", quant: "f16"))
    }

    // MARK: - file resolution

    @Test("ggufFiles picks the right quant out of a realistic multi-quant listing")
    func resolvesRealisticQuant() {
        // Shape verified live from bartowski/Meta-Llama-3.1-8B-Instruct-GGUF
        // (PR 16's catalog verification): Q4_K_M, Q5_K_M, Q6_K, Q6_K_L,
        // Q8_0, plus IQ* quants that must NOT be pulled in by a Q8_0 pick.
        let listing = HFRepo(id: "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF", files: [
            Self.hfFile("Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf", size: 4),
            Self.hfFile("Meta-Llama-3.1-8B-Instruct-Q8_0.gguf", size: 8),
            Self.hfFile("Meta-Llama-3.1-8B-Instruct-IQ8_0.gguf", size: 81),
            Self.hfFile("Meta-Llama-3.1-8B-Instruct-Q6_K_L.gguf", size: 6),
            Self.hfFile("README.md"),
        ])
        let picked = ModelAddPlan.ggufFiles(for: listing, quant: "Q8_0", mmproj: nil)
        #expect(picked.map(\.localFilename) == ["Meta-Llama-3.1-8B-Instruct-Q8_0.gguf"])
    }

    @Test("ggufFiles includes every shard of a split pick, first part sorted first")
    func resolvesShards() {
        let listing = HFRepo(id: "r", files: [
            Self.hfFile("Big-Q4_K_M-00002-of-00002.gguf", size: 2),
            Self.hfFile("Big-Q4_K_M-00001-of-00002.gguf", size: 1),
        ])
        let picked = ModelAddPlan.ggufFiles(for: listing, quant: "Q4_K_M", mmproj: nil)
        #expect(picked.map(\.localFilename) == [
            "Big-Q4_K_M-00001-of-00002.gguf",
            "Big-Q4_K_M-00002-of-00002.gguf",
        ])
    }

    @Test("a named mmproj companion joins the pick only when the repo has it")
    func resolvesMmproj() {
        let listing = HFRepo(id: "r", files: [
            Self.hfFile("gemma-3-12b-it-Q4_K_M.gguf"),
            Self.hfFile("mmproj-F16.gguf"),
        ])
        #expect(ModelAddPlan.ggufFiles(for: listing, quant: "Q4_K_M", mmproj: "mmproj-F16.gguf").count == 2)
        #expect(ModelAddPlan.ggufFiles(for: listing, quant: "Q4_K_M", mmproj: "mmproj-Q8_0.gguf").count == 1)
    }

    @Test("mmproj companions are never main files")
    func mmprojNeverMain() {
        let listing = HFRepo(id: "r", files: [Self.hfFile("mmproj-model-F16.gguf")])
        #expect(ModelAddPlan.quants(in: listing).isEmpty)
        #expect(ModelAddPlan.ggufFiles(for: listing, quant: "F16", mmproj: nil).isEmpty)
    }

    @Test("mlxFiles drops dotfiles and sorts deterministically")
    func mlxFileSelection() {
        let listing = HFRepo(id: "r", files: [
            Self.hfFile("tokenizer.json"), Self.hfFile(".gitattributes"), Self.hfFile("config.json"),
            Self.hfFile("model.safetensors"),
        ])
        #expect(ModelAddPlan.mlxFiles(for: listing).map(\.localFilename) == [
            "config.json", "model.safetensors", "tokenizer.json",
        ])
    }
}
