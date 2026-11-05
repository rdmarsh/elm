#!/usr/bin/env python3
"""elm-duplicate-devices: find devices that are probably one device under two names.

A device added once by IP and once by FQDN (or by two collectors) shows up
twice, with its data and alerts split between them. This pairs devices that
share something only one machine should have, and scores each pair on every
check both devices can be compared on:

  serial    a serial number: any auto property with "serial" in its name
            (BIOS, Cisco, Fortinet, entPhysical ...)
  mac       auto.network.mac_address
  sysname   system.sysname, the name the device gives itself (short name,
            any case)
  address   one device is monitored by an address that is in the other's
            system.ips, or both by the same one
  name      the short display name or hostname (before the first dot, any
            case), so GLOBAL01 and global01.example.com match

A pair is listed only when serial, mac, sysname or address match: a name
alone is not enough (two customers can each have a web01). The score is
"x of y": y is the checks both devices have a value for, x the ones that
agree. 2 of 2 is a strong match; 1 of 3 means two values differ, so it is
more likely two machines that share one thing (a cluster, a stack).

A value on more than --max-share devices (default 4) in one portal
identifies nothing ("To be filled by O.E.M.", a VRRP MAC) and is ignored; the
run says how many.

Scope: real devices only (deviceType 0), the whole portal: one DeviceList
query, paged 1000 at a time by id, so past LM's 10,000-row limit.

Two or more portals (-p a,b): one device monitored in both (after a
migration, or by two teams) is a pair across them; --across lists only
those. Across portals an address is weak evidence (customers reuse private
IPs), so such a pair needs a serial, mac or sysname match; address and name
still count in its score.

Output: Markdown on stdout, best matches first (--jsonl: one record per
pair, for pipes); progress and errors on stderr. With --portal NAME each
device name links to the device in the portal (jsonl: a "url" on each).

Examples:
  elm-duplicate-devices.py
  elm-duplicate-devices.py -p portal01 --portal portal01 --min 100
  elm-duplicate-devices.py -p portal01,portal02 --across --portal portal01=acme,portal02=acme2
  elm-duplicate-devices.py --jsonl | jq -r 'select(.matched == .compared) | [.a.id, .b.id] | @tsv'

Requires: elm
"""

import argparse
import collections
import ipaddress
import itertools
import json
import re
import subprocess
import sys
import time

PAGE = 1000
CHECKS = ["serial", "mac", "sysname", "address", "name"]
STRONG = {"serial", "mac", "sysname", "address"}   # a pair needs one of these
ACROSS = {"serial", "mac", "sysname"}              # a pair across portals needs one of these
JUNK = {"", "none", "(none)", "null", "0", "n/a", "na", "unknown", "not specified", "not available",
        "default string", "to be filled by o.e.m.", "system serial number", "chassis serial number",
        "serial number", "localhost", "localhost.localdomain"}
KEEP = ("id", "displayName", "name", "hostStatus", "currentCollectorId")
# The device in the portal's Resources tree. The REST API gives no UI link.
# The id alone (resourcePath=resources-ID) does not open it; with the root
# group in front it does, whatever group the device is in (checked by hand on
# a work portal, 2026-11-05). The portal name is not worked out from elm: only
# -f api and -vv show it, and both show credential material too.
DEFAULT_URL_TEMPLATE = ("https://{portal}.logicmonitor.com/santaba/uiv4/resources/treeNodes"
                        "?resourcePath=resourceGroups-1%2Cresources-{id}")


class ElmError(Exception):
    pass


def err(*args, **kw):
    print(*args, file=sys.stderr, **kw)


def elm(target, key, *args):
    """Rows of `elm -f json ARGS`, retrying a 429 with a growing wait.

    target is ["--profile", P] or ["--config", PATH]."""
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
    raise ElmError(f"{' '.join(args[:4])}: {said}")


