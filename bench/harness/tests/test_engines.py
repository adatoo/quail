import unittest
from pathlib import Path
from unittest import mock

from harness import config, engines


class EngineSettingsTests(unittest.TestCase):
    def setUp(self):
        self.model = config.models(Path("/store"))[0]
        self.fairness = config.fairness()

    def test_gguf_presets_share_one_context_pool_across_slots(self):
        text = engines.presets(self.model, "gguf", "m-gguf", self.fairness)
        self.assertIn("[m-gguf]\n", text)
        self.assertIn(f"model = {self.model.gguf}\n", text)
        self.assertIn(f"ctx-size = {8 * 8192}\n", text)
        self.assertIn("parallel = 8\n", text)
        self.assertIn("flash-attn = on\n", text)
        self.assertNotIn("kv-unified", text)  # llama-server's key only
        self.assertIn("kv-unified = true", engines.presets(self.model, "gguf", "m", self.fairness, llama_server=True))

    def test_mlx_presets_give_each_request_its_own_context(self):
        text = engines.presets(self.model, "mlx", "m-mlx", self.fairness)
        self.assertIn("ctx-size = 8192\n", text)
        self.assertNotIn("flash-attn", text)

    def test_ollama_imports_the_same_file_with_neutral_settings(self):
        text = engines.OllamaEngine("gguf").modelfile(self.model, self.fairness)
        self.assertTrue(text.startswith(f"FROM {self.model.gguf}\n"))
        self.assertIn("PARAMETER num_ctx 8192", text)
        self.assertIn("PARAMETER repeat_penalty 1", text)

    def test_rapid_mlx_is_held_to_a_full_precision_cache(self):
        engine = engines.RapidMLXEngine()
        with mock.patch.object(engines.RapidMLXEngine, "locate", return_value=Path("/opt/homebrew/bin/rapid-mlx")):
            launch = engine.launch(self.model, Path("/tmp/w"), 1234, "k")
        argv = launch.argv
        self.assertEqual(argv[argv.index("--kv-cache-turboquant") + 1], "none")
        self.assertEqual(argv[argv.index("--pflash") + 1], "off")
        self.assertEqual(argv[argv.index("--max-num-seqs") + 1], "8")
        self.assertEqual(argv[argv.index("--served-model-name") + 1], self.model.served_id("mlx"))

    def test_debug_builds_are_refused(self):
        with mock.patch.dict("os.environ", {"QUAIL_BENCH_APP": "/tmp/DerivedData/Build/Products/Debug/Quail.app"}), \
                mock.patch.object(Path, "exists", return_value=True):
            with self.assertRaises(engines.EngineUnavailable):
                engines.quail_app()

    def test_keys_never_reach_the_recorded_command(self):
        self.assertEqual(engines.redact("--api-key=abc123", "abc123"), "--api-key=<key>")

    def test_the_roster_covers_both_lanes(self):
        lanes = {engine.lane for engine in engines.ENGINES.values()}
        self.assertEqual(lanes, {"gguf", "mlx"})
        self.assertEqual([e.name for e in engines.select("omlx,quail-mlx")], ["omlx", "quail-mlx"])
        with self.assertRaises(SystemExit):
            engines.select("nope")


if __name__ == "__main__":
    unittest.main()
