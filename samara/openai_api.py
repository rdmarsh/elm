"""One request to an OpenAI-compatible chat API: Ollama, LM Studio, OpenAI.

agent.py keeps the conversation in Anthropic's message shape, so a question
can start on a local model and go to Claude on Think harder. This turns that
shape into a chat-completions request, and the reply back into it.
"""

import json
import re
import time

import requests


class ModelError(Exception):
    """The model's API could not be reached, or refused the request."""


def models(url, key, timeout=1.5, tries=1):
    """The model ids the API offers, or None if it sends no list it understands.

    Short timeout: the page's health check calls this on every load. LM Studio
    with just-in-time loading lists every downloaded model, loaded or not.
    Raises ModelError when the API cannot be reached, tries times a second apart.
    """
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    for attempt in range(tries):
        try:
            r = requests.get(url.rstrip("/") + "/models", headers=headers, timeout=timeout)
            break
        except requests.RequestException as exc:
            if attempt == tries - 1:
                raise ModelError(f"Could not reach the model API at {url}: {exc}") from exc
            time.sleep(1)
    try:
        return [m["id"] for m in r.json()["data"]] if r.ok else None
    except (ValueError, KeyError, TypeError):
        return None


def block(b, key):
    """A field of a content block: an Anthropic SDK object, or a plain dict."""
    return b.get(key) if isinstance(b, dict) else getattr(b, key, None)


def to_chat(system, messages):
    """Anthropic-shaped messages as chat-completions ones. Thinking blocks are left out."""
    out = [{"role": "system", "content": system}]
    for m in messages:
        content = m["content"]
        if isinstance(content, str):
            out.append({"role": m["role"], "content": content})
            continue
        texts = [block(b, "text") for b in content if block(b, "type") == "text"]
        if m["role"] == "assistant":
            calls = [{"id": block(b, "id"), "type": "function",
                      "function": {"name": block(b, "name"), "arguments": json.dumps(block(b, "input") or {})}}
                     for b in content if block(b, "type") == "tool_use"]
            out.append({"role": "assistant", "content": "\n\n".join(texts) or None, **({"tool_calls": calls} if calls else {})})
            continue
        for b in content:
            if block(b, "type") == "tool_result":
                out.append({"role": "tool", "tool_call_id": block(b, "tool_use_id"), "content": str(block(b, "content"))})
        if texts:
            out.append({"role": "user", "content": "\n\n".join(texts)})
    return out


def from_chat(message, n):
    """A reply's message as Anthropic content blocks; n numbers ids the server left out."""
    # Thinking models (Qwen3, DeepSeek) may leave their reasoning in the text.
    text = re.sub(r"<think>.*?(</think>|$)", "", message.get("content") or "", flags=re.S).strip()
    content = [{"type": "text", "text": text}] if text else []
    for i, call in enumerate(message.get("tool_calls") or []):
        fn = call.get("function") or {}
        args = fn.get("arguments") or "{}"
        try:
            args = json.loads(args) if isinstance(args, str) else args
        except ValueError:
            args = {"_unparsed": args}   # agent.call_tool sends that back to the model as an error
        # Claude takes ids of letters, digits, _ and - only, should it read this history later.
        cid = re.sub(r"[^A-Za-z0-9_-]", "_", call.get("id") or "") or f"call_{n}_{i}"
        name = fn.get("name")
        if name == "run_elm" and isinstance(args, dict) and "recipe" in args and "command" not in args:
            # A recipe asked for through run_elm (gpt-oss-20b, three times on
            # 2026-10-30): run the recipe it plainly meant, not an error.
            name = "recipe"
        content.append({"type": "tool_use", "id": cid, "name": name, "input": args})
    return content


def create(url, key, model, system, tools, messages, n=0):
    """(content blocks, stop reason, usage) in Anthropic's terms, for agent.py."""
    body = {
        "model": model,
        # A thinking model can loop until the read timeout: qwen3.5-4b and qwen3-30b
        # each sent nothing for 600s on the 2026-11-01 eval. A step's reply is
        # normally a tool call or a short answer; this stops a loop in minutes, as
        # an answer cut off at the length limit rather than an error.
        "max_tokens": 8192,
        "messages": to_chat(system, messages),
        "tools": [{"type": "function", "function": {"name": t["name"], "description": t["description"],
                                                    "parameters": t["input_schema"]}} for t in tools],
    }
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    endpoint = url.rstrip("/") + "/chat/completions"
    # Once more after a dropped connection or a 5xx: LM Studio on the mini sent
    # "Internal Server Error" now and then, and each failed a whole ask (2026-11-06).
    for attempt in range(2):
        try:
            r = requests.post(endpoint, json=body, headers=headers, timeout=600)
        except requests.ConnectionError as exc:
            if attempt:
                raise ModelError(f"Could not reach the model at {url}: {exc}") from exc
            time.sleep(3)
            continue
        except requests.RequestException as exc:   # a read timeout: 600s gone, not worth another
            raise ModelError(f"Could not reach the model at {url}: {exc}") from exc
        if r.status_code < 500 or attempt:
            break
        time.sleep(3)
    if not r.ok:
        raise ModelError(f"The model at {url} refused the request (HTTP {r.status_code}): {r.text[:300]}")
    try:
        choice = r.json()["choices"][0]
        usage = r.json().get("usage") or {}
    except (ValueError, KeyError, IndexError) as exc:
        raise ModelError(f"The model at {url} sent back something that is not a chat reply: {r.text[:300]}") from exc
    content = from_chat(choice.get("message") or {}, n)
    reason = choice.get("finish_reason")
    stop = "max_tokens" if reason == "length" else "tool_use" if any(b["type"] == "tool_use" for b in content) else "end_turn"
    return content, stop, {"input": usage.get("prompt_tokens") or 0, "output": usage.get("completion_tokens") or 0}
