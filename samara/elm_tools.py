"""Read-only LogicMonitor tools for Samara, built on the elm CLI.

Every LM call goes through elm, and elm only ever sends GET requests (the
Makefile generates commands from the swagger "get" operations only). On top of
that, this module only lets the model choose a command name, a filter, fields,
paging and the command's own documented parameters -- never global flags such
as -f api/curl/wget, which would print the signed Authorization header.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path


def setting(name, default=None):
    """SAMARA_<name>, or the older ELM_ASK_<name>, so setups from before the rename keep working."""
    return os.environ.get(f"SAMARA_{name}", os.environ.get(f"ELM_ASK_{name}", default))


ELM_HOME = Path(os.environ.get("ELM_HOME", Path(__file__).resolve().parents[1]))
ELM_CMD = [sys.executable, str(ELM_HOME / "elm.py")]
# Samara runs as its own profile, `ai`, not the default `config`: the person
# has to create it on purpose (from ai.example.ini), so a powerful everyday
# token is never the one the assistant uses by accident. The model cannot
# change these; only whoever starts Samara can.
ELM_PROFILE = os.environ.get("ELM_PROFILE") or "ai"   # --profile NAME
ELM_CONFIG = os.environ.get("ELM_CONFIG")             # --config PATH (wins over profile)
# Refuse to answer with a profile that has no allowed_commands, unless this is set.
ALLOW_UNRESTRICTED = setting("ALLOW_UNRESTRICTED") == "1"
ELM_CACERT = os.environ.get("ELM_CACERT")        # --cacert PATH for TLS-inspecting proxies

MAX_ROWS = 1000          # LM's page cap; -s0 means "up to 1000"
SAMPLE_ROWS = 5
MAX_SAMPLE_CHARS = 6000  # a full CollectorList row alone can be several KB
MAX_TOOL_TEXT = 15000    # characters of tool output handed back to the model
MAX_TABLE_ROWS = 2000    # rows sent to the browser per table
PAGING_PARAMS = {"fields", "size", "offset", "filter"}

# Removed from every row before the model, jq or the page can see it. With a
# read-only token LM returns these empty, but a token with write rights gets
# real collector configs and tokens.
SECRET_FIELDS = {
    "bearerToken", "collectorConf", "wrapperConf", "watchdogConf", "sbproxyConf",
    "websiteConf", "encodedConfigData", "config", "downloadUrl", "copyUrl",
    "accessKey", "password", "privateKey", "secret",
}
# Personal contact details, removed for the same reason: no question Samara is
# for needs them, and they would otherwise be sent to the model. PortalInfo
# carries a contacts list (names, emails, mobile numbers); email and phone
# appear on people elsewhere too. A question that really is about people ("are
# the portal contacts the same on both portals?") needs these back, and pseudo-
# nyms rather than plain removal -- see the README.
PERSONAL_FIELDS = {"contacts", "email", "phone"}
# A dashboard's widget tokens are values an admin typed for its widgets (paths,
# hosts, anything): kept from the reader too (David, 2026-10-31).
REMOVED_FIELDS = SECRET_FIELDS | PERSONAL_FIELDS | {"widgetTokens"}

# Property lists (customProperties, systemProperties, ...) hold {name, value}.
# LM already masks credential properties as ******** (verified with a read-only
# token); mask any credential-like name it did not. Not "auth": snmp.auth is the
# SNMPv3 auth protocol (SHA, MD5), not a secret.
SECRET_PROPERTY_NAME = re.compile(r"pass|secret|community|token|accesskey|privatekey|apikey", re.I)
LM_MASK = re.compile(r"^\*+$")
REDACTED = "[removed: secret]"

# Free text anyone with access can type: descriptions, SDT comments, property
# values. A small model repeated a planted "[LM Admin] Decommissioned" note as
# fact about a device that was up, whatever the prompt said (qwen3-8b,
# 2026-10-29). So the model never gets these values: jq and run_elm's sample
# read a copy without them, and show_table, which only the reader sees, reads
# the real rows. Kept: system properties LM fills in itself, and a collector's
# description, which is its name. An alert's acknowledgement note is free text
# too, and who acknowledged it is a person's login; so are a report's
# last editor and a private dashboard's owner, and a report's recipients are
# email addresses. The reader still sees them, so "what reports go to bob?"
# can be answered from a table, by code, never by the model reading them.
FREE_TEXT_FIELDS = {"description", "comment", "note", "ackComment", "ackedBy",
                    "recipients", "lastmodifyUserName", "owner"}
PROPERTY_LISTS = {"customProperties", "inheritedProperties", "systemProperties", "autoProperties"}
LM_SET_PROPERTIES = {"system.sysinfo", "system.ips", "system.sysoid", "system.hoststatus", "system.devicetype",
                     "system.collectorplatform", "system.collectorarch", "system.collectorversion"}
WITHHELD = "(withheld; show_table shows it to the reader)"


def load_commands():
    """Return {command: definition} from the generated _defs/commands.json."""
    with open(ELM_HOME / "_defs" / "commands.json") as f:
        return {c["command"]: c for c in json.load(f)["commands"]}


COMMANDS = load_commands()


def global_args():
    """Global elm flags that select credentials; never chosen by the model."""
    args = []
    if ELM_CONFIG:
        args += ["--config", ELM_CONFIG]
    elif ELM_PROFILE:
        args += ["--profile", ELM_PROFILE]
    if ELM_CACERT:
        args += ["--cacert", ELM_CACERT]
    return args


def truncate(text, limit=MAX_TOOL_TEXT):
    """Cap text handed to the model, saying so when it was cut."""
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n... [truncated, {len(text) - limit} more characters]"


def redact(value):
    """Return (value with secret and personal fields removed or masked, number of changes)."""
    changes = 0
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            if key in REMOVED_FIELDS:
                changes += 1
                continue
            item, n = redact(item)
            changes += n
            out[key] = item
        if isinstance(out.get("name"), str) and "value" in out and SECRET_PROPERTY_NAME.search(out["name"]):
            if out["value"] not in ("", None) and not LM_MASK.match(str(out["value"])):
                out["value"] = REDACTED
                changes += 1
        return out, changes
    if isinstance(value, list):
        items = [redact(item) for item in value]
        return [item for item, _ in items], sum(n for _, n in items)
    return value, 0


def lm_set(prop):
    """An LM-set property as the model sees it. sysinfo is what the device
    reports about itself, so whoever runs the device chooses it: plain
    characters only, and short."""
    return prop | {"value": re.sub(r"[^A-Za-z0-9 .,:()/_#+-]", "", str(prop.get("value", "")))[:100]}


def withhold(record, command):
    """The record as the model sees it: free text replaced by WITHHELD."""
    out = dict(record)
    for key, item in record.items():
        if key in FREE_TEXT_FIELDS and item not in ("", None) and not command.startswith("Collector"):
            out[key] = WITHHELD
        elif key in PROPERTY_LISTS and isinstance(item, list):
            out[key] = [lm_set(p) if p.get("name") in LM_SET_PROPERTIES
                        else p | {"value": WITHHELD} if p.get("value") not in ("", None) else p
                        for p in item if isinstance(p, dict)]
    return out


def usable_tz(name):
    """An IANA timezone name (Australia/Sydney) that is safe to hand jq, else None.

    Times go through jq's strflocaltime, which applies daylight saving for each
    date. A fixed offset cannot: +11 is right in October and an hour out for
    August in Sydney.
    """
    if (name and len(name) < 64 and re.fullmatch(r"[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*", name)
            and os.path.isfile(f"/usr/share/zoneinfo/{name}")):
        return name
    return None


class Session:
    """Datasets fetched during one conversation, kept as jsonl files for jq."""

    def __init__(self):
        self.dir = tempfile.TemporaryDirectory(prefix="samara-")
        self.datasets = {}   # id -> {"path", "rows", "description"}
        self.described = set()   # commands whose notes have been sent already
        self.tz = None           # the reader's timezone for jq (usable_tz), if known

    def with_notes(self, command, text):
        """Attach a command's verified notes the first time it is used here."""
        if command in self.described:
            return text
        self.described.add(command)
        notes = command_notes(command)
        return f"{text}\n\n{notes}" if notes else text

    def add(self, lines, description, command=""):
        """Store jsonl lines as a new dataset and return its id.

        Each dataset is kept twice: as fetched, for show_table and recipes, and
        with free text withheld (withhold), for everything the model reads.
        """
        ds_id = f"d{len(self.datasets) + 1}"
        path = Path(self.dir.name) / f"{ds_id}.jsonl"
        path.write_text("".join(line + "\n" for line in lines))
        model_path = Path(self.dir.name) / f"{ds_id}.model.jsonl"
        model_path.write_text("".join(json.dumps(withhold(json.loads(line), command)) + "\n" for line in lines))
        self.datasets[ds_id] = {"path": path, "model_path": model_path, "rows": len(lines), "description": description}
        return ds_id

    def model_lines(self, ds_id):
        return self.datasets[ds_id]["model_path"].read_text().splitlines()

    def close(self):
        self.dir.cleanup()


