"""The question-answering loop: a model plans, calls the read-only elm tools, answers."""

import ipaddress
import json
import os
import random
import re
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlparse

import anthropic

import elm_tools
import openai_api
import recipes  # noqa: F401  adds the recipe tool to elm_tools

# The ladder: the model that answers, then the ones "Think harder" and
# Ultrathink re-ask on. SAMARA_MODEL is one step or a comma list of them.
# A Claude line (haiku, sonnet, opus) answers with the newest model in it,
# looked up from the API, so a new release needs no edit here; one line alone
# climbs the lines from there. A full Claude id alone stays on that model, then
# climbs from its line. Anything else is a model at SAMARA_MODEL_URL, an
# OpenAI-compatible API (Ollama, LM Studio, OpenAI): qwen3:8b,sonnet,opus asks
# a local model first and Claude when it falls short. The cheapest by default:
# most questions are lookups, and every one costs money; questions.md is how to
# tell whether a dearer one answers better.
LINES = ["haiku", "sonnet", "opus"]
MODEL = elm_tools.setting("MODEL", "haiku")
MODELS = [m.strip() for m in MODEL.split(",") if m.strip()] or ["haiku"]
MODEL_URL = elm_tools.setting("MODEL_URL", "")
MODEL_KEY = elm_tools.setting("MODEL_KEY", "")   # for an API that wants one (OpenAI); Ollama does not
# low|medium|high|xhigh|max. High by default: the cheap model slips most on care
# (a field elm warned about, words that drift from its own table), and high costs
# a little more thinking, far less than moving up a model line. Empty = the API's.
# Claude only: OpenAI-compatible servers differ in what they take.
EFFORT = elm_tools.setting("EFFORT", "high")
MAX_STEPS = int(elm_tools.setting("MAX_STEPS", "25"))
# Sent for the page's Dig deeper button. Answers stop at the facts (see
# system_prompt.md); this asks for the analysis that was left out.
# Asked as "Tell me more", it gave generic causes (DNS, SNMP settings) and
# checks it never ran, nearly every time (qwen3-8b, 2026-10-30): so it is asked
# to look, and to keep what it found apart from what it guesses.
DETAIL_REQUEST = ("Dig deeper into your last answer. Look further in the portal: fetch what would confirm or rule "
                  "out a cause (when the alerts started, what else alerted then, other devices on the same "
                  "collector or in the same group). Then give the patterns and likely causes, saying for each "
                  "whether the data shows it or it is a guess, and what to check next. Do not repeat the facts "
                  "I already have.")
HERE = Path(__file__).resolve().parent
# What the page says while the model thinks, one picked per step. Only for fun.
THINKING = ["Branching out", "Putting down roots", "Leafing through it", "Rustling the leaves",
            "Counting rings", "Photosynthesising", "Barking up the right tree", "Turning over a new leaf",
            "Going out on a limb", "Getting to the root of it", "Sapping", "Thinking"]


def load_system_prompt():
    """Instructions plus the elm knowledge base, as one cacheable block."""
    instructions = (HERE / "system_prompt.md").read_text()
    knowledge_path = Path(os.environ.get("ELM_KNOWLEDGE", elm_tools.ELM_HOME / "elm-knowledge.md"))
    knowledge = knowledge_path.read_text() if knowledge_path.exists() else "(no knowledge file found)"
    return f"{instructions}\n\n<elm_knowledge>\n{knowledge}\n</elm_knowledge>"


SYSTEM = [{"type": "text", "text": load_system_prompt(), "cache_control": {"type": "ephemeral"}}]


_newest = {}   # line -> newest model id; a pinned model id -> its line


def newest(client, line):
    """The newest model in a line that is not being retired, asked once per run.

    The Models API gives each model its line (haiku, sonnet, ...).
    """
    if line not in _newest:
        models = [m for m in client.models.list(limit=100) if getattr(m, "line", None) == line]
        current = [m for m in models if not getattr(m, "deprecated_at", None)] or models
        if not current:
            raise ValueError(f"The Claude API offers no {line} model.")
        _newest[line] = max(current, key=lambda m: m.created_at).id
    return _newest[line]


