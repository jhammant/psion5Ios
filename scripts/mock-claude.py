#!/usr/bin/env python3
"""A stand-in for the Claude Messages API, for testing the app without an API key.

Checks each request the way the real API would care about (headers, the
fallback opt-in, alternating turns, thinking blocks echoed back unchanged) and
streams a reply in the real server-sent-event format. Debug builds use it when
launched with CLAUDE_API_URL=http://localhost:8787/v1/messages.

    python3 scripts/mock-claude.py [port]

Every request and verdict is appended to mock-claude.log in the current directory.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = "mock-claude.log"
signatures = {}  # assistant turn number -> signature we issued


def log(entry):
    with open(LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")


def problems(headers, body):
    found = []
    if not headers.get("x-api-key"):
        found.append("missing x-api-key")
    if headers.get("anthropic-version") != "2023-06-01":
        found.append("anthropic-version should be 2023-06-01")
    if "server-side-fallback-2026-07-01" not in (headers.get("anthropic-beta") or ""):
        found.append("missing server-side-fallback-2026-07-01 beta")
    if body.get("fallbacks") != "default":
        found.append('fallbacks should be "default"')
    if body.get("stream") is not True:
        found.append("stream should be true")
    if not body.get("model"):
        found.append("missing model")
    messages = body.get("messages") or []
    for i, m in enumerate(messages):
        want = "user" if i % 2 == 0 else "assistant"
        if m.get("role") != want:
            found.append(f"message {i} should be {want}")
        if want == "assistant":
            blocks = m.get("content") if isinstance(m.get("content"), list) else []
            thinking = [b for b in blocks if b.get("type") == "thinking"]
            expected = signatures.get(i // 2 + 1)
            if expected and (not thinking or thinking[0].get("signature") != expected):
                found.append(f"assistant turn {i // 2 + 1} lost its thinking block signature")
            if any(b.get("type") == "text" and not b.get("text") for b in blocks):
                found.append(f"assistant turn {i // 2 + 1} has an empty text block")
    if not messages or messages[-1].get("role") != "user":
        found.append("last message should be from the user")
    return found


def reply_text(prompt, turn):
    if "packing" in prompt.lower():
        return ("Packing list for Rome:\n- Passport & tickets\n- Adaptor (UK to EU)\n"
                "- Linen shirts, 3x\nBudget: about £40-50 for food; it's worth it!")
    return f"You asked: {prompt}. This is answer {turn}."


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        headers = {k.lower(): v for k, v in self.headers.items()}
        issues = problems(headers, body)
        messages = body.get("messages") or []
        prompt = messages[-1].get("content") if messages else ""
        turn = len(messages) // 2 + 1
        log({"turn": turn, "prompt": prompt, "problems": issues, "messages": len(messages),
             "effort": (body.get("output_config") or {}).get("effort"), "model": body.get("model")})

        if issues:
            self.send_response(400)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"type": "error", "error": {
                "type": "invalid_request_error", "message": "; ".join(issues)}}).encode())
            return

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()

        def send(event):
            self.wfile.write(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n".encode())
            self.wfile.flush()

        signature = f"sig-turn-{turn}"
        signatures[turn] = signature
        send({"type": "message_start", "message": {"id": f"msg_{turn}", "type": "message", "role": "assistant",
                                                  "model": body["model"], "content": [], "stop_reason": None}})
        send({"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": "", "signature": ""}})
        send({"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": signature}})
        send({"type": "content_block_stop", "index": 0})
        send({"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}})
        text = "Sorry, I started to answer but " if "refuse" in prompt.lower() else reply_text(prompt, turn)
        for i in range(0, len(text), 6):
            send({"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": text[i:i + 6]}})
            time.sleep(0.03)
        send({"type": "content_block_stop", "index": 1})
        stop = "refusal" if "refuse" in prompt.lower() else "end_turn"
        send({"type": "message_delta", "delta": {"stop_reason": stop}, "usage": {"output_tokens": 42}})
        send({"type": "message_stop"})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    print(f"mock Claude API on http://localhost:{port}/v1/messages (log: {LOG})")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
