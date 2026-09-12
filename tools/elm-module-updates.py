#!/usr/bin/env python3
"""elm-module-updates: list LogicModules that have an upgrade waiting.

Answers the question "which stock LogicMonitor modules am I running an old
version of, and does anything actually use them?" -- by default, DataSources
that are

  1. NOT customised locally,
  2. either have a newer version available in the LM Exchange, or are
     deprecated -- both mean "this needs attention", and a deprecated module
     can never have an upgrade because it is replaced rather than updated,
  3. are LM official (originStatus CORE or DEPRECATED),

split into two sections -- not in use, then in use -- each sorted from the most
out of date to the least. `-t`/`--type` reports any other module type, several
comma-separated, or ALL: the same one call already carries propertysources,
configsources, eventsources, logsources, topologysources, SNMP sysOID maps and
appliesTo functions, so other types cost nothing extra. With more than one type
each section gets a table per type.

Everything comes from ONE API call: `elm V4Metadata`
(GET /setting/logicmodules/metadata), the same feed the portal's
Modules -> My Module Toolbox page is built on. It returns every installed
module plus everything installable from the Exchange, with per-module
installation status. Nothing else is queried, so the report costs one request
no matter how big the portal is.

How each criterion is derived (field -> meaning):

  installationStatuses   IS_INSTALLED   the module exists in this portal
                         CAN_UPGRADE    a newer published version exists
                         IS_CUSTOMIZED  locally edited, so upgrading would
                                        overwrite local changes
                         CAN_INSTALL    Exchange-only, not installed here
  originStatus           CORE           LM official. Other values seen:
                                        DEPRECATED, COMMUNITY, SECURITY_REVIEW
  isInUse                true/false     LM's own in-use flag
  originVersion          e.g. "2.0.0"   version currently installed
  originPublishedAtMS    epoch ms       when THAT version was published

Ordering ("most out of date"):
  LM does not tell you the version number you would be upgrading TO -- the feed
  carries an `upgradeableRegistryId` pointing at the newer registry entry, but
  no endpoint in the v3 API resolves it. So out-of-dateness is ranked by how old
  the version you are running is: `originPublishedAtMS` ascending, oldest first.
  A module whose installed version was published in 2017 is further behind than
  one published last year. The `age` column is years since that publish date.

Caveats worth knowing before acting on the output:
  - Registry publish timestamps only go back to about 2017-05. Modules older
    than that all bunch up around the same date and cannot be ranked against
    each other.
  - The usage column counts INSTANCES for datasources and configsources, never
    devices. Device figures need one API call per module, which `--devices`
    opts into: it adds `devices` (how many the module applies to) and `active`
    (how many are actually collecting). All three are different numbers.
  - The usage count is not one field. `associatedHostsCount` is hard-wired to 0
    for DataSources and ConfigSources (so their column uses
    `associatedInstancesCount`) but is a real number for every other type;
    appliesTo functions use `useInModulesCount`. The Markdown column is headed
    with the unit -- `instances`, `hosts` or `modules`; `--csv`/`--json` carry
    both a `usage` number and a `usage_of` label. A module can be in use with a
    count of 0 (applied, nothing discovered yet).
  - "in use" is LM's flag, not an assertion that anyone looks at the data.
  - Upgrading is done in the portal (or via the Exchange), not here -- elm is
    read-only.

Status messages go to stderr; the report goes to stdout.
"""

import argparse
import csv
import datetime
import json
import math
import shutil
import subprocess
import sys

# Module types the metadata feed reports, for --type. DATASOURCE is the default
# because it is what the report was built for; the feed covers the rest at no
# extra cost, so they are offered too.
TYPES = ("DATASOURCE", "PROPERTYSOURCE", "CONFIGSOURCE", "EVENTSOURCE",
         "LOGSOURCE", "TOPOLOGYSOURCE", "SNMP_SYSOID_MAP",
         "APPLIESTO_FUNCTION", "JOBMONITOR", "DIAGNOSTICSOURCE",
         "REMEDIATIONSOURCE")

MS_PER_YEAR = 365.2425 * 24 * 60 * 60 * 1000

