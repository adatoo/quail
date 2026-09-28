import unittest
from pathlib import Path

from harness import config


class ConfigTests(unittest.TestCase):
    def test_models_load_with_dotted_ids(self):
        # "qwen3.6-35b-a3b" must stay one id: an unquoted TOML table name would nest it under "qwen3".
        models = {m.id: m for m in config.models(Path("/store"))}
        self.assertIn("qwen3.6-35b-a3b", models)
        model = models["qwen3.6-35b-a3b"]
        self.assertEqual(model.gguf, Path("/store/gguf/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"))
        self.assertEqual(model.path("mlx"), Path("/store/mlx/mlx-community--Qwen3.6-35B-A3B-4bit"))

    def test_every_engine_in_a_lane_serves_the_same_id(self):
        model = config.models(Path("/store"))[0]
        self.assertEqual(model.served_id("gguf"), f"{model.id}-gguf")
        self.assertNotEqual(model.served_id("gguf"), model.served_id("mlx"))

    def test_budgets_and_fairness(self):
        fairness = config.fairness()
        self.assertEqual(fairness["slots"], 8)
        self.assertEqual(fairness["sampling"]["temperature"], 0.0)
        self.assertIn("requests_per_stream", config.budget("quick"))
        with self.assertRaises(SystemExit):
            config.budget("nonsense")


if __name__ == "__main__":
    unittest.main()
