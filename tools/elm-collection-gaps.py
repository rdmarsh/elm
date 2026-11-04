#!/usr/bin/env python3
"""elm-collection-gaps: find datasource instances that have stopped collecting.

Three lists, each grouped by DataSource (most instances first) so one bad
DataSource stands out:

  stopped   polled before, but not in the last N collect intervals (N is
            --intervals, default 3; the interval is the DataSource's
            collectInterval) and not in the last --min-age minutes (default
            30), so a few minutes' lag (Azure Insights, a slow batchscript)
            is not a stop
  no data   no poll at all in the last --lookback hours (default 24): never
            collected, or stopped before then (bad AppliesTo, credentials ...)
  No Data   polled on schedule, but every value of every poll in that window
            is "No Data" (NaN): the collector runs it and gets nothing. Listed
            with --device or --datasource; a whole-portal run only counts them
            per DataSource (No Data is normal for many: drop tables, error
            reasons), unless --nodata

Scope: the whole portal, one DataSource (--datasource NAME, for straight after
an upgrade), one device (--device NAME), or both.

How: an instance's lastCollectedTime is always 0 for DataSources (only
ConfigSources fill it in, checked 2026-11-03), so the times come from the data
itself. Per device: DeviceDatasourceList and DeviceInstanceList, then one
DeviceDatasourceDataById per DataSource on it, over the last N intervals; its
rows are the polls, newest first. Only a DataSource with an instance that has
no rows there gets a second call over --lookback, with one datapoint, to find
its last poll. So it costs about one call per DataSource per device: a whole
portal takes a while, which is what --jobs is for.

Left out, and counted at the end: dead devices and devices whose collector is
down, devices in SDT, modules that are not DataSources (ConfigSources ...),
DataSources with monitoring disabled or in SDT, DataSources with no instances,
and instances that are disabled or in SDT.

Output: Markdown on stdout (--jsonl: one record per instance, for pipes);
progress and errors on stderr.

Examples:
  elm-collection-gaps.py --device web01
  elm-collection-gaps.py --datasource WinCPU --intervals 5
  elm-collection-gaps.py -p portal01 --jobs 8 > gaps.md
  elm-collection-gaps.py --jsonl | jq -r 'select(.list == "stopped") | .device'

Requires: elm
"""

import argparse
import collections
import concurrent.futures
import datetime
import json
import math
import subprocess
import sys
import time

PAGE = 1000
LISTS = {
    "stopped": "Stopped",
    "nodata": "No data in the last {lookback} hours",
    "allnan": "Polled, but all No Data",
}
TARGET = []         # ["--profile", P] or ["--config", PATH]


class ElmError(Exception):
    pass


def err(*args, **kw):
    print(*args, file=sys.stderr, **kw)


def elm(key, *args):
    """Rows of `elm -f json ARGS`, retrying a 429 with a growing wait."""
    cmd = ["elm", *TARGET, "-f", "json", *args]
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
    raise ElmError(f"{' '.join(args[:4])}: {said}")


def every(key, *args):
    """All rows, 1000 at a time."""
    rows, offset = [], 0
    while True:
        page = elm(key, *args, "-s", str(PAGE), "-o", str(offset))
        rows += page
        if len(page) < PAGE:
            return rows
        offset += PAGE


def first_match(key, command, filters, fields):
    """The rows of the first filter that matches anything."""
    for f in filters:
        rows = elm(key, command, "-F", f, "-f", fields, "-s", "50")
        if rows:
            return rows
    return []


def in_sdt(status):
    """sdtStatus is <group>-<device>-<instance>, each "none" when not in SDT."""
    return any(part != "none" for part in (status or "none").split("-"))


def no_data(x):
    return isinstance(x, str) or (isinstance(x, float) and math.isnan(x))


def plan_device(dev, datasources, only_ds):
    """The device's DataSources to check, as (dev, ds, hds id, {instance name: instance}),
    and what was left out."""
    plan, out = [], collections.Counter()
    narrow = ["-F", f"dataSourceId:{only_ds}"] if only_ds else []
    hdss = every("DeviceDatasourceList", "DeviceDatasourceList", "--deviceId", str(dev["id"]), *narrow,
                 "-f", "id,dataSourceId,dataSourceType,stopMonitoring,sdtStatus,instanceNumber")
    insts = every("DeviceInstanceList", "DeviceInstanceList", "--id", str(dev["id"]), *narrow,
                  "-f", "deviceDataSourceId,name,displayName,stopMonitoring,sdtStatus")
    by_hds = collections.defaultdict(list)
    for i in insts:
        by_hds[i["deviceDataSourceId"]].append(i)
    for h in hdss:
        ds = datasources.get(h["dataSourceId"])
        if h["dataSourceType"] != "DS":
            out[f"not a DataSource ({h['dataSourceType']})"] += 1
        elif h["stopMonitoring"]:
            out["DataSource monitoring disabled on the device"] += 1
        elif in_sdt(h["sdtStatus"]):
            out["DataSource in SDT"] += 1
        elif not h["instanceNumber"]:
            out["DataSource with no instances"] += 1
        elif not ds or not ds.get("collectInterval"):
            out["DataSource with no collect interval"] += 1
        else:
            want = {}
            for i in by_hds[h["id"]]:
                if i["stopMonitoring"]:
                    out["instance disabled"] += 1
                elif in_sdt(i["sdtStatus"]):
                    out["instance in SDT"] += 1
                else:
                    want[i["name"]] = i
            if want:
                plan.append((dev, ds, h["id"], want))
    return plan, out


