"""The question-answering loop: Claude plans, calls the read-only elm tools, answers."""

import json
import os
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import anthropic

import elm_tools

# The cheapest current model by default: these are lookup questions, not hard
# reasoning, and every question costs money. ELM_ASK_MODEL picks another; the
# question set in todo.md is how to tell whether a dearer one answers better.
MODEL = os.environ.get("ELM_ASK_MODEL", "claude-haiku-4-5")
EFFORT = os.environ.get("ELM_ASK_EFFORT")          # low|medium|high|xhigh|max; unset = API default
MAX_STEPS = int(os.environ.get("ELM_ASK_MAX_STEPS", "25"))
HERE = Path(__file__).resolve().parent


def load_system_prompt():
    """Instructions plus the elm knowledge base, as one cacheable block."""
    instructions = (HERE / "system_prompt.md").read_text()
    knowledge_path = Path(os.environ.get("ELM_KNOWLEDGE", elm_tools.ELM_HOME / "elm-knowledge.md"))
    knowledge = knowledge_path.read_text() if knowledge_path.exists() else "(no knowledge file found)"
    return f"{instructions}\n\n<elm_knowledge>\n{knowledge}\n</elm_knowledge>"


SYSTEM = [{"type": "text", "text": load_system_prompt(), "cache_control": {"type": "ephemeral"}}]


_effort_unsupported = False


def create(client, messages, emit):
    """One request to Claude, dropping effort if this model will not take it.

    Not every model accepts output_config.effort (Haiku 4.5 rejects it with a
    400). Rather than make the person match model to setting, ask once, and on
    that refusal drop it and carry on -- for the rest of this run, so it costs
    one wasted request, not one per step.
    """
    global _effort_unsupported
    extra = {} if (not EFFORT or _effort_unsupported) else {"output_config": {"effort": EFFORT}}
    try:
        return client.beta.messages.create(
            model=MODEL,
            max_tokens=16000,
            system=SYSTEM,
            tools=elm_tools.TOOLS,
            messages=messages,
            cache_control={"type": "ephemeral"},
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
            **extra,
        )
    except anthropic.BadRequestError as exc:
        if not extra or "effort" not in str(exc):
            raise
        _effort_unsupported = True
        emit({"type": "status", "text": f"{MODEL} does not take an effort setting; continuing without it."})
        return create(client, messages, emit)


class Conversation:
    """One browser tab's chat: message history plus the datasets it fetched."""

    def __init__(self):
        self.messages = []
        self.session = elm_tools.Session()
        self.last_used = time.time()


def call_tool(conv, block):
    """Run one tool_use block; return (tool_result, ui_event_or_None)."""
    handler = elm_tools.HANDLERS.get(block.name)
    try:
        if handler is None:
            raise ValueError(f"Unknown tool {block.name}")
        text, event = handler(conv.session, **block.input)
        return {"type": "tool_result", "tool_use_id": block.id, "content": text}, event
    except Exception as exc:  # errors go back to the model so it can correct itself
        event = {"type": "step", "command": f"{block.name} {json.dumps(block.input)[:300]}", "result": f"error: {exc}"}
        return {"type": "tool_result", "tool_use_id": block.id, "content": str(exc), "is_error": True}, event


def ask(client, conv, question, emit, where=None):
    """Answer one question, streaming progress events through emit(dict).

    `where` carries the reader's timezone from the browser, so answers can be in
    the time they keep rather than UTC.
    """
    now = datetime.now(timezone.utc)
    conv.last_used = time.time()
    minutes = (where or {}).get("utc_offset_minutes") or 0
    sign = "+" if minutes >= 0 else "-"
    offset = f"UTC{sign}{abs(minutes) // 60:02d}:{abs(minutes) % 60:02d}"
    # A browser may report the offset without a zone name; then the offset is the name.
    zone = (where or {}).get("timezone") or offset
    local = now + timedelta(minutes=minutes)
    conv.messages.append({
        "role": "user",
        "content": (f"{question}\n\n"
                    f"(Now: {local:%Y-%m-%d %H:%M} for the reader, timezone {zone}{'' if zone == offset else f' ({offset})'}; "
                    f"{now:%Y-%m-%d %H:%M} UTC, epoch {int(now.timestamp())}. "
                    f"Add {minutes * 60} seconds to an epoch to get their local time, and give times in it.)"),
    })
    for _ in range(MAX_STEPS):
        emit({"type": "status", "text": "Thinking..."})
        response = create(client, conv.messages, emit)
        if response.stop_reason == "refusal":
            conv.messages.pop()
            emit({"type": "error", "text": "The model declined to answer this question."})
            return

        conv.messages.append({"role": "assistant", "content": response.content})
        texts = [b.text for b in response.content if b.type == "text" and b.text.strip()]
        tool_uses = [b for b in response.content if b.type == "tool_use"]

        if not tool_uses:
            answer = "\n\n".join(texts) or "(no answer)"
            if response.stop_reason == "max_tokens":
                answer += "\n\n_(Answer was cut off at the length limit.)_"
            emit({"type": "answer", "markdown": answer})
            return

        for text in texts:
            emit({"type": "status", "text": text})
        results = []
        for block in tool_uses:
            emit({"type": "status", "text": f"Running {block.name}..."})
            result, event = call_tool(conv, block)
            results.append(result)
            if event:
                emit(event)
        conv.messages.append({"role": "user", "content": results})

    emit({"type": "error", "text": f"Stopped after {MAX_STEPS} steps without a final answer. Try a narrower question."})