# ---------------------------------------------------------------------------
# Tool implementations. Each returns (text_for_model, ui_event_or_None).
# ---------------------------------------------------------------------------

def profile_status():
    """Whether the profile exists and is restricted, and what it allows.

    Returns {"name", "exists", "restricted", "allowed", "problem"}; problem is
    None when Samara may answer questions with this profile.
    """
    if ELM_CONFIG:
        name, exists = ELM_CONFIG, os.path.isfile(ELM_CONFIG)
    else:
        name = ELM_PROFILE
        listing = subprocess.run(ELM_CMD + ["--list"], capture_output=True, text=True, timeout=60).stdout
        exists = name in {line.lstrip("* ").split()[0] for line in listing.splitlines() if line.strip()}
    help_text = subprocess.run(ELM_CMD + global_args() + ["--help"], capture_output=True, text=True, timeout=60)
    restricted = "Restricted profile:" in help_text.stdout
    lines = help_text.stdout.split("Commands:", 1)[-1].split("Restricted profile:", 1)[0].splitlines()
    allowed = {line.split()[0] for line in lines if line.startswith("  ") and line.split()[0] in COMMANDS}

    account = portal()
    problem = None
    if help_text.returncode != 0:
        problem = f"elm cannot read the profile: {help_text.stderr.strip()[:300]}"
    elif not exists:
        problem = (f"Profile '{name}' not found. Create ~/.config/logicmonitor/credentials/{name}.ini from "
                   f"ai.example.ini, with a read-only API token.")
    elif not restricted and not ALLOW_UNRESTRICTED:
        problem = (f"Profile '{name}' has no allowed_commands, so it can run every command. Add allowed_commands "
                   f"(see ai.example.ini), or set SAMARA_ALLOW_UNRESTRICTED=1 to use it anyway.")
    return {"name": name, "account": account, "exists": exists, "restricted": restricted,
            "allowed": sorted(allowed), "problem": problem}


