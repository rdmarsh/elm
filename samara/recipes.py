"""Recipes: checked answers to the questions people ask most (recipes.yaml).

A small local model gets these wrong when it plans the queries itself: it
looked devices up by hostname, read counts off a 5-row sample and made up
whole tables (qwen3-8b, 2026-10-29). A recipe fixes the queries, counts in
jq and writes the summary from the data, so the model only has to pick the
recipe, pass the name it was asked about, and repeat what comes back.

Recipes are written and checked against a portal with a bigger model and
elm (see samara/questions.md); the model running Samara cannot change them.

recipes.yaml, one entry per recipe:
  name, asks    the recipe's name and the questions it answers
  covers        what it answers, in a few words, shown under the answer: a
                near-miss recipe answering a different question ("this week"
                answered as "now") then says so
  params        lookups, run first: device or group, found by name
  many          a lookup that may match several (find_device): no "which one?"
  steps         elm queries, each saved as `$<as>` for the jq below. Filters
                and params are str.format templates over the lookups
                ({device[id]}); `size: all` pages past 1000 rows; `when` is a
                jq test that skips the step when false; `each` is jq giving a
                list: the step runs once per item ({row[id]}, at most MAX_EACH)
                and every result row carries its item as `of`
  summary       jq giving the answer's text
  table_only    the rows hold free text (properties): the model is not told
                where they are, so planted text reaches only the reader
  table         {title, columns, rows}: jq giving the rows; shown on the page
"""

import json
import re
from pathlib import Path

import yaml

import elm_tools

HERE = Path(__file__).resolve().parent
RECIPES = {r["name"]: r for r in yaml.safe_load((HERE / "recipes.yaml").read_text())}
MAX_PAGES = 10   # LM stops paging at 10,000 rows
MAX_EACH = 10    # an `each` step's queries, one per item

# Defined in front of every recipe expression. Times are the reader's (jq
# runs in their timezone); SDT times are milliseconds, so divide first.
PRELUDE = r"""
def sev: {"2": "warning", "3": "error", "4": "critical"}[tostring] // tostring;
def when: strflocaltime("%d %b %Y, %H:%M %Z");
def ago: ((. - now) / 86400) as $d | ($d | fabs | round | if . < 1 then 1 else . end) as $n
  | "\($n) day\(if $n == 1 then "" else "s" end)" as $span
  | if $d >= 1 then "in about \($span)" elif $d > 0 then "within a day"
    elif $d > -1 then "less than a day ago" else "\($span) ago" end;
def at: "\(when), \(ago)";
def n($word): "\(.) \($word)\(if . == 1 then "" else "s" end)";
def severities: (map(.severity | sev) | group_by(.) | map({key: .[0], value: length}) | from_entries) as $c
  | [("critical", "error", "warning") as $s | select($c[$s]) | "\($c[$s]) \($s)"] | join(", ");
def kind: {"0": "device", "2": "AWS resource", "4": "Azure resource", "6": "service", "7": "GCP resource",
  "8": "Kubernetes resource", "9": "push-metrics device", "11": "synthetic check",
  "18": "synthetic check"}[tostring] // "type \(.)";
def updown: {"normal": "up", "dead": "not responding",
  "dead-collector": "not being monitored: its collector is down"}[.] // .;
def state: {"normal": "up", "dead": "not responding", "dead-collector": "collector down"}[.] // .;   # for tables
def ver: tostring | "\(.[:-3]).\(.[-3:])";   # collector build "41100" -> 41.100
def disabled_by: [["a group", "its own setting", "some instances"], split("-")] | transpose
  | map(select(.[1] == "disable") | .[0]);   # alertDisableStatus is <group>-<device>-<instance>
"""

# How a name the person typed becomes one record: exact display name, then
# part of it, then part of the hostname or IP (for "is 203.0.113.7 monitored?").
LOOKUPS = {
    "device": ("DeviceList", ['displayName:"{}"', 'displayName~"{}"', 'name~"{}"'],
               ["id", "displayName", "name", "hostStatus", "sdtStatus", "alertDisableStatus",
                "currentCollectorId", "collectorDescription", "deviceType"]),
    # A path ("/Customers/acme") is matched as fullPath, which has no leading
    # slash; ~ ignores case, for "/customers/ACME/".
    "group": ("DeviceGroupList", ['name:"{}"', 'fullPath:"{}"', 'fullPath~"{}"', 'name~"{}"'],
              ["id", "name", "fullPath", "numOfHosts", "groupStatus"]),
    # Collector names are usually DOMAIN\HOST or an FQDN, so a bare host name
    # needs the contains filters. A number is its id ("collector 281").
    "collector": ("CollectorList", ['id:{}', 'description:"{}"', 'hostname:"{}"', 'description~"{}"', 'hostname~"{}"'],
                  ["id", "description", "hostname", "isDown", "inSDT", "collectorGroupName", "collectorDeviceId",
                   "numberOfHosts", "backupAgentId", "build", "upTime", "watchdogUpdatedOn"]),
}