def is_claude(model):
    return model in LINES or model.startswith("claude-")


def where(model):
    """None if this model runs on this machine, else who it sends questions and portal data to."""
    if is_claude(model):
        return "Anthropic"
    host = urlparse(MODEL_URL).hostname or MODEL_URL
    try:
        if ipaddress.ip_address(host).is_loopback:
            return None
    except ValueError:
        pass
    return None if host in ("localhost", "host.docker.internal") else host


def config_problem():
    """What stops the ladder working, said before anything is asked, or None."""
    others = [m for m in MODELS if not is_claude(m)]
    if others and not MODEL_URL:
        return (f"SAMARA_MODEL names {', '.join(others)}, which {'is not a Claude model' if len(others) == 1 else 'are not Claude models'}, "
                f"so Samara needs SAMARA_MODEL_URL: the OpenAI-compatible API that serves "
                f"{'it' if len(others) == 1 else 'them'} (Ollama: http://host.docker.internal:11434/v1).")
    return None


def ladder(client):
    """The steps a question can climb, as SAMARA_MODEL gives them (see MODELS)."""
    if len(MODELS) > 1 or not is_claude(MODELS[0]):
        return MODELS
    model = MODELS[0]
    if model in LINES:
        return LINES[LINES.index(model):]
    if model not in _newest:   # a pinned Claude id: harder goes on from the line after its own
        _newest[model] = getattr(client.models.retrieve(model), "line", None)
    line = _newest[model]
    return [model] + (LINES[LINES.index(line) + 1:] if line in LINES else [])


def pick_model(client, harder=0):
    """(model id, the next step or None, where that step sends data if somewhere new, else None).

    The next step is {"model": its name as SAMARA_MODEL gives it, "top": whether
    it is the last}, for the button's label (Think harder, or Ultrathink at the
    top). Where lets the page say before Think harder that it would send the
    question and its portal data somewhere this step did not.
    """
    if is_claude(MODELS[0]) and len(MODELS) == 1 and not has_claude_key():
        raise NoClaudeKey(MODELS[0])
    steps = ladder(client)
    i = min(harder, len(steps) - 1)
    if is_claude(steps[i]) and not has_claude_key():
        raise NoClaudeKey(steps[i])
    model = newest(client, steps[i]) if steps[i] in LINES else steps[i]
    if i + 1 == len(steps):
        return model, None, None
    nxt = {"model": steps[i + 1], "top": i + 2 == len(steps)}
    off = where(steps[i + 1])
    return model, nxt, off if off != where(steps[i]) else None


class NoClaudeKey(Exception):
    """The step to ask is a Claude model, and no key is set."""

    def __str__(self):
        return (f"{self.args[0]} is a Claude model, and no Claude API key is set. "
                "Restart Samara with -e ANTHROPIC_API_KEY (run.sh finds it).")