def portal():
    """The profile's account name (the portal, as in NAME.logicmonitor.com), or ""."""
    global _PORTAL
    if _PORTAL is None:
        _PORTAL = ""
        try:
            from configobj import ConfigObj
            path = ELM_CONFIG or os.path.expanduser(f"~/.config/logicmonitor/credentials/{ELM_PROFILE}.ini")
            # Only the account name: the id and key in this file are never read.
            _PORTAL = str(ConfigObj(path, unrepr=True).get("account_name") or "")
        except Exception:
            pass
    return _PORTAL


_PORTAL = None


def allowed_commands():
    """Commands the profile allows: `elm --help` lists only those (allowed_commands)."""
    global _ALLOWED
    if _ALLOWED is None:
        _ALLOWED = profile_status()["allowed"]
    return _ALLOWED


_ALLOWED = None


def find_commands(session, keyword=""):
    """List the elm commands matching the keyword, and name the ones this profile withholds.

    Matches the profile does not allow are named but not described: without them
    an answer can only say "I cannot", when what helps is "AdminList would
    answer this; ask for it to be allowed".
    """
    kw = keyword.lower()
    allowed = allowed_commands()
    hits, withheld = [], []
    for name, c in sorted(COMMANDS.items()):
        if not (kw in name.lower() or kw in (c.get("summary") or "").lower() or kw in (c.get("tag") or "").lower()):
            continue
        if name in allowed:
            required = [o["name"] for o in c["options"] if o.get("required")]
            hits.append({"command": name, "summary": c.get("summary"), "required_params": required})
        else:
            withheld.append(name)
    text = json.dumps(hits[:40], indent=1)
    if len(hits) > 40:
        text += f"\n({len(hits) - 40} more; use a narrower keyword)"
    if withheld:
        text += ("\n\nMatching commands this profile does not allow, so you cannot run them: "
                 + ", ".join(withheld[:20])
                 + ". If one of these is what the question needs, say so and name it, so the person can "
                   "decide to allow it; do not guess the answer instead.")
    return text, None


