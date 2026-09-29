import tempfile
import unittest
import xml.dom.minidom
from pathlib import Path

from harness import config, report, stats, svg

MODEL = config.Model(id="m", name="Model M", catalog="", gguf=Path("m.gguf"), mlx=Path("m-mlx"), family="qwen3")


class StatsTests(unittest.TestCase):
    def test_wilson(self):
        low, high = stats.wilson(8, 10)
        self.assertAlmostEqual(low, 0.4902, places=3)
        self.assertAlmostEqual(high, 0.9433, places=3)
        self.assertEqual(stats.wilson(0, 0), (0.0, 1.0))

    def test_mcnemar_uses_only_the_disagreements(self):
        a = {i: True for i in range(20)}
        b = {i: i >= 8 for i in range(20)}  # b misses the first 8
        only_a, only_b, p = stats.mcnemar(a, b)
        self.assertEqual((only_a, only_b), (8, 0))
        self.assertAlmostEqual(p, 2 / 2**8)
        self.assertEqual(stats.mcnemar(a, a)[2], 1.0)

    def test_a_speed_gap_must_beat_five_percent_and_the_spread(self):
        self.assertAlmostEqual(stats.meaningful_speed_gap([100, 101], [110, 111], True), 0.1, places=2)
        self.assertIsNone(stats.meaningful_speed_gap([100, 101], [104, 104], True))  # under 5%
        self.assertIsNone(stats.meaningful_speed_gap([90, 110], [115, 116], True))  # within the rounds' spread
        self.assertAlmostEqual(stats.meaningful_speed_gap([200], [150], False), 0.25)  # lower is better


class ChartTests(unittest.TestCase):
    def test_charts_are_well_formed_svg(self):
        line = svg.lines("Throughput", [1, 2, 4, 8], {"Quail": [40, 70, 110, None], "oMLX": [38, 60, 90, 120]},
                         "tokens/s")
        bar = svg.bars("Accuracy", [("Quail", 0.9, 0.85, 0.94), ("Ollama", 0.88, None, None)], "", maximum=1.0)
        for text in (line, bar):
            xml.dom.minidom.parseString(text)
            self.assertIn("prefers-color-scheme: dark", text)


