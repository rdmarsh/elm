#!/usr/bin/env python3
"""eval: ask Samara the questions in eval.toml and grade each answer.

Usage:
  samara/eval.py [--url URL] [--elm CMD] [--values FILE] [--repeat N] [--only TEXT] [--out FILE]

Each case in eval.toml is a question, with {placeholders} for this portal's
names, and the checks its answer must pass. Values for the placeholders come
from --values (default ~/.config/samara/eval-values.toml), never from the repo:
real names stay out of it.

  --url URL      Samara (default http://127.0.0.1:8080)
  --elm CMD      elm to check facts with (default "elm -p ai": the profile
                 Samara uses, so both see the same portal)
  --values FILE  the placeholder values
  --repeat N     ask each question N times (default 1)
  --only TEXT    only the cases whose question contains TEXT
  --claude       run even when Samara's model is a Claude one (each ask is billed)
  --out FILE     every event of every answer, as JSON lines (default
                 ~/.cache/samara/eval-DATE.jsonl). It holds portal data: keep it.

Verdicts, worst first:
  WRONG   a fact check failed, or the answer has something it must never have,
          and the answer does not say it could not tell: confidently wrong
  FAIL    a check failed, but the answer says it could not answer
  PASS    every check passed

What is printed is safe to paste: questions as templates, verdicts, numbers.
Asking a local model costs only time; this never presses Think harder.

Requires: python 3.11+ (tomllib), elm, and Samara running.
"""
import argparse, datetime, json, os, re, shlex, subprocess, sys, time, tomllib, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Words an answer uses when it says it could not answer: a miss, not a lie.
ADMITS = re.compile(r"\b(could not|couldn't|cannot|can't|unable|not available|isn't available|"
                    r"is not available|read-only|no data|not able)\b", re.I)


def fill(text, values):
    """The text with each {name} it has a value for filled in: a regex's {32,} stays."""
    return re.sub(r"{(\w+)}", lambda m: str(values.get(m.group(1), m.group(0))), text or "")


