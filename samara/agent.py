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
import router
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
        self.level = 0             # steps above the default for the question being answered
        self.lock = threading.Lock()    # one request at a time per conversation
        self.stop = threading.Event()   # set by a newer request: the running one gives way
        self.session = elm_tools.Session()
        self.last_used = time.time()
        self.seen = []             # tool results of earlier turns: a follow-up's numbers may come from them


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

# gpt-oss's own markup, and the planning it sometimes leaves in the answer:
# "<|channel|>commentary to=functions jq?", "We have list. Provide answer."
# (gpt-oss-20b, 2026-10-31).
MARKUP = re.compile(r"<\|[a-z_]+\|>(?:commentary|analysis|final|Continue)?(?: to=\S+(?: \w+)?)?\??\s*")
PLANNING = re.compile(r"^(?:We (?:have|used|need|should)[^.\n]{0,60}\.\s*)?(?:Provide (?:the )?answer\.|Continue\?)\s*", re.M)


def no_commands(answer):
    """The answer without elm commands for the reader to run.

    The reader has no elm, and a small model made them up anyway, prompt rule
    or not: `elm AlertList --acknowledge`, `elm recipe device_health` (qwen3-8b,
    2026-10-29). The queries that really ran are under How I worked this out.
    Drops each code block or line that is one, and the sentence ending in ":"
    that only introduced it. In prose, only the sentence holding it goes:
    "This tool is read-only ... The required command is `elm SDTCreate ...`"
    was one line, and dropping it left a blank answer (qwen3-8b, 2026-10-31).
    """
    answer = re.sub(r"```[^\n]*\n\s*elm .*?```", "\x00", answer, flags=re.S)   # a block: one marker line
    out = []
    for line in answer.splitlines():
        if "`elm " in line and not re.match(r"\s*(?:[-*]|\d+\.)?\s*`elm ", line):
            kept = [x for x in re.split(r"(?<=[.!?])\s+", line) if "`elm " not in x]
            line = " ".join(kept)
            if not line.strip():
                continue
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


# Sent back with an answer that looked nothing up (agent._ask).
LOOK_IT_UP = ("You answered without looking anything up, so nothing in that answer came from "
              "the portal. If the question is about this portal's devices, groups, collectors, "
              "alerts, downtime or websites, call a recipe or a tool now and answer only from "
              "what it returns. If it is not (what a term means, or off topic), give the same "
              "answer again.")

def new_columns(text, shown):
    """The columns of a table typed in text that no table on the page has.

    A typed copy of a recipe's table adds nothing and is dropped (tidy); one
    with a column of its own ("% of its total") is what was asked for, so it
    is sent back to be made properly. With no table on the page, every column
    is new.
    """
    header = next((l for l in text.splitlines() if TABLE_ROW.match(l)), None)
    if not header:
        return []
    have = {re.sub(r"\W+", "", c).lower() for c in shown}
    cells = [c.strip() for c in header.strip().strip("|").split("|")]
    return [c for c in cells if c and re.sub(r"\W+", "", c).lower() not in have
            and not any(re.sub(r"\W+", "", c).lower() in h or h in re.sub(r"\W+", "", c).lower() for h in have if h)]


# Sent back with an answer holding a table it typed over fetched rows (agent._answer).
TABLE_IT = ("Your answer has a table you typed yourself, and Samara shows only tables it works "
            "out. Call show_table with a jq expression over the rows ({}) that gives the table, "
            "with any column you were asked for (a percentage, a total, a difference) computed "
            "in jq. Then answer in words, without typing the table.")

# Never a blank answer: "(no answer)" read as a fault (qwen3-8b, 2026-10-31).
NO_ANSWER = "I could not put an answer together for this one. Try asking it another way."

# A Markdown table row, typed by the model.
TABLE_ROW = re.compile(r"^\s*\|.*\|\s*$", re.M)

# Tools that only describe elm's commands: they fetch nothing from the portal.
LOOKUP_TOOLS = {"find_commands", "describe_command"}

# What the recipes cover, for the note on answers they did not give. Change
# it with recipes.yaml.
BEST_AT = "what is happening now: devices, groups, collectors, open alerts, downtime and website checks"


