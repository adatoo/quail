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

    def test_quails_switches_reach_its_server_but_the_harness_settings_dont(self):
        environment = {"QUAIL_MLX_CLEAR_CACHE": "0", "QUAIL_BENCH_APP": "/Applications/Quail.app", "PATH": "/bin"}
        with mock.patch.dict("os.environ", environment, clear=True):
            self.assertEqual(engines.quail_switches(), {"QUAIL_MLX_CLEAR_CACHE": "0"})

    def test_the_roster_covers_both_lanes(self):
        lanes = {engine.lane for engine in engines.ENGINES.values()}
        self.assertEqual(lanes, {"gguf", "mlx"})
        self.assertEqual([e.name for e in engines.select("omlx,quail-mlx")], ["omlx", "quail-mlx"])
        with self.assertRaises(SystemExit):
            engines.select("nope")

    def test_the_swa_full_variant_only_by_name_with_its_setting(self):
        self.assertNotIn("llama-server-swa-full", [e.name for e in engines.select(None)])
        [variant] = engines.select("llama-server-swa-full")
        gemma = next(m for m in config.models() if m.id == "gemma-4-26b-a4b")
        with mock.patch.object(engines, "quail_app", return_value=Path("/Applications/Quail.app")):
            launch = variant.launch(gemma, Path("/tmp/w"), 1, "k")
        self.assertTrue(launch.files["presets.ini"].endswith("swa-full = true\n"))
        self.assertIn("kv-unified = true", launch.files["presets.ini"])



class DiscardTests(unittest.TestCase):
    def test_caches_go_logs_stay_and_links_are_never_followed(self):
        import tempfile
        from pathlib import Path
        from harness.engines import discard_caches

        with tempfile.TemporaryDirectory() as tmp:
            store = Path(tmp) / "store"
            (store / "model").mkdir(parents=True)
            (store / "model" / "weights.safetensors").write_text("precious")
            work = Path(tmp) / "work"
            (work / "home" / ".cache").mkdir(parents=True)
            (work / "home" / ".cache" / "prefix.bin").write_text("x" * 100)
            (work / "omlx-ssd").mkdir()
            (work / "server.log").write_text("log")
            (work / "launch.json").write_text("{}")
            (work / "models").mkdir()
            (work / "models" / "link").symlink_to(store / "model")
            (work / "direct-link").symlink_to(store / "model")
            discard_caches(work)
            self.assertEqual(sorted(p.name for p in work.iterdir()), ["launch.json", "server.log"])
            self.assertEqual((store / "model" / "weights.safetensors").read_text(), "precious")


if __name__ == "__main__":
    unittest.main()
