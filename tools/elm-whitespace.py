#!/usr/bin/env python3
"""elm-whitespace: find names, descriptions and properties with a space at the start or end.

A value typed with a stray space ("NSW " for "NSW", " web01") looks right in
the portal but does not match: an AppliesTo, a filter or a report that asks
for "NSW" misses it. This checks every text field of every object it fetches,
and the name and value of each custom property, for whitespace at either end:
spaces, tabs, newlines, non-breaking spaces and zero-width characters.

Left out, as layout rather than typing: text that runs over several lines (a
script, a long description), whitespace at an end that includes a newline (LM
pads widget column labels that way), and two fields LM writes itself: a
user's lastAction, and a widget's unitLabel, which LM starts with a space
(" bytes").

Checked by default (COMMAND ... to choose):
  DeviceList DeviceGroupList WebsiteList WebsiteGroupList CollectorList
  CollectorGroupList AlertRuleList EscalationChainList RecipientGroupList
  DashboardList DashboardGroupList WidgetList ReportList ReportGroupList
  AdminList RoleList NetscanList

Properties: custom properties only. --all-properties adds system, auto and
inherited properties too; those are set by the collector or copied from a
group, so most are not yours to fix (a collector pads some disk sizes with
spaces), and an inherited one is already listed on the group that sets it.

A command the profile does not allow is skipped with a warning. Each command
is paged 1,000 at a time by id, so past LM's 10,000-row limit.

--files PATH ... reads saved records instead of asking LM: .json (one record,
a list of them, or elm -f json output), .jsonl and .xml (a LogicModule
export), and every such file under a directory. The first column is then the
file.

Output: tab-separated on stdout (command, id, name, field, where, value), the
value in JSON quotes so the space shows: "NSW ". --jsonl gives one record per
line instead. Progress and warnings go to stderr.

Examples:
  elm-whitespace.py
  elm-whitespace.py -p portal01 DeviceList DeviceGroupList
  elm-whitespace.py -p portal01 | grep -i company
  elm-whitespace.py --jsonl | jq -r .field | sort | uniq -c
  elm-whitespace.py --files ~/backups/devices ~/backups/devicegroups

Requires: elm
"""

import argparse
import json
import pathlib
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

PAGE = 1000
COMMANDS = ["DeviceList", "DeviceGroupList", "WebsiteList", "WebsiteGroupList", "CollectorList",
            "CollectorGroupList", "AlertRuleList", "EscalationChainList", "RecipientGroupList",
            "DashboardList", "DashboardGroupList", "WidgetList", "ReportList", "ReportGroupList",
            "AdminList", "RoleList", "NetscanList"]
OTHER_PROPERTIES = ("systemProperties", "autoProperties", "inheritedProperties")
LABELS = ("displayName", "fullPath", "name", "title", "username", "userName")
ZERO_WIDTH = "\u200b\u200c\u200d\u2060\ufeff"   # str.strip() keeps these
LM_WRITES = {"lastAction", "unitLabel"}


class ElmError(Exception):
    pass


def err(*args, **kw):
    print(*args, file=sys.stderr, **kw)


def elm(target, command, *args):
    """Rows of `elm -f json COMMAND ARGS`, retrying a 429 with a growing wait."""
    cmd = ["elm", *target, "-f", "json", command, *args]
    for attempt in range(6):
        out = subprocess.run(cmd, capture_output=True, text=True)
        try:
            return json.loads(out.stdout)[command]
        except (ValueError, KeyError):
            pass
        if "no data found" in out.stderr:
            return []
        if "429" not in out.stderr:
            break
        time.sleep(5 * 2 ** attempt)
    said = (out.stderr.strip().splitlines() or ["no output"])[-1]
    raise ElmError(said)


def rows(target, command):
    """Every row of COMMAND, paged by id (LM stops offset paging at 10,000)."""
    last = -1
    while True:
        page = elm(target, command, "-F", f"id>{last}", "-S", "id", "-s", str(PAGE))
        yield from page
        if len(page) < PAGE:
            return
        last = page[-1]["id"]


def from_xml(el):
    """An element as plain data: its text alone, or a dict of attributes and children."""
    kids = list(el)
    if not kids and not el.attrib:
        return el.text or ""
    d = dict(el.attrib)
    if el.text and el.text.strip():
        d["text"] = el.text
    for kid in kids:
        value = from_xml(kid)
        if kid.tag in d:
            d[kid.tag] = (d[kid.tag] if isinstance(d[kid.tag], list) else [d[kid.tag]]) + [value]
        else:
            d[kid.tag] = value
    return d


