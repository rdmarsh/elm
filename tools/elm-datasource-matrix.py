#!/usr/bin/env python3
"""elm-datasource-matrix: build a device x datasource usage matrix.

For every datasource whose name matches PATTERN, build a matrix whose rows are
devices and whose columns are the matching datasources; a cell holds a tick (✓)
where the datasource is applied to the device, blank otherwise. Output is a
GitHub Flavored Markdown (GFM) table, or CSV with --csv. Output columns are:
device ID, device name, then one column per datasource.

Matching:
  PATTERN is a case-INSENSITIVE substring by default, so 'ntp', 'NTP' and 'Ntp'
  all match NTPv4 / Cisco_NTP. Pass -s for a case-SENSITIVE match (the same flag
  as ripgrep), so 'NTP' matches NTPv4/Cisco_NTP but not incidental substrings
  like AccessPoi[ntP]erformance or OverCurre[ntP]rotectors. Pass -x to treat
  PATTERN as a Python regular expression (re.search); anchor with ^ and $ to
  match only at the start or end of the name, e.g. '^NTP|NTP$' matches NTP,
  NTPv4 and Cisco_NTP but NOT a mid-string Cisco_NTP_Stats. (Note: \\bNTP\\b
  does NOT work for that -- '_' is a regex word character, so there is no
  boundary in Cisco_NTP.) Combine alternatives with | to OR several patterns in
  one run, e.g. 'NTP|Ping' -- each branch is pushed as its own server-side
  name~ filter and the results are unioned (LM ANDs repeated -F filters, so OR
  cannot be done in a single query; this makes one call per branch instead).

Size guard:
  A wide or tall matrix is rarely useful (and a wide one also means one API call
  per column). --max-cols (default 20) aborts before the per-datasource calls if
  too many datasources match; --max-rows (default 1000) aborts before rendering
  if too many devices use them. 1000 is LM's per-request row cap: every call
  here uses -s0 (a single max-size page), so beyond ~1000 the underlying device
  lists are themselves truncated and the matrix can no longer be trusted to be
  complete. Narrow the pattern, or raise/disable a limit with --max-cols N /
  --max-rows N (0 = unlimited).

Efficiency (N_datasources API calls, not N_devices):
  1. DatasourceList -F name~PATTERN  -> candidate datasources. The server-side ~
     filter is case-insensitive. In regex mode the server can't evaluate a
     regex, so a literal substring is derived from the pattern (e.g. 'NTP' from
     '^NTP|NTP$') and used for the name~ filter, then the full regex refines the
     result client-side -- the full datasource list (which can be thousands of
     entries) is never downloaded. If no literal can be derived (e.g. '.*' or a
     bare alternation group), it warns and falls back to fetching all.
  2. AssociatedDeviceListByDataSourceId --id  -> devices per datasource (one
     call per matching datasource).
  3. DeviceList -F deviceType!:0 -F deviceType!:1  -> non-device ids to exclude.
  4. Pivot into the GFM device x datasource matrix.

Real devices only: rows are restricted to actual devices (deviceType 0 or 1).
Everything else LM models as a "device" -- LM Services / Service Insight
(deviceType 6), cloud accounts/resources (AWS, Azure), Kubernetes resources,
etc. -- is excluded. This is not configurable.

Datasources with zero (real-device) associated devices are dropped (empty
columns). Only devices that use at least one matching datasource appear as rows.

"Applied" means the live /setting/datasources/{id}/devices association, NOT the
24h-stale auto.activedatasources property. Status messages go to stderr; the
table/CSV goes to stdout.
"""

import argparse
import csv
import json
import re
import shutil
import subprocess
import sys

# LM deviceType values that are real devices; all others (services=6,
# cloud=2/4/7, k8s=8, ...) are excluded from the matrix.
DEVICE_TYPES = (0, 1)


def err(*args):
    print(*args, file=sys.stderr)


