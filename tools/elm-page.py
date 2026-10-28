#!/usr/bin/env python3
"""elm-page: fetch every row of an elm query, past the 1,000-row page and, by
splitting the time range, past LM's 10,000-row limit.

Usage:
  elm-page.py [-p PROFILE] COMMAND [COMMAND FLAGS...]
  elm-page.py [-p PROFILE] --by hour|day|month --from DATE --to DATE
              [--field FIELD] COMMAND [COMMAND FLAGS...]

Pages the query 1,000 rows at a time (-s 1000 -o 0, 1000, ...) until a page
comes back short. LM stops paging at 10,000 rows with no error, so with --by
the range [--from, --to) is cut into hours, days or months, each fetched on its
own with -F FIELD>:START,FIELD<END. FIELD defaults to startEpoch. Dates are
YYYY-MM-DD or YYYY-MM-DDTHH:MM, local time (elm converts them).

Output: one JSON record per line (jsonl) on stdout, each id once. On stderr,
the rows per piece, and a warning for any piece that reached 9,000 rows: it
was probably cut short, so use a smaller --by.

Examples:
  elm-page.py DeviceList -f id,displayName > devices.jsonl
  elm-page.py -p busy --by hour --from 2026-10-27 --to 2026-10-28 \\
      AlertList -F cleared:true -f id,startEpoch | wc -l

Do not pass -s or -o: elm-page sets them. Global elm flags other than -p are
not passed through; the output is always jsonl.

Requires: elm
"""

import argparse
import datetime
import json
import subprocess
import sys

PAGE = 1000         # LM's maximum page size
NEAR_CAP = 9000     # a piece this big may have hit the 10,000 limit


def err(*args):
    print(*args, file=sys.stderr)


def pieces(start, end, by):
    """(start, end) pairs covering [start, end) in steps of an hour, day or month."""
    while start < end:
        if by == "hour":
            step = start + datetime.timedelta(hours=1)
        elif by == "day":
            step = start + datetime.timedelta(days=1)
        else:
            month = start.month % 12 + 1
            step = start.replace(year=start.year + (start.month == 12), month=month, day=1,
                                 hour=0, minute=0)
        yield start, min(step, end)
        start = step


def fetch(profile, command, args, seen):
    """Page one query to its end, print new rows, return how many came back."""
    rows = 0
    for offset in range(0, 10**6, PAGE):
        cmd = ["elm", "-f", "jsonl"] + (["-p", profile] if profile else [])
        cmd += [command, *args, "-s", str(PAGE), "-o", str(offset)]
        out = subprocess.run(cmd, capture_output=True, text=True)
        if out.returncode != 0:
            sys.stderr.write(out.stderr)
            sys.exit(out.returncode)
        lines = out.stdout.splitlines()
        for line in lines:
            key = json.loads(line).get("id", line)
            if key not in seen:
                seen.add(key)
                print(line)
        rows += len(lines)
        if len(lines) < PAGE:
            return rows
    return rows


def main():
    parser = argparse.ArgumentParser(add_help=False, usage=__doc__.split("\n\n")[1])
    parser.add_argument("-p", "--profile")
    parser.add_argument("--by", choices=("hour", "day", "month"))
    parser.add_argument("--from", dest="start", type=datetime.datetime.fromisoformat)
    parser.add_argument("--to", dest="end", type=datetime.datetime.fromisoformat)
    parser.add_argument("--field", default="startEpoch")
    parser.add_argument("-h", "--help", action="store_true")
    parser.add_argument("command", nargs="?")
    parser.add_argument("args", nargs=argparse.REMAINDER)
    opts = parser.parse_args()

    if opts.help or not opts.command:
        print(__doc__.strip(), file=sys.stdout if opts.help else sys.stderr)
        sys.exit(0 if opts.help else 2)
    if any(a in ("-s", "--size", "-o", "--offset") for a in opts.args):
        parser.error("do not pass -s or -o: elm-page pages the query itself")
    if opts.by and not (opts.start and opts.end):
        parser.error("--by needs --from and --to")

    seen = set()
    if not opts.by:
        rows = fetch(opts.profile, opts.command, opts.args, seen)
        err(f"{rows} rows" + (": near 10,000, probably cut short; split it with --by" if rows >= NEAR_CAP else ""))
        return

    for a, b in pieces(opts.start, opts.end, opts.by):
        span = f"{opts.field}>:{a:%Y-%m-%dT%H:%M},{opts.field}<{b:%Y-%m-%dT%H:%M}"
        rows = fetch(opts.profile, opts.command, opts.args + ["-F", span], seen)
        err(f"{a:%Y-%m-%d %H:%M}  {rows}" + ("  near 10,000, probably cut short: use a smaller --by" if rows >= NEAR_CAP else ""))
    err(f"{len(seen)} rows")


if __name__ == "__main__":
    main()
