import unittest
from pathlib import Path

from harness import config, speed
from harness.monitor import parse_footprint, parse_power, summarise as summarise_resources


class SpeedTests(unittest.TestCase):
    def test_levels_follow_fairness(self):
        names = [level.name for level in speed.levels(config.fairness())]
        self.assertEqual(names, ["512x256-c1", "512x256-c2", "512x256-c4", "512x256-c8", "4096x128-c1"])

    def test_every_prompt_is_numbered_apart_and_every_level_has_its_own(self):
        fairness = config.fairness()
        budget = config.budget("night")
        model = config.models(Path("/store"))[0]
        paths, spec = speed.prompt_plan(model, 2, budget, fairness, Path("/runs/p"))
        self.assertEqual(spec["tokenizer"], "/store/mlx/mlx-community--Qwen3-8B-4bit")
        firsts = [s["first"] for s in spec["sets"]]
        ends = [s["first"] + s["count"] for s in spec["sets"]]
        self.assertEqual(firsts[1:], ends[:-1])  # one numbering, no overlap
        self.assertEqual(len(paths), 2 * (1 + 2 * len(speed.levels(fairness))))  # warm-up, levels, re-runs
        self.assertIn((0, "512x256-c8-rerun"), paths)
        c8 = next(s for s in spec["sets"] if s["path"].endswith("round-1/512x256-c8.jsonl"))
        self.assertEqual(c8["count"], 8 * budget["requests_per_stream"])
        self.assertEqual(paths[(1, "warmup")], Path("/runs/p/round-2/warmup.jsonl"))

    def test_summary_from_a_guidellm_report(self):
        def stat(mean, p50, p95):
            return {"successful": {"mean": mean, "percentiles": {"p50": p50, "p95": p95}}}

        requests = [
            {"output_tokens": 256, "request_start_time": 100.0, "request_end_time": 110.0},
            {"output_tokens": 256, "request_start_time": 100.5, "request_end_time": 111.0},
            {"output_tokens": 200, "request_start_time": 110.0, "request_end_time": 120.0},
        ]
        report = {"benchmarks": [{
            "metrics": {
                "request_totals": {"successful": 3, "errored": 0, "incomplete": 0},
                "time_to_first_token_ms": stat(300.0, 290.0, 400.0),
                "inter_token_latency_ms": stat(20.0, 19.5, 25.0),
                "time_per_output_token_ms": stat(21.0, 20.5, 26.0),
                "request_latency": stat(10.0, 10.0, 10.5),
                "prompt_token_count": stat(524.0, 524.0, 524.0),
                "output_tokens_per_second": stat(35.0, 36.0, 40.0),
            },
            "requests": {"successful": requests},
        }]}
        summary = speed.summarise(report, speed.Level(512, 256, 2))
        self.assertEqual(summary["successful"], 3)
        self.assertEqual(summary["ttft_ms"], {"mean": 300.0, "p50": 290.0, "p95": 400.0})
        self.assertEqual(summary["itl_ms"]["p50"], 19.5)
        self.assertEqual(summary["short_requests"], 1)
        self.assertEqual(summary["output_tokens_per_second"], round(712 / 20.0, 2))
        self.assertEqual(summary["measured_prompt_tokens"], 524.0)

    def test_request_body_is_neutral_and_turns_thinking_off(self):
        class FakeEngine:
            def request_fields(self, _model):
                return {"reasoning_effort": "none"}

        class FakeServer:
            engine = FakeEngine()
            model = None

        body = speed.request_body(FakeServer(), config.fairness(), 256)
        self.assertEqual(body["max_tokens"], 256)
        self.assertEqual(body["temperature"], 0.0)
        self.assertEqual(body["reasoning_effort"], "none")
        self.assertNotIn("ignore_eos", body)  # only some engines honour it; the prompts hold the length instead


class MonitorTests(unittest.TestCase):
    def test_footprint_table(self):
        text = ("llama-server [41148]: 64-bit    Footprint: 2000 B (16384 bytes per page)\n"
                "      Dirty         Clean   Reclaimable    Regions    Category\n"
                "        ---           ---           ---        ---    ---\n"
                "     1500 B           0 B           0 B       1339    IOAccelerator (graphics)\n"
                "      500 B        9000 B           0 B          3    mapped file\n")
        self.assertEqual(parse_footprint(text), (2000, 11000))
        self.assertIsNone(parse_footprint("nothing"))

    def test_power_lines(self):
        text = "CPU Power: 1058 mW\nGPU Power: 5 mW\nCombined Power (CPU + GPU + ANE): 1063 mW\n"
        self.assertEqual(parse_power(text), [1.063])

    def test_summary(self):
        summary = summarise_resources([(0.0, 10, 50), (1.0, 30, 70), (2.0, 20, 60)], [10.0, 20.0], 2.04)
        self.assertEqual(summary["peak_footprint_bytes"], 30)
        self.assertEqual(summary["median_footprint_bytes"], 20)
        self.assertEqual(summary["peak_resident_bytes"], 70)
        self.assertEqual(summary["mean_watts"], 15.0)
        self.assertEqual(summarise_resources([], [], 1.0)["mean_watts"], None)


if __name__ == "__main__":
    unittest.main()