# Numbers that are not facts to check: dates, times and how long ago, which
# Samara works out from epochs (recipes.py PRELUDE), not the data as it stands.
NOT_FACTS = re.compile(
    r"\d{4}-\d{2}-\d{2}(?:[ T]\d{1,2}:\d{2}(?::\d{2})?)?"
    r"|\d{1,2} (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*(?: \d{4})?"
    r"|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]* \d{1,2}(?:st|nd|rd|th)?(?:,? \d{4})?"
    r"|\d{1,2}:\d{2}(?::\d{2})?"
    r"|(?:in about |about )?(?<![\d.])\d+(?:\.\d+)? (?:seconds?|minutes?|hours?|days?|weeks?|months?|years?)(?: ago)?", re.I)
# A comma only as a thousands separator: "2594,2478,35" is three ids, not one number.
NUMBER = re.compile(r"(?<![\w.,])(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?![\w])")


def unfound(answer, seen):
    """The answer's numbers that are in none of the tool results it had.

    Nothing the model writes is checked otherwise: "dead since 29 Oct" and
    ids 123 and 456 (qwen3-30b-a3b, qwen3-8b, 2026-10-31) came from nowhere.
    A count the model made itself is not found either, which is right: no
    query said it. Notes in italics and How I worked this out are Samara's.
    """
    answer = re.sub(r"[\u2010-\u2015\u2212]", "-", answer).replace("\u00a0", " ").replace("\u202f", " ")
    m = WORKED.search(answer)
    main = "\n".join(l for l in (answer[:m.start()] if m else answer).splitlines() if not l.lstrip().startswith("_"))
    main = NOT_FACTS.sub(" ", main)
    # Every digit run in the data counts, as well as its numbers with thousands
    # separators, so "2594,2478,35" there backs 2478 in the answer.
    data = " ".join(seen)
    have = set(re.findall(r"\d+(?:\.\d+)?", data)) | {n.replace(",", "") for n in NUMBER.findall(data)}
    out = []
    for n in NUMBER.findall(main):
        n = n.replace(",", "").rstrip(".")
        # A collector build is 41100 in the data and 41.100 in words (recipes.py ver).
        if n and n not in have and n.replace(".", "") not in have and n not in out:
            out.append(n)
    return out


def ok(result):
    """Whether a step's result is data, not a failure."""
    return not str(result).startswith(("failed", "error"))