def devices(target, portal, fields):
    """Every real device, 1000 at a time, each reduced to what is compared.

    Paged by id (-S id, id>LAST), not by offset: LM stops offset paging at
    10,000 rows with no error, and a big portal has more devices than that.
    Each page is reduced as it arrives, so 20,000 devices' properties are
    never all held at once."""
    found, last = [], -1
    while True:
        page = elm(target, "DeviceList", "DeviceList", "-F", f"deviceType:0,id>{last}", "-S", "id",
                   "-f", fields, "-s", str(PAGE))
        for d in page:
            found.append(({"portal": portal, **{k: d.get(k) for k in KEEP}}, values(d)))
        err(f"  {portal}: {len(found)} devices", end="\r")
        if len(page) < PAGE:
            err()
            return found
        last = page[-1]["id"]


def is_ip(text):
    try:
        ipaddress.ip_address(text)
        return True
    except ValueError:
        return False


def short(name):
    """web01.example.com -> web01; an IP is not a name."""
    name = (name or "").strip().lower()
    return "" if not name or is_ip(name) else name.split(".")[0]


def values(device):
    """{check: set of normalised values} for one device."""
    props = {p["name"]: str(p.get("value", "")).strip()
             for p in (device.get("systemProperties") or []) + (device.get("autoProperties") or [])}
    got = collections.defaultdict(set)
    for name, value in props.items():
        if value.lower() in JUNK:
            continue
        if name.startswith("auto.") and "serial" in name.lower() and not name.endswith(".latest"):
            got["serial"].add(re.sub(r"\s+", " ", value.upper()))
        elif name == "auto.network.mac_address":
            mac = re.sub(r"[^0-9a-f]", "", value.lower())
            if len(mac) == 12 and mac not in ("0" * 12, "f" * 12):
                got["mac"].add(mac)
        elif name == "system.sysname" and short(value):
            got["sysname"].add(short(value))
    ips = {ip.strip() for ip in props.get("system.ips", "").split(",") if ip.strip()}
    if is_ip(device.get("name", "")):
        ips.add(device["name"])
    if ips:
        got["ips"] = ips
    got["name"] = {n for n in (short(device.get("displayName")), short(device.get("name"))) if n}
    return got


