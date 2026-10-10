#!/usr/bin/env python3
"""portal-matrix: one row per item, one column per portal, from elm's output.

Pivots the rows elm prints for several profiles (elm -p a,b,c) into a table
that shows at a glance which portal is out of step:

    elm -p prod,preprod,test -e contacts -f jsonl PortalInfo -f contacts \\
      | tools/portal-matrix.py -k contacts.email

    | contacts.email   | prod | preprod | test |
    |------------------|------|---------|------|
    | joe@example.com  |  ✓   |    ✓    |  ✓   |
    | fred@example.com |  ✓   |    —    |  ✓   |

Rows are identified by the -k field(s). Without -k, when each portal has one
record (PortalInfo, a ...ById command) there is one row per field with each
portal's value, so settings line up side by side; with several records per
portal, every field together identifies a row. Without -v a cell is ✓ where the
portal has that row and — where it does not; with -v it holds that field's
value (several -v fields are joined with " / "), so differing values show:

    elm -p prod,preprod -f jsonl DatasourceList -F name:Ping -f name,checksum \\
      | tools/portal-matrix.py -k name -v checksum -d

-d keeps only the rows where some portal differs or is missing. Use it here
rather than elm's own -d: elm -d drops the rows a portal shares with all the
others, and a portal left with no rows would vanish from the table, hiding
what it lacks. -m adds a "same" column (✓ / ✗) instead, for a full table.

Columns are the profiles (or -c account_name, for readers who know the
portals by account; refused when two profiles share an account, since their
rows would merge), in the order they first appear, then "same" with -m.
Reads elm's -f jsonl, -f json or -f prettyjson from stdin, so -f can be left
out. --tick and --cross change the marks (e.g. :true: and :false: for a wiki).
In a terminal the marks are coloured; piped or with NO_COLOR set, they are not. GitHub Flavored Markdown by default, CSV with --csv.
Exit status: 0 when every row is the same on every portal, 1 when any
differs (like diff), 2 on bad input.
"""

import argparse
import csv
import json
import os
import sys

TICK, CROSS = "✓", "✗"     # the defaults; --tick / --cross change them


def err(*args):
    print(*args, file=sys.stderr)


def read_rows(text):
    """Records from elm -f jsonl (one per line), -f json or -f prettyjson ({"Command": [...]})."""
    text = text.strip()
    if not text:
        return []
    try:
        whole = json.loads(text)
    except json.JSONDecodeError:
        whole = None
    if isinstance(whole, dict) and len(whole) == 1 and isinstance(next(iter(whole.values())), list):
        return next(iter(whole.values()))
    if isinstance(whole, dict):
        return [whole]
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def show(value):
    """A cell's text: blank for null, 1 not 1.0, JSON for anything nested."""
    if value is None:
        return ""
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True)
    return str(value)


def get(row, field):
    """row's field; a dotted name not in row (escalatingChain.name) looks inside its records."""
    if field in row:
        return row[field]
    value = row
    for part in field.split("."):
        if not isinstance(value, dict) or part not in value:
            return None
        value = value[part]
    return value


def has(rows, field):
    return any(field in row or get(row, field) is not None for row in rows)


def pivot(rows, keys, values, column, tick):
    """(columns, {key tuple: {column: cell}}), both in first-seen order."""
    columns, table = [], {}
    for row in rows:
        col = show(get(row, column))
        if col not in columns:
            columns.append(col)
        key = tuple(show(get(row, k)) for k in keys)
        cell = " / ".join(show(get(row, v)) for v in values) if values else tick
        cells = table.setdefault(key, {}).setdefault(col, [])
        if cell not in cells:
            cells.append(cell)      # one portal with several rows for a key: list each value once
    return columns, {key: {col: ", ".join(cells) for col, cells in row.items()} for key, row in table.items()}


def same(cells, columns):
    return len(cells) == len(columns) and len(set(cells.values())) == 1


def emit_csv(headers, body):
    w = csv.writer(sys.stdout)
    w.writerow(headers)
    w.writerows(body)


def emit_gfm(headers, body, centred, colours, first):
    """GFM table, padded so the raw Markdown lines up too; ticks centred.

    colours maps a mark to an ANSI colour code, applied after padding so the
    columns still line up.
    """
    def esc(s):
        return str(s).replace("|", "\\|").replace("\n", " ")

    headers = [esc(h) for h in headers]
    body = [[esc(c) for c in row] for row in body]
    widths = [max([3, len(h)] + [len(row[i]) for row in body]) for i, h in enumerate(headers)]

    def pad(s, i):
        padded = s.center(widths[i]) if i in centred else s.ljust(widths[i])
        if s and s in colours and i >= first:
            padded = padded.replace(s, f"\x1b[{colours[s]}m{s}\x1b[0m", 1)
        return padded

    def line(cells):
        print("| " + " | ".join(cells) + " |")

    line([pad(h, i) for i, h in enumerate(headers)])
    line([(":" + "-" * (w - 2) + ":") if i in centred else "-" * w for i, w in enumerate(widths)])
    for row in body:
        line([pad(c, i) for i, c in enumerate(row)])