def build_elm_args(command, filter=None, fields=None, size=0, offset=0, params=None, total=False):
    """Validate the model's request and build the elm argument list."""
    if command not in COMMANDS:
        raise ValueError(f"Unknown command {command!r}. Use find_commands to look it up.")
    allowed = {o["name"]: o for o in COMMANDS[command]["options"] if o["name"] not in PAGING_PARAMS}
    params = params or {}
    for name in params:
        if name not in allowed:
            raise ValueError(f"{command} has no parameter {name!r}. Allowed: {sorted(allowed) or 'none'}")
    missing = [n for n, o in allowed.items() if o.get("required") and n not in params]
    if missing:
        # Say where they go: qwen3-8b put deviceId in the filter and sent the
        # same call six times against a bare "requires: ['deviceId']" (2026-10-29).
        example = ", ".join(f'"{n}": 123' for n in missing)
        raise ValueError(f"{command} requires {missing} in params, not in filter: params={{{example}}}")
    size = int(size)
    if not 0 <= size <= MAX_ROWS:
        raise ValueError("size must be 0-1000 (0 means up to 1000)")
    # Paging, filtering and field selection are per-command options, not global
    # flags: a command that returns one object (PortalInfo, anything ById) has
    # no size/offset/filter, and passing them makes elm exit 2.
    has = {o["name"] for o in COMMANDS[command]["options"]}

    args = ["-f", "jsonl", command]
    for name, value in params.items():
        args += [f"--{name}", str(value)]
    if total:
        args += ["-C"]
    elif "size" in has:
        args += ["-s", str(size), "-o", str(int(offset))]
    if filter:
        if "filter" not in has:
            raise ValueError(f"{command} takes no filter: it does not return a list to filter.")
        args += ["-F", str(filter)]
    if fields:
        if "fields" not in has:
            raise ValueError(f"{command} takes no fields.")
        args += ["-f", ",".join(fields) if isinstance(fields, list) else str(fields)]
    return args


def tally(lines, most=8):
    """{field: {value: rows}} over every row, for scalar fields with at most `most` values."""
    counts = {}
    for line in lines:
        for key, value in json.loads(line).items():
            if not isinstance(value, (dict, list)):
                value = value if isinstance(value, str) else json.dumps(value)   # 2 -> "2", true -> "true"
                counts.setdefault(key, Counter())[value] += 1
    # Two to `most` values: one value is in the sample already, and ids or names tell nothing counted.
    return {k: dict(c.most_common()) for k, c in counts.items() if 1 < len(c) <= most}


def command_notes(command):
    """The Notes block of `elm COMMAND --info`: what live testing found."""
    proc = subprocess.run(ELM_CMD + [command, "--info"], capture_output=True, text=True, timeout=60)
    if proc.returncode != 0 or "\nNotes" not in proc.stdout:
        return ""
    notes = proc.stdout.split("\nNotes", 1)[1].split("\nFields (", 1)[0]
    return "Notes" + notes.rstrip()


class Refused(Exception):
    """elm failed or refused the query: (text for the model, step event)."""


