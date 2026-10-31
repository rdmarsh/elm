#!/usr/bin/env python3
"""Samara: a local web page where people ask LogicMonitor questions in plain English.

Serves index.html and a streaming /api/ask endpoint. Answers come from Claude,
or a model at an OpenAI-compatible API (see agent.py), using read-only elm queries (see elm_tools.py). Intended to run on the user's
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
import openai_api

HOST = elm_tools.setting("HOST", "127.0.0.1")
PORT = int(elm_tools.setting("PORT", "8080"))
IDLE_SECONDS = 3600
# The question log, when the person running Samara turns it on (run.sh with
# SAMARA_LOG=1 mounts a folder here). Each person still opts in on the page:
# nothing is written for a question unless they ticked the box or rated it.
LOG_DIR = os.environ.get("SAMARA_LOG_DIR")
LOG_LOCK = threading.Lock()
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


def default_model_id():
    """The model the first step answers with today, or None without a working key."""
    if agent.is_claude(agent.MODELS[0]) and not agent.has_claude_key():
        return None
    try:
        return agent.pick_model(anthropic.Anthropic())[0]
    except Exception:
        return None


def health():
    """What is and isn't configured, for the page's setup banner."""
    status = elm_tools.profile_status()
    return {
        "claude_key": agent.has_claude_key(),
        "needs_claude": any(agent.is_claude(m) for m in agent.MODELS),
        "model_problem": agent.config_problem(),
        # Who the first step sends questions and portal data to; None for this machine.
        "off": agent.where(agent.MODELS[0]),
        "profile": Path(elm_tools.ELM_CONFIG).name if elm_tools.ELM_CONFIG else status["name"],
        "portal": status["account"],
        "profile_problem": status["problem"],
        "restricted": status["restricted"],
        "allowed": status["allowed"],
        "model": agent.MODEL,
        "effort": (agent.EFFORT or "default") if agent.is_claude(agent.MODELS[0]) else None,   # Claude only
        "model_id": default_model_id(),
        "elm_version": elm_version(),
        "build": os.environ.get("SAMARA_BUILD") or None,   # git describe at docker build
        "log": bool(LOG_DIR),   # whether the page may offer to save questions
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
        if self.path == "/api/feedback":
            return self.feedback()
        if self.path != "/api/ask":
            return self.send_json(404, {"error": "not found"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            question = str(body.get("question") or "").strip()[:2000]
            harder = max(0, min(int(body.get("harder") or 0), 9))   # agent.pick_model stops at the top step
            detail = bool(body.get("detail"))
            where = {"timezone": str(body.get("timezone") or "")[:64],
                     "utc_offset_minutes": int(body.get("utc_offset_minutes") or 0)}
        except (ValueError, KeyError):
            return self.send_json(400, {"error": "expected JSON {question, conversation_id}"})
        if not question and not harder and not detail:
            return self.send_json(400, {"error": "empty question"})

        conv_id, conv = get_conversation(body.get("conversation_id"))
        # Newline-delimited JSON events; the connection closes when the answer is done.
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        said = {}   # the answer's source, for the log

        def emit(event):
            if event.get("type") in ("answer", "error", "model"):
                said[event["type"]] = event
            self.wfile.write((json.dumps(event, default=str) + "\n").encode())
            self.wfile.flush()

        emit({"type": "conversation", "id": conv_id})
        problem = agent.config_problem() or elm_tools.profile_status()["problem"]
        if problem:
            return emit({"type": "error", "text": problem})
        try:
            agent.ask(anthropic.Anthropic(), conv, question, emit, where, harder, detail)
        except anthropic.AuthenticationError:
            emit({"type": "error", "text": "The Claude API key is missing or invalid. Stop Samara, run run.sh --set-key, and start it again."})
        except anthropic.RateLimitError:
            emit({"type": "error", "text": "Claude API rate limit reached. Wait a minute and try again."})
        except anthropic.APIConnectionError:
            emit({"type": "error", "text": "Could not reach the Claude API. Check the network or proxy."})
        except anthropic.APIStatusError as exc:
            emit({"type": "error", "text": f"Claude API error {exc.status_code}: {exc.message}"})
        except (openai_api.ModelError, agent.NoClaudeKey) as exc:
            emit({"type": "error", "text": str(exc)})
        except (BrokenPipeError, ConnectionResetError, agent.Stopped):
            pass  # Stop pressed or the tab closed; agent.ask has dropped the half-finished turn
        except Exception as exc:
            emit({"type": "error", "text": f"Unexpected error: {exc}"})
        if body.get("save"):
            answer = said.get("answer", {})
            log({"kind": "question", "conversation": conv_id,
                 "question": question or ("(Dig deeper)" if detail else "(asked again)"), "harder": harder,
                 "model": said.get("model", {}).get("id"), "source": answer.get("source"),
                 "unfound": answer.get("unfound"), "error": said.get("error", {}).get("text")})

    def feedback(self):
        """A reader's rating of an answer, and the conversation if they shared it.

        right (thumbs up); or after a thumbs down, wrong (wrong facts), missed (not
        what was asked) or partly (right, but incomplete): pass, fail and partial,
        as the eval grades them.
        """
        if not LOG_DIR:
            return self.send_json(404, {"error": "the question log is off"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            rating = str(body.get("rating"))
            if rating not in ("right", "wrong", "missed", "partly"):
                raise ValueError(rating)
        except (ValueError, KeyError):
            return self.send_json(400, {"error": "expected JSON {question, rating: right|wrong|missed|partly}"})
        log({"kind": "rating", "conversation": str(body.get("conversation_id") or "")[:64],
             "question": str(body.get("question") or "")[:2000], "rating": rating,
             "source": str(body.get("source") or "")[:16] or None,
             "transcript": str(body.get("transcript") or "")[:200000] or None})
        self.send_json(200, {"ok": True})


def log(entry):
    """Add a line to the question log, if it is on. Mode 600: questions name customers."""
    if not LOG_DIR:
        return
    line = json.dumps({"time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "build": os.environ.get("SAMARA_BUILD"),
                       "portal": elm_tools.portal(), **entry}, default=str)
    path = Path(LOG_DIR) / "questions.jsonl"
    with LOG_LOCK:
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a") as f:
            f.write(line + "\n")


# Where the dockerfile puts the CAs from samara/certs/.
EXTRA_CAS = Path("/usr/local/share/ca-certificates/extra")


def relax_x509_strict():
    """SAMARA_RELAX_X509_STRICT=1: let elm accept a CA that fails Python 3.13's strict
    X.509 checks, but only when one was supplied in samara/certs/. Off by default.

    A TLS-inspecting proxy's root without Basic Constraints marked critical made
    every query fail inside the container (2026-10-30). elm then clears
    VERIFY_X509_STRICT and nothing else: the chain and hostname are still checked.
    """
    if os.environ.get("SAMARA_RELAX_X509_STRICT", "").lower() not in ("1", "true", "yes"):
        return
    if not any(EXTRA_CAS.glob("*.crt")):
        print("Warning: SAMARA_RELAX_X509_STRICT ignored: no CA in samara/certs/, so TLS stays strict.", flush=True)
        return
    os.environ["ELM_RELAX_X509_STRICT"] = "1"
    print("Warning: SAMARA_RELAX_X509_STRICT is on: TLS skips Python 3.13's strict X.509 rules "
          "(for samara/certs/), still checking the chain and hostname.", flush=True)


def main():
    relax_x509_strict()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Samara listening on http://{HOST}:{PORT}  (model {agent.MODEL})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