def elm_json(profile, command, *args, key):
    """Run `elm --profile P -f json COMMAND ...` and return result[key] (a list).

    Errors (non-zero exit, unparseable output) yield an empty list rather than
    raising -- matches the tolerant behaviour the shell version had.
    """
    cmd = ["elm", "--profile", profile, "-f", "json", command, *args]
    out = subprocess.run(cmd, capture_output=True, text=True)
    try:
        return json.loads(out.stdout).get(key, [])
    except Exception:
        return []


# --- regex -> server-side literal narrowing ---------------------------------

def split_top_alternation(pattern):
    """Split a regex on top-level | only, ignoring | inside groups, [classes]
    and escapes."""
    parts, cur, depth, i, n = [], [], 0, 0, len(pattern)
    while i < n:
        c = pattern[i]
        if c == "\\" and i + 1 < n:
            cur.append(c)
            cur.append(pattern[i + 1])
            i += 2
            continue
        if c == "[":                       # char class -- copy verbatim
            cur.append(c)
            i += 1
            while i < n and pattern[i] != "]":
                if pattern[i] == "\\" and i + 1 < n:
                    cur.append(pattern[i])
                    i += 1
                cur.append(pattern[i])
                i += 1
            if i < n:
                cur.append(pattern[i])
                i += 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif c == "|" and depth == 0:
            parts.append("".join(cur))
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    parts.append("".join(cur))
    return parts


def mandatory_runs(alt):
    """Literal substrings that MUST appear in every string matching `alt`.

    Only depth-0 runs count (anything inside ( ) or [ ] is not guaranteed), and
    a trailing char made optional by * ? {..} is dropped. Querying any of these
    as a server-side name~ filter therefore returns a superset of the true
    matches -- it can over-fetch, but never drops a real match.
    """
    runs, cur, depth, i, n = [], [], 0, 0, len(alt)

    def flush():
        if cur:
            runs.append("".join(cur))
            cur.clear()

    while i < n:
        c = alt[i]
        if c == "\\" and i + 1 < n:
            nxt = alt[i + 1]
            if depth == 0:
                if nxt.isalnum():          # \d \w \s \b ... -- not a literal
                    flush()
                else:                      # \. \_ \- ... -- literal next char
                    cur.append(nxt)
            i += 2
            continue
        if c == "[":                       # char class -- breaks a run
            flush()
            i += 1
            while i < n and alt[i] != "]":
                if alt[i] == "\\" and i + 1 < n:
                    i += 1
                i += 1
            i += 1
            continue
        if c == "(":
            flush()
            depth += 1
            i += 1
            continue
        if c == ")":
            depth -= 1
            i += 1
            continue
        if depth > 0:                      # ignore everything inside groups
            i += 1
            continue
        if c in "*?{":                     # quantifier: preceding char optional
            if cur:
                cur.pop()
            flush()
            if c == "{":
                while i < n and alt[i] != "}":
                    i += 1
            i += 1
            continue
        if c in "+^$.":                    # + keeps the char but ends the run
            flush()
            i += 1
            continue
        cur.append(c)
        i += 1
    flush()
    return [r for r in runs if r]


def server_cores(pattern):
    """Literal name~ substrings to push server-side, or None if the pattern is
    too broad to narrow (some alternative has no guaranteed literal)."""
    cores = []
    for alt in split_top_alternation(pattern):
        runs = mandatory_runs(alt)
        if not runs:
            return None
        cores.append(max(runs, key=len))
    # Minimal covering set: drop any core that already contains a shorter kept
    # one (the shorter, broader filter covers it -- e.g. 'NTP' covers 'SNTP').
    uniq = []
    for c in sorted(set(cores), key=len):
        if not any(u.lower() in c.lower() for u in uniq):
            uniq.append(c)
    return uniq


# --- candidate datasources --------------------------------------------------