def taking(param):
    """The recipes that take this lookup (device, group), or none (the whole portal)."""
    return [name for name, r in RECIPES.items() if r.get("params", [None])[0] == param]


def tool_description():
    def listed(names):
        return "\n".join(f"- {name}: {'; '.join(RECIPES[name]['asks'])}" for name in names)
    return ("Checked answers to the questions people ask most: the queries, the counting and the summary are "
            "already worked out, so the numbers are right. If one of these fits the question, use it first, "
            "before run_elm.\n\nAbout one device (pass device):\n" + listed(taking("device"))
            + "\n\nAbout one group (pass group):\n" + listed(taking("group"))
            + "\n\nAbout one collector (pass collector):\n" + listed(taking("collector"))
            + "\n\nAbout the whole portal (pass no name):\n" + listed(taking(None)))


def fetch_all(command, **kw):
    """Every row, a page of 1000 at a time; (lines, shown, cut).

    shown is the first page's command. cut is None when every row came back,
    else what is known of the real total: LM stops paging at 10,000 rows with
    no error, and the last page can fall a little short, so reaching the last
    page means the rows may be cut short. -C says by how much (AlertList gives
    only ">N"), or that nothing was cut after all.
    """
    lines, shown = [], None
    for page in range(MAX_PAGES):
        got, _, _, cmd = elm_tools.fetch(command, size=0, offset=page * elm_tools.MAX_ROWS, **kw)
        lines += got
        shown = shown or cmd
        if len(got) < elm_tools.MAX_ROWS and page < MAX_PAGES - 1:
            return lines, shown, None
    total = elm_tools.fetch(command, total=True, filter=kw.get("filter"), params=kw.get("params"))[0]
    return lines, shown, None if total == str(len(lines)) else total