# Deprecated modules are REPLACED, not updated, so they never carry CAN_UPGRADE
# and can never appear in the default report -- you could run it forever and not
# learn that in-use modules are deprecated with an end-of-support date. The
# report therefore counts them separately and says so on stderr.
DEPRECATION_URL = ("https://www.logicmonitor.com/support/logicmodules/"
                   "about-logicmodules/deprecated-logicmodules")

# Which `associatedCounts` field actually measures usage, per module type, and
# what it counts. The feed reports several counts per module and the useful one
# differs: `associatedHostsCount` is a real number for most types but is
# hard-wired to 0 for DATASOURCE and CONFIGSOURCE, where the instance count is
# the live figure. Anything not listed falls back to hosts.
USAGE = {
    "DATASOURCE":         ("associatedInstancesCount", "instances"),
    "CONFIGSOURCE":       ("associatedInstancesCount", "instances"),
    "APPLIESTO_FUNCTION": ("useInModulesCount", "modules"),
}
USAGE_DEFAULT = ("associatedHostsCount", "hosts")

# Types whose devices can be counted. For these the feed's usage number counts
# INSTANCES, not devices -- their associatedHostsCount is hard-wired to 0 --
# and the device figures need one AssociatedDeviceListByDataSourceId call each,
# which is what --devices opts into.
DEVICE_LISTABLE = ("DATASOURCE", "CONFIGSOURCE")

# Portal UI link. No API field carries one -- no endpoint returns a deep link,
# and the route belongs to the LM web UI, not the REST API -- but the feed
# happens to supply both halves of it: `model` (exchangeDataSources,
# exchangePropertySources, ...) is the toolbox path segment, and `id` is the
# module id, so one template covers every module type.
#
# Pass `--portal NAME` to switch links on. The subdomain is deliberately NOT
# auto-detected: the only ways to get it out of elm are `-f api` (which also
# prints the Authorization header) and `-vv` (which prints a truncated
# access_id/access_key fingerprint under a SENSITIVE INFORMATION banner).
# Neither is something a tool should capture just to build a URL.
#
# Override with `--url-template`; the placeholders are {portal} {model} {id}
# {name}.
DEFAULT_URL_TEMPLATE = ("https://{portal}.logicmonitor.com"
                        "/santaba/uiv4/modules/toolbox/{model}/edit/{id}")


def risk(instances, devices, years):
    """A 0-10 score for "how much should I worry about this upgrade?".

    Two different things go in, and they are different kinds of thing:

    CONSEQUENCE -- how much breaks if it goes wrong. Breadth counts about twice
    depth, so 1 instance on 1000 devices outranks 1000 instances on 1 device.
    LogicMonitor's worst documented outcome, an AppliesTo change that stops a
    module applying, destroys history *per device*, so breadth is the
    multiplier on permanent data loss; alert storms scale with devices too.
    Depth is the volume of history at stake on one host, so it carries about
    half the weight rather than none.

    LIKELIHOOD -- how probable that is. The further behind you are, the more
    released change is folded into one jump, and the more chance it contains a
    renamed datapoint, a restructured Active Discovery or an AppliesTo change.
    Age is a proxy for the size of the diff, not a measure of it: the API
    cannot tell us the target version, let alone what changed between here and
    there, so this is the best available stand-in and it is weighted modestly.

    Age contributes at most about 1.4 of the 10, so it nudges the order rather
    than driving it: a nine-year-old module on one device still scores 2.3,
    while a six-month-old one on 300 devices scores 8.0. All three inputs stay
    visible in their own columns, so the number is always auditable.
    """
    return round(min(10.0,
                     2.0 * math.log10(1 + max(devices, 0))
                     + 1.0 * math.log10(1 + max(instances, 0))
                     + 0.15 * max(years, 0)), 1)


def err(*args):
    print(*args, file=sys.stderr)