def fetch(command, filter=None, fields=None, size=0, offset=0, params=None, total=False):
    """Run one elm query; return (jsonl lines, stderr, removed, shown), or the -C value for total.

    The lines are redacted, so neither the model, jq nor the page sees a
    secret; the caller stores them with session.add. Raises Refused on failure.
    """
    args = build_elm_args(command, filter, fields, size, offset, params, total)
    # Shell-quoted, so the page can offer the queries as a script to paste and rerun.
    shown = "elm " + shlex.join(args)
    # --halt-on-api-error: without it a failed request (a TLS proxy's CA
    # rejected, a 403) prints an error and exits 0 with no rows, which read as
    # "no device web02" inside one machine's container (2026-10-30).
    proc = subprocess.run(ELM_CMD + global_args() + ["--halt-on-api-error"] + args,
                          capture_output=True, text=True, timeout=300)
    stderr = proc.stderr.strip()
    if proc.returncode != 0:
        step = {"type": "step", "command": shown, "result": f"failed: {why_failed(stderr)}"}
        if proc.returncode == 3:
            # elm's own message asks an assistant to show the command and names
            # the profile's file, for someone at a terminal. Samara's reader has
            # neither, and a small model pasted both into answers (qwen3-8b,
            # 2026-10-29).
            raise Refused(f"{command} is not allowed for this profile; no request was sent. Tell the person, "
                          f"in plain words, that this tool cannot see that information, and that an "
                          f"administrator would have to allow {command}. Show no commands and no file paths.", step)
        raise Refused(f"elm failed (exit {proc.returncode}):\n{truncate(stderr, 3000)}", step)

    unknown = [line for line in stderr.splitlines() if "Warning: unknown field" in line or "Warning: no row has" in line]
    if unknown:
        # Refused, not warned: LM sent back no such field (elm refuses most
        # before sending), or a field only other kinds of record have. A small
        # model read past the warning and told the reader the data was missing
        # (qwen3-8b, 2026-10-28); a refusal makes it ask again with a real name.
        step = {"type": "step", "command": shown, "result": "failed"}
        raise Refused(f"Refused, nothing saved: {command}: {'; '.join(u.split('Warning: ', 1)[1] for u in unknown)}. "
                      f"Ask again with fields these records have (describe_command {command} lists them).", step)
    if total:
        return proc.stdout.strip(), stderr, 0, shown

    lines, removed = [], 0
    for line in proc.stdout.splitlines():
        if line.strip():
            row, n = redact(json.loads(line))
            removed += n
            lines.append(json.dumps(row))
    return lines, stderr, removed, shown


def why_failed(stderr):
    """elm's reason for a failed request, in one line, for the page and the answer.

    The model alone was told, and passed it on as "a connection issue"
    (gpt-oss-20b, 2026-10-30), which left nothing to act on.
    """
    lines = [line.split(":", 2)[-1].strip() if line.startswith(("ERROR:", "WARNING:")) else line.strip()
             for line in stderr.splitlines() if line.strip()]
    keep = [line for line in lines if re.search(
        r"Request failed|HTTP error|Response:|not JSON|certificate|SSL|not allowed|Error:", line)
        and line != "Error: request failed"]
    def short(line):
        # The query is already shown, so drop its URL; keep requests' "Caused by",
        # the part that says why (it came after the URL and was cut off, 2026-10-30).
        line = re.sub(r"^(?:ERROR|WARNING) \S+ \S+ \S+ \S+ ", "", line)   # elm's log prefix
        line = re.sub(r" for url: \S+|Max retries exceeded with url: \S+ ?", "", line)
        cause = re.search(r"\(Caused by (.*)\)\s*$", line)
        return f"Request failed: {cause.group(1)}" if cause else line
    reason = " · ".join(dict.fromkeys(short(line) for line in keep or lines[-1:])) or "no message"
    return reason if len(reason) <= 500 else reason[:499] + "…"


def run_elm(session, command, filter=None, fields=None, size=0, offset=0, params=None, total=False):
    """Run one read-only elm query and store the rows as a dataset.

    The first use of a command in a conversation comes back with that command's
    verified notes attached, whether or not describe_command was called: a model
    that skips the lookup still cannot miss "-C gives no real total here".
    """
    try:
        lines, stderr, removed, shown = fetch(command, filter, fields, size, offset, params, total)
    except Refused as exc:
        return exc.args

    if total:
        value = lines
        step = {"type": "step", "command": shown, "result": f"total {value}"}
        text = f"LM reports a total of {value} matching records."
        if not value.lstrip("-").isdigit():
            # e.g. ">50": this endpoint has no real total, so the number is a floor.
            text = (f"{command} returned {value!r}, not a real total: this endpoint does not give one. "
                    f"That is a lower bound, not the answer. Count the rows instead: run_elm with "
                    f"size 0 (add offset to page past 1000) and count what comes back.")
        return session.with_notes(command, text), step

    ds_id = session.add(lines, f"{command} filter={filter or '-'}", command)
    lines = session.model_lines(ds_id)   # from here on, what the model may read
    rows, sample_chars = [], 0
    for line in lines[:SAMPLE_ROWS]:   # keep the sample small enough to stay valid JSON after truncate()
        if rows and sample_chars + len(line) > MAX_SAMPLE_CHARS:
            break
        rows.append(json.loads(line))
        sample_chars += len(line)
    field_names = sorted({k for line in lines[:200] for k in json.loads(line)})
    limit = size or MAX_ROWS
    result = {
        "dataset": ds_id,
        "rows": len(lines),
        "may_have_more": len(lines) >= limit,
        "fields": field_names,
        "sample": rows,
    }
    if len(lines) > len(rows):
        # A small model reads the sample as the whole result: "all warnings"
        # from 5 of 15 alerts, "no device has alerting disabled" from 5 of
        # 1000 (qwen3-8b, 2026-10-29). Counts of the few-valued fields over
        # every row answer most "how many by X" questions without jq.
        result["sample_note"] = (f"The sample is {len(rows)} of {len(lines)} rows. Count, list or check "
                                 f"rows with jq on ${ds_id}, never from the sample. counts cover these {len(lines)} rows only.")
        counts = tally(lines)
        if counts:
            result["counts"] = counts
    if result["may_have_more"]:
        result["note"] = f"Hit the {limit}-row page limit; fetch the next page with offset={offset + limit}."
    if not lines and command == "DeviceList" and re.search(r"(^|,)name[:~]", filter or ""):
        result["note"] = ("name is the hostname or IP, not the name people use: "
                          "look the device up by displayName instead.")
    if stderr:
        # e.g. "results truncated" -- the query needs fixing (an unknown field is
        # refused above), and without this a gap looks like missing data.
        result["elm_warnings"] = truncate(stderr, 500)
    if removed:
        result["secrets_removed"] = f"{removed} secret-bearing or personal values were removed; request specific fields to avoid them."
    step = {"type": "step", "command": shown, "result": f"{len(lines)} rows", "dataset": ds_id}
    return session.with_notes(command, truncate(json.dumps(result, indent=1, default=str))), step


