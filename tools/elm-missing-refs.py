#!/usr/bin/env python3
"""elm-missing-refs: dashboards, reports and alert rules that name a group or device that isn't there.

A widget, report or alert rule names its resources by group path and device
name, usually as globs ("Linux Servers/*", "web*"). Rename or delete the
group, or retire the device, and nothing complains: the widget goes blank,
the report comes out empty, the alert rule stops routing. This lists every
such name that matches nothing in the portal.

  dashboards  every widget's groups and devices, with the dashboard's tokens
              (##defaultResourceGroup##, ##defaultResourceName## ...) filled in
  reports     a report's groups and devices (hosts, metrics, SLA rows), and
              the dashboard a dashboard report prints
  rules       each alert rule's resource groups and resources

Each name is one of:

  no group     the group path (or glob) matches no group
  no device    the device name (or glob) matches no device's display name
               or hostname
  not in group the group and the device both exist, but no matching device
               is in a matching group or below it
  no token     a ##token## the dashboard doesn't set
  no dashboard the dashboard a report prints is gone

A missing group gets a "moved to?" guess: the groups (up to three) with the
same last name, which is where a moved group usually went.

Before removing a group, --group NAME|ID turns this round: every widget,
report and alert rule that names the group or one below it, by name or by a
glob that takes it in. A glob that takes in everything ("*") isn't listed:
removing one group doesn't break it. Then check the devices: a widget
naming only a device keeps working wherever the device goes.

A glob is matched the generous way (* crosses /, any case, !(...) matches
anything), so a name listed here really matches nothing; a few that LM would
also find empty may slip through. Tokens set on a single widget, not the
dashboard, aren't read: such a widget may show as "no token".

Run with no section for all three. Output: Markdown on stdout (--jsonl: one
record per missing name, for pipes); progress and errors on stderr. With
--portal NAME each dashboard and report name links to it in the portal
(jsonl: a "url" on each).

Examples:
  elm-missing-refs.py
  elm-missing-refs.py -p portal01 rules
  elm-missing-refs.py dashboards reports > missing.md
  elm-missing-refs.py --portal portal01 > missing.md    # names link to the portal
  elm-missing-refs.py --group "Servers/Old DC"      # before removing it
  elm-missing-refs.py --group 123 rules
  elm-missing-refs.py --jsonl | jq -r 'select(.problem == "no group") | .name' | sort -u

Requires: elm
"""

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.parse

PAGE = 1000
# Each dashboard and report in the portal's UI (checked by hand on a work
# portal, 2026-11-06). The REST API gives no UI link. Alert rules have no page
# of their own to link to: pass --url-template rules=URL if yours do.
URLS = {"dashboards": "https://{portal}.logicmonitor.com/santaba/uiv4/dashboards/dashboards-{id}",
        "reports": "https://{portal}.logicmonitor.com/santaba/uiv4/reports/treeNodes/reports-{id}"}
LINKED = {"dashboards": ("dashboard", "dashboard_id"), "reports": ("report", "report_id"), "rules": ("rule", "rule_id")}
SECTIONS = ["dashboards", "reports", "rules"]
# Keys that name a group, and the key beside them that names a device.
PAIRS = [("deviceGroupFullPath", "deviceDisplayName"), ("groupFullPath", "deviceDisplayName"),
         ("groupName", "deviceName"), ("hostGroup", "host")]
# Old and new names of the same dashboard token.
ALIASES = {"defaultdevicegroup": "defaultresourcegroup", "defaultdevicename": "defaultresourcename"}


class ElmError(Exception):
    pass


def err(*args, **kw):
    print(*args, file=sys.stderr, **kw)


def elm(target, key, *args):
    """Rows of `elm -f json ARGS`, retrying a 429 with a growing wait."""
    cmd = ["elm", *target, "-f", "json", *args]
    for attempt in range(6):
        out = subprocess.run(cmd, capture_output=True, text=True)
        try:
            return json.loads(out.stdout)[key]
        except (ValueError, KeyError):
            pass
        if "no data found" in out.stderr:
            return []
        if "429" not in out.stderr:
            break
        time.sleep(5 * 2 ** attempt)
    said = (out.stderr.strip().splitlines() or ["no output"])[-1]
    raise ElmError(f"{' '.join(args[:2])}: {said}")