def fetch_metadata(elm, profile, config):
    """Run `elm -f json V4Metadata` and return the list of module records."""
    cmd = [elm]
    cmd += ["--config", config] if config else ["--profile", profile]
    cmd += ["-f", "json", "V4Metadata"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    try:
        items = json.loads(out.stdout)["V4Metadata"]
    except Exception:
        # Non-zero exit with unparseable output is a real failure: show elm's
        # own error, which is the useful one (bad profile, 403, network).
        err(out.stderr.strip() or f"{elm} V4Metadata produced no usable output")
        return None
    # elm before the bare-array fix returned this endpoint double-wrapped
    # ([[{...}]]) and exited 1 after printing perfectly good JSON. Accept both
    # shapes so the tool works against an older binary.
    if len(items) == 1 and isinstance(items[0], list):
        items = items[0]
    return items


def device_counts(elm, profile, config, module_id):
    """{applied, active} devices for one datasource/configsource.

    Three different numbers get confused here, so they are kept apart:
      instances  what the feed's usage column counts -- discovered objects
      applied    devices the module's appliesTo matches, from `-C` (LM's true
                 total; the row list itself caps at 1000 per page)
      active     of the devices returned, those with hasActiveInstance -- i.e.
                 actually collecting. Only exact while applied <= 1000, since
                 beyond that the rows are capped; reported as a floor otherwise.
    One module here matches 1205 devices but collects 2 instances on 2 of them.
    """
    cmd = [elm]
    cmd += ["--config", config] if config else ["--profile", profile]
    base = cmd + ["AssociatedDeviceListByDataSourceId", "--id", str(module_id)]
    total = subprocess.run(base + ["-C"], capture_output=True, text=True).stdout.strip()
    rows = subprocess.run(cmd + ["-f", "json", "AssociatedDeviceListByDataSourceId",
                                 "--id", str(module_id), "-s0"],
                          capture_output=True, text=True).stdout
    try:
        devs = json.loads(rows)["AssociatedDeviceListByDataSourceId"]
    except Exception:
        devs = []
    try:
        applied = int(total)
    except ValueError:
        applied = len(devs)
    active = sum(1 for d in devs if d.get("hasActiveInstance"))
    return {"applied": applied, "active": active,
            "capped": applied > len(devs)}


def select(items, types, statuses, include_customised, include_current,
           tags=None):
    """Apply the criteria and return the matching module records.

    `types` and `statuses` are each a set of accepted values, or the string
    "ALL" to accept any.
    """
    out = []
    for i in items:
        st = set(i.get("installationStatuses") or ())
        if "IS_INSTALLED" not in st:
            continue                                  # Exchange-only entry
        if types != "ALL" and i.get("type") not in types:
            continue
        # A deprecated module can never carry CAN_UPGRADE -- it is replaced,
        # not updated -- so requiring an upgrade would silently exclude every
        # one of them. Both mean "this needs attention", so either qualifies.
        deprecated = i.get("originStatus") == "DEPRECATED"
        if not include_current and "CAN_UPGRADE" not in st and not deprecated:
            continue
        if not include_customised and "IS_CUSTOMIZED" in st:
            continue
        if statuses != "ALL" and i.get("originStatus") not in statuses:
            continue
        if tags and not (tags & {t.lower() for t in (i.get("tags") or ())}):
            continue
        out.append(i)
    return out


def row(i, now_ms, url_template=None, portal=None):
    """Flatten one module record into the report's columns."""
    pub = i.get("originPublishedAtMS")
    counts = i.get("associatedCounts") or {}
    field, label = USAGE.get(i.get("type"), USAGE_DEFAULT)
    url = (url_template.format(id=i.get("id", ""), name=i.get("name", ""),
                               model=i.get("model", ""), portal=portal or "")
           if url_template else "")
    return {
        "published": (datetime.datetime.fromtimestamp(
            pub / 1000, datetime.timezone.utc).strftime("%Y-%m-%d")
            if pub else ""),
        "age": f"{(now_ms - pub) / MS_PER_YEAR:.1f}" if pub else "",
        "type": i.get("type") or "",
        "version": i.get("originVersion") or "",
        "id": i.get("id") or "",
        "name": i.get("name") or "",
        "group": i.get("group") or "",
        "usage": counts.get(field, ""),
        "usage_of": label,
        "risk": "",
        "tags": ";".join(i.get("tags") or ()),
        "devices": "",
        "active": "",
        # `active` stays a plain number so a spreadsheet or jq can use it. The
        # ">1000 devices so this is a floor" caveat rides alongside in
        # active_capped rather than turning the number into "2+", which would
        # make the whole column non-numeric for every consumer.
        "active_capped": "",
        "url": url,
        "customised": "yes" if "IS_CUSTOMIZED" in set(
            i.get("installationStatuses") or ()) else "no",
        "upgrade": "yes" if "CAN_UPGRADE" in set(
            i.get("installationStatuses") or ()) else "no",
        "status": i.get("originStatus") or "",
        "in_use": "yes" if i.get("isInUse") else "no",
    }


def ordered(mods, now_ms, url_template=None, portal=None, counted=None,
            sort="age"):
    """Rows in the requested order.

    `age` (default) is oldest-published first, undated last by name -- the
    "most out of date" reading. `risk` is highest-scoring first, with age as
    the tie-break. `name` is alphabetical.
    """
    dated = sorted((m for m in mods if m.get("originPublishedAtMS")),
                   key=lambda m: m["originPublishedAtMS"])
    undated = sorted((m for m in mods if not m.get("originPublishedAtMS")),
                     key=lambda m: (m.get("name") or "").lower())
    out = []
    for m in dated + undated:
        r = row(m, now_ms, url_template, portal)
        c = (counted or {}).get((m.get("type"), str(m["id"])))
        if c:
            r["devices"] = c["applied"]
            r["active"] = c["active"]
            r["active_capped"] = "yes" if c["capped"] else "no"
        # Devices actually collecting is the truest breadth; fall back to the
        # devices the module applies to, and to 0 when --devices was not used,
        # in which case the score reflects depth alone and says so.
        breadth = (c["active"] or c["applied"]) if c else 0
        r["risk"] = risk(r["usage"] or 0, breadth, float(r["age"] or 0))
        out.append(r)
    if sort == "risk":
        # `out` is already in age order, and sorted() is stable, so equal
        # scores keep it -- the tie-break is free.
        out.sort(key=lambda r: -float(r["risk"] or 0))
    elif sort == "name":
        out.sort(key=lambda r: r["name"].lower())
    return out


# `type` is dropped from the output unless more than one module type is
# selected -- a single-type report repeats it on every row for nothing.
COLUMNS = ("published", "age", "type", "status", "version", "id", "name",
           "group", "tags", "usage", "usage_of", "risk")
# `url` is appended to CSV/JSON only when a template is configured; in Markdown
# it becomes a link on the name instead of a column of its own.



def cell(r, c):
    """One table cell. The name carries the portal link when there is one."""
    if c == "name" and r.get("url"):
        return f"[{r['name']}]({r['url']})"
    if c == "tags" and r["tags"]:
        return ", ".join(r["tags"].split(";"))
    if c == "active" and r["active"] != "" and r["active_capped"] == "yes":
        # Only the rendered table carries the "more than this" marker -- see
        # the note on active_capped in row().
        return f"{r['active']}+"
    return str(r[c])


def gfm_table(rows, cols=COLUMNS, headers=None):
    head = ("| " + " | ".join((headers or {}).get(c, c) for c in cols) + " |\n"
            "|" + "|".join("---" for _ in cols) + "|")
    body = "\n".join("| " + " | ".join(cell(r, c) for c in cols) + " |"
                     for r in rows)
    return head + ("\n" + body if body else "")


def by_type(rows):
    """Group report rows by module type, preserving each group's order.

    Types are ordered by size, largest first, so the type you asked about leads
    when several are selected.
    """
    groups = {}
    for r in rows:
        groups.setdefault(r["type"], []).append(r)
    return sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0]))


