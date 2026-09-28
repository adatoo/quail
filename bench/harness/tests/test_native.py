import unittest

from harness import native


class NativeParserTests(unittest.TestCase):
    def test_llama_bench_json(self):
        text = '[{"n_prompt": 512, "n_gen": 0, "avg_ts": 812.5, "stddev_ts": 4.1, "model_type": "qwen3 8B"},' \
               ' {"n_prompt": 0, "n_gen": 256, "avg_ts": 44.2, "stddev_ts": 0.3}]'
        rows = native.parse_llama_bench(text)
        self.assertEqual(rows[0], {"prompt_tokens": 512, "generated_tokens": 0, "tokens_per_second": 812.5,
                                   "stddev": 4.1})
        self.assertEqual(rows[1]["generated_tokens"], 256)

    def test_batched_bench_jsonl_among_log_lines(self):
        text = "main: n_kv_max = 65536\n" \
               '{"n_kv_max": 65536, "pp": 512, "tg": 256, "pl": 4, "n_kv": 3072, "t_pp": 2.1, "speed_pp": 975.2,' \
               ' "t_tg": 7.9, "speed_tg": 129.6, "t": 10.0, "speed": 307.2}\n'
        self.assertEqual(native.parse_batched_bench(text), [{
            "sequences": 4, "prompt_tokens": 512, "generated_tokens": 256,
            "prompt_tokens_per_second": 975.2, "generated_tokens_per_second": 129.6}])

    def test_mlx_benchmark_averages(self):
        text = "Running warmup..\nTrial 1:  prompt_tps=900.1, generation_tps=51.0, peak_memory=5.1, total_time=6.0\n" \
               "Averages: prompt_tps=901.500, generation_tps=50.250, peak_memory=5.120\n"
        self.assertEqual(native.parse_mlx_benchmark(text), {
            "prompt_tokens_per_second": 901.5, "generated_tokens_per_second": 50.25, "peak_memory_gb": 5.12})
        with self.assertRaises(ValueError):
            native.parse_mlx_benchmark("Running warmup..\n")


if __name__ == "__main__":
    unittest.main()