def every(target, command, *args):
    """Every row, paged by id: offset paging stops at 10,000 rows with no error."""
    rows, last = [], -1
    while True:
        page = elm(target, command, command, "-F", f"id>{last}", "-S", "id", "-s", str(PAGE), *args)
        rows += page
        err(f"  {command}: {len(rows)}", end="\r")
        if len(page) < PAGE:
            err()
            return rows
        last = page[-1]["id"]


def glob(pattern):
    """An LM glob as a regex, matched generously: a miss is a real miss."""
    out, i = "", 0
    while i < len(pattern):
        c = pattern[i]
        if c == "*":
            out += ".*"
        elif c == "?":
            out += "."
        elif c == "!" and pattern[i + 1:i + 2] == "(":
            depth, j = 0, i + 1
            while j < len(pattern):
                depth += {"(": 1, ")": -1}.get(pattern[j], 0)
                if depth == 0:
                    break
                j += 1
            out, i = out + ".*", j
        elif c in "(|)":
            out += c
        elif c == "[":
            j = pattern.find("]", i + 1)
            out, i = (out + pattern[i:j + 1], j) if j > i else (out + r"\[", i)
        else:
            out += re.escape(c)
        i += 1
    try:
        return re.compile(out + r"\Z", re.I)
    except re.error:
        return re.compile(re.escape(pattern) + r"\Z", re.I)


def anything(pattern):
    return pattern is None or re.fullmatch(r"[*/.]*", pattern.strip()) is not None   # "", "*", "**", "*/*"


class Portal:
    def __init__(self, target):
        groups = every(target, "DeviceGroupList", "-f", "id,fullPath")
        self.paths = {g["id"]: g["fullPath"] or "" for g in groups}
        self.devices = []
        for d in every(target, "DeviceList", "-f", "id,displayName,name,hostGroupIds"):
            ids = [int(x) for x in str(d.get("hostGroupIds") or "").split(",") if x.strip().isdigit()]
            groups = [self.paths.get(i, "") for i in ids]
            self.devices += [(n, groups) for n in {d.get("displayName") or "", d.get("name") or ""} if n]

    def moved(self, group):
        """Groups with the same last name as a missing one: where it may have gone."""
        first = re.sub(r"^\((.*?)\|.*\)$", r"\1", group.strip())   # (A|A/*) -> A
        last = first.rstrip("*/").rsplit("/", 1)[-1]
        if not last or re.search(r"[(|)]", last):
            return ""
        g = glob(last)
        hits = sorted(p for p in self.paths.values() if g.match(p.rsplit("/", 1)[-1]))
        return ", ".join(hits) if len(hits) <= 3 else ""   # "All" is in every customer: no hint

    def find(self, group):
        """The path of a group given by id or full path, or None."""
        if group.strip().isdigit():
            return self.paths.get(int(group))
        path = group.strip().strip("/")
        return next((p for p in self.paths.values() if p.lower() == path.lower()), None)

    def uses(self, group, path):
        """How a group pattern takes in path or a group below it: by name, or by a glob.

        "*" and the like take in every group, so aren't counted: removing one
        group doesn't break them."""
        if anything(group):
            return []
        g = glob(group.strip())
        below = [p for p in self.paths.values() if p == path or p.startswith(path + "/")]
        hit = [p for p in below if g.match(p)]
        if not hit:
            return []
        if group.strip().lower() == path.lower():
            return [("names it", group, "")]
        if group.strip().lower().startswith(path.lower() + "/"):
            return [("names a subgroup", group, "")]
        return [("glob takes it in" if path in hit else "glob takes in a subgroup", group, "")]

    def check(self, group, device):
        """Problems with one group pattern and one device pattern (either may be None)."""
        groups = None
        if not anything(group):
            g = glob(group.strip())
            groups = [p for p in self.paths.values() if g.match(p)]
            if not groups:
                return [("no group", group, self.moved(group))]
        if anything(device):
            return []
        d = glob(device.strip())
        found = [paths for name, paths in self.devices if d.match(name)]   # display name or hostname
        if not found:
            return [("no device", device, "")]
        if groups is not None and not any(p == g or p.startswith(g + "/") for paths in found
                                          for p in paths for g in groups):
            return [("not in group", f"{device} in {group}", "")]
        return []


def pairs(obj):
    """(group, device) for every dict in obj that names one, LM's {value: ...} or a plain string."""
    if isinstance(obj, list):
        for v in obj:
            yield from pairs(v)
    elif isinstance(obj, dict):
        for gk, dk in PAIRS:
            if gk in obj or dk in obj:
                g, d = obj.get(gk), obj.get(dk)
                g, d = (x.get("value") if isinstance(x, dict) else x for x in (g, d))
                yield (g if isinstance(g, str) else None, d if isinstance(d, str) else None)
        for k, v in obj.items():
            if isinstance(v, (dict, list)):
                yield from pairs(v)