def ask(url, question, conversation=None):
    """The events of one answer, and how long it took."""
    now = datetime.datetime.now().astimezone()
    body = {"question": question, "utc_offset_minutes": int(now.utcoffset().total_seconds() // 60)}
    try:   # the zone's name, e.g. Australia/Sydney, as the page sends it
        body["timezone"] = str(Path("/etc/localtime").resolve()).split("zoneinfo/")[1]
    except (IndexError, OSError):
        pass
    if conversation:
        body["conversation_id"] = conversation
    req = urllib.request.Request(url + "/api/ask", json.dumps(body).encode(), {"Content-Type": "application/json"})
    began, events = time.time(), []
    with urllib.request.urlopen(req, timeout=1800) as r:
        for line in r:
            events.append(json.loads(line))
    return events, round(time.time() - began)


def fact(elm, command):
    """What a check command prints: one value, from the portal now."""
    out = subprocess.run(["bash", "-c", command], capture_output=True, text=True, timeout=300,
                         env={**os.environ, "ELM": elm})
    return out.stdout.strip() if out.returncode == 0 else None


def near(want, text):
    """Whether the fact is in the text: a count within 2% of it (small counts exactly), as
    live counts move between the answer and the check (575 open, then 574)."""
    if not re.fullmatch(r"\d+", want):
        return re.search(rf"(?<![\w.]){re.escape(want)}(?![\w.])", text) is not None
    n = int(want)
    return any(abs(int(x) - n) <= n // 50 for x in re.findall(r"(?<![\d.])\d+(?![\d.])", text))


def grade(case, events, values, elm, facts=None):
    """The verdict and its reasons. facts, if given, holds each check command's
    value and is filled in: a regrade uses the values of the run."""
    facts = {} if facts is None else facts
    answer = next((e["markdown"] for e in events if e["type"] == "answer"),
                  next((e["text"] for e in events if e["type"] == "error"), ""))
    main = answer.split("**How I worked this out**")[0]
    plain = main.replace(",", "")   # 1,158 reads as 1158
    recipes = [e["input"].get("recipe") for e in events if e.get("type") == "call" and e.get("name") == "recipe"]
    queried = any(e.get("type") == "step" for e in events)
    misses, wrong, lie = [], False, False
    off = case.get("recipe") and not set(case["recipe"]) & set(recipes)
    if off:
        misses.append(f"recipe: wanted {' or '.join(case['recipe'])}, got {', '.join(filter(None, recipes)) or 'none'}")
    if case.get("queries") is False and queried:
        misses.append("queried the portal, and should not have")
    for command in case.get("fact", []):
        if command not in facts:
            facts[command] = fact(elm, fill(command, values))
        want = facts[command]
        if want is None:
            misses.append("fact: the check command failed")
        elif not near(want, plain):
            misses.append(f"fact: {want} not in the answer")
            wrong = True
    for pattern in case.get("says", []):
        if not re.search(fill(pattern, values), main, re.I):
            misses.append(f"says: no /{pattern}/")
    for pattern in case.get("never", []):
        if re.search(fill(pattern, values), answer, re.I):
            misses.append(f"never: /{pattern}/ is in it")
            lie = True
    if not main.strip():
        misses.append("blank answer")
    if not misses:
        return "PASS", misses
    # A wrong number is confidently wrong unless the answer says it could not
    # tell, or says what it answered instead ("What this answers: ..." under a
    # near recipe). Something it must never say is wrong whatever else it says.
    told = ADMITS.search(main) or ((off or not case.get("recipe")) and "_What this answers:" in main)
    return ("WRONG" if lie or (wrong and not told) else "FAIL"), misses


def main():
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("--url", default="http://127.0.0.1:8080")
    p.add_argument("--elm", default="elm -p ai")
    p.add_argument("--values", default=str(Path.home() / ".config/samara/eval-values.toml"))
    p.add_argument("--repeat", type=int, default=1)
    p.add_argument("--only", default="")
    p.add_argument("--out")
    p.add_argument("--claude", action="store_true")
    p.add_argument("-h", "--help", action="store_true")
    a = p.parse_args()
    if a.help:
        print(__doc__.strip()); return
    cases = tomllib.loads((HERE / "eval.toml").read_text())["case"]
    try:
        values = tomllib.loads(Path(a.values).read_text())
    except FileNotFoundError:
        names = sorted({m for c in cases for m in re.findall(r"{(\w+)}", json.dumps(c))})
        sys.exit(f"eval: no {a.values}. Make it with a value for each of: {', '.join(names)}\n"
                 f"(see the top of eval.toml)")
    now = datetime.date.today()
    values = {"yesterday": (now - datetime.timedelta(days=1)).isoformat(), **values}
    health = json.load(urllib.request.urlopen(a.url + "/api/health", timeout=10))
    if re.search(r"claude|sonnet|haiku|opus|fable", str(health.get("model_id")), re.I) and not a.claude:
        # each answer would be billed: say so first
        sys.exit(f"eval: Samara is on {health.get('model_id')}, a Claude model: each ask costs money. "
                 "Restart it on a local model, or pass --claude.")
    out = Path(a.out or Path.home() / f".cache/samara/eval-{datetime.datetime.now():%Y%m%d-%H%M}.jsonl")
    out.parent.mkdir(parents=True, exist_ok=True)
    print(f"Samara {health.get('model_id')} · build {health.get('build')} · elm {health.get('elm_version')} "
          f"· {datetime.datetime.now():%Y-%m-%d %H:%M}")
    tally = {"PASS": 0, "FAIL": 0, "WRONG": 0}
    with open(out, "a") as log:
        for case in cases:
            if a.only not in case["q"]:
                continue
            for _ in range(a.repeat):
                conversation, events, secs, facts = None, [], 0, {}
                try:
                    for q in case.get("after", []) + [case["q"]]:   # earlier turns of a conversation first
                        events, secs = ask(a.url, fill(q, values), conversation)
                        conversation = next((e["id"] for e in events if e["type"] == "conversation"), conversation)
                    verdict, misses = grade(case, events, values, a.elm, facts)
                except Exception as exc:   # one broken ask is a FAIL, not the end of the run
                    verdict, misses = "FAIL", [f"driver: {exc}"]
                tally[verdict] += 1
                log.write(json.dumps({"q": case["q"], "verdict": verdict, "misses": misses, "facts": facts, "secs": secs,
                                      "events": events}) + "\n")
                log.flush()
                print(f"{verdict:5}  {secs:4}s  {case['q']}" + "".join(f"\n              {m}" for m in misses),
                      flush=True)
    total = sum(tally.values())
    if total:
        print(f"\n{total} asks: {tally['PASS']} pass ({100 * tally['PASS'] // total}%), {tally['FAIL']} fail, "
              f"{tally['WRONG']} confidently wrong ({100 * tally['WRONG'] // total}%). Answers in {out}")


if __name__ == "__main__":
    main()
