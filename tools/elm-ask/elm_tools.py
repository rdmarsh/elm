"""Read-only LogicMonitor tools for elm-ask, built on the elm CLI.

Every LM call goes through elm, and elm only ever sends GET requests (the
Makefile generates commands from the swagger "get" operations only). On top of
that, this module only lets the model choose a command name, a filter, fields,
paging and the command's own documented parameters -- never global flags such
as -f api/curl/wget, which would print the signed Authorization header.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


ELM_HOME = Path(os.environ.get("ELM_HOME", Path(__file__).resolve().parents[2]))
ELM_CMD = [sys.executable, str(ELM_HOME / "elm.py")]
# elm-ask runs as its own profile, `ai`, not the default `config`: the person
# has to create it on purpose (from ai.example.ini), so a powerful everyday
# token is never the one the assistant uses by accident. The model cannot
# change these; only whoever starts elm-ask can.
ELM_PROFILE = os.environ.get("ELM_PROFILE") or "ai"   # --profile NAME
ELM_CONFIG = os.environ.get("ELM_CONFIG")             # --config PATH (wins over profile)
# Refuse to answer with a profile that has no allowed_commands, unless this is set.
ALLOW_UNRESTRICTED = os.environ.get("ELM_ASK_ALLOW_UNRESTRICTED") == "1"
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
# Property lists (customProperties, systemProperties, ...) hold {name, value}.
# LM already masks credential properties as ******** (verified with a read-only
# token); mask any credential-like name it did not. Not "auth": snmp.auth is the
# SNMPv3 auth protocol (SHA, MD5), not a secret.
SECRET_PROPERTY_NAME = re.compile(r"pass|secret|community|token|accesskey|privatekey|apikey", re.I)
LM_MASK = re.compile(r"^\*+$")
REDACTED = "[removed by elm-ask]"


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
    """Return (value with secret fields removed or masked, number of changes)."""
    changes = 0
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            if key in SECRET_FIELDS:
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


class Session:
    """Datasets fetched during one conversation, kept as jsonl files for jq."""

    def __init__(self):
        self.dir = tempfile.TemporaryDirectory(prefix="elm-ask-")
        self.datasets = {}   # id -> {"path", "rows", "description"}
        self.described = set()   # commands whose notes have been sent already

    def with_notes(self, command, text):
        """Attach a command's verified notes the first time it is used here."""
        if command in self.described:
            return text
        self.described.add(command)
        notes = command_notes(command)
        return f"{text}\n\n{notes}" if notes else text

    def add(self, lines, description):
        """Store jsonl lines as a new dataset and return its id."""
        ds_id = f"d{len(self.datasets) + 1}"
        path = Path(self.dir.name) / f"{ds_id}.jsonl"
        path.write_text("".join(line + "\n" for line in lines))
        self.datasets[ds_id] = {"path": path, "rows": len(lines), "description": description}
        return ds_id

    def close(self):
        self.dir.cleanup()


# ---------------------------------------------------------------------------
# Tool implementations. Each returns (text_for_model, ui_event_or_None).
# ---------------------------------------------------------------------------