def fill(text, tokens):
    """text with the dashboard's ##tokens## filled in; the unset ones as a list."""
    unset = []

    def one(m):
        name = m.group(1).lower()
        value = tokens.get(ALIASES.get(name, name))
        if value is None:
            unset.append(m.group(0))
            return m.group(0)
        return value

    return re.sub(r"##(\w+)##", one, text or "") if text else text, unset


def dashboards(target, portal, uses=None):
    boards = {b["id"]: b for b in every(target, "DashboardList", "-f", "id,fullName,widgetTokens")}
    out = []
    for w in every(target, "WidgetList"):
        b = boards.get(w.get("dashboardId"))
        if not b:
            continue
        tokens = {}
        for t in b.get("widgetTokens") or []:
            name = str(t.get("name", "")).lower()
            tokens[ALIASES.get(name, name)] = str(t.get("value") or "")
        refs = list(pairs({k: v for k, v in w.items() if k not in ("filters", "parsedFilters")}))
        f = w.get("parsedFilters") or {}
        if f.get("group") or f.get("host"):
            refs.append(tuple(urllib.parse.unquote_plus(f.get(k) or "") or None for k in ("group", "host")))
        for group, device in dict.fromkeys(refs):
            (group, ug), (device, ud) = fill(group, tokens), fill(device, tokens)
            if uses:
                problems = portal.uses(group, uses)
            else:
                problems = [("no token", t, "") for t in dict.fromkeys(ug + ud)] or portal.check(group, device)
            for problem, name, hint in problems:
                out.append({"dashboard": b["fullName"], "dashboard_id": b["id"], "widget": w["name"],
                            "widget_id": w["id"], "problem": problem, "name": name, "moved": hint})
    return out


def reports(target, portal, dashboard_ids, uses=None):
    out = []
    for r in every(target, "ReportList"):
        refs = list(pairs(r))
        kind = r.get("hostsValType")
        for v in str(r.get("hostsVal") or "").split(","):
            refs.append((v, None) if kind == "group" else (None, v))
        for m in r.get("metrics") or []:
            if m.get("itemType") in ("group", "host"):
                refs.append((m.get("itemVal"), None) if m["itemType"] == "group" else (None, m.get("itemVal")))
        if uses:
            problems = [p for g, _ in dict.fromkeys(refs) for p in portal.uses(g, uses)]
        else:
            problems = [p for g, d in dict.fromkeys(refs) for p in portal.check(g, d)]
        if not uses and r.get("dashboardId") and r["dashboardId"] not in dashboard_ids:
            problems.append(("no dashboard", r.get("dashboardName") or str(r["dashboardId"]), ""))
        for problem, name, hint in dict.fromkeys(problems):
            out.append({"report": r["name"], "report_id": r["id"], "type": r.get("type"),
                        "problem": problem, "name": name, "moved": hint})
    return out


def rules(target, portal, uses=None):
    out = []
    for r in every(target, "AlertRuleList", "-f", "id,name,priority,deviceGroups,devices"):
        groups = [g for g in r.get("deviceGroups") or [] if g] or [None]
        devices = [d for d in r.get("devices") or [] if d] or [None]
        if uses:
            for problem, name, hint in dict.fromkeys(p for g in groups for p in portal.uses(g, uses)):
                out.append({"rule": r["name"], "rule_id": r["id"], "priority": r.get("priority"),
                            "problem": problem, "name": name, "moved": hint})
            continue
        problems = [p for g in groups for p in portal.check(g, None)]
        problems += [p for d in devices for p in portal.check(None, d)]
        # One rule matches a device in any of its groups: only say "not in group"
        # when no device it names is in any group it names.
        if not problems and groups != [None] and any(not anything(d) for d in devices):
            hits = [portal.check(g, d) for g in groups for d in devices]
            if all(hits):
                problems = [("not in group", f"{', '.join(devices)} in {', '.join(groups)}", "")]
        for problem, name, hint in dict.fromkeys(problems):
            out.append({"rule": r["name"], "rule_id": r["id"], "priority": r.get("priority"),
                        "problem": problem, "name": name, "moved": hint})
    return out


