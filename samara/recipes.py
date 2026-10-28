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
  params        lookups, run first: device or group, found by name
  many          a lookup that may match several (find_device): no "which one?"
  steps         elm queries, each saved as `$<as>` for the jq below. Filters
                and params are str.format templates over the lookups
                ({device[id]}); `size: all` pages past 1000 rows; `when` is a
                jq test that skips the step when false
  summary       jq giving the answer's text
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
def disabled_by: [["a group", "its own setting", "some instances"], split("-")] | transpose
  | map(select(.[1] == "disable") | .[0]);   # alertDisableStatus is <group>-<device>-<instance>
"""

# How a name the person typed becomes one record: exact display name, then
# part of it, then part of the hostname or IP (for "is 203.0.113.7 monitored?").
LOOKUPS = {
    "device": ("DeviceList", ['displayName:"{}"', 'displayName~"{}"', 'name~"{}"'],
               ["id", "displayName", "name", "hostStatus", "sdtStatus", "alertDisableStatus",
                "currentCollectorId", "collectorDescription", "deviceType"]),
    "group": ("DeviceGroupList", ['name:"{}"', 'fullPath:"{}"', 'name~"{}"'],
              ["id", "name", "fullPath", "numOfHosts", "groupStatus"]),
}


def tool_description():
    lines = [f"- {name}{' (' + ', '.join(r['params']) + ')' if r.get('params') else ''}: {'; '.join(r['asks'])}"
             for name, r in RECIPES.items()]
    return ("Checked answers to the questions people ask most: the queries, the counting and the summary are "
            "already worked out, so the numbers are right. If one of these fits the question, use it first, "
            "before run_elm. Recipes:\n" + "\n".join(lines))


def fetch_all(command, **kw):
    """Every row, a page of 1000 at a time; (lines, shown) of the first page's command."""
    lines, shown = [], None
    for page in range(MAX_PAGES):
        got, _, _, cmd = elm_tools.fetch(command, size=0, offset=page * elm_tools.MAX_ROWS, **kw)
        lines += got
        shown = shown or cmd
        if len(got) < elm_tools.MAX_ROWS:
            break
    return lines, shown


def run_recipe(session, recipe, device=None, group=None):
    """Run one recipe; return (text for the model, [step and table events])."""
    r = RECIPES.get(recipe)
    if not r:
        raise ValueError(f"No recipe {recipe!r}. Recipes: {', '.join(RECIPES)}")
    given = {"device": device, "group": group}
    names, records, events = {}, {}, []   # names: step name -> dataset id

    def keep(name, lines, shown, what):
        ds_id = session.add(lines, f"recipe {recipe}: {what}")
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
            for f in filters:
                lines, _, _, shown = elm_tools.fetch(command, filter=f.format(value), fields=fields, size=20)
                if lines:
                    break
            keep(param, lines, shown, f"{param} {value}")
            found = [json.loads(line) for line in lines]
            if not found:
                return f"No {param} has a name like {value!r}. Say so; do not guess another {param}.", events
            if len(found) > 1 and not r.get("many"):
                listed = ", ".join(d.get("displayName") or d.get("fullPath") or d.get("name") for d in found)
                some = "At least " if len(found) == 20 else ""
                return (f"{some}{len(found)} {param}s have a name like {value!r}: {listed}. Ask which one "
                        f"is meant, then use the recipe again with its exact name."), events
            records[param] = found[0]

        for step in r.get("steps", []):
            if "when" in step and elm_tools._jq(session, jq(step["when"])).strip() != "true":
                names[step["as"]] = session.add([], f"recipe {recipe}: {step['as']} (skipped)")   # still bound for jq
                continue
            kw = {"filter": step["filter"].format(**records) if "filter" in step else None,
                  "fields": step.get("fields"),
                  "params": {k: str(v).format(**records) for k, v in step.get("params", {}).items()} or None}
            if step.get("size") == "all":
                lines, shown = fetch_all(step["run"], **kw)
            else:
                lines, _, _, shown = elm_tools.fetch(step["run"], size=step.get("size", 0), **kw)
            keep(step["as"], lines, shown, step["as"])
    except elm_tools.Refused as exc:
        text, step = exc.args
        events.append(step)
        return f"The recipe could not run: {text}", events

    summary = json.loads(elm_tools._jq(session, jq(r["summary"])))
    text = f"Lead with this, keeping its facts and numbers exactly:\n\n{summary}\n\n"
    if "table" in r:
        t = r["table"]
        note, table = elm_tools.show_table(session, t["title"].format(**records), jq(t["rows"]), t["columns"])
        if table["total"]:
            events.append(table)
            text += f"A table of {table['total']} rows is shown to the reader: do not write it out yourself.\n"
    worked = [f"found the {p} by name" for p in r.get("params", [])]
    worked += [step.get("says", step["as"]) for step in r.get("steps", []) if step["as"] in names]
    if worked:
        text += "Then a short How I worked this out, one line each: " + "; ".join(worked) + "."
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
            "group": {"type": "string", "description": "For a group recipe: the group's name as the person wrote it"},
        },
        "required": ["recipe"],
    },
})