def candidate_datasources(profile, pattern, ignore_case, use_regex):
    """Return [{id, name}] of datasources matching PATTERN, narrowed
    server-side and refined client-side."""
    if use_regex:
        try:
            rx = re.compile(pattern, re.IGNORECASE if ignore_case else 0)
        except re.error as e:
            err(f"invalid regex '{pattern}': {e}")
            sys.exit(2)
        cores = server_cores(pattern)
        by_id = {}
        if cores is None:
            err("warning: no literal substring could be derived from the regex; "
                "fetching all datasources (may be slow on large portals)")
            for d in elm_json(profile, "DatasourceList", "-f", "id,name", "-s0",
                              key="DatasourceList"):
                by_id[d["id"]] = d
        else:
            err("regex narrowed to server filter(s): "
                + ", ".join(f"name~{c}" for c in cores))
            for c in cores:
                for d in elm_json(profile, "DatasourceList", "-F", f"name~{c}",
                                  "-f", "id,name", "-s0", key="DatasourceList"):
                    by_id[d["id"]] = d
        return [d for d in by_id.values() if rx.search(d["name"])]

    # Substring mode: server ~ filter is case-insensitive; refine client-side
    # only to honour a case-SENSITIVE match when -s is given.
    cands = elm_json(profile, "DatasourceList", "-F", f"name~{pattern}",
                     "-f", "id,name", "-s0", key="DatasourceList")
    if ignore_case:
        return cands
    return [d for d in cands if pattern in d["name"]]


# --- output -----------------------------------------------------------------

def emit_csv(devices, cols, used):
    w = csv.writer(sys.stdout)
    w.writerow(["id", "device"] + cols)
    for did, dname in devices:
        w.writerow([did, dname] + [1 if did in used[c] else 0 for c in cols])


def emit_gfm(devices, cols, used):
    """GFM table: full datasource names as headers, tick where applied. Columns
    are padded so the raw Markdown source lines up too."""
    def esc(s):
        return str(s).replace("|", "\\|")

    headers = ["ID", "Device"] + [esc(c) for c in cols]
    aligns = ["right", "left"] + ["center"] * len(cols)
    body = [[str(did), esc(dname)] + ["✓" if did in used[c] else "" for c in cols]
            for did, dname in devices]

    # Column widths, with minimums the alignment markers (--:, :--:) require.
    widths = [max(2, len(h)) for h in headers]
    for i, a in enumerate(aligns):
        if a == "center":
            widths[i] = max(widths[i], 3)
    for row in body:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))

    def pad(s, w, a):
        if a == "center":
            return s.center(w)
        return s.rjust(w) if a == "right" else s.ljust(w)

    def sep(w, a):
        if a == "right":
            return "-" * (w - 1) + ":"
        if a == "center":
            return ":" + "-" * (w - 2) + ":"
        return "-" * w

    def line(cells):
        print("| " + " | ".join(cells) + " |")

    line([pad(h, widths[i], aligns[i]) for i, h in enumerate(headers)])
    line([sep(widths[i], aligns[i]) for i in range(len(headers))])
    for row in body:
        line([pad(c, widths[i], aligns[i]) for i, c in enumerate(row)])


# --- main -------------------------------------------------------------------