def table(title, rows, cols):
    def cell(text):
        return str(text).replace("|", "\\|").replace("\n", " ")

    def show(r, k):
        # The name links to the portal when there is a url (--portal).
        if r.get("url") and k in ("dashboard", "report", "rule"):
            return f"[{cell(r[k]).replace('[', '(').replace(']', ')')}]({r['url']})"
        return cell(r[k])

    print(f"## {title}\n")
    if not rows:
        print("None.\n")
        return
    print("| " + " | ".join(h for h, _ in cols) + " |")
    print("|" + "---|" * len(cols))
    for r in rows:
        print("| " + " | ".join(show(r, k) for _, k in cols) + " |")
    print()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("sections", nargs="*", metavar="SECTION",
                   help="dashboards, reports or rules (default: all three)")
    p.add_argument("-g", "--group", metavar="NAME|ID",
                   help="instead: what uses this group or a group below it (before removing it)")
    p.add_argument("-p", "--profile", default="config", help="elm credential profile (default: config)")
    p.add_argument("-c", "--config", metavar="PATH", help="elm config file, instead of --profile")
    p.add_argument("--jsonl", action="store_true", help="one JSON record per missing name instead of Markdown")
    p.add_argument("--portal", metavar="NAME",
                   help="portal subdomain (the bit before .logicmonitor.com): link each dashboard and report to it")
    p.add_argument("--url-template", metavar="SECTION=URL", action="append", default=[],
                   help="override a section's link (dashboards, reports or rules). Placeholders: {portal} {id}")
    a = p.parse_args()
    urls = dict(URLS) if a.portal else {}
    for t in a.url_template:
        section, _, url = t.partition("=")
        if section not in SECTIONS or not url:
            p.error(f"--url-template is SECTION=URL, SECTION one of {', '.join(SECTIONS)}")
        if "{portal}" in url and not a.portal:
            p.error("that link template needs {portal}: pass --portal NAME")
        urls[section] = url
    target = ["--config", a.config] if a.config else ["--profile", a.profile]
    want = a.sections or SECTIONS
    if set(want) - set(SECTIONS):
        p.error(f"a section is one of {', '.join(SECTIONS)}")
    try:
        portal = Portal(target)
        uses = None
        if a.group:
            uses = portal.find(a.group)
            if uses is None:
                err(f"elm-missing-refs: no group {a.group!r} (a full path such as Servers/Linux, or an id)")
                return 2
            err(f"  what uses {uses or '(root)'} and the groups below it")
        found = {}
        if "dashboards" in want:
            found["dashboards"] = dashboards(target, portal, uses)
        if "reports" in want:
            ids = {b["id"] for b in every(target, "DashboardList", "-f", "id")}
            found["reports"] = reports(target, portal, ids, uses)
        if "rules" in want:
            found["rules"] = rules(target, portal, uses)
    except ElmError as e:
        err(f"elm-missing-refs: {e}")
        return 1
    for section, rows in found.items():
        if section in urls:
            for r in rows:
                r["url"] = urls[section].format(portal=a.portal or "", id=r[LINKED[section][1]])
    if a.jsonl:
        for section, rows in found.items():
            for r in rows:
                print(json.dumps({"section": section, **r}))
        return 0
    how = "How" if uses is not None else "Problem"
    heads = {"dashboards": [("Dashboard", "dashboard"), ("Widgets", "widget"), (how, "problem"), ("Name", "name")],
             "reports": [("Report", "report"), ("Type", "type"), (how, "problem"), ("Name", "name")],
             "rules": [("Alert rule", "rule"), ("Priority", "priority"), (how, "problem"), ("Name", "name")]}
    if uses is None:
        for cols in heads.values():
            cols.append(("Moved to?", "moved"))
    titles = {"dashboards": "Dashboards", "reports": "Reports", "rules": "Alert rules"}
    if "dashboards" in found:
        rows = {}
        for r in found["dashboards"]:
            k = (r["dashboard_id"], r["problem"], r["name"])
            rows.setdefault(k, {**r, "widgets": []})["widgets"].append(r["widget"])
        for r in rows.values():
            w = list(dict.fromkeys(r["widgets"]))
            r["widget"] = ", ".join(w[:3]) + (f" (+{len(w) - 3})" if len(w) > 3 else "")
        found["dashboards"] = list(rows.values())
    for section, rows in found.items():
        word = "use it" if uses is not None else "missing"
        table(f"{titles[section]}: {len(rows)} {word}", rows, heads[section])
    return 0


if __name__ == "__main__":
    sys.exit(main())