def compare(a, b, va, vb):
    """(matched checks, compared checks) for one pair."""
    matched, compared = [], []
    for check in CHECKS:
        if check == "address":
            if not (va.get("ips") and vb.get("ips")):
                continue
            hit = a["name"].lower() == b["name"].lower() or a["name"] in vb["ips"] or b["name"] in va["ips"]
        else:
            if not (va.get(check) and vb.get(check)):
                continue
            hit = bool(va[check] & vb[check])
        compared.append(check)
        if hit:
            matched.append(check)
    return matched, compared


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-p", "--profile", default="config",
                   help="elm profile, or several comma-separated to compare portals (default: config)")
    p.add_argument("-c", "--config", metavar="PATH", help="elm config file, instead of --profile")
    p.add_argument("--across", action="store_true", help="with several portals: only pairs across two of them")
    p.add_argument("--min", type=float, default=0, metavar="PERCENT",
                   help="list only pairs that match on at least this %% of their checks (default: all)")
    p.add_argument("--max-share", type=int, default=4, metavar="N",
                   help="ignore a value shared by more than N devices in one portal (default: 4)")
    p.add_argument("--jsonl", action="store_true", help="one JSON record per pair instead of Markdown")
    p.add_argument("--portal", metavar="NAME",
                   help="portal subdomain (the bit before .logicmonitor.com): link each device to it. "
                        "With several profiles: PROFILE=NAME,PROFILE=NAME")
    p.add_argument("--url-template", metavar="URL",
                   help="override the link format. Placeholders: {portal} {id}")
    a = p.parse_args()
    if a.config:
        targets = {a.config: ["--config", a.config]}
    else:
        targets = {name: ["--profile", name] for name in dict.fromkeys(n.strip() for n in a.profile.split(",")) if name}
    many = len(targets) > 1
    if a.across and not many:
        p.error("--across needs two or more profiles: -p a,b")
    subdomain = {}
    if a.portal:
        if "=" in a.portal:
            subdomain = dict(part.split("=", 1) for part in a.portal.split(",") if "=" in part)
            missing = [t for t in targets if t not in subdomain]
            if missing:
                p.error(f"--portal has no NAME for {', '.join(missing)}")
        else:
            subdomain = {t: a.portal for t in targets}
    template = a.url_template or (DEFAULT_URL_TEMPLATE if a.portal else None)
    if template and "{portal}" in template and not a.portal:
        p.error("that link template needs {portal}: pass --portal NAME")

    err("Fetching devices ...")
    found = []
    for portal, target in targets.items():
        try:
            found += devices(target, portal, ",".join(KEEP) + ",systemProperties,autoProperties")
        except ElmError as e:
            sys.exit(f"elm-duplicate-devices: {portal}: {e}")
    # A device is (portal, id): ids repeat across portals.
    by_key = {(d["portal"], d["id"]): d for d, _ in found}
    vals = {(d["portal"], d["id"]): v for d, v in found}

    # Candidate pairs: devices sharing a serial, MAC or sysname value, or one
    # monitored at an address in the other's system.ips.
    index = collections.defaultdict(set)
    for k, v in vals.items():
        for check in ("serial", "mac", "sysname"):
            for value in v.get(check, ()):
                index[(check, value)].add(k)
        for ip in v.get("ips", ()):
            index[("ips", ip)].add(k)
    # Common in any one portal: the same device in two portals is not "common".
    common = {kv for kv, keys in index.items()
              if max(collections.Counter(portal for portal, _ in keys).values()) > a.max_share}
    pairs = set()
    for (check, value), keys in index.items():
        if (check, value) in common:
            continue
        if check == "ips":
            # only a device monitored at this address pairs with the others
            heads = {k for k in keys if by_key[k]["name"] == value}
            pairs |= {tuple(sorted((h, o))) for h in heads for o in keys if o != h}
        else:
            pairs |= {tuple(sorted(pair)) for pair in itertools.combinations(keys, 2)}
    # A common value is no evidence either way: as if the device had none.
    for v in vals.values():
        for check in ("serial", "mac", "sysname"):
            v[check] = {s for s in v.get(check, ()) if (check, s) not in common}

    rows = []
    for x, y in pairs:
        dx, dy = by_key[x], by_key[y]
        apart = dx["portal"] != dy["portal"]
        if a.across and not apart:
            continue
        matched, compared = compare(dx, dy, vals[x], vals[y])
        if not (ACROSS if apart else STRONG) & set(matched):
            continue
        pct = round(100 * len(matched) / len(compared))
        if pct < a.min:
            continue
        rows.append({"matched": len(matched), "compared": len(compared), "percent": pct,
                     "on": matched, "differs": [c for c in compared if c not in matched],
                     "a": dict(dx), "b": dict(dy)})
        if template:
            for d in (rows[-1]["a"], rows[-1]["b"]):
                d["url"] = template.format(portal=subdomain.get(d["portal"], ""), id=d["id"])
    rows.sort(key=lambda r: (-r["percent"], -r["matched"], r["a"]["displayName"].lower(), r["a"]["portal"]))

    err(f"{len(found)} devices, {len(rows)} likely pairs"
        + (f"; {len(common)} values on more than {a.max_share} devices ignored" if common else ""))
    if a.jsonl:
        for r in rows:
            print(json.dumps(r))
        return
    if not rows:
        print("No devices look like the same device under two names.")
        return

    def cell(text):
        return str(text).replace("|", "\\|")

    def device(d):
        return f"[{cell(d['displayName'])}]({d['url']})" if d.get("url") else cell(d["displayName"])

    def side(d):
        return (f"| {device(d)} " + (f"| {cell(d['portal'])} " if many else "")
                + f"| {cell(d['name'])} | {d['hostStatus']} ")

    portal_col = "Portal | " if many else ""
    print(f"| # | Match | Device | {portal_col}Monitored as | Status | Other device | {portal_col}Monitored as | Status "
          "| Matched on | Differs |")
    print("|---:|---|" + "---|" * (8 + 2 * many))
    for n, r in enumerate(rows, 1):
        print(f"| {n} | {r['matched']} of {r['compared']} ({r['percent']}%) " + side(r["a"]) + side(r["b"])
              + f"| {', '.join(r['on'])} | {', '.join(r['differs']) or '-'} |")


if __name__ == "__main__":
    main()