def records(path):
    """The records saved in one file."""
    if path.suffix == ".xml":
        root = ET.parse(path).getroot()
        named = root.find(".//name")
        return [{"name": named.text if named is not None else path.stem, root.tag: from_xml(root)}]
    text = path.read_text(encoding="utf-8")
    try:
        data = json.loads(text)
    except ValueError:
        return [json.loads(line) for line in text.splitlines() if line.strip()]
    if isinstance(data, dict) and len(data) == 1 and isinstance(next(iter(data.values())), list):
        data = next(iter(data.values()))   # elm -f json: {"DeviceList": [...]}
    elif isinstance(data, dict) and isinstance(data.get("items"), list):
        data = data["items"]
    return data if isinstance(data, list) else [data]


def files(paths):
    """(file, records) for each .json, .jsonl and .xml file in PATHS, directories searched."""
    for arg in paths:
        top = pathlib.Path(arg).expanduser()
        found = sorted(f for f in top.rglob("*") if f.suffix in (".json", ".jsonl", ".xml")) if top.is_dir() else [top]
        for f in found:
            try:
                yield str(f), records(f)
            except (OSError, ValueError, ET.ParseError) as e:
                err(f"{f}: skipped: {e}")


def strip(text):
    return text.strip().strip(ZERO_WIDTH).strip()


def where(text):
    """'start', 'end', 'both' or 'only' for whitespace at the ends of TEXT, else None."""
    if not isinstance(text, str) or not text:
        return None
    bare = strip(text)
    if bare == text or "\n" in bare:
        return None
    if not bare:
        return None if "\n" in text else "only"
    i = text.index(bare)
    head, tail = text[:i], text[i + len(bare):]
    if "\n" in head + tail:
        return None
    start, end = bool(head), bool(tail)
    return "both" if start and end else "start" if start else "end"


def is_property_list(value):
    return (isinstance(value, list) and value
            and all(isinstance(p, dict) and "name" in p and "value" in p for p in value))


def walk(value, path, skip):
    """(field, part, text) for each string in VALUE: part is 'name', 'value' or ''."""
    if isinstance(value, str):
        yield path, "", value
    elif isinstance(value, dict):
        for key, sub in value.items():
            if key in skip or key in LM_WRITES:
                continue
            yield from walk(sub, f"{path}.{key}" if path else key, skip)
    elif is_property_list(value):
        for p in value:
            field = f"{path}[{p['name']}]"
            yield field, "name", p["name"]
            yield from ((f, part or "value", t) for f, part, t in walk(p["value"], field, skip))
    elif isinstance(value, list):
        for i, sub in enumerate(value):
            yield from walk(sub, f"{path}[{i}]", skip)


def label(row):
    for key in LABELS:
        if isinstance(row.get(key), str) and row[key]:
            return row[key]
    return ""


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("commands", nargs="*", metavar="COMMAND",
                   help="elm list commands to check (default: the list above); with --files, files and directories")
    p.add_argument("-p", "--profile", default="config", help="elm profile (default: config)")
    p.add_argument("-c", "--config", metavar="PATH", help="elm config file, instead of --profile")
    p.add_argument("--all-properties", action="store_true",
                   help="check system, auto and inherited properties too")
    p.add_argument("--files", action="store_true", help="read saved .json, .jsonl and .xml files instead of asking LM")
    p.add_argument("--jsonl", action="store_true", help="one JSON record per finding instead of tab-separated")
    a = p.parse_args()
    if a.files and not a.commands:
        p.error("--files needs a file or directory")
    target = ["--config", a.config] if a.config else ["--profile", a.profile]
    skip = set() if a.all_properties else set(OTHER_PROPERTIES)

    found = 0
    if not a.jsonl:
        print(("file" if a.files else "command") + "\tid\tname\tfield\twhere\tvalue")
    if a.files:
        sources = ((f, iter(rs)) for f, rs in files(a.commands))
    else:
        sources = ((c, rows(target, c)) for c in a.commands or COMMANDS)
    per_file = 0
    for command, source in sources:
        seen = hits = 0
        try:
            for row in source:
                if not isinstance(row, dict):
                    continue
                seen += 1
                for field, part, text in walk(row, "", skip):
                    at = where(text)
                    if not at:
                        continue
                    hits += 1
                    rec = {"file" if a.files else "command": command, "id": row.get("id"), "name": label(row),
                           "field": field + (" (name)" if part == "name" else ""), "where": at, "value": text}
                    if a.jsonl:
                        print(json.dumps(rec), flush=True)
                    else:
                        print("\t".join([command, "" if rec["id"] is None else str(rec["id"]), rec["name"].replace("\t", " "),
                                         rec["field"], at, json.dumps(text)]), flush=True)
        except ElmError as e:
            err(f"{command}: skipped: {e}")
            continue
        found += hits
        per_file += 1
        if not a.files or hits:
            err(f"{command}: {seen} checked, {hits} found")
    err(f"{found} found" + (f" in {per_file} files" if a.files else ""))


if __name__ == "__main__":
    main()