def describe_command(session, command):
    """The command's `elm COMMAND --info`: parameters, verified notes, examples and fields.

    Works for commands the profile withholds too: what a command would return is
    documentation, not portal data, and knowing it is what lets an answer say
    "AdminList carries lastLoginOn; ask for it to be allowed" instead of
    guessing that the API cannot do it at all.
    """
    if command not in COMMANDS:
        raise ValueError(f"Unknown command {command!r}. Use find_commands to look it up.")
    proc = subprocess.run(ELM_CMD + [command, "--info"], capture_output=True, text=True, timeout=60)
    if proc.returncode == 0 and proc.stdout.strip():
        return truncate(proc.stdout), None
    # Refused by allowed_commands: the same text is built into the definition file.
    info = COMMANDS[command].get("info")
    if info:
        return truncate(f"This profile does not allow running {command}, so it can only be described:\n\n{info}"), None
    raise ValueError(f"elm {command} --info failed: {proc.stderr.strip()[:500]}")


def _jq(session, expression, model=False):
    """Evaluate a jq expression with every dataset bound as $d1, $d2, ... (arrays).

    model: the output goes to the model, so read the copies with free text withheld.
    """
    args = ["jq", "-c", "-n"]
    for ds_id, ds in session.datasets.items():
        args += ["--slurpfile", ds_id, str(ds["model_path" if model else "path"])]
    args.append(expression)
    # Nearly empty environment: jq's $ENV must not expose API keys to the model.
    # TZ is the reader's zone, so strflocaltime gives their local time.
    env = {"PATH": os.environ.get("PATH", "")}
    tz = session.tz or usable_tz(os.environ.get("TZ"))
    if tz:
        env["TZ"] = tz
    proc = subprocess.run(args, capture_output=True, text=True, timeout=60, env=env)
    if proc.returncode != 0:
        raise ValueError(f"jq error: {proc.stderr.strip()}{jq_hint(expression, proc.stderr)}")
    return proc.stdout


def jq_hint(expression, stderr):
    """What a jq error usually means here. qwen3-8b sent 16 broken expressions
    in a row, each with `.d1` for $d1 or `sort_by(-count)` for -.count, then
    made the answer up (2026-10-29)."""
    hints = []
    if re.search(r"(?<![\w$])\.?d\d+\b", expression):
        hints.append("datasets are jq variables: write $d1, not .d1 or d1")
    word = re.search(r"error: (\w+)/0 is not defined", stderr)
    if word and not re.fullmatch(r"d\d+", word[1]):
        hints.append(f"a bare word like {word[1]} is a function call in jq; a field is .{word[1]}")
    return "\nHint: " + "; ".join(hints) if hints else ""


def run_jq(session, expression):
    """Filter, join, count or reshape stored datasets with jq."""
    out = _jq(session, expression, model=True)
    step = {"type": "step", "command": f"jq {expression}", "result": f"{len(out.splitlines())} line(s)",
            "expression": expression}
    return truncate(out or "(no output)"), step