class ReportTests(unittest.TestCase):
    def test_levels_sort_by_size_then_concurrency(self):
        rows = [{"level": name} for name in ("4096x128-c1", "512x256-c8", "512x256-c1", "512x256-c2")]
        self.assertEqual(report.levels_of(rows), ["512x256-c1", "512x256-c2", "512x256-c8", "4096x128-c1"])

    def test_paths_recorded_on_the_other_mac_are_found_in_the_copy(self):
        from pathlib import Path
        run = Path("/here/bench/runs/20260929-010000-compare")
        found = report.local("/Users/x/code/quail/bench/runs/20260929-010000-compare/tools/a/score.json", run)
        self.assertEqual(found, run / "tools" / "a" / "score.json")

    def test_quail_comes_first(self):
        self.assertEqual(report.ordered({"omlx", "rapid-mlx", "quail-mlx"}, "mlx"), ["quail-mlx", "omlx", "rapid-mlx"])

    def test_speed_losses_are_records(self):
        def row(engine, rnd, tps, itl):
            return {"model": "m", "engine": engine, "level": "512x256-c1", "round": rnd,
                    "output_tokens_per_second": tps, "ttft_ms": {"p50": 500}, "itl_ms": {"p50": itl}}
        rows = [row("quail-mlx", 1, 40, 20), row("quail-mlx", 2, 41, 20),
                row("rapid-mlx", 1, 50, 16), row("rapid-mlx", 2, 51, 16), row("omlx", 1, 41, 20), row("omlx", 2, 40, 20)]
        losses = report.speed_losses(rows, MODEL)
        self.assertEqual({(x["engine"], x["metric"]) for x in losses}, {("rapid-mlx", "tps"), ("rapid-mlx", "itl")})
        self.assertEqual({x["lane"] for x in losses}, {"mlx"})

    def test_losses_are_one_table_per_model_and_lane(self):
        losses = [
            {"model": "m", "model_name": "Model M", "lane": "mlx", "level": "4096x128-c1", "metric": "tps",
             "engine": "omlx", "gap": 0.28},
            {"model": "m", "model_name": "Model M", "lane": "mlx", "level": "4096x128-c1", "metric": "tps",
             "engine": "rapid-mlx", "gap": 0.5},
            {"model": "m", "model_name": "Model M", "lane": "mlx", "level": "512x256-c8", "metric": "ttft",
             "engine": "omlx", "gap": 0.92},
            {"model": "m", "model_name": "Model M", "lane": "gguf", "level": "4096x128-c1", "metric": "ttft",
             "engine": "llama-server", "gap": 0.21},
        ]
        text = "\n".join(report.losses_lines(losses, ["Model M, MLX, GSM8K: oMLX got 13 items right…"]))
        self.assertEqual(text.count("#### Model M, MLX lane"), 1)
        self.assertIn("#### Model M, GGUF lane", text)
        # Levels in size order, the engine furthest ahead first, a dash where no engine is ahead.
        self.assertLess(text.index("| 512x256-c8 |"), text.index("| 4096x128-c1 | Rapid-MLX 50%, oMLX 28% | — |"))
        self.assertIn("| 512x256-c8 | — | oMLX 92% |", text)
        self.assertIn("- Model M, MLX, GSM8K", text)
        self.assertEqual(report.losses_lines([], []), ["Nowhere by a margin D-063 lets this report claim.", ""])

    def test_the_engines_logs_add_caveats(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            log = run / "round-1" / "servers" / "ollama-gguf--m" / "server.log"
            log.parent.mkdir(parents=True)
            log.write_text('level=WARN msg="model architecture does not currently support parallel requests"\n')
            (run / "round-2" / "servers" / "ollama-gguf--m").mkdir(parents=True)
            (run / "round-2" / "servers" / "ollama-gguf--m" / "server.log").write_text(log.read_text())
            found = report.caveats({}, [MODEL], run)
        self.assertEqual(len(found), 1)
        self.assertIn("served one request at a time", found[0])
        self.assertTrue(found[0].endswith("— Model M."))

    def test_notes_are_read_from_toml(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "notes.toml"
            path.write_text('found = """\n**Level on GGUF.**\n"""\ncaveats = ["A thing the run couldn\'t see."]\n')
            notes = report.read_notes(path)
        self.assertEqual(notes["found"].strip(), "**Level on GGUF.**")
        self.assertEqual(notes["caveats"], ["A thing the run couldn't see."])
        self.assertEqual(report.read_notes(None), {})

    def test_reproducing_names_the_folders_the_version_and_the_budget(self):
        fairness = {"budgets": {"night": {"speed_rounds": 2, "requests_per_stream": 6, "gsm8k_limit": 150,
                                          "mmlu_pro_limit": 8, "bfcl_per_category": 0}}}
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp) / "20260929-022439-compare"
            run.mkdir()
            (run / "repo.txt").write_text("ac5e75890a013005e7d6ce208dbabce1d6a53dc5\n")
            text = "\n".join(report.reproduce_lines(run, Path(tmp) / "20260929-021845-smoke", "night", fairness,
                                                    "0.58.1"))
        self.assertIn("`20260929-022439-compare` with the smoke test `20260929-021845-smoke`", text)
        self.assertIn("commit `ac5e758`, with Quail 0.58.1.", text)
        self.assertIn("task bench:compare BUDGET=night", text)
        self.assertIn("2 speed rounds of 6 requests per stream", text)
        self.assertIn("the first 150 GSM8K items, the first 8 MMLU-Pro items per subject and every BFCL case.", text)


if __name__ == "__main__":
    unittest.main()