def has_claude_key():
    return bool(os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN"))


_effort_unsupported = set()


class Reply:
    """One model reply, the same shape from either API: content blocks, stop reason, tokens."""

    def __init__(self, content, stop_reason, usage):
        self.content, self.stop_reason, self.usage = content, stop_reason, usage


def create(client, model, messages, emit):
    """One request to whichever API serves this model, as a Reply."""
    if not is_claude(model):
        content, stop, usage = openai_api.create(MODEL_URL, MODEL_KEY, model, SYSTEM[0]["text"],
                                                 elm_tools.TOOLS, messages, len(messages))
        return Reply(content, stop, usage)
    response = create_claude(client, model, messages, emit)
    u = response.usage
    return Reply(response.content, response.stop_reason, {
        "input": getattr(u, "input_tokens", 0) or 0,
        "output": getattr(u, "output_tokens", 0) or 0,
        "cache_read": getattr(u, "cache_read_input_tokens", 0) or 0,
        "cache_write": getattr(u, "cache_creation_input_tokens", 0) or 0,
    })


def create_claude(client, model, messages, emit):
    """One request to Claude, dropping effort if this model will not take it.

    Not every model accepts output_config.effort (Haiku 4.5 rejects it with a
    400). Rather than make the person match model to setting, ask once, and on
    that refusal drop it and carry on -- for the rest of this run, so it costs
    one wasted request, not one per step. Haiku has no fallback model to hand a
    declined request to, so only the others are sent `fallbacks`.
    """
    extra = {} if (not EFFORT or model in _effort_unsupported) else {"output_config": {"effort": EFFORT}}
    if "haiku" not in model:
        extra |= {"betas": ["server-side-fallback-2026-07-01"], "fallbacks": "default"}
    try:
        return client.beta.messages.create(
            model=model,
            max_tokens=16000,
            system=SYSTEM,
            tools=elm_tools.TOOLS,
            messages=messages,
            cache_control={"type": "ephemeral"},
            **extra,
        )
    except anthropic.BadRequestError as exc:
        if "output_config" not in extra or "effort" not in str(exc):
            raise
        _effort_unsupported.add(model)
        emit({"type": "status", "text": f"{model} does not take an effort setting; continuing without it."})
        return create_claude(client, model, messages, emit)


class Conversation:
    """One browser tab's chat: message history plus the datasets it fetched."""

    def __init__(self):
        self.messages = []
        self.question = None       # the last question, and where it starts in messages,
        self.asked_at = 0          # so "Think harder" can ask it again from there
        self.model = None          # the model that answered it, for Dig deeper
        self.level = 0             # steps above the default line; follow-ups keep it
        self.lock = threading.Lock()    # one request at a time per conversation
        self.stop = threading.Event()   # set by a newer request: the running one gives way
        self.session = elm_tools.Session()
        self.last_used = time.time()


# The heading the page folds into the steps (index.html splitWorked).
WORKED = re.compile(r"^(?:#{1,4}\s+|\*\*)?How I worked (?:this |it )?out\b.*$", re.I | re.M)


# Lines a small model copied from tool results into its answer.
ECHOES = ("Samara puts the table", "add nothing else", "If the question asks something this does not cover",
          "The values are for the reader", "Answer with this, keeping its facts", "This recipe answers only")


# A stock refusal a small model wrote beside facts a recipe had found: "is luna
# okay?" got the right summary, then "I'm sorry, but I can't answer that
# question." (gpt-oss-20b, 2026-10-30), after one of its own queries failed.
REFUSAL = re.compile(r"^\s*I(?:'|’| a)?m sorry,? but I (?:can(?:'|’)?t|cannot|am unable to)"
                     r" (?:answer|help with) (?:that|this)\b[^\n]*$", re.I | re.M)


def no_echoes(answer):
    """The answer without instructions copied from a tool result.

    Any answer, table or not: a small model handed "Answer with this, keeping
    its facts and numbers exactly: ..." to the reader whenever it made another
    call besides the recipe (qwen3-8b, 2026-10-30, 4 of 194 answers).
    """
    kept = [line for line in answer.splitlines() if not any(e in line for e in ECHOES)]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(kept)).strip()


def tidy(answer):
    """The answer without tables typed into it.

    Called when Samara has already put a real table on the page: the model's
    own copy was at best a duplicate, and once a made-up one (qwen3-8b,
    2026-10-29: invented SDT ids, dates and who set them under a right summary).
    """
    kept = [line for line in answer.splitlines()
            if not line.lstrip().startswith("|")
            and not re.fullmatch(r"\s*</?table>\s*", line) and not re.search(r"\$d\d+ \(", line)]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(kept)).strip()


# A tool call a small model wrote as text instead of making it (qwen3-8b,
# 2026-10-29): never run, so never shown.
CALL_TEXT = re.compile(r"<function_call>.*?(</function_call>|\Z)", re.S)


def no_commands(answer):
    """The answer without elm commands for the reader to run.

    The reader has no elm, and a small model made them up anyway, prompt rule
    or not: `elm AlertList --acknowledge`, `elm recipe device_health` (qwen3-8b,
    2026-10-29). The queries that really ran are under How I worked this out.
    Drops each line or code block holding one, and the sentence ending in ":"
    that only introduced it.
    """
    answer = re.sub(r"```[^\n]*\n\s*elm .*?```", "\x00", answer, flags=re.S)   # a block: one marker line
    out = []
    for line in answer.splitlines():
        if "\x00" in line or re.search(r"`elm |^\s*elm ", line):
            while out and not out[-1].strip():
                out.pop()
            if out and out[-1].rstrip().endswith(":"):
                # "Read-only. To do it, run:" keeps "Read-only."
                out[-1] = re.sub(r"(^|(?<=[.!?])\s)[^.!?]*:\s*$", "", out[-1]).rstrip()
                if not out[-1]:
                    out.pop()
            continue
        out.append(line)
    return re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip()