def show_table(session, title, expression, columns):
    """Send a table to the user's screen (the model does not see the rows)."""
    # A table typed in by the model (jq -n '[{"Device": "x", ...}]') shows
    # whatever it wrote, not what the portal returned, and its rerun script
    # replays a snapshot. It must come from a fetched dataset.
    if not re.search(r"\$d\d+", expression):
        raise ValueError("Build the table from a fetched dataset ($d1, $d2 ...) with jq, "
                         "not from values written into the expression." + jq_hint(expression, ""))
    out = _jq(session, expression).strip()
    try:
        rows = json.loads(out) if out else []
    except json.JSONDecodeError:
        raise ValueError("expression must produce a single JSON array of objects (wrap it in [ ... ])")
    if not isinstance(rows, list) or (rows and not isinstance(rows[0], dict)):
        raise ValueError("expression must produce a JSON array of objects")
    table = {
        "type": "table",
        "title": title,
        "columns": columns,
        "rows": [[r.get(c) for c in columns] for r in rows[:MAX_TABLE_ROWS]],
        "total": len(rows),
        "expression": expression,
    }
    note = f"Showed a table of {len(rows)} rows to the user."
    if len(rows) > MAX_TABLE_ROWS:
        note += f" Only the first {MAX_TABLE_ROWS} are displayed."
    return note, table


HANDLERS = {
    "find_commands": find_commands,
    "describe_command": describe_command,
    "run_elm": run_elm,
    "jq": run_jq,
    "show_table": show_table,
}

TOOLS = [
    {
        "name": "find_commands",
        "description": "Search the elm command list (every command is a read-only LogicMonitor API GET). "
                       "Returns command names, summaries and required parameters.",
        "input_schema": {
            "type": "object",
            "properties": {"keyword": {"type": "string", "description": "Case-insensitive substring, e.g. 'alert', 'sdt', 'collector'"}},
            "required": ["keyword"],
        },
    },
    {
        "name": "describe_command",
        "description": "Look up one elm command before using it (runs `elm COMMAND --info`): its parameters, "
                       "verified notes and gotchas from live testing, example commands, and the documented "
                       "response fields with descriptions. "
                       "Use it to choose fields and filters for commands you have not used in this conversation.",
        "input_schema": {
            "type": "object",
            "properties": {"command": {"type": "string", "description": "elm command name, e.g. AlertList"}},
            "required": ["command"],
        },
    },
    {
        "name": "run_elm",
        "description": "Run a read-only elm query against LogicMonitor. Rows are stored as a dataset ($d1, $d2, ...) "
                       "usable in jq and show_table; you get back the row count, field names and a small sample. "
                       "Use fields to keep results small. With total=true, returns LM's total match count instead of rows.",
        "input_schema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "elm command name, e.g. DeviceList, AlertList"},
                "filter": {"type": "string", "description": "elm -F filter, e.g. 'cleared:false,severity:4'"},
                "fields": {"type": "array", "items": {"type": "string"}, "description": "Fields to return"},
                "size": {"type": "integer", "description": "Rows per page, 0-1000; 0 means up to 1000 (default)"},
                "offset": {"type": "integer", "description": "Paging offset (default 0)"},
                "params": {"type": "object", "description": "Command-specific parameters such as {\"deviceId\": 123}"},
                "total": {"type": "boolean", "description": "Return LM's total match count only (-C)"},
            },
            "required": ["command"],
        },
    },
    {
        "name": "jq",
        "description": "Run a jq expression (with -n) over the stored datasets, each bound as an array: $d1, $d2, ... "
                       "Use it to count, group, join datasets by id, and compare epochs with `now`.",
        "input_schema": {
            "type": "object",
            "properties": {"expression": {"type": "string"}},
            "required": ["expression"],
        },
    },
    {
        "name": "show_table",
        "description": "Display a table to the user. expression is a jq expression producing ONE JSON array of objects; "
                       "columns lists the object keys to show, in order. Use readable keys (e.g. 'Device', 'Started') "
                       "and convert epochs with todate in the expression. Build it from the datasets ($d1 ...), "
                       "never from values typed into the expression.",
        "input_schema": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "expression": {"type": "string"},
                "columns": {"type": "array", "items": {"type": "string"}},
            },
            "required": ["title", "expression", "columns"],
        },
    },
]