def parse_args(argv):
    p = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        epilog=__doc__.split("\n\n", 1)[1],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-k", "--key", metavar="FIELD[,FIELD]",
                   help="field(s) that identify a row, e.g. name or name,privileges.objectName. "
                        "Without it: one row per field when each portal has one record (PortalInfo), "
                        "otherwise every field together")
    p.add_argument("-v", "--value", metavar="FIELD[,FIELD]",
                   help="show this field's value in each cell instead of a tick")
    p.add_argument("-c", "--column", default="profile", metavar="FIELD",
                   help="field whose values become the columns (default: profile; or account_name)")
    p.add_argument("-d", "--diff", action="store_true",
                   help="only the rows where some portal differs or is missing")
    p.add_argument("-m", "--match", action="store_true",
                   help=f"add a 'same' column: {TICK} where every portal agrees, {CROSS} where not")
    p.add_argument("--missing", default="—", metavar="TEXT",
                   help="what a cell shows where the portal has no such row (default: —)")
    p.add_argument("--tick", default=TICK, metavar="TEXT",
                   help=f"the mark for present / the same (default: {TICK}; e.g. :true: for a wiki)")
    p.add_argument("--cross", default=CROSS, metavar="TEXT",
                   help=f"the mark for not the same, in the -m column (default: {CROSS}; e.g. :false:)")
    p.add_argument("--csv", action="store_true", help="CSV instead of a Markdown table")
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    keys = [k.strip() for k in (args.key or "").split(",") if k.strip()]
    values = [v.strip() for v in (args.value or "").split(",") if v.strip()]

    try:
        rows = read_rows(sys.stdin.read())
    except json.JSONDecodeError as e:
        err(f"portal-matrix: input is not elm's -f jsonl, json or prettyjson output ({e})")
        return 2
    if not rows:
        err("portal-matrix: no rows on stdin (pipe in elm -p a,b,... -f jsonl COMMAND ...)")
        return 2

    present = set().union(*(row.keys() for row in rows))
    absent = [f for f in [args.column] + keys + values if not has(rows, f)]
    if absent:
        err(f"portal-matrix: no field {', '.join(absent)} in the input; it has: {', '.join(sorted(present))}")
        return 2
    if args.column != "profile" and "profile" in present:
        behind = {}
        for row in rows:
            behind.setdefault(row.get(args.column), set()).add(row.get("profile"))
        shared = {col: names for col, names in behind.items() if len(names) > 1}
        if shared:
            col, names = next(iter(shared.items()))
            err(f"portal-matrix: {args.column} {col} is behind several profiles ({', '.join(sorted(names))}), "
                f"whose rows would merge; use -c profile")
            return 2

    if not keys:
        # the portal's own fields, in first-seen order
        fields = [f for f in dict.fromkeys(f for row in rows for f in row)
                  if f not in (args.column, "profile", "account_name")]
        per_portal = {}
        for row in rows:
            per_portal[show(get(row, args.column))] = per_portal.get(show(get(row, args.column)), 0) + 1
        if set(per_portal.values()) == {1}:
            # one record each (PortalInfo, a ById): one row per field, its value per portal
            fields = values or fields
            rows = [{args.column: get(row, args.column), "field": f, "value": get(row, f)}
                    for row in rows for f in fields]
            keys, values = ["field"], ["value"]
        else:
            keys = [f for f in fields if f not in values]

    columns, table = pivot(rows, keys, values, args.column, args.tick)
    differ = [key for key, cells in table.items() if not same(cells, columns)]

    headers = keys + columns + (["same"] if args.match else [])     # read left to right: verdict last
    body = []
    for key, cells in table.items():
        if args.diff and key in differ or not args.diff:
            mark = [args.cross if key in differ else args.tick] if args.match else []
            body.append(list(key) + [cells.get(col, args.missing) for col in columns] + mark)

    if not body:
        err(f"No differences: {len(table)} rows the same on {len(columns)} portals")
        return 0
    if args.csv:
        emit_csv(headers, body)
    else:
        first = len(keys)
        centred = set(range(first, len(headers))) if not values else ({len(headers) - 1} if args.match else set())
        colour = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
        green, red = "32", "31"
        colours = {args.tick: green, args.cross: red, args.missing: red} if colour else {}
        emit_gfm(headers, body, centred, colours, first)
    sys.stdout.flush()      # the table first, then the summary on stderr
    err(f"{len(differ)} of {len(table)} rows differ across {len(columns)} portals")
    return 1 if differ else 0


if __name__ == "__main__":
    sys.exit(main())
