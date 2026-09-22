#!/usr/bin/env python3
"""elm-ask: a local web page where people ask LogicMonitor questions in plain English.

Serves index.html and a streaming /api/ask endpoint. Answers come from Claude
using read-only elm queries (see elm_tools.py). Intended to run on the user's
own machine, bound to localhost (see README.md for the Docker command).
"""

import json
import os
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import anthropic

import agent
import elm_tools

HOST = os.environ.get("ELM_ASK_HOST", "127.0.0.1")
PORT = int(os.environ.get("ELM_ASK_PORT", "8080"))
IDLE_SECONDS = 3600
HERE = Path(__file__).resolve().parent

conversations = {}
lock = threading.Lock()


def get_conversation(conv_id):
    """Return (id, Conversation), creating one and evicting idle ones."""
    with lock:
        cutoff = time.time() - IDLE_SECONDS
        for old_id in [k for k, c in conversations.items() if c.last_used < cutoff]:
            conversations.pop(old_id).session.close()
        if conv_id not in conversations:
            conv_id = uuid.uuid4().hex
            conversations[conv_id] = agent.Conversation()
        return conv_id, conversations[conv_id]


def elm_version():
    """elm's own version, for the credit line ("elm.py, version 1.10.0")."""
    global _ELM_VERSION
    if _ELM_VERSION is None:
        try:
            out = subprocess.run(elm_tools.ELM_CMD + ["--version"], capture_output=True, text=True, timeout=30).stdout
            _ELM_VERSION = out.strip().rsplit(" ", 1)[-1]
        except Exception:
            _ELM_VERSION = ""
    return _ELM_VERSION


_ELM_VERSION = None


def has_claude_key():
    return bool(os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN"))


def health():
    """What is and isn't configured, for the page's setup banner."""
    status = elm_tools.profile_status()
    return {
        "claude_key": has_claude_key(),
        "profile": Path(elm_tools.ELM_CONFIG).name if elm_tools.ELM_CONFIG else status["name"],
        "portal": status["account"],
        "profile_problem": status["problem"],
        "restricted": status["restricted"],
        "allowed": status["allowed"],
        "model": agent.MODEL,
        "elm_version": elm_version(),
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # keep the console quiet; questions may be sensitive

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            data = (HERE / "index.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        elif self.path == "/api/health":
            self.send_json(200, health())
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/api/ask":
            return self.send_json(404, {"error": "not found"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            question = str(body["question"]).strip()[:2000]
            where = {"timezone": str(body.get("timezone") or "")[:64],
                     "utc_offset_minutes": int(body.get("utc_offset_minutes") or 0)}
        except (ValueError, KeyError):
            return self.send_json(400, {"error": "expected JSON {question, conversation_id}"})
        if not question:
            return self.send_json(400, {"error": "empty question"})

        conv_id, conv = get_conversation(body.get("conversation_id"))
        # Newline-delimited JSON events; the connection closes when the answer is done.
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def emit(event):
            self.wfile.write((json.dumps(event, default=str) + "\n").encode())
            self.wfile.flush()

        emit({"type": "conversation", "id": conv_id})
        if not has_claude_key():
            return emit({"type": "error", "text": "No Claude API key is set. Restart the container with -e ANTHROPIC_API_KEY."})
        problem = elm_tools.profile_status()["problem"]
        if problem:
            return emit({"type": "error", "text": problem})
        try:
            agent.ask(anthropic.Anthropic(), conv, question, emit, where)
        except anthropic.AuthenticationError:
            emit({"type": "error", "text": "The Claude API key is missing or invalid."})
        except anthropic.RateLimitError:
            emit({"type": "error", "text": "Claude API rate limit reached. Wait a minute and try again."})
        except anthropic.APIConnectionError:
            emit({"type": "error", "text": "Could not reach the Claude API. Check the network or proxy."})
        except anthropic.APIStatusError as exc:
            emit({"type": "error", "text": f"Claude API error {exc.status_code}: {exc.message}"})
        except BrokenPipeError:
            pass  # the user closed the tab
        except Exception as exc:
            emit({"type": "error", "text": f"Unexpected error: {exc}"})


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"elm-ask listening on http://{HOST}:{PORT}  (model {agent.MODEL})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