def with_worked(answer, lines):
    """The answer with its How I worked this out replaced by these lines."""
    m = WORKED.search(answer)
    main = answer[:m.start()].rstrip() if m else answer.rstrip()
    return main + "\n\n**How I worked this out**\n\n" + "\n".join(f"- {line}" for line in lines)


def ran_line(step):
    """A How I worked this out line for one of the model's own queries."""
    command = step.get("command") or ""
    m = re.search(r"\belm (?:-\S+ \S+ )*([A-Z]\w+)", command)
    what = m.group(1) if m else (command or "a query").split(" ", 1)[0]
    # The filter too, so a pasted answer shows what was asked: "no device web02"
    # came from a query the model described as displayName~web02 (2026-10-30).
    f = re.search(r" -F ('[^']*'|\S+)", command)
    where = f" (filter {f.group(1).strip(chr(39))})" if f else ""
    return f"Ran its own {what} query{where}: {str(step.get('result', 'no result'))[:80]}."


def with_covers(answer, covered):
    """The answer with what its recipes answer said under it, above How I worked this out.

    A recipe near the question answers its own question, not the one asked:
    "this week" got "open now", a group got the whole portal, "CPU on DEVICE"
    got its properties, with nothing to say so (qwen3-8b, 2026-10-30, about
    40 of 194 answers). Saying what was answered lets the reader see it.
    """
    line = "_What this answers: " + "; ".join(covered) + "._"
    m = WORKED.search(answer)
    at = m.start() if m else len(answer)
    return (answer[:at].rstrip() + "\n\n" + line + "\n\n" + answer[at:]).strip()


# Tools that only describe elm's commands: they fetch nothing from the portal.
LOOKUP_TOOLS = {"find_commands", "describe_command"}

# What the recipes cover, for the note on answers they did not give. Change
# it with recipes.yaml.
BEST_AT = "what is happening now: devices, groups, collectors, open alerts, downtime and website checks"


def unchecked(partly, more):
    """The note on an answer the model worked out with its own queries.

    Recipes are checked in advance; run_elm queries are the model's own, and
    nearly every confident wrong answer in testing came from them (qwen3-8b,
    2026-10-29). The reader should know which kind they are reading, and what
    to ask instead for a checked answer.
    """
    note = (f"_I'm best at {BEST_AT}. " + ("I worked part of this out myself" if partly
                                           else "I worked this one out myself") + ", so check it")
    return note + (": Think harder asks a bigger model._" if more else "._")


def call_tool(conv, block):
    """Run one tool_use block; return (tool_result, ui_event_or_None)."""
    name, args, use_id = (openai_api.block(block, k) for k in ("name", "input", "id"))
    handler = elm_tools.HANDLERS.get(name)
    try:
        if handler is None:
            raise ValueError(f"Unknown tool {name}")
        if "_unparsed" in args:
            raise ValueError(f"The arguments were not valid JSON: {args['_unparsed'][:300]}")
        text, event = handler(conv.session, **args)
        return {"type": "tool_result", "tool_use_id": use_id, "content": text}, event
    except Exception as exc:  # errors go back to the model so it can correct itself
        event = {"type": "step", "command": f"{name} {json.dumps(args)[:300]}", "result": f"error: {exc}"}
        return {"type": "tool_result", "tool_use_id": use_id, "content": str(exc), "is_error": True}, event


# US$ per million tokens: input, output, cache read. Cache writes cost 1.25x
# input. From https://www.anthropic.com/pricing, checked 2026-10-27 (Haiku's
# rate is for prompts up to 100K tokens). A model not listed shows its token
# count instead of a price, so a new release is never priced wrongly.
PRICES = {
    "claude-haiku-5-5": (0.10, 0.50, 0.01),
    "claude-sonnet-5-5": (2.00, 10.00, 0.20),
    "claude-opus-5-5": (4.00, 20.00, 0.20),
}