def check(dev, ds, hds, want, n, min_age, lookback):
    """Rows for one DataSource on one device, and the calls it took."""
    rows, now = [], time.time()
    window = max(n * ds["collectInterval"], min_age * 60)
    data = elm("DeviceDatasourceDataById", "DeviceDatasourceDataById", "--deviceId", str(dev["id"]),
               "--id", str(hds), "--start", str(int(now - window)), "--end", str(int(now)))[0]
    got = data.get("instances") or {}
    missing = []
    for name, i in want.items():
        d = got.get(name) or {}
        if not d.get("time"):
            missing.append(name)
        elif all(no_data(x) for row in d["values"] for x in row):
            rows.append(row_for("allnan", dev, ds, i, d["time"][0] / 1000, now))
    if not missing:
        return rows, 1
    points = data.get("dataPoints") or []
    more = ["--datapoints", points[0]] if points else []
    old = elm("DeviceDatasourceDataById", "DeviceDatasourceDataById", "--deviceId", str(dev["id"]),
              "--id", str(hds), "--start", str(int(now - lookback * 3600)), "--end", str(int(now)),
              *more)[0].get("instances") or {}
    for name in missing:
        t = (old.get(name) or {}).get("time")
        rows.append(row_for("stopped" if t else "nodata", dev, ds, want[name], t[0] / 1000 if t else None, now))
    return rows, 2


