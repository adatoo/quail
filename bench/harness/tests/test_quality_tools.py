import json
import tempfile
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from harness import config, quality, records, shim, tools


class ShimTests(unittest.TestCase):
    def test_rewrite_keeps_the_prompt_and_enforces_the_rules(self):
        body = {"model": "whatever", "messages": [{"role": "user", "content": "hi"}], "temperature": 0.7,
                "seed": 1234, "max_tokens": 512, "stop": ["Q:"], "tools": [{"type": "function"}]}
        sampling = config.fairness()["sampling"]
        out = shim.rewrite(body, "qwen3-8b-gguf", sampling, {"chat_template_kwargs": {"enable_thinking": False}})
        self.assertEqual(out["model"], "qwen3-8b-gguf")
        self.assertEqual((out["temperature"], out["seed"]), (0.0, 42))
        self.assertEqual((out["max_tokens"], out["stop"], out["tools"]), (512, ["Q:"], [{"type": "function"}]))
        self.assertEqual(out["chat_template_kwargs"], {"enable_thinking": False})
        self.assertEqual(body["temperature"], 0.7)  # the tool's own body is left alone

    def test_forwarding_adds_the_key_and_logs_without_the_text(self):
        seen = {}

        class Upstream(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                seen["auth"] = self.headers.get("Authorization")
                seen["body"] = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                data = json.dumps({"choices": [{"finish_reason": "stop", "message": {"content": "ok"}}],
                                   "usage": {"completion_tokens": 1}}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()

        class Engine:
            def request_fields(self, _model):
                return {"reasoning_effort": "none"}

        class Server:
            engine, model, served, key = Engine(), None, "m-gguf", "secret"
            chat_url = f"http://127.0.0.1:{upstream.server_address[1]}/v1/chat/completions"

        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "requests.jsonl"
            proxy = shim.Shim(Server(), config.fairness(), log).start()
            try:
                request = urllib.request.Request(
                    proxy.base + "/v1/chat/completions", method="POST",
                    data=json.dumps({"model": "x", "messages": [{"role": "user", "content": "secret text"}],
                                     "stream": True}).encode(), headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(request) as response:
                    self.assertEqual(json.loads(response.read())["choices"][0]["message"]["content"], "ok")
            finally:
                proxy.stop()
                upstream.shutdown()
                upstream.server_close()
            self.assertEqual(seen["auth"], "Bearer secret")
            self.assertEqual(seen["body"]["model"], "m-gguf")
            self.assertEqual(seen["body"]["reasoning_effort"], "none")
            self.assertNotIn("stream", seen["body"])
            entry = json.loads(log.read_text())
            self.assertEqual((entry["status"], entry["finish_reason"]), (200, "stop"))
            self.assertNotIn("secret text", log.read_text())


    def test_a_deferred_request_is_sent_again_after_the_wait_given(self):
        calls = []

        class Busy(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                calls.append(1)
                busy = len(calls) < 3
                data = json.dumps({"error": {"message": "busy"}} if busy else
                                  {"choices": [{"finish_reason": "stop", "message": {"content": "ok"}}]}).encode()
                self.send_response(503 if busy else 200)
                if busy:
                    self.send_header("Retry-After", "0.05")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        upstream = ThreadingHTTPServer(("127.0.0.1", 0), Busy)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()

        class Engine:
            def request_fields(self, _model):
                return {}

        class Server:
            engine, model, served, key = Engine(), None, "m", None
            chat_url = f"http://127.0.0.1:{upstream.server_address[1]}/v1/chat/completions"

        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "requests.jsonl"
            proxy = shim.Shim(Server(), config.fairness(), log)
            try:
                status, _ = proxy.forward({"messages": []})
            finally:
                upstream.shutdown()
                upstream.server_close()
            self.assertEqual((status, len(calls)), (200, 3))
            self.assertEqual(json.loads(log.read_text())["retries"], 2)

class ResultTests(unittest.TestCase):
    def test_lm_eval_results_for_a_task_and_a_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "mmlu_pro" / "model"
            out.mkdir(parents=True)
            (out / "results_2026-09-28T22-00-00.json").write_text(json.dumps({
                "results": {
                    "gsm8k_cot_llama": {"exact_match,strict-match": 0.9, "exact_match_stderr,strict-match": 0.03},
                    "mmlu_pro": {"exact_match,custom-extract": 0.5, "exact_match_stderr,custom-extract": "N/A"},
                },
                "n-samples": {"gsm8k_cot_llama": {"original": 1319, "effective": 150},
                              "mmlu_pro_law": {"effective": 8}, "mmlu_pro_math": {"effective": 8}},
            }))
            (out / "samples_mmlu_pro_law_2026.jsonl").write_text("")
            gsm = quality.read_results(Path(tmp), "gsm8k_cot_llama", "exact_match,strict-match")
            self.assertEqual((gsm["score"], gsm["stderr"], gsm["items"]), (0.9, 0.03, 150))
            mmlu = quality.read_results(Path(tmp), "mmlu_pro", "exact_match,custom-extract")
            self.assertEqual((mmlu["score"], mmlu["stderr"], mmlu["items"]), (0.5, None, 16))
            self.assertEqual(len(mmlu["samples"]), 1)

    def test_bfcl_summary_line(self):
        text = "Generating…\nBFCL-SUMMARY {\"simple_python\": {\"accuracy\": 0.875, \"correct\": 7, \"total\": 8}}\n"
        self.assertEqual(tools.parse_summary(text)["simple_python"]["correct"], 7)
        with self.assertRaises(ValueError):
            tools.parse_summary("nothing")


class RecordsTests(unittest.TestCase):
    def test_a_combination_is_done_only_when_every_part_is(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "quality.jsonl"
            for record in [
                {"model": "a", "engine": "x", "task": "gsm8k"},
                {"model": "a", "engine": "x", "task": "mmlu"},
                {"model": "a", "engine": "y", "task": "gsm8k"},
                {"model": "a", "engine": "y", "task": "mmlu", "error": "boom"},
                {"model": "b", "engine": "x", "task": "gsm8k", "discarded": True},
            ]:
                records.append(path, record)
            self.assertEqual(records.done(path, ("model", "engine"), need="task", count=2), {("a", "x")})
            self.assertEqual(records.done(path, ("model",)), {("a",)})
            self.assertEqual(records.done(Path(tmp) / "missing.jsonl", ("model",)), set())


if __name__ == "__main__":
    unittest.main()
