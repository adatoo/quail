import os
import unittest
from pathlib import Path
from unittest import mock

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

    def test_catalog_models_file(self):
        # The catalog's own scores (ADR D-070): every chat model in catalog.json, one lane each.
        with mock.patch.dict(os.environ, {"QUAIL_BENCH_MODELS": "catalog-models"}):
            models = {m.id: m for m in config.models(Path("/store"))}
        self.assertGreaterEqual(len(models), 28)
        self.assertNotIn("nomic-embed-v1.5", models)
        self.assertNotIn("muse-glimmer-30b", models, "it always thinks, so it isn't on this scale")
        fairness = config.fairness()
        self.assertEqual(models["gemma-4-31b"].slot_count(fairness), 4)
        self.assertEqual(models["qwen3-8b"].slot_count(fairness), fairness["slots"])
        self.assertEqual(models["qwen3.8-27b"].gguf, Path("/store/gguf/Qwen3.8-27B-UD-Q4_K_M.gguf"))
        self.assertFalse(models["qwen3.8-27b"].mlx.exists(), "a lane a model isn't in never exists")
        self.assertFalse(models["bonsai-2-27b"].gguf.exists())
        self.assertEqual(models["gpt-oss-20b"].request, {"reasoning_effort": "low"})
        self.assertIsNone(models["qwen3-8b"].request)

    def test_a_model_can_carry_its_own_request_fields(self):
        from harness import engines
        with mock.patch.dict(os.environ, {"QUAIL_BENCH_MODELS": "catalog-models"}):
            models = {m.id: m for m in config.models(Path("/store"))}
        quail = engines.QuailEngine("gguf")
        self.assertEqual(quail.request_fields(models["gpt-oss-20b"]), {"reasoning_effort": "low"})
        self.assertEqual(quail.request_fields(models["qwen3-8b"]),
                         {"chat_template_kwargs": {"enable_thinking": False}})

    def test_budgets_and_fairness(self):
        fairness = config.fairness()
        self.assertEqual(fairness["slots"], 8)
        self.assertEqual(fairness["sampling"]["temperature"], 0.0)
        self.assertIn("requests_per_stream", config.budget("quick"))
        with self.assertRaises(SystemExit):
            config.budget("nonsense")


if __name__ == "__main__":
    unittest.main()