def run(pool, fn, items, label):
    """fn(*item) for every item, with progress; results in any order, and the items that failed."""
    results, failed, tty = [], [], sys.stderr.isatty()
    if not items:
        return results, failed
    jobs = {pool.submit(fn, *item): item for item in items}
    for done, job in enumerate(concurrent.futures.as_completed(jobs), 1):
        try:
            results.append(job.result())
        except ElmError as e:
            failed.append(jobs[job])
            err(f"\n{jobs[job][0]['displayName']}: {e}")
        if tty:
            err(f"\r{label} {done}/{len(jobs)}", end="" if done < len(jobs) else "\n")
        elif done % max(1, len(jobs) // 20) == 0 or done == len(jobs):
            err(f"{label} {done}/{len(jobs)}")   # a line about every 5%, for a log
    return results, failed


def row_for(kind, dev, ds, inst, last, now):
    return {
        "list": kind,
        "device": dev["displayName"],
        "deviceId": dev["id"],
        "datasource": ds["name"],
        "collectInterval": ds["collectInterval"],
        "collectMethod": ds.get("collectMethod"),
        "instance": inst.get("displayName") or inst["name"],
        "lastCollected": int(last) if last else None,
        "intervalsAgo": max(0, round((now - last) / ds["collectInterval"])) if last else None,
    }


def when(epoch):
    return datetime.datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M") if epoch else "-"


def table(head, rows):
    cols = list(zip(head, *rows))
    widths = [max(len(str(c)) for c in col) for col in cols]
    line = lambda r: "| " + " | ".join(str(c).ljust(w) for c, w in zip(r, widths)) + " |"
    return "\n".join([line(head), "| " + " | ".join("-" * w for w in widths) + " |"] + [line(r) for r in rows])


def report(rows, left, args, scope):
    print(f"# Collection gaps: {scope}\n")
    print(f"Stopped = no poll in the last {args.intervals} collect intervals or {args.min_age:g} minutes, "
          f"whichever is longer. Checked {time.strftime('%Y-%m-%d %H:%M %Z')}.\n")
    for kind, title in LISTS.items():
        these = [r for r in rows if r["list"] == kind]
        print(f"## {title.format(lookback=f'{args.lookback:g}')} ({len(these)})\n")
        if not these:
            print("None.\n")
            continue
        groups = collections.defaultdict(list)
        for r in these:
            groups[r["datasource"]].append(r)
        groups = sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0]))
        if kind == "allnan" and not args.listed:
            print(table(["DataSource", "Instances", "Devices"],
                        [[name, len(g), len({r["deviceId"] for r in g})] for name, g in groups]))
            print("\nNo Data is normal for some DataSources; --nodata lists the instances.\n")
            continue
        for name, g in groups:
            print(f"### {name} ({len(g)}, every {g[0]['collectInterval']}s, {g[0]['collectMethod']})\n")
            g.sort(key=lambda r: (r["device"].lower(), r["instance"].lower()))
            print(table(["Device", "Instance", "Last collected", "Intervals ago"],
                        [[r["device"], r["instance"], when(r["lastCollected"]),
                          r["intervalsAgo"] if r["intervalsAgo"] is not None else "-"] for r in g]))
            print()
    print("## Left out\n")
    print(table(["Why", "Count"], [[k, v] for k, v in left.most_common()]) if left else "Nothing.")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-p", "--profile", default="config", help="elm profile (default: config)")
    p.add_argument("-c", "--config", metavar="PATH", help="elm config file, instead of --profile")
    p.add_argument("--device", metavar="NAME", help="one device: display name, hostname or IP")
    p.add_argument("--datasource", metavar="NAME", help="one DataSource: name or display name")
    p.add_argument("--intervals", type=int, default=3, metavar="N",
                   help="stopped = no poll in the last N collect intervals (default: 3)")
    p.add_argument("--min-age", type=float, default=30, metavar="MINUTES",
                   help="and no poll in this many minutes, so lag is not a stop (default: 30)")
    p.add_argument("--nodata", action="store_true",
                   help="list every polled-but-No-Data instance on a whole-portal run, not a count")
    p.add_argument("--lookback", type=float, default=24, metavar="HOURS",
                   help="how far back to look for the last poll (default: 24)")
    p.add_argument("--jobs", type=int, default=4, metavar="N", help="devices checked at once (default: 4)")
    p.add_argument("--jsonl", action="store_true", help="one JSON record per instance instead of Markdown")
    args = p.parse_args()
    if args.intervals < 1 or args.lookback <= 0 or args.min_age < 0:
        p.error("--intervals must be 1 or more, --lookback above 0 and --min-age 0 or more")
    if args.min_age / 60 >= args.lookback:
        p.error("--min-age must be shorter than --lookback")
    args.listed = args.nodata or bool(args.device or args.datasource)
    TARGET[:] = ["--config", args.config] if args.config else ["--profile", args.profile]

    try:
        fields = "id,name,displayName,collectInterval,collectMethod"
        if args.datasource:
            found = first_match("DatasourceList", "DatasourceList",
                                [f'name:"{args.datasource}"', f'displayName:"{args.datasource}"'], fields)
            if not found:
                sys.exit(f"No DataSource named {args.datasource}")
            only_ds = found[0]["id"]
        else:
            err("Reading DataSources ...")
            found, only_ds = every("DatasourceList", "DatasourceList", "-f", fields), None
        datasources = {d["id"]: d for d in found}

        fields = "id,displayName,hostStatus,sdtStatus"
        if args.device:
            d = args.device
            devices = first_match("DeviceList", "DeviceList",
                                  [f'displayName:"{d}"', f'name:"{d}"', f'displayName~"{d}"'], fields)
            if not devices:
                sys.exit(f"No device named {d}")
            if len(devices) > 1:
                sys.exit(f"{len(devices)} devices match {d}: "
                         + ", ".join(x["displayName"] for x in devices[:10]) + ". Use the full name.")
        else:
            err("Reading devices ...")
            devices = every("DeviceList", "DeviceList", "-f", fields)
        if only_ds:
            uses = {d["id"] for d in every("AssociatedDeviceListByDataSourceId", "AssociatedDeviceListByDataSourceId",
                                           "--id", str(only_ds), "-f", "id")}
            devices = [d for d in devices if d["id"] in uses]
    except ElmError as e:
        sys.exit(f"elm failed: {e}")

    left, live = collections.Counter(), []
    for dev in devices:
        if dev["hostStatus"] == "dead":
            left["device dead"] += 1
        elif dev["hostStatus"] == "dead-collector":
            left["device's collector down"] += 1
        elif in_sdt(dev["sdtStatus"]):
            left["device in SDT"] += 1
        else:
            live.append(dev)
    if args.device and not live:
        err(f"{devices[0]['displayName']} is left out: {next(iter(left))}")

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        plans, failed = run(pool, plan_device, [(dev, datasources, only_ds) for dev in live], "devices")
        todo = []
        for plan, out in plans:
            todo += plan
            left += out
        if failed:
            left["device not checked: elm failed (see above)"] += len(failed)
        checked, failed = run(pool, check, [(*t, args.intervals, args.min_age, args.lookback) for t in todo], "DataSources")
        if failed:
            left["DataSource not checked: elm failed (see above)"] += len(failed)
    rows = [r for found, _ in checked for r in found]
    err(f"{len(live) * 2 + sum(c for _, c in checked)} calls, {len(rows)} found")

    if args.jsonl:
        for r in rows:
            print(json.dumps(r))
        for k, v in left.most_common():
            err(f"left out: {k}: {v}")
    else:
        scope = " / ".join(filter(None, [args.device, args.datasource])) or "whole portal"
        report(rows, left, args, scope)


if __name__ == "__main__":
    main()