def spend(model, usage):
    """{"tokens", "cost"} for one turn's summed usage; cost is None for an unpriced model."""
    tokens = sum(usage.values())
    price = PRICES.get(model)
    if not price:
        return {"tokens": tokens, "cost": None}
    inp, out, read = price
    cost = (usage["input"] * inp + usage["output"] * out + usage["cache_read"] * read
            + usage["cache_write"] * inp * 1.25) / 1e6
    return {"tokens": tokens, "cost": round(cost, 6)}


class Stopped(Exception):
    """A newer request for the same conversation took over (Stop, then Try again)."""


# What the status line says while a tool runs: the tool names mean nothing to a reader.
DOING = {"recipe": "Following a recipe", "run_elm": "Asking LogicMonitor", "jq": "Counting", "show_table": "Making a table",
         "describe_command": "Reading the manual", "find_commands": "Finding the right query"}


def ask(client, conv, question, emit, where=None, harder=0, detail=False):
    """Answer one question, one request at a time per conversation.

    A Stop only reaches the server at the request's next step, so Try again can
    arrive while the stopped request is still running. Without the lock the two
    share one message history: the retry answers from the stopped one's
    half-finished results, then the stopped one's rollback deletes the retry's.
    So a new request asks the running one to give way, and waits for it.
    """
    conv.stop.set()
    with conv.lock:
        conv.stop.clear()
        return _ask(client, conv, question, emit, where, harder, detail)


def _ask(client, conv, question, emit, where=None, harder=0, detail=False):
    """Answer one question, streaming progress events through emit(dict).

    `where` carries the reader's timezone from the browser, so answers can be in
    the time they keep rather than UTC. `harder` > 0 asks the last question
    again on a dearer model, from before it was first asked, so the new model
    starts fresh instead of building on the answer that was not good enough.
    `detail` (Dig deeper) asks the model that answered for the analysis behind its answer;
    it is not a new question, so Think harder still redoes the one before it.
    Once a question has been asked harder, later questions in the conversation
    stay at that level: they are usually about the same problem, and dropping
    back would have the cheap model build on the dearer one's work. Start over
    (a new conversation) returns to the default.
    """
    if detail:
        if conv.model is None:
            return emit({"type": "error", "text": "Nothing to add detail to: ask the question again."})
        question, model, nxt, off = DETAIL_REQUEST, conv.model, None, None
    elif harder:
        if conv.question is None:
            return emit({"type": "error", "text": "Nothing to try harder on: ask the question again."})
        del conv.messages[conv.asked_at:]
        question = conv.question
        conv.level = harder
    if not detail:
        conv.question, conv.asked_at = question, len(conv.messages)
        model, nxt, off = pick_model(client, conv.level)
        conv.model = model
    emit({"type": "model", "id": model, "harder": harder, "level": conv.level,
          "more": nxt is not None, "next": nxt, "off": off})
    start = len(conv.messages)
    try:
        _answer(client, conv, question, model, emit, where, start, more=nxt is not None)
    except BaseException:
        # Stopped (the reader closed the request) or failed part way: drop the
        # half-finished turn, or a tool call left without its result makes
        # every later request in this conversation fail.
        del conv.messages[start:]
        raise