def parse_args(argv):
    p = argparse.ArgumentParser(
        prog="elm-datasource-matrix.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("pattern", nargs="?", default="NTP",
                   help="substring (or regex with -x) to match in the datasource "
                        "NAME. Default: 'NTP'.")
    p.add_argument("-p", "--profile", default="config",
                   help="elm credential profile (default: 'config', the sandbox).")
    p.add_argument("-s", "--case-sensitive", action="store_true",
                   help="match PATTERN case-sensitively (ripgrep's flag).")
    p.add_argument("-x", "--regex", action="store_true",
                   help="treat PATTERN as a Python regex; anchor with ^/$ to "
                        "match only the start/end of the name, e.g. '^NTP|NTP$'.")
    p.add_argument("--csv", action="store_true",
                   help="emit CSV (id,device,<datasource...>) with 1/0 cells "
                        "instead of the GFM table.")
    p.add_argument("--max-cols", type=int, default=20, metavar="N",
                   help="abort if more than N datasources match (columns / API "
                        "calls). Default: 20. 0 = unlimited.")
    p.add_argument("--max-rows", type=int, default=1000, metavar="N",
                   help="abort if more than N devices would be rows. Default: "
                        "1000 (LM's per-request -s0 row cap). 0 = unlimited.")
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if shutil.which("elm") is None:
        err("elm not found on PATH")
        return 1

    ignore_case = not args.case_sensitive
    err(f"profile: {args.profile}   pattern: '{args.pattern}'   "
        f"match: {'case-insensitive' if ignore_case else 'case-sensitive'}"
        f"{' (regex)' if args.regex else ''}")

    # Step 1: candidate datasources.
    cands = candidate_datasources(args.profile, args.pattern, ignore_case, args.regex)
    if not cands:
        err(f"no datasources match '{args.pattern}'")
        return 0

    # Column guard: each candidate is one column AND one step-2 API call, so cap
    # here, before the expensive per-datasource loop.
    err(f"{len(cands)} datasource(s) match '{args.pattern}'")
    if args.max_cols and len(cands) > args.max_cols:
        err(f"that exceeds --max-cols ({args.max_cols}): the matrix would be "
            f"{len(cands)} columns wide and cost {len(cands)} API calls. "
            "Narrow the pattern (e.g. anchor with ^/$ via -x), or raise/disable "
            "with --max-cols N (0 = unlimited).")
        return 1

    # Step 2: devices per datasource.
    ds_devices = []   # (datasource_name, {device_id: device_name})
    for d in sorted(cands, key=lambda x: x["name"].lower()):
        devs = elm_json(args.profile, "AssociatedDeviceListByDataSourceId",
                        "--id", str(d["id"]), "-s0",
                        key="AssociatedDeviceListByDataSourceId")
        dmap = {x["id"]: (x.get("displayName") or x.get("name") or str(x["id"]))
                for x in devs}
        if dmap:                       # drop empty columns
            ds_devices.append((d["name"], dmap))

    if not ds_devices:
        err(f"{len(cands)} datasource(s) matched '{args.pattern}' but none are "
            "applied to any device")
        return 0

    # Step 3: keep real devices only. Fetch the set of NON-device ids (deviceType
    # not in DEVICE_TYPES) in one filtered call and drop them. Excluding the
    # (smaller) non-device set is safer than fetching the device set, which can
    # exceed the 1000-row cap on large portals.
    not_eq = []
    for t in DEVICE_TYPES:
        not_eq += ["-F", f"deviceType!:{t}"]
    nondevice_ids = {x["id"] for x in elm_json(args.profile, "DeviceList",
                                               *not_eq, "-s0", "-f", "id",
                                               key="DeviceList")}

    excluded = set()
    filtered = []
    for name, dmap in ds_devices:
        excluded |= (set(dmap) & nondevice_ids)
        dmap2 = {i: n for i, n in dmap.items() if i not in nondevice_ids}
        if dmap2:                      # column may go empty once non-devices gone
            filtered.append((name, dmap2))
    ds_devices = filtered
    if excluded:
        err(f"excluded {len(excluded)} non-device resource(s) "
            f"(services / cloud / k8s -- deviceType not in {DEVICE_TYPES})")
    if not ds_devices:
        err("all matching usage was on non-device resources (services / cloud / "
            "k8s); nothing left to show")
        return 0

    # Build the device universe (rows = devices using >=1 matching datasource).
    dev_names = {}
    for _, dmap in ds_devices:
        dev_names.update(dmap)
    devices = sorted(dev_names.items(), key=lambda kv: kv[1].lower())   # (id, name)

    cols = [name for name, _ in ds_devices]
    used = {name: set(dmap.keys()) for name, dmap in ds_devices}

    err(f"{len(devices)} device(s) x {len(cols)} datasource(s)")

    # Row guard: device count is only known after fetching, so this aborts
    # before rendering (not before the API calls) -- it spares you a giant dump.
    if args.max_rows and len(devices) > args.max_rows:
        err(f"that exceeds --max-rows ({args.max_rows}; LM's per-request -s0 "
            "cap, beyond which the underlying device lists truncate anyway). "
            "Narrow the pattern, or raise/disable with --max-rows N "
            "(0 = unlimited).")
        return 1

    if args.csv:
        emit_csv(devices, cols, used)
    else:
        emit_gfm(devices, cols, used)
    return 0


if __name__ == "__main__":
    sys.exit(main())