def run_recipe(session, recipe, device=None, group=None, collector=None):
    """Run one recipe; return (text for the model, [step and table events])."""
    r = RECIPES.get(recipe)
    if not r:
        raise ValueError(f"No recipe {recipe!r}. Recipes: {', '.join(RECIPES)}")
    given = {"device": device, "group": group, "collector": collector}
    for param, value in given.items():
        if value and param not in r.get("params", []):
            # A small model asked about one device's downtime ran the portal's
            # and reported every SDT as the device's (qwen3-8b, 2026-10-29).
            return (f"Not run: {recipe} is not about one {param}, so it cannot answer a question about {value}. "
                    f"Use one of these with {param}={value!r}: {', '.join(taking(param))}; "
                    f"or, if none fits, run_elm."), []
    names, records, events = {}, {}, []   # names: step name -> dataset id
    cut, skipped = [], set()   # steps LM's 10,000-row limit cut short; steps whose `when` was false

    def keep(name, lines, shown, what, command):
        ds_id = session.add(lines, f"recipe {recipe}: {what}", command)
        names[name] = ds_id
        events.append({"type": "step", "command": shown, "result": f"{len(lines)} rows", "dataset": ds_id})

    def jq(expression):
        # $device -> $d3: the page's rerun script binds datasets by id.
        for name, ds_id in names.items():
            expression = re.sub(rf"\${name}\b", f"${ds_id}", expression)
        return PRELUDE + expression

    try:
        for param in r.get("params", []):
            value = (given.get(param) or "").strip()
            if not value or '"' in value:
                raise ValueError(f"Recipe {recipe} needs {param}: the name as the person wrote it, without quotes.")
            command, filters, fields = LOOKUPS[param]
            if param == "group":
                value = value.strip("/")
            if not value.isdigit():
                filters = [f for f in filters if not f.startswith("id:")]
            for f in filters:
                lines, _, _, shown = elm_tools.fetch(command, filter=f.format(value), fields=fields, size=20)
                if lines:
                    break
            keep(param, lines, shown, f"{param} {value}", command)
            found = [json.loads(line) for line in lines]
            if not found and param == "device":
                # "What's alerting in Customers/acme?" was looked up as a device
                # every time it lacked the word "group" (qwen3-8b, 2026-10-30).
                command, filters, fields = LOOKUPS["group"]
                for f in filters:
                    groups = elm_tools.fetch(command, filter=f.format(value.strip("/")), fields=fields, size=20)[0]
                    if groups:
                        paths = ", ".join(json.loads(line)["fullPath"] for line in groups)
                        return (f"No device has a name like {value!r}, but these groups do: {paths}. "
                                f"Use a group recipe with group={value!r}."), events
            if not found:
                # Shown as the answer and its How I worked this out, so the reader
                # sees what was looked for: a bare "couldn't find web01" from a
                # second machine said nothing about which name or portal (2026-10-30).
                how = {"device": "display name, then part of it, then hostname or IP",
                       "group": "name, then path, then part of either",
                       "collector": "id, then description, then hostname"}[param]
                # How many this profile sees at all: a token whose role hides a group
                # finds collectors but not that group's devices (a second machine's
                # ai.ini, 2026-10-30), and "not found" alone reads as "not monitored".
                try:
                    seen = elm_tools.fetch(LOOKUPS[param][0], total=True)[0]
                except elm_tools.Refused:
                    seen = ""
                where = elm_tools.portal() or "this portal"
                among = f" (this profile can see {seen} {param}s there)" if seen.isdigit() else ""
                events.append({"type": "worked", "lines": [f"Looked for a {param} named {value!r} by {how}: none found."]
                               + ([f"Counted the {param}s this profile can see: {seen}."] if seen.isdigit() else []),
                               "summary": f"No {param} in {where} has a name like {value!r}{among}.",
                               "covers": None})
                return f"No {param} has a name like {value!r}. Say so; do not guess another {param}.", events
            if len(found) > 1 and not r.get("many"):
                listed = ", ".join(d.get("displayName") or d.get("fullPath") or d.get("description") or d.get("name")
                                   for d in found)
                some = "At least " if len(found) == 20 else ""
                return (f"{some}{len(found)} {param}s have a name like {value!r}: {listed}. Ask which one "
                        f"is meant, then use the recipe again with its exact name."), events
            records[param] = found[0]

        for step in r.get("steps", []):
            if "when" in step and elm_tools._jq(session, jq(step["when"])).strip() != "true":
                names[step["as"]] = session.add([], f"recipe {recipe}: {step['as']} (skipped)")   # still bound for jq
                skipped.add(step["as"])
                continue
            if "each" in step:
                items = json.loads(elm_tools._jq(session, jq(step["each"])))[:MAX_EACH]
                lines, shown = [], f"{step['run']}: nothing to fetch"
                for i, row in enumerate(items):
                    params = {k: str(v).format(**records, row=row) for k, v in step.get("params", {}).items()}
                    got, _, _, one = elm_tools.fetch(step["run"], fields=step.get("fields"), params=params, size=0)
                    lines += [json.dumps(json.loads(line) | {"of": row}) for line in got]
                    shown = one if i == 0 else f"{shown.split('  # ')[0]}  # and {i} more like it"
                keep(step["as"], lines, shown, step["as"], step["run"])
                continue
            kw = {"filter": step["filter"].format(**records) if "filter" in step else None,
                  "fields": step.get("fields"),
                  "params": {k: str(v).format(**records) for k, v in step.get("params", {}).items()} or None}
            if step.get("size") == "all":
                lines, shown, total = fetch_all(step["run"], **kw)
                if total:
                    cut.append(f"{step['as']}: {len(lines)} rows, " +
                               ("possibly more" if total.startswith(">") else f"of {total}"))
            else:
                lines, _, _, shown = elm_tools.fetch(step["run"], size=step.get("size", 0), **kw)
            keep(step["as"], lines, shown, step["as"], step["run"])
    except elm_tools.Refused as exc:
        text, step = exc.args
        events.append(step)
        return f"The recipe could not run: {text}", events

    summary = json.loads(elm_tools._jq(session, jq(r["summary"])))
    if cut:
        # The counts are over the rows that came back, so they may be too low.
        summary = (f"Only part of the data could be fetched ({'; '.join(cut)}: LogicMonitor returns at most "
                   f"10,000 rows), so the counts below may be too low. {summary}")
    # Only the summary goes to the model. The table and How I worked this out
    # are Samara's: a small model copied instructions about them into its
    # answers word for word, and listed queries that never ran.
    text = f"Answer with this, keeping its facts and numbers exactly:\n\n{summary}\n\n"
    if r.get("covers"):
        text += (f"This recipe answers only: {r['covers']}. If the question asked for more (another time, "
                 f"place or measure), say what you could not check; add nothing else.\n\n")
    if r.get("table_only"):
        text += "The values are for the reader to read in the table, not for you: add nothing else."
    else:
        data = ", ".join(f"${ds_id} ({name})" for name, ds_id in names.items())
        text += (f"If the question asks something this does not cover, get it from the recipe's rows with jq "
                 f"({data}); add nothing else.")
    if "table" in r:
        t = r["table"]
        note, table = elm_tools.show_table(session, t["title"].format(**records), jq(t["rows"]), t["columns"])
        if table["total"]:
            events.append(table)
    worked = [f"Found the {p} by name." for p in r.get("params", [])]
    says = [step.get("says", step["as"]) for step in r.get("steps", []) if step["as"] not in skipped]
    worked += [line[:1].upper() + line[1:] + "." for line in says]
    events.append({"type": "worked", "lines": worked, "summary": summary, "covers": r.get("covers")})
    return text, events


# Registered with the other tools, first, so a model reading the list in
# order meets it before run_elm. Importing this module is what adds it.
elm_tools.HANDLERS["recipe"] = run_recipe
elm_tools.TOOLS.insert(0, {
    "name": "recipe",
    "description": tool_description(),
    "input_schema": {
        "type": "object",
        "properties": {
            "recipe": {"type": "string", "enum": list(RECIPES), "description": "The recipe's name"},
            "device": {"type": "string", "description": "For a device recipe: the device's name as the person wrote it"},
            "group": {"type": "string", "description": "For a group recipe: the group's name or path as the person wrote it"},
            "collector": {"type": "string", "description": "For a collector recipe: the collector's name or number as the person wrote it"},
        },
        "required": ["recipe"],
    },
})
