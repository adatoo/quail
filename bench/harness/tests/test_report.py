import unittest
import xml.dom.minidom

from harness import report, stats, svg


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


if __name__ == "__main__":
    unittest.main()