def main(argv=None):
    p = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Report: stdout. Progress and caveats: stderr.")
    p.add_argument("-p", "--profile", default="config",
                   help="elm credential profile (default: config)")
    p.add_argument("-c", "--config", metavar="PATH",
                   help="full path to an elm .ini, instead of --profile")
    p.add_argument("-t", "--type", default="DATASOURCE", metavar="TYPE,...",
                   help="module type(s) to report, comma-separated (default: "
                        "DATASOURCE; ALL for every type). With more than one "
                        "type the Markdown report gets a table per type inside "
                        "each section, and a `type` column appears in --csv / "
                        "--json. Choices: " + ", ".join(TYPES) + ", ALL")
    p.add_argument("--status", default="CORE,DEPRECATED", metavar="S,...",
                   help="keep only these originStatus values (default: "
                        "CORE,DEPRECATED -- LM official modules that are "
                        "either behind or on their way out). Try COMMUNITY, "
                        "SECURITY_REVIEW, or ALL")
    p.add_argument("--include-customised", action="store_true",
                   help="also list locally customised modules (upgrading one "
                        "overwrites the local edits)")
    p.add_argument("--tag", metavar="TAG,...",
                   help="keep only modules carrying at least one of these tags "
                        "(case-insensitive), e.g. --tag linux,windows")
    p.add_argument("--sort", default="age", choices=("age", "risk", "name"),
                   help="row order within each section: age (default, most out "
                        "of date first), risk (highest score first), or name. "
                        "--sort risk turns on --devices by itself when the "
                        "lookups are affordable, since the score is only "
                        "trustworthy with a device count")
    p.add_argument("--devices", action="store_true",
                   help="add devices/active columns. For datasources and "
                        "configsources the feed counts INSTANCES, not devices, "
                        "so this costs one extra API call per module: "
                        "`devices` is how many the module applies to, `active` "
                        "how many are actually collecting")
    p.add_argument("--max-device-calls", type=int, default=100, metavar="N",
                   help="refuse --devices above N modules (default: 100, "
                        "0 = no limit)")
    p.add_argument("--include-current", action="store_true",
                   help="also list modules that are already up to date")
    p.add_argument("--csv", action="store_true",
                   help="emit one flat CSV of both sections (with in_use, "
                        "customised and upgrade columns) "
                        "instead of the GFM report")
    p.add_argument("--json", action="store_true",
                   help="emit the report rows as JSON, in report order")
    p.add_argument("--portal", metavar="NAME",
                   help="portal subdomain (the bit before .logicmonitor.com). "
                        "Giving it turns each module name into a link to that "
                        "module in My Module Toolbox. Not auto-detected -- "
                        "see the note in the source")
    p.add_argument("--url-template", metavar="URL",
                   help="override the link format. Placeholders: {portal} "
                        "{model} {id} {name}. Default: "
                        + DEFAULT_URL_TEMPLATE.replace("%", "%%"))
    p.add_argument("--elm", default="elm", metavar="PATH",
                   help="elm executable to call (default: elm on PATH)")
    args = p.parse_args(argv)

    if shutil.which(args.elm) is None:
        err(f"{args.elm} not found on PATH")
        return 1

    types = ("ALL" if args.type.upper() == "ALL"
             else {t.strip().upper() for t in args.type.split(",") if t.strip()})
    if types != "ALL":
        unknown = types - set(TYPES)
        if unknown:
            err(f"unknown module type(s): {', '.join(sorted(unknown))}")
            err("choose from: " + ", ".join(TYPES) + ", ALL")
            return 1

    statuses = ("ALL" if args.status.upper() == "ALL"
                else {s.strip().upper() for s in args.status.split(",") if s.strip()})

    err(f"fetching module metadata ({args.config or args.profile}) ...")
    items = fetch_metadata(args.elm, args.profile, args.config)
    if items is None:
        return 1
    err(f"{len(items)} module records returned")

    tags = ({t.strip().lower() for t in args.tag.split(",") if t.strip()}
            if args.tag else None)
    mods = select(items, types, statuses, args.include_customised,
                  args.include_current, tags)

    # Deprecated modules of the same type(s), whatever the status filter is.
    dep = [i for i in items
           if "IS_INSTALLED" in set(i.get("installationStatuses") or ())
           and i.get("originStatus") == "DEPRECATED"
           and (types == "ALL" or i.get("type") in types)]
    dep_used = [i for i in dep if i.get("isInUse")]

    if not mods:
        err("nothing matches those criteria")
        return 0

    multi = types == "ALL" or len(types) > 1
    now_ms = datetime.datetime.now(datetime.timezone.utc).timestamp() * 1000

    counted = {}
    if args.sort == "risk" and not args.devices:
        # The score is only trustworthy with a device count, so asking for it
        # asks for the lookups -- but silently spending 2400 calls is worse
        # than a weaker score, so this only happens when it is affordable.
        n = sum(1 for m in mods if m.get("type") in DEVICE_LISTABLE)
        if not args.max_device_calls or n <= args.max_device_calls:
            args.devices = True
        else:
            err(f"note: --sort risk would need {n} device lookups, over "
                f"--max-device-calls ({args.max_device_calls}), so the score "
                "rests on instances alone. Narrow the report, or raise the "
                "limit, for a device-aware ranking.")
    if args.devices:
        listable = [m for m in mods if m.get("type") in DEVICE_LISTABLE]
        if args.max_device_calls and len(listable) > args.max_device_calls:
            err(f"--devices needs one API call per module and {len(listable)} "
                f"match, over --max-device-calls ({args.max_device_calls}).")
            err("Narrow with --tag / -t / --status, or raise the limit "
                "(0 = no limit).")
            return 1
        err(f"counting devices for {len(listable)} module(s) "
            f"({len(listable) * 2} call(s), two each) ...")
        for n, m in enumerate(listable, 1):
            counted[(m.get("type"), str(m["id"]))] = device_counts(
                args.elm, args.profile, args.config, m["id"])
            if n % 25 == 0:
                err(f"  {n}/{len(listable)}")
    template = args.url_template or (DEFAULT_URL_TEMPLATE if args.portal else None)
    if template and "{portal}" in template and not args.portal:
        err("that link template needs {portal}: pass --portal NAME")
        return 1
    linked = bool(template)
    unused = ordered([m for m in mods if not m.get("isInUse")], now_ms,
                     template, args.portal, counted, args.sort)
    inuse = ordered([m for m in mods if m.get("isInUse")], now_ms,
                    template, args.portal, counted, args.sort)
    dep_shown = sum(1 for m in mods if m.get("originStatus") == "DEPRECATED")
    err(f"{len(mods)} match: {len(unused)} not in use, {len(inuse)} in use"
        + (f" ({dep_shown} deprecated)" if dep_shown else ""))
    if dep and statuses != "ALL" and "DEPRECATED" not in statuses:
        err(f"note: {len(dep)} installed module(s) of this type are DEPRECATED "
            f"({len(dep_used)} in use) and your --status excludes them. They "
            "cannot be upgraded -- they are replaced -- so they are in the "
            "report by default. Add DEPRECATED back to --status to see them.")
    elif dep_shown:
        err(f"note: {dep_shown} of the modules above are DEPRECATED -- they "
            "are replaced by a different module rather than upgraded, on LM's "
            "timetable.")
        err(f"      replacements and end-of-support dates: {DEPRECATION_URL}")

    if args.json:
        rows = unused + inuse
        if not linked:
            rows = [{k: v for k, v in r.items() if k != "url"} for r in rows]
        json.dump(rows, sys.stdout, indent=2)
        print()
        return 0

    if args.csv:
        cols = COLUMNS + ("devices", "active", "active_capped", "in_use",
                          "customised", "upgrade")
        if linked:
            cols += ("url",)
        # type/usage/usage_of stay in CSV and JSON even for a single-type
        # report: downstream consumers get a stable schema, never have to guess
        # the unit, and -- since module ids are only unique WITHIN a type (329
        # ids in one test portal belong to several types, id 28 to six) -- an id
        # without its type is ambiguous. elm-change-advice.py reads this back.
        # extrasaction="ignore": every row carries `url` whether or not links
        # are configured, and `type` is dropped from some views, so the row
        # dicts are deliberately wider than the selected columns.
        w = csv.DictWriter(sys.stdout, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(unused + inuse)
        return 0

    title = ("modules" if multi
             else args.type.strip().lower().replace("_", " ") + "s")
    print(f"# Upgradable {title}\n")
    print(f"Profile: `{args.config or args.profile}`  |  "
          f"generated {datetime.date.today():%Y-%m-%d}  |  "
          f"{len(mods)} module(s)\n")
    deprecated_in = statuses == "ALL" or "DEPRECATED" in statuses
    print(f"Selected: origin status {args.status.upper()}"
          + ("" if args.include_customised else ", not locally customised")
          + ("" if args.include_current else
             (", upgrade available or deprecated" if deprecated_in
              else ", upgrade available"))
          + {"age": ". Sorted most out of date first.",
             "risk": ". Sorted highest risk first.",
             "name": ". Sorted by name."}[args.sort] + "\n")
    # Every Markdown table covers exactly one type -- one per section when a
    # single type is selected, one per `### TYPE` heading otherwise -- so the
    # type and the usage unit are constant within a table. Both are dropped as
    # columns: the type is in the heading, and the unit becomes the `usage`
    # header. (`--csv`/`--json` keep them as real columns instead.)
    # `status` earns a column only when it can differ between rows. The default
    # report is all CORE, and the "Selected:" line above already says so, which
    # is the same reason `type` and `usage_of` are dropped when constant.
    varies = len({r["status"] for r in unused + inuse}) > 1
    cols = tuple(c for c in COLUMNS
                 if c not in ("type", "usage_of")
                 and (c != "status" or varies))
    if args.devices:
        cols += ("devices", "active")
    for heading, rows in (("Not in use", unused), ("In use", inuse)):
        print(f"## {heading} ({len(rows)})\n")
        if multi:
            # One table per type, rather than one long interleaved table: an
            # 8-year-old propertysource and an 8-year-old datasource are not
            # really comparable, and each type is upgraded in its own place.
            for type_, group in by_type(rows):
                print(f"### {type_} ({len(group)})\n")
                print(gfm_table(group, cols,
                                {"usage": group[0]["usage_of"]}) + "\n")
        else:
            print(gfm_table(rows, cols,
                            {"usage": (unused + inuse)[0]["usage_of"]}) + "\n")
    print("## Legend\n")
    print("- **published** -- when the version you have installed was published "
          "to the LM Exchange. The API does not expose the version you would "
          "upgrade *to*, so this is the ranking key: the older it is, the "
          "further behind you are.")
    print("- **age** -- years since that publish date. Registry timestamps only "
          "start around 2017-05, so anything older bunches up there and cannot "
          "be ranked against its peers.")
    print("- **version** -- the installed version, not the available one.")
    if varies:
        print("- **status** -- the module's `originStatus`: `CORE` is LM "
              "official, `DEPRECATED` means it is replaced rather than "
              "updated (so it can never carry an upgrade), and `COMMUNITY` / "
              "`SECURITY_REVIEW` are the other published states. Shown only "
              "when the selection contains more than one -- the \"Selected:\" "
              "line above names it when they are all the same.")
    print("- **tags** -- the module's own tags. `--tag` filters on them.")
    print("- **usage** (headed `instances`, `hosts` or `modules`) -- how widely "
          "the module is used, from `associatedCounts`. Which count that is depends "
          "on the module type, because the feed's counts are not uniform: "
          "datasources and configsources use `associatedInstancesCount` (their "
          "`associatedHostsCount` is hard-wired to 0 and is not shown), "
          "appliesTo functions use `useInModulesCount`, and everything else "
          "uses `associatedHostsCount`. `--csv`/`--json` always carry both a "
          "`usage` number and a `usage_of` label. A module can be in use with a "
          "count of 0.")
    if args.devices:
        print("- **devices** / **active** -- devices the module *applies to* "
              "(its appliesTo match), and how many of those are actually "
              "collecting (`hasActiveInstance`). These are not the same as "
              "`instances`: one module in this portal applies to 1205 devices "
              "and collects 2 instances on 2 of them. A trailing `+` on "
              "`active` means the module applies to more than 1000 devices, "
              "the API's per-page cap, so the figure is a floor. In "
              "`--csv`/`--json` that marker is a separate `active_capped` "
              "column, leaving `active` a plain number.")
    print("- **risk** -- 0-10, combining how much breaks with how likely that "
          "is. Consequence: breadth counts about twice depth (both "
          "log-scaled), so 1 instance on 1000 devices outranks 1000 instances "
          "on 1 device -- an AppliesTo change destroys history per device, and "
          "alert storms scale with devices. Likelihood: every year behind adds "
          "0.15, because a bigger version gap folds in more released change "
          "and more chance of a renamed datapoint or restructured discovery. "
          "Age contributes at most ~1.4 of the 10, so it nudges rather than "
          "drives: a nine-year-old module on one device still scores 2.3."
          + ("" if args.devices else " **No device count was fetched, so the "
             "consequence half rests on instances alone and understates wide, "
             "shallow modules -- run with --devices or --sort risk.**"))
    print("- **in use** -- LM's own `isInUse` flag: something references the "
          "module. It does not mean anyone reads the data.")
    print("\nUpgrade from LogicMonitor Exchange -- elm is read-only.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