def unchecked(partly, more):
    """The note on an answer the model worked out with its own queries.

    Recipes are checked in advance; run_elm queries are the model's own, and
    nearly every confident wrong answer in testing came from them (qwen3-8b,
    2026-10-29). The label above the answer says which kind it is; this says
    what Samara is best at, and what to ask instead.
    """
    return f"_I'm best at {BEST_AT}" + (": Think harder asks a bigger model._" if more else "._")


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
    Think harder is for one question: the next one goes back to the default
    model. The dearer model is the exception, asked for each time, not a mode
    the conversation stays in (2026-10-31: recipes make the default right most
    of the time, and a follow-up on the default still sees the dearer answer).
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
    else:
        conv.level = 0   # a new question, on the default model
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
    # What the question is, decided in code (router.py): a request to change
    # something, a LogicMonitor term, and the portal's objects it names.
    routed = router.route(question) if question != DETAIL_REQUEST else {"write": None, "term": False, "found": []}
    conv.messages.append({
        "role": "user",
        "content": (f"{question}\n\n"
                    + (f"(Portal: {elm_tools.portal()}.) " if elm_tools.portal() else "")
                    + (router.hint(routed["found"]) + " " if routed["found"] else "")
                    + f"(Now: {local:%Y-%m-%d %H:%M} for the reader, timezone {tz or offset}; "
                    f"{now:%Y-%m-%d %H:%M} UTC, epoch {int(now.timestamp())}. {how})"),
    })
    # Tokens for this turn, across its steps, for the cost shown with the answer.
    usage = {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0}

    def spent():
        emit({"type": "usage", **spend(model, usage)})

    if routed["write"]:
        # Read-only, said by Samara, not the model: sent back for looking nothing
        # up, a model looked up "Put web01 into SDT" and showed its health
        # instead (qwen3-8b, 2026-10-31); others said yes.
        answer = router.read_only(routed["write"], elm_tools.portal())
        conv.messages.append({"role": "assistant", "content": [{"type": "text", "text": answer}]})
        spent()
        emit({"type": "answer", "markdown": answer, "source": "none", "unfound": []})
        return

    # A recipe says what it did; used is every tool this turn called. Only a
    # turn that used nothing but recipes gets their lines in place of the
    # model's own How I worked this out, which listed queries that never ran.
    worked, used, tabled = [], set(), False   # tabled: a real table is on the page
    summaries, recipe_calls = [], 0   # what each recipe that ran said, and how many were asked for
    covered = []   # what each recipe that ran answers, for the line under the answer
    ran = []   # the model's own queries, for How I worked this out
    own = []   # their results in full, to tell when every one failed
    fetched = False   # whether any query this turn returned rows, for a table typed without them
    failed_calls = {}   # tool call -> times it failed, to stop a model retrying the same one
    done_calls = set()   # tool calls that worked, so a repeat is not run (or tabled) twice
    forced = None   # set to end the turn without asking the model again: the answer's own text
    seen = []   # every tool result and table this turn: what the answer's numbers may come from
    inject = None   # a tool call Samara makes itself, in place of asking the model
    sent_back = {}   # why an answer was sent back -> where it is in conv.messages
    shown = []   # the columns of the tables Samara put on the page this turn
    datasets = []   # the rows this turn fetched ($d1, $d2 ...), for a table made from them
    for _ in range(MAX_STEPS):
        if conv.stop.is_set():
            raise Stopped()
        if inject:
            response, inject = Reply([inject], "tool_use", {}), None   # Samara's own call (router.HEALTH)
        elif forced is None:
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
            # The model's own words, before Samara tidies them: for the bug report (index.html).
            emit({"type": "draft", "text": "\n\n".join(texts)})
            if (not used - LOOKUP_TOOLS and routed["found"] and "look" in sent_back and "ran" not in sent_back
                    and forced is None):
                # Sent back, and it still looked nothing up about a device, group or
                # collector the question names: Samara runs that one's health recipe
                # for it, and the model answers from the result. qwen3-30b-a3b gave
                # the same made-up answer back (2026-10-31).
                h = routed["found"][0]
                sent_back["ran"] = len(conv.messages) - 1
                inject = {"type": "tool_use", "id": "samara-health", "name": "recipe",
                          "input": {"recipe": router.HEALTH[h["kind"]], h["kind"]: h["name"]}}
                conv.messages.append({"role": "user", "content": "Samara looked it up: answer from this."})
                emit({"type": "status", "text": "Looking it up..."})
                continue
            if (not used - LOOKUP_TOOLS and not sent_back and question != DETAIL_REQUEST and forced is None
                    and not (routed["term"] and not routed["found"])):
                # An answer with no lookup behind it, sent back once. Asked "is
                # web01 okay?", a model called nothing and wrote "dead since
                # 29 Oct", with a How I worked this out naming a recipe that never
                # ran (qwen3-30b-a3b, 2026-10-31: 34 of 54 answers called no tool).
                # A definition or a joke comes back the same, which is right.
                sent_back["look"] = len(conv.messages) - 1
                conv.messages.append({"role": "user", "content": LOOK_IT_UP})
                emit({"type": "status", "text": "Checking it against the portal..."})
                continue
            if (new_columns("\n".join(texts), shown) and datasets and "table" not in sent_back
                    and question != DETAIL_REQUEST and forced is None):
                # A table typed over rows a query fetched, sent back once to be made
                # with show_table. "Can you add a percentage to that table?" got the
                # right percentages typed by the model, then dropped: a typed table
                # never shows beside a real one (gpt-oss-20b, 2026-10-31). jq works
                # the numbers out, so they are right and can be checked.
                sent_back["table"] = len(conv.messages) - 1
                conv.messages.append({"role": "user", "content": TABLE_IT.format(", ".join(f"${d}" for d in datasets))})
                emit({"type": "status", "text": "Making that table..."})
                continue
            answer = (no_echoes(no_commands(PLANNING.sub("", MARKUP.sub("", CALL_TEXT.sub("", "\n\n".join(texts))))))
                      or "\n\n".join(dict.fromkeys(summaries)) or NO_ANSWER)
            if tabled:
                answer = tidy(answer)
            elif TABLE_ROW.search(answer) and not fetched:
                # A table with no rows behind it is made up: "[Device Name]" rows after
                # every query failed; ids 123 and 456 after fetching only a count
                # (qwen3-8b, 2026-10-31).
                answer = tidy(answer) + "\n\n_A table was left out here: no rows came from the portal for it._"
            if own and not summaries and not any(ok(r) for r in own):
                # Every query of its own failed, so nothing it says came from the portal:
                # "no alerts were cleared in the last hour" after each one failed
                # (qwen3-8b, 2026-10-31). Samara says what happened instead.
                why = str(own[-1]).removeprefix("failed: ").removeprefix("error: ")
                answer = (f"I could not get this from {elm_tools.portal() or 'the portal'}: every query I tried "
                          f"failed. The last one said: {why[:300]}")
                forced = forced or ""
            # Its own queries all failed: nothing it added came from them, so its
            # answer is the recipes' as much as if only recipes had run. Retyped,
            # "4 alerts started in the last hour" said it twice, with "the table
            # below" (gpt-oss-20b, 2026-10-31).
            only_recipes = used - LOOKUP_TOOLS <= {"recipe"} or (own and not any(ok(r) for r in own))
            if summaries and only_recipes and len(summaries) == recipe_calls:
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
            if covered:
                answer = with_covers(answer, covered)
            # Where the answer came from, for the label above it (index.html):
            # what Samara knows, not how sure the model says it is. "What does
            # web02 do?" got a made-up feature with no query (qwen3-30b,
            # 2026-10-30): the label says nothing was looked up.
            failed = any("could not get an answer" in x for x in summaries)
            source = ("none" if not used - LOOKUP_TOOLS or failed or (not summaries and not any(ok(r) for r in own))
                      else "checked" if not any(ok(r) for r in own)
                      # recipe rows made into a new table by the model's jq, with no query of its own
                      else "worked" if summaries and "run_elm" not in used
                      else "own")
            if source == "own" and forced is None:
                # Above How I worked this out, which the page folds away.
                m = WORKED.search(answer)
                at = m.start() if m else len(answer)
                answer = (answer[:at].rstrip() + "\n\n" + unchecked("recipe" in used, more) + "\n\n" + answer[at:]).strip()
            if response.stop_reason == "max_tokens":
                answer += "\n\n_(Answer was cut off at the length limit.)_"
            for at in sorted(sent_back.values(), reverse=True):
                # Each answer sent back, and why, leave the conversation, so a
                # follow-up cannot build on what it made up.
                del conv.messages[at:at + 2]
            spent()
            # Numbers may come from this turn, an earlier one ("243" from the answer
            # before), or the question itself ("devices on collector 281").
            missing = unfound(answer, conv.seen + seen + summaries + [question]) if source != "none" else []
            conv.seen += seen + summaries
            emit({"type": "answer", "markdown": answer, "source": source, "unfound": missing})
            return

        for text in texts:
            # "<|channel|>?" was shown as a status line (gpt-oss-20b, 2026-11-01).
            if text := MARKUP.sub("", text).strip():
                emit({"type": "status", "text": text})
        results = []
        for block in tool_uses:
            if conv.stop.is_set():
                raise Stopped()
            emit({"type": "status", "text": DOING.get(openai_api.block(block, "name"), "Working") + "..."})
            call = f"{openai_api.block(block, 'name')} {json.dumps(openai_api.block(block, 'input'), sort_keys=True)}"
            emit({"type": "call", "name": openai_api.block(block, "name"), "input": openai_api.block(block, "input")})
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
                    if event["type"] == "table":
                        seen.append(json.dumps(event.get("rows", [])))
                        shown += [str(c) for c in event.get("columns", [])]
                    if event["type"] == "step" and openai_api.block(block, "name") != "recipe":
                        ran.append(ran_line(event))
                        own.append(event.get("result", ""))
                    if event["type"] == "step" and re.match(r"[1-9]\d* rows", str(event.get("result", ""))):
                        fetched = True
                    if event["type"] == "step" and event.get("dataset") and ok(event.get("result")):
                        datasets.append(event["dataset"])
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
        seen += [str(r.get("content", "")) for r in results]
        conv.messages.append({"role": "user", "content": results})

    del conv.messages[start:]
    spent()
    emit({"type": "error", "text": f"Stopped after {MAX_STEPS} steps without a final answer. Try a narrower question."})
