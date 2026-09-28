import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from harness import httpc

CHUNKS = [
    {"choices": [{"index": 0, "delta": {"role": "assistant"}}]},
    {"choices": [{"index": 0, "delta": {"reasoning_content": "hmm"}}]},
    {"choices": [{"index": 0, "delta": {"content": "Hello"}}]},
    {"choices": [{"index": 0, "delta": {"content": " there"}, "finish_reason": "length"}]},
    # The usage chunk, as include_usage sends it: no choices at all.
    {"choices": [], "usage": {"prompt_tokens": 5, "completion_tokens": 3, "total_tokens": 8}},
]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length))
        if self.path == "/fail":
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"nope"}}')
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        assert body["stream"] is True and body["stream_options"]["include_usage"] is True
        for chunk in CHUNKS:
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")


class StreamTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_stream_is_timed_and_usage_collected(self):
        stream = httpc.stream_chat(self.base + "/chat", {"model": "m", "messages": []})
        self.assertEqual(stream.content, "Hello there")
        self.assertEqual(stream.reasoning, "hmm")
        self.assertEqual(stream.usage["completion_tokens"], 3)
        self.assertEqual(stream.finish_reason, "length")
        # The first token is the first reasoning or content delta, not the role-only first chunk.
        self.assertGreaterEqual(stream.first_token, stream.first_byte)
        self.assertLessEqual(stream.first_token, stream.ended)

    def test_errors_carry_the_servers_message(self):
        with self.assertRaises(httpc.HTTPError) as caught:
            httpc.post(self.base + "/fail", {})
        self.assertEqual(caught.exception.status, 400)
        self.assertIn("nope", caught.exception.body)


if __name__ == "__main__":
    unittest.main()