def profile_status():
    """Whether the profile exists and is restricted, and what it allows.

    Returns {"name", "exists", "restricted", "allowed", "problem"}; problem is
    None when elm-ask may answer questions with this profile.
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

    account = ""
    try:
        from configobj import ConfigObj
        path = ELM_CONFIG or os.path.expanduser(f"~/.config/logicmonitor/credentials/{name}.ini")
        # Only the account name: the id and key in this file are never read.
        account = str(ConfigObj(path, unrepr=True).get("account_name") or "")
    except Exception:
        pass

    problem = None
    if help_text.returncode != 0:
        problem = f"elm cannot read the profile: {help_text.stderr.strip()[:300]}"
    elif not exists:
        problem = (f"Profile '{name}' not found. Create ~/.config/logicmonitor/credentials/{name}.ini from "
                   f"ai.example.ini, with a read-only API token.")
    elif not restricted and not ALLOW_UNRESTRICTED:
        problem = (f"Profile '{name}' has no allowed_commands, so it can run every command. Add allowed_commands "
                   f"(see ai.example.ini), or set ELM_ASK_ALLOW_UNRESTRICTED=1 to use it anyway.")
    return {"name": name, "account": account, "exists": exists, "restricted": restricted,
            "allowed": sorted(allowed), "problem": problem}


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
        raise ValueError(f"{command} requires: {missing}")
    size = int(size)
    if not 0 <= size <= MAX_ROWS:
        raise ValueError("size must be 0-1000 (0 means up to 1000)")

    args = ["-f", "jsonl", command]
    for name, value in params.items():
        args += [f"--{name}", str(value)]
    if total:
        args += ["-C"]
    else:
        args += ["-s", str(size), "-o", str(int(offset))]
    if filter:
        args += ["-F", str(filter)]
    if fields:
        args += ["-f", ",".join(fields) if isinstance(fields, list) else str(fields)]
    return args


def command_notes(command):
    """The Notes block of `elm COMMAND --info`: what live testing found."""
    proc = subprocess.run(ELM_CMD + [command, "--info"], capture_output=True, text=True, timeout=60)
    if proc.returncode != 0 or "\nNotes" not in proc.stdout:
        return ""
    notes = proc.stdout.split("\nNotes", 1)[1].split("\nFields (", 1)[0]
    return "Notes" + notes.rstrip()


def run_elm(session, command, filter=None, fields=None, size=0, offset=0, params=None, total=False):
    """Run one read-only elm query and store the rows as a dataset.

    The first use of a command in a conversation comes back with that command's
    verified notes attached, whether or not describe_command was called: a model
    that skips the lookup still cannot miss "-C gives no real total here".
    """
    args = build_elm_args(command, filter, fields, size, offset, params, total)
    shown = "elm " + " ".join(a if re.fullmatch(r"[\w.,:/-]+", a) else repr(a) for a in args)
    proc = subprocess.run(ELM_CMD + global_args() + args, capture_output=True, text=True, timeout=300)
    stderr = proc.stderr.strip()
    if proc.returncode != 0:
        step = {"type": "step", "command": shown, "result": "failed"}
        return f"elm failed (exit {proc.returncode}):\n{truncate(stderr, 3000)}", step

    if total:
        value = proc.stdout.strip()
        step = {"type": "step", "command": shown, "result": f"total {value}"}
        text = f"LM reports a total of {value} matching records."
        if not value.lstrip("-").isdigit():
            # e.g. ">50": this endpoint has no real total, so the number is a floor.
            text = (f"{command} returned {value!r}, not a real total: this endpoint does not give one. "
                    f"That is a lower bound, not the answer. Count the rows instead: run_elm with "
                    f"size 0 (add offset to page past 1000) and count what comes back.")
        return session.with_notes(command, text), step

    lines, removed = [], 0
    for line in proc.stdout.splitlines():
        if line.strip():
            row, n = redact(json.loads(line))
            removed += n
            lines.append(json.dumps(row))
    ds_id = session.add(lines, f"{command} filter={filter or '-'}")
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
    if result["may_have_more"]:
        result["note"] = f"Hit the {limit}-row page limit; fetch the next page with offset={offset + limit}."
    if stderr:
        # e.g. "unknown field: uptime" -- the query needs fixing, and without this
        # an empty column looks like missing data rather than a wrong field name.
        result["elm_warnings"] = truncate(stderr, 500)
    if removed:
        result["secrets_removed"] = f"{removed} secret-bearing values were removed; request specific fields to avoid them."
    step = {"type": "step", "command": shown, "result": f"{len(lines)} rows as ${ds_id}"}
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


def _jq(session, expression):
    """Evaluate a jq expression with every dataset bound as $d1, $d2, ... (arrays)."""
    args = ["jq", "-c", "-n"]
    for ds_id, ds in session.datasets.items():
        args += ["--slurpfile", ds_id, str(ds["path"])]
    args.append(expression)
    # Empty environment: jq's $ENV must not expose API keys to the model.
    proc = subprocess.run(args, capture_output=True, text=True, timeout=60, env={"PATH": os.environ.get("PATH", "")})
    if proc.returncode != 0:
        raise ValueError(f"jq error: {proc.stderr.strip()}")
    return proc.stdout


def run_jq(session, expression):
    """Filter, join, count or reshape stored datasets with jq."""
    out = _jq(session, expression)
    step = {"type": "step", "command": f"jq {expression}", "result": f"{len(out.splitlines())} line(s)"}
    return truncate(out or "(no output)"), step


def show_table(session, title, expression, columns):
    """Send a table to the user's screen (the model does not see the rows)."""
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
                       "and convert epochs with todate in the expression.",
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