def _answer(client, conv, question, model, emit, where, start, more=False):
    """The loop for one turn of ask(): plan, call tools, answer."""
    now = datetime.now(timezone.utc)
    conv.last_used = time.time()
    minutes = (where or {}).get("utc_offset_minutes") or 0
    sign = "+" if minutes >= 0 else "-"
    offset = f"UTC{sign}{abs(minutes) // 60:02d}:{abs(minutes) % 60:02d}"
    local = now + timedelta(minutes=minutes)
    tz = elm_tools.usable_tz((where or {}).get("timezone"))
    conv.session.tz = tz
    if tz:
        # jq runs in their zone: strflocaltime gets each date's own offset right,
        # daylight saving included, which adding today's offset does not.
        how = (f"jq runs in their timezone, so format an epoch with strflocaltime, e.g. "
               f'`.startEpoch | strflocaltime("%d %b %Y, %H:%M %Z")`: it applies daylight saving '
               f"for each date. Never add an offset yourself.")
    else:
        how = f"Add {minutes * 60} seconds to an epoch to get their local time, and give times in it."
    conv.messages.append({
        "role": "user",
        "content": (f"{question}\n\n"
                    + (f"(Portal: {elm_tools.portal()}.) " if elm_tools.portal() else "")
                    + f"(Now: {local:%Y-%m-%d %H:%M} for the reader, timezone {tz or offset}; "
                    f"{now:%Y-%m-%d %H:%M} UTC, epoch {int(now.timestamp())}. {how})"),
    })
    # Tokens for this turn, across its steps, for the cost shown with the answer.
    usage = {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0}

    def spent():
        emit({"type": "usage", **spend(model, usage)})

    # A recipe says what it did; used is every tool this turn called. Only a
    # turn that used nothing but recipes gets their lines in place of the
    # model's own How I worked this out, which listed queries that never ran.
    worked, used, tabled = [], set(), False   # tabled: a real table is on the page
    summaries, recipe_calls = [], 0   # what each recipe that ran said, and how many were asked for
    covered = []   # what each recipe that ran answers, for the line under the answer
    ran = []   # the model's own queries, for How I worked this out
    failed_calls = {}   # tool call -> times it failed, to stop a model retrying the same one
    done_calls = set()   # tool calls that worked, so a repeat is not run (or tabled) twice
    forced = None   # set to end the turn without asking the model again: the answer's own text
    for _ in range(MAX_STEPS):
        if conv.stop.is_set():
            raise Stopped()
        if forced is None:
            emit({"type": "status", "text": random.choice(THINKING) + "..."})
            response = create(client, model, conv.messages, emit)
        else:
            response = Reply([{"type": "text", "text": forced}], "end_turn", {})
        for k, v in response.usage.items():
            usage[k] += v
        if response.stop_reason == "refusal":
            del conv.messages[start:]   # the whole turn, not just its last message
            spent()
            emit({"type": "error", "text": "The model declined to answer this question."})
            return

        conv.messages.append({"role": "assistant", "content": response.content})
        kind = lambda b: openai_api.block(b, "type")
        texts = [openai_api.block(b, "text") for b in response.content
                 if kind(b) == "text" and openai_api.block(b, "text").strip()]
        tool_uses = [b for b in response.content if kind(b) == "tool_use"]

        if not tool_uses:
            answer = (no_echoes(no_commands(CALL_TEXT.sub("", "\n\n".join(texts))))
                      or "\n\n".join(dict.fromkeys(summaries)) or "(no answer)")
            if tabled:
                answer = tidy(answer)
            if summaries and used - LOOKUP_TOOLS <= {"recipe"} and len(summaries) == recipe_calls:
                # Nothing but recipes, all of which ran: their summaries are the
                # answer, word for word. Retyping them, a small model changed a
                # group name and left in "the table below" and instructions
                # (qwen3-8b, 2026-10-29); with no other data it had nothing to add.
                # Looking up a command fetches no data either: "is web02 a Windows
                # host?" got find_device, describe_command and a made-up OS (qwen3-30b).
                answer = "\n\n".join(dict.fromkeys(summaries))
            elif summaries:
                # Recipes and its own queries: the recipes' facts lead. Asked "show me
                # the down collectors", a model ran the recipe and then wrote about
                # the device from the question before (qwen3-30b, 2026-10-30).
                answer = re.sub(r"\n{3,}", "\n\n", REFUSAL.sub("", answer)).strip()
                main = answer[:m.start()] if (m := WORKED.search(answer)) else answer
                facts = [s for s in dict.fromkeys(summaries) if s not in main]
                answer = "\n\n".join(facts + [answer]) if facts else answer
            if worked or ran:
                # Samara's record of what ran, never the model's: its own list named
                # recipes and checks from an earlier question (qwen3-30b, 2026-10-30).
                answer = with_worked(answer, worked + ran)
            elif WORKED.search(answer):
                # Nothing ran, so any How I worked this out is made up.
                answer = answer[:WORKED.search(answer).start()].rstrip() or answer
            if not used - LOOKUP_TOOLS:
                # "What does web02 do?" got a made-up LogicMonitor feature, no query
                # (qwen3-30b, 2026-10-30): say when nothing came from the portal.
                answer += "\n\n_Nothing in this answer was looked up in the portal._"
            if covered:
                answer = with_covers(answer, covered)
            if "run_elm" in used and forced is None:
                # Above How I worked this out, which the page folds away.
                m = WORKED.search(answer)
                at = m.start() if m else len(answer)
                answer = (answer[:at].rstrip() + "\n\n" + unchecked("recipe" in used, more) + "\n\n" + answer[at:]).strip()
            if response.stop_reason == "max_tokens":
                answer += "\n\n_(Answer was cut off at the length limit.)_"
            spent()
            emit({"type": "answer", "markdown": answer})
            return

        for text in texts:
            emit({"type": "status", "text": text})
        results = []
        for block in tool_uses:
            if conv.stop.is_set():
                raise Stopped()
            emit({"type": "status", "text": DOING.get(openai_api.block(block, "name"), "Working") + "..."})
            call = f"{openai_api.block(block, 'name')} {json.dumps(openai_api.block(block, 'input'), sort_keys=True)}"
            if call in done_calls:
                # The same call again, after it worked: its result is already in
                # the conversation. Run again, a recipe put its table on the page
                # twice ("is luna okay?", gpt-oss-20b, 2026-10-30).
                results.append({"type": "tool_result", "tool_use_id": openai_api.block(block, "id"),
                                "content": "Not run: this exact call already worked this turn, and its "
                                           "result is above. Use it, or do something different."})
                continue
            if failed_calls.get(call):
                # The same call again, after it failed: not run. A model retried
                # one failing show_table a dozen times after the portal could not
                # be reached (gpt-oss-20b, 2026-10-30).
                failed_calls[call] += 1
                results.append({"type": "tool_result", "tool_use_id": openai_api.block(block, "id"), "is_error": True,
                                "content": "Not run: this exact call already failed. Do something different, "
                                           "or answer with what you have."})
                if sum(failed_calls.values()) - len(failed_calls) >= 3:
                    # three repeats: answer now, from what came back
                    forced = forced or "I could not finish this: the same step kept failing."
                continue
            result, events = call_tool(conv, block)
            results.append(result)
            used.add(openai_api.block(block, "name"))
            recipe_calls += openai_api.block(block, "name") == "recipe"
            # One event, or a list from a tool that runs several queries (a recipe).
            for event in events if isinstance(events, list) else [events] if events else []:
                if event["type"] == "worked":
                    worked += [line for line in event["lines"] if line not in worked]   # a recipe run twice says it once
                    summaries.append(event["summary"])
                    if event.get("covers") and event["covers"] not in covered:
                        covered.append(event["covers"])
                    result["content"] += "\nSamara puts the table and How I worked this out under your answer itself."
                else:
                    tabled = tabled or event["type"] == "table"
                    if event["type"] == "step" and openai_api.block(block, "name") != "recipe":
                        ran.append(ran_line(event))
                    if event["type"] == "step" and str(event.get("result", "")).startswith("failed: Request failed:"):
                        # The portal cannot be reached (TLS, proxy, DNS): every other
                        # query would fail the same way, so answer with the reason now.
                        why = f"I could not get an answer from {elm_tools.portal() or 'the portal'}: the query " \
                              f"failed. elm said: {event['result'].removeprefix('failed: ')}"
                        if why not in summaries and not any("could not get an answer" in s for s in summaries):
                            summaries.append(why)
                        forced = ""
                    emit(event)
            if result.get("is_error") or any(str(e.get("result", "")).startswith(("failed", "error"))
                                             for e in (events if isinstance(events, list) else [events] if events else [])
                                             if e.get("type") == "step"):
                failed_calls[call] = failed_calls.get(call, 0) + 1
            else:
                done_calls.add(call)
        conv.messages.append({"role": "user", "content": results})

    del conv.messages[start:]
    spent()
    emit({"type": "error", "text": f"Stopped after {MAX_STEPS} steps without a final answer. Try a narrower question."})
