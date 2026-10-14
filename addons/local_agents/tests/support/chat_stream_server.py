import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = payload.get("messages", [])
        if not payload.get("stream") or sum(message.get("role") == "user" for message in messages) != 1:
            self.send_error(400, "Expected streaming and one user prompt")
            return
        case = payload["model"]
        self.send_response(500 if case == "http_error" else 200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        if case == "http_error":
            self.wfile.write(b'{"error":"service failed"}')
            return
        events = [
            {"choices": [{"delta": {"role": "assistant", "content": None}}]},
            {"choices": [{"delta": {"content": "Hello "}}]},
            {"choices": [{"delta": {"content": "🌍"}}]},
            {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "call_1", "type": "function", "function": {"name": "wave", "arguments": '{"x":'}}]}}]},
            {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": "1}"}}]}}]},
            {"choices": [], "usage": {"completion_tokens": 2}},
            {"choices": [{"delta": {}, "finish_reason": "stop"}]},
        ]
        if case == "invalid_tool":
            events[3]["choices"][0]["delta"]["tool_calls"][0]["function"]["arguments"] = 7
        time.sleep(0.25)
        for event in events:
            data = ("data: " + json.dumps(event, ensure_ascii=False) + "\r\n\r\n").encode()
            for offset in range(0, len(data), 7):
                self.wfile.write(data[offset:offset + 7])
                self.wfile.flush()
            time.sleep(0.015)
        if case != "incomplete":
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
