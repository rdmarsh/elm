"""One request to an OpenAI-compatible chat API: Ollama, LM Studio, OpenAI.

agent.py keeps the conversation in Anthropic's message shape, so a question
can start on a local model and go to Claude on Think harder. This turns that
shape into a chat-completions request, and the reply back into it.
"""

import json
import re

import requests


class ModelError(Exception):
    """The model's API could not be reached, or refused the request."""


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
        "messages": to_chat(system, messages),
        "tools": [{"type": "function", "function": {"name": t["name"], "description": t["description"],
                                                    "parameters": t["input_schema"]}} for t in tools],
    }
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    endpoint = url.rstrip("/") + "/chat/completions"
    try:
        r = requests.post(endpoint, json=body, headers=headers, timeout=600)
    except requests.RequestException as exc:
        raise ModelError(f"Could not reach the model at {url}: {exc}") from exc
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
