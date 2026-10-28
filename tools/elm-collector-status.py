#!/usr/bin/env python3
"""elm-collector-status: what every collector's own status check found, as one page.

Usage:
  elm-collector-status.py [-p PROFILE] [--all] [--jsonl]

Each collector checks itself about once a day, as on the Status Check page in
LM's UI: memory, proxy settings in agent.conf, its modules, and how many tasks
of each collection method return no data. This reads the last run of every up
collector (CollectorStatusCheck: reading does not start a new one) and lists
what was not OK, worst first, with LM's own words for what is wrong.

Output: Markdown on stdout, for tools/report-pdf.sh to make a page of:
  a summary line, the findings (collector, check, status, detail, when the
  check ran), the collectors whose check is over two days old, and the down
  collectors (a down collector has no result).
--all lists the collectors with nothing to report too. --jsonl prints one
finding per line instead, for jq or a ticket.

Status values: WARN is a problem to look at, DISABLED a module turned off in
agent.conf (often on purpose), OK everything else. A read-only token is enough.

Examples:
  tools/elm-collector-status.py > collectors.md && tools/report-pdf.sh collectors.md
  tools/elm-collector-status.py -p prod --jsonl | jq -r 'select(.status=="WARN") | .collector'

Every day at 07:00 (crontab -e), a page to open with your coffee:
  0 7 * * * cd ~/code/elm && tools/elm-collector-status.py -p prod > ~/collectors.md \\
      && tools/report-pdf.sh ~/collectors.md

Requires: elm
"""

import argparse
import json
import subprocess
import sys
import time

ORDER = {"WARN": 0, "DISABLED": 1}   # anything else LM may add sorts after these
STALE_DAYS = 2                       # a daily check older than this has stopped running


def err(*args):
    print(*args, file=sys.stderr, flush=True)


def elm(profile, *args):
    """The records one elm query returns, or None if it failed."""
    cmd = ["elm"] + (["-p", profile] if profile else []) + ["-f", "jsonl", *args]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        return None
    return [json.loads(line) for line in p.stdout.splitlines() if line.strip()]


def cell(text):
    """Text safe inside a Markdown table cell."""
    return " ".join(str(text).split()).replace("|", "\\|")


def ago(ms, now):
    hours = (now - ms / 1000) / 3600
    return f"{hours:.0f} h ago" if hours < 48 else f"{hours / 24:.0f} days ago"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("-p", "--profile", help="elm credential profile (default: elm's)")
    ap.add_argument("--all", action="store_true", help="also list collectors with nothing to report")
    ap.add_argument("--jsonl", action="store_true", help="one finding per line, as JSON")
    opts = ap.parse_args()

    collectors = elm(opts.profile, "CollectorList", "-s0", "-f",
                     "id,hostname,description,collectorGroupName,isDown,numberOfHosts,build")
    if collectors is None:
        sys.exit("elm-collector-status: CollectorList failed (run it by hand to see why)")
    now = time.time()
    findings, clean, stale, down = [], [], [], []
    for c in sorted(collectors, key=lambda c: c["id"]):
        if c.get("isDown"):
            down.append(c)
            continue
        result = elm(opts.profile, "CollectorStatusCheck", "--collectorId", str(c["id"]))
        if not result:
            down.append(c | {"no_result": True})
            continue
        check = result[0]
        when = check.get("lastTriggeredMills") or 0
        if when and now - when / 1000 > STALE_DAYS * 86400:
            stale.append((c, when))
        bad = [p for p in check.get("checkPoints") or [] if p.get("status") != "OK"]
        for p in bad:
            findings.append({"collector": c["id"], "hostname": c.get("hostname"),
                             "group": c.get("collectorGroupName"), "hosts": c.get("numberOfHosts"),
                             "status": p.get("status"), "check": p.get("name"),
                             "detail": p.get("detail"), "checked": when})
        if not bad:
            clean.append((c, when))
        err(f"collector {c['id']}: {len(bad)} finding(s)")
    findings.sort(key=lambda f: (ORDER.get(f["status"], 2), -(f["hosts"] or 0), f["collector"]))

    if opts.jsonl:
        for f in findings:
            print(json.dumps(f))
        return

    up = len(collectors) - len(down)
    warn = len({f["collector"] for f in findings if f["status"] == "WARN"})
    print(f"# Collector status checks\n\n{time.strftime('%d %b %Y, %H:%M %Z')}. "
          f"{len(collectors)} collectors: {up} up, {len(down)} down. "
          f"**{warn} with warnings**, {len(findings)} findings in all.\n")
    if findings:
        print("## Findings\n")
        print("| Collector | Group | Hosts | Status | Check | Detail | Checked |")
        print("|---|---|--:|---|---|---|---|")
        for f in findings:
            print(f"| {f['collector']} {cell(f['hostname'] or '')} | {cell(f['group'] or '')} | {f['hosts'] or 0} "
                  f"| {f['status']} | {cell(f['check'])} | {cell(f['detail'])} | {ago(f['checked'], now) if f['checked'] else '?'} |")
        print()
    if stale:
        print(f"## Checks more than {STALE_DAYS} days old\n\nThe daily check has stopped running on these:\n")
        for c, when in stale:
            print(f"- {c['id']} {c.get('hostname') or ''}: last ran {ago(when, now)}")
        print()
    if down:
        print("## Down, or no check result\n")
        for c in sorted(down, key=lambda c: -(c.get("numberOfHosts") or 0)):
            why = "up, but has no check result" if c.get("no_result") else "down"
            print(f"- {c['id']} {c.get('hostname') or ''} ({c.get('collectorGroupName') or 'no group'}): "
                  f"{why}, {c.get('numberOfHosts') or 0} host{'' if c.get('numberOfHosts') == 1 else 's'}")
        print()
    if opts.all and clean:
        print("## Nothing to report\n")
        for c, when in clean:
            print(f"- {c['id']} {c.get('hostname') or ''}: checked {ago(when, now) if when else '?'}")
        print()


if __name__ == "__main__":
    main()
