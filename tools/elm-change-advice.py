#!/usr/bin/env python3
"""elm-change-advice: draft a change notice for a LogicModule upgrade.

Turns "we are upgrading these modules" into the notice an IT department
actually sends: what is changing, when, who is affected, what to expect, and
what happens if it goes wrong -- with the affected devices and counts filled in
from the live portal rather than guessed.

    tools/elm-module-updates.py --csv | head -20 > batch.csv
    tools/elm-change-advice.py --date 2026-10-02 --from batch.csv

    tools/elm-change-advice.py --date 2026-10-02 --id 28,544 --format all

It **drafts only**. Nothing is sent, no mail is configured, no ticket is
raised: the notice goes to stdout for a human to read, edit and send. elm is
read-only and this tool inherits that -- it also never performs the upgrade it
describes, which is done in the portal.

Three output shapes (`--format`, default `email`, `all` for every one):

  email  plain text with a suggested subject line, ready to paste into a mail
         client -- wrapped to 72 columns
  itsm   field-per-line block for a change record: summary, risk, impact,
         implementation plan, backout plan, test plan
  md     the same content as Markdown, for a wiki page or ticket description

What is filled in from the API, and what is left for you:

  filled  module names, installed versions and their publish dates, module
          type, collection method and interval, whether each module is locally
          customised, the number of instances/hosts affected, and -- for
          datasources and configsources -- the affected devices, named under
          the module they belong to when there are few enough to read
          (--list-devices-under, default 10)
  flagged a DEPRECATED module is called out loudly: it cannot be upgraded at
          all, only replaced by a different module, on LM's timetable

  linked  --portal NAME links each module to itself in the portal: a Markdown
          link on the name, a URL on its own line in the plain-text formats

  yours   the change window time, the approver, the change reference, the
          contact, and anything site-specific. These appear as <ANGLE BRACKET>
          placeholders so an unedited draft is obviously unfinished.

Risk is derived, not asserted: a locally customised module is called out as
higher risk because upgrading overwrites local edits, and a module on many
instances is called out as wider blast radius. `--risk` overrides it.

Data comes from `elm V4Metadata` (one call) plus one
`AssociatedDeviceListByDataSourceId` call per datasource/configsource to name
the affected devices; `--no-devices` skips those calls and reports counts only.
Status messages go to stderr; the notice goes to stdout.
"""

import argparse
import csv
import datetime
import json
import shutil
import subprocess
import sys
import textwrap

WRAP = 72

# Module types whose affected devices can be listed. The others have no
# equivalent "which devices use this" endpoint in the v3 API, so they report
# the usage count from the metadata feed only.
DEVICE_LISTABLE = ("DATASOURCE", "CONFIGSOURCE")

USAGE = {
    "DATASOURCE":         ("associatedInstancesCount", "instances"),
    "CONFIGSOURCE":       ("associatedInstancesCount", "instances"),
    "APPLIESTO_FUNCTION": ("useInModulesCount", "modules"),
}
USAGE_DEFAULT = ("associatedHostsCount", "hosts")

# A deprecated module is not upgraded, it is replaced by a different module --
# so a change notice that says "we are upgrading it" would be wrong. LM
# publishes the replacement and the end-of-support date per module here.
DEPRECATION_URL = ("https://www.logicmonitor.com/support/logicmodules/"
                   "about-logicmodules/deprecated-logicmodules")

# LM's own write-up of what an update can cost you. The historical-data risks
# below are taken from it, and the notice cites it so an approver can read the
# source rather than take this tool's word for it.
UPDATE_RISK_URL = ("https://www.logicmonitor.com/support/logicmodules/"
                   "about-logicmodules/keeping-your-datasources-up-to-date")

# Link each module to itself in the portal. The REST API exposes no deep link,
# but the metadata feed supplies both halves of one: `model` is the toolbox
# path segment and `id` is the module, so one template covers every type.
# Same flags and default as tools/elm-module-updates.py -- see the longer note
# there on why the subdomain is not auto-detected.
DEFAULT_URL_TEMPLATE = ("https://{portal}.logicmonitor.com"
                        "/santaba/uiv4/modules/toolbox/{model}/edit/{id}")


def err(*args):
    print(*args, file=sys.stderr)


def run_elm(elm, profile, config, *args):
    """Run elm with the right credential flag and return parsed JSON, or None."""
    cmd = [elm]
    cmd += ["--config", config] if config else ["--profile", profile]
    cmd += ["-f", "json", *args]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode == 0 and not out.stdout.strip():
        # A query that matches nothing gives empty stdout, exit 0, and
        # "Warning: no data found" on stderr. That is a normal result here --
        # most modules are applied to no devices at all -- so it must not be
        # reported as a failure the way a real error is.
        return {}
    try:
        return json.loads(out.stdout)
    except Exception:
        err(out.stderr.strip() or f"{elm} {' '.join(args)} produced no output")
        return None


def fetch_metadata(elm, profile, config):
    d = run_elm(elm, profile, config, "V4Metadata")
    if not d:
        err("no module metadata returned")
        return None
    items = d["V4Metadata"]
    # Tolerate the pre-fix double-wrapped shape from an older elm binary.
    if len(items) == 1 and isinstance(items[0], list):
        items = items[0]
    return items


def run_elm_text(elm, profile, config, *args):
    """Run elm and return stripped stdout (for -c/-C, which print a bare number)."""
    cmd = [elm]
    cmd += ["--config", config] if config else ["--profile", profile]
    cmd += list(args)
    out = subprocess.run(cmd, capture_output=True, text=True)
    return out.stdout.strip()


def affected_devices(elm, profile, config, module_id):
    """{total, names} for the devices a datasource/configsource is applied to.

    The count and the names come from different calls on purpose.
    AssociatedDeviceListByDataSourceId caps at 1000 rows per page, so -s0 on a
    module applied to more than that silently returns exactly 1000 -- which
    reads as a real figure. `-C` asks LM for the true total instead (verified:
    a module reporting 1000 rows from -s0 has a -C total of 1205), so the
    notice states the real number and treats the names as a sample.
    """
    total = run_elm_text(elm, profile, config,
                         "AssociatedDeviceListByDataSourceId",
                         "--id", str(module_id), "-C")
    d = run_elm(elm, profile, config, "AssociatedDeviceListByDataSourceId",
                "--id", str(module_id), "-s0")
    names = sorted(
        (x.get("displayName") or x.get("name") or str(x.get("id")))
        for x in (d or {}).get("AssociatedDeviceListByDataSourceId", [])
    )
    try:
        n = int(total)
    except ValueError:
        n = len(names)
    return {"total": n, "names": names}


def ids_from_file(path):
    """(type, id) pairs from elm-module-updates.py --csv or --json output.

    Both carry a `type` column precisely so the id is unambiguous; a file
    without one yields None for the type, and the caller falls back to --type.
    """
    text = sys.stdin.read() if path == "-" else open(path).read()
    text = text.strip()
    if not text:
        return []
    if text.startswith("["):
        rows = json.loads(text)
    else:
        rows = list(csv.DictReader(text.splitlines()))
        if not rows or "id" not in rows[0]:
            raise SystemExit("no 'id' column found -- expected "
                             "elm-module-updates.py --csv or --json output")
    return [((r.get("type") or "").upper() or None, str(r["id"]))
            for r in rows if r.get("id")]


def parse_id_arg(spec, default_type):
    """'28' -> (default_type, '28');  'TOPOLOGYSOURCE:28' -> ('TOPOLOGYSOURCE', '28')."""
    if ":" in spec:
        t, _, i = spec.partition(":")
        return (t.strip().upper(), i.strip())
    return (default_type, spec.strip())


def collect(mods, elm, profile, config, want_devices, url_template=None,
            portal=None):
    """Build one record per module, with live impact detail."""
    out = []
    for m in mods:
        counts = m.get("associatedCounts") or {}
        field, unit = USAGE.get(m.get("type"), USAGE_DEFAULT)
        pub = m.get("originPublishedAtMS")
        interval = (m.get("collectionInterval") or {}).get("offset")
        devices = {"total": 0, "names": []}
        if want_devices and m.get("type") in DEVICE_LISTABLE:
            devices = affected_devices(elm, profile, config, m["id"])
        out.append({
            "id": m.get("id"),
            "name": m.get("name") or "",
            "display": m.get("displayName") or m.get("name") or "",
            "type": m.get("type") or "",
            "version": m.get("originVersion") or "unknown",
            # The Exchange lookup key. The API cannot tell you the version an
            # upgrade goes TO, so this is what makes that a manual lookup
            # rather than a search.
            "locator": m.get("originLocator") or "",
            "published": (datetime.datetime.fromtimestamp(
                pub / 1000, datetime.timezone.utc).strftime("%Y-%m-%d")
                if pub else "unknown"),
            "method": m.get("collectionMethod") or "",
            "interval": interval,
            "customised": "IS_CUSTOMIZED" in set(m.get("installationStatuses") or ()),
            "deprecated": m.get("originStatus") == "DEPRECATED",
            "upgradable": "CAN_UPGRADE" in set(m.get("installationStatuses") or ()),
            "usage": counts.get(field, 0) or 0,
            "unit": unit,
            "devices": devices["names"],
            "device_total": devices["total"],
            "url": (url_template.format(id=m.get("id", ""),
                                        name=m.get("name", ""),
                                        model=m.get("model", ""),
                                        portal=portal or "")
                    if url_template else ""),
        })
    return out


def derive_risk(recs):
    """Risk level and the reasons behind it. Deliberately conservative."""
    reasons = []
    customised = [r["name"] for r in recs if r["customised"]]
    if customised:
        reasons.append(
            "{} module(s) are locally customised -- upgrading replaces the "
            "local version, so any local edits are lost: {}".format(
                len(customised), ", ".join(sorted(customised))))
    total = sum(r["usage"] for r in recs)
    if total >= 100:
        reasons.append(
            "wide blast radius: {} monitored objects across {} module(s)"
            .format(total, len(recs)))
    scope = max([r["device_total"] for r in recs] or [0])
    if scope >= 20:
        reasons.append("wide scope: the widest module applies to {} devices"
                       .format(scope))
    deprecated = [r["name"] for r in recs if r["deprecated"]]
    if deprecated:
        reasons.append(
            "{} module(s) are DEPRECATED and cannot be upgraded -- they are "
            "replaced by a different module, and have an end-of-support date. "
            "This change needs to be a migration, not an upgrade: {}. "
            "Replacements and dates: {}".format(
                len(deprecated), ", ".join(sorted(deprecated)),
                DEPRECATION_URL))
    not_up = [r["name"] for r in recs
              if not r["upgradable"] and not r["deprecated"]]
    if not_up:
        reasons.append(
            "{} module(s) have no upgrade published -- check the id(s): {}"
            .format(len(not_up), ", ".join(sorted(not_up))))
    level = "High" if deprecated else (
        "Medium" if customised else ("Low" if total < 100 else "Medium"))
    return level, reasons


def fill(text, indent="", hang=None):
    """Wrap to WRAP columns. `hang` indents continuation lines separately, so a
    bullet marker appears once instead of on every wrapped line."""
    # break_long_words/break_on_hyphens off: a wrapped URL is a broken URL,
    # and these notices carry them. A long token overruns WRAP instead.
    return textwrap.fill(text, WRAP, initial_indent=indent,
                         subsequent_indent=(hang if hang is not None else indent),
                         break_long_words=False, break_on_hyphens=False)


def bullet(text, marker="  - "):
    return fill(text, marker, " " * len(marker))


def module_lines(recs, marker="  - ", list_under=10):
    """One block per module. Devices are named under the module they affect
    rather than pooled into one list at the end -- a reader wants to know who
    is hit by *this* change to *this* module. Named only when there are few
    enough to be worth reading; past that the count above already says it."""
    lines = []
    for r in sorted(recs, key=lambda x: x["name"].lower()):
        ver = "v{}, published {}".format(r["version"], r["published"])
        if r["locator"]:
            ver += ", locator {}".format(r["locator"])
        bits = ["{} {} ({})".format(r["type"].lower(), r["name"], ver)]
        if r["method"]:
            bits.append("collected by {}".format(r["method"].lower()))
        if r["interval"]:
            bits.append("every {}s".format(r["interval"]))
        lines.append(bullet("; ".join(bits), marker))
        detail = "{} {} collected".format(r["usage"], r["unit"])
        if r["device_total"]:
            detail += "; applies to {} device(s)".format(r["device_total"])
        if r["customised"]:
            detail += " -- LOCALLY CUSTOMISED, local edits will be lost"
        if r["deprecated"]:
            detail += " -- DEPRECATED, needs replacing rather than upgrading"
        lines.append(fill(detail, " " * len(marker)))
        if r["url"]:
            # Plain text has no inline links, so the URL gets its own line.
            lines.append(fill(r["url"], " " * len(marker)))
        if named_devices(r, list_under):
            lines.append(fill("devices: " + ", ".join(r["devices"]),
                              " " * len(marker)))
    return lines


def named_devices(r, list_under):
    """Whether this module's devices are few enough to name."""
    return (r["devices"] and list_under
            and 0 < r["device_total"] <= list_under)


def expectations():
    """What an update can actually cost, per LogicMonitor's own documentation.

    The historical-data cases are the ones worth spelling out in a notice: they
    are permanent, they are not obvious from "we are upgrading a module", and
    an approver who only hears "brief interruption" has not been told the truth.
    """
    return [
        "Monitoring for the affected modules is briefly interrupted while each "
        "module is replaced. A short gap in graphed data is normal.",

        "Historical data can be lost permanently. LogicMonitor documents three "
        "cases: a datapoint renamed or removed in the new version; Active "
        "Discovery changing so instances are rediscovered under different "
        "names; and a change to the AppliesTo expression that stops the module "
        "applying to a device, even temporarily, which discards all history "
        "for that module on those devices. Review the diff the Exchange shows "
        "before importing, and check the AppliesTo change in particular.",

        "Alert thresholds you have set at device or device group level are "
        "preserved. Thresholds, datapoints, graphs and polling intervals set "
        "on the module itself are replaced by the new version's.",

        "LogicMonitor's own summary of these risks: " + UPDATE_RISK_URL,
    ]


def backout_lines(recs):
    """The backout plan, which depends on what is actually in scope.

    An uncustomised official module is a published registry version, so the
    version you upgraded from can simply be reinstalled from the module
    Exchange -- nothing needs exporting first. That is only true while the
    module is unmodified: a customised module's local edits exist nowhere but
    this portal, so for those an export beforehand is the only way back.
    """
    custom = sorted(r["name"] for r in recs if r["customised"])
    lines = ["Reinstall the previous version from LogicMonitor Exchange. Each "
             "module in scope is an unmodified published version, so the "
             "version listed against it above is the one to go back to. "
             "Backout is per module and does not require the whole change to "
             "be reversed."]
    if custom:
        lines[0] = lines[0].replace("Each module in scope is an unmodified "
                                    "published version, so the", "For the "
                                    "unmodified modules the")
        lines.append("EXPORT THESE BEFORE YOU START -- they are locally "
                     "customised, so their current content exists nowhere but "
                     "this portal and reinstalling a published version will "
                     "not bring the local edits back: {}."
                     .format(", ".join(custom)))
    return lines


def impact_summary(recs):
    """Impact in the terms that mean something, with the two kept apart.

    "Applies to" (the appliesTo match) and "collected" (actual instances) are
    very different numbers -- one module here applies to 1205 devices but
    collects 2 instances -- so the notice never merges them into one figure.
    """
    collected = sum(r["usage"] for r in recs)
    scope = max([r["device_total"] for r in recs] or [0])
    s = "{} module(s), {} monitored object(s) actually collected".format(
        len(recs), collected)
    if scope:
        s += "; the widest module applies to {} device(s)".format(scope)
    return s


def render_email(recs, args, level, reasons):
    o = []
    o.append("Subject: Monitoring change {} - {} LogicMonitor module(s) upgraded"
             .format(args.date, len(recs)))
    o.append("")
    o.append(fill("We are upgrading the LogicMonitor modules listed below to "
                  "their current published versions on {} during {}."
                  .format(args.date, args.window)))
    o.append("")
    o.append("WHAT IS CHANGING")
    o += module_lines(recs, list_under=args.list_devices_under)
    o.append("")
    o.append("WHY")
    o.append(fill(args.reason))
    o.append("")
    o.append("WHO IS AFFECTED")
    o.append(fill(impact_summary(recs)))
    o.append("")
    o.append("WHAT TO EXPECT")
    for line in expectations():
        o.append(fill(line))
        o.append("")
    o = o[:-1]
    o.append("")
    o.append("RISK: " + level)
    for r in reasons:
        o.append(bullet(r))
    if not reasons:
        o.append(bullet("No customised modules and a limited blast radius."))
    o.append("")
    o.append("IF SOMETHING GOES WRONG")
    for line in backout_lines(recs):
        o.append(fill(line))
        o.append("")
    o.append(fill("Report anything unexpected to {}.".format(args.contact)))
    o.append("")
    o.append("Change reference: {}".format(args.ref))
    o.append("Contact: {}".format(args.contact))
    return "\n".join(o)


def render_itsm(recs, args, level, reasons):
    o = []
    o.append("Summary: Upgrade {} LogicMonitor module(s) to current published "
             "versions".format(len(recs)))
    o.append("Change reference: {}".format(args.ref))
    o.append("Scheduled: {} {}".format(args.date, args.window))
    o.append("Risk: {}".format(level))
    o.append("Impact: {}".format(impact_summary(recs)))
    o.append("")
    o.append("Justification:")
    o.append(fill(args.reason, "  "))
    o.append("")
    o.append("Modules in scope:")
    o += module_lines(recs, list_under=args.list_devices_under)

    o.append("")
    o.append("Risk factors:")
    for r in (reasons or ["None identified beyond routine monitoring "
                          "interruption."]):
        o.append(bullet(r))
    o.append("")
    o.append("Implementation plan:")
    for line in (
        ([] if not any(r["customised"] for r in recs) else
         ["Export the locally customised modules listed under Backout -- "
          "upgrading replaces them and their edits are not recoverable from "
          "the registry."]) +
        [
        "Look each module up in LogicMonitor Exchange by its locator (shown "
        "against it above) to see the version it will be upgraded to and to "
        "review the diff. The API does not expose the target version, so this "
        "is the step that establishes what is actually changing.",
        "Upgrade each module from LogicMonitor Exchange.",
        "Confirm each module reports data on a sample device before moving to "
        "the next.",
    ]):
        o.append(bullet(line))
    o.append("")
    o.append("Backout plan:")
    for line in backout_lines(recs):
        o.append(bullet(line))
    o.append("")
    o.append("Test plan:")
    o.append(bullet("For each module, confirm data is collected on at least "
                    "one affected device after the upgrade, and that no new "
                    "alerts were raised by the change itself."))
    o.append("")
    o.append("Approver: <APPROVER>")
    return "\n".join(o)


def render_md(recs, args, level, reasons):
    o = ["# Monitoring change - {}".format(args.date), ""]
    o.append("**Window:** {}  |  **Risk:** {}  |  **Reference:** {}"
             .format(args.window, level, args.ref))
    o.append("")
    o.append("## What is changing")
    o.append("")
    o.append("| module | type | locator | installed | published | collected | "
             "applies to | customised |")
    o.append("|---|---|---|---|---|---|---|---|")
    for r in sorted(recs, key=lambda x: x["name"].lower()):
        name = f"[{r['name']}]({r['url']})" if r["url"] else r["name"]
        o.append("| {} | {} | {} | {} | {} | {} {} | {} | {} |".format(
            name, r["type"].lower(), r["locator"] or "-", r["version"],
            r["published"],
            r["usage"], r["unit"], r["device_total"] or "-",
            "**yes**" if r["customised"] else "no"))
    o.append("")
    o.append("## Why")
    o.append("")
    o.append(args.reason)
    o.append("")
    o.append("## What to expect")
    o.append("")
    for line in expectations():
        o.append("- " + line)
    o.append("")
    o.append("## Impact")
    o.append("")
    o.append(impact_summary(recs))
    named = [r for r in sorted(recs, key=lambda x: x["name"].lower())
             if named_devices(r, args.list_devices_under)]
    if named:
        o.append("")
        o.append("## Devices")
        o.append("")
        for r in named:
            o.append("- **{}** — {}".format(r["name"], ", ".join(r["devices"])))
    o.append("")
    o.append("## Risk")
    o.append("")
    for r in (reasons or ["No customised modules and a limited blast radius."]):
        o.append("- " + r)
    o.append("")
    o.append("## Backout")
    o.append("")
    for line in backout_lines(recs):
        o.append(line)
        o.append("")
    o.append("")
    o.append("Contact: {}".format(args.contact))
    return "\n".join(o)


def main(argv=None):
    p = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Drafts only -- nothing is sent. Notice on stdout, progress on "
               "stderr.")
    p.add_argument("--date", required=True, metavar="YYYY-MM-DD",
                   help="date of the change")
    p.add_argument("--window", default="<TIME WINDOW>", metavar="TEXT",
                   help="change window, e.g. '19:00-20:00 AEST'")
    p.add_argument("--id", metavar="ID,...",
                   help="module ids to include, comma-separated. Ids are only "
                        "unique within a type, so a bare id means --type; "
                        "qualify others as TYPE:ID (e.g. TOPOLOGYSOURCE:28)")
    p.add_argument("--type", default="DATASOURCE", metavar="TYPE",
                   help="module type for unqualified ids (default: DATASOURCE)")
    p.add_argument("--from", dest="from_file", metavar="PATH",
                   help="read ids from elm-module-updates.py --csv/--json "
                        "output ('-' for stdin)")
    p.add_argument("--format", default="email",
                   choices=("email", "itsm", "md", "all"),
                   help="notice shape (default: email)")
    p.add_argument("--reason", metavar="TEXT",
                   default="The installed versions are behind the versions "
                           "LogicMonitor currently publishes. Upgrading picks "
                           "up collection fixes and new metrics, and keeps the "
                           "modules supportable.",
                   help="the justification paragraph")
    p.add_argument("--ref", default="<CHANGE REF>", metavar="TEXT",
                   help="change reference number")
    p.add_argument("--contact", default="<CONTACT>", metavar="TEXT",
                   help="who to contact about the change")
    p.add_argument("--risk", choices=("Low", "Medium", "High"),
                   help="override the derived risk level")
    p.add_argument("--portal", metavar="NAME",
                   help="portal subdomain (the bit before .logicmonitor.com). "
                        "Giving it links each module to itself in the portal: "
                        "a Markdown link on the name, a URL on its own line in "
                        "the plain-text formats")
    p.add_argument("--url-template", metavar="URL",
                   help="override the link format. Placeholders: {portal} "
                        "{model} {id} {name}")
    p.add_argument("--max-device-calls", type=int, default=100, metavar="N",
                   help="refuse the device lookups above N API calls "
                        "(default: 100; two calls per module, 0 = no limit). "
                        "Guards against piping a whole report in")
    p.add_argument("--list-devices-under", type=int, default=10, metavar="N",
                   help="name the affected devices under any module that has "
                        "at most N of them (default: 10, 0 = never name them). "
                        "Past that the count alone is more readable; raise it "
                        "to name more. The API caps its own device list at "
                        "1000 per module")
    p.add_argument("--no-devices", action="store_true",
                   help="skip the per-module device lookups (one API call each) "
                        "and report counts only")
    p.add_argument("-p", "--profile", default="config",
                   help="elm credential profile (default: config)")
    p.add_argument("-c", "--config", metavar="PATH",
                   help="full path to an elm .ini, instead of --profile")
    p.add_argument("--elm", default="elm", metavar="PATH",
                   help="elm executable to call (default: elm on PATH)")
    args = p.parse_args(argv)
    args.type = args.type.upper()

    if shutil.which(args.elm) is None:
        err(f"{args.elm} not found on PATH")
        return 1
    try:
        datetime.date.fromisoformat(args.date)
    except ValueError:
        err(f"--date {args.date} is not a YYYY-MM-DD date")
        return 1

    wanted = []
    if args.id:
        wanted += [parse_id_arg(i, args.type)
                   for i in args.id.split(",") if i.strip()]
    if args.from_file:
        wanted += ids_from_file(args.from_file)
    if not wanted:
        err("no modules given: use --id ID,... or --from FILE ('-' for stdin)")
        return 1
    wanted = list(dict.fromkeys(wanted))          # de-dup, keep order

    err(f"fetching module metadata ({args.config or args.profile}) ...")
    items = fetch_metadata(args.elm, args.profile, args.config)
    if items is None:
        return 1

    # Module ids are only unique WITHIN a type -- in one test portal 329 ids
    # belonged to several types at once, and id 28 to six of them -- so the
    # index is keyed by (type, id) and an id alone is never enough.
    installed = {}
    by_id = {}
    for i in items:
        if "IS_INSTALLED" not in set(i.get("installationStatuses") or ()):
            continue
        installed[(i.get("type"), str(i["id"]))] = i
        by_id.setdefault(str(i["id"]), []).append(i.get("type"))

    mods, missing = [], []
    for type_, mid in wanted:
        key = (type_ or args.type, mid)
        if key in installed:
            mods.append(installed[key])
        elif mid in by_id:
            missing.append("{} (no {} with that id; it exists as {}) -- "
                           "qualify it as TYPE:{}"
                           .format(mid, key[0], "/".join(sorted(by_id[mid])), mid))
        else:
            missing.append("{} (no installed module with that id)".format(mid))
    for m in missing:
        err("  skipped: " + m)
    if not mods:
        err("none of the given ids matched an installed module")
        return 1

    listable = sum(1 for m in mods if m.get("type") in DEVICE_LISTABLE)
    if not args.no_devices and listable:
        # Two calls per module (-C for the true total, -s0 for the names), so
        # this is where an unnarrowed pipe from elm-module-updates.py turns
        # into thousands of requests and half an hour of waiting.
        if args.max_device_calls and listable * 2 > args.max_device_calls:
            err(f"{listable} module(s) would need {listable * 2} API calls to "
                f"look up affected devices, over --max-device-calls "
                f"({args.max_device_calls}).")
            err("A change notice is meant for the modules you are actually "
                "changing on the day, not a whole report. Narrow the input "
                "(--id, or filter the report with --tag / -t / --status), "
                "pass --no-devices to skip the lookups, or raise the limit "
                "(0 = no limit).")
            return 1
        err(f"looking up affected devices for {listable} module(s) "
            f"({listable * 2} call(s)) ...")
    template = args.url_template or (DEFAULT_URL_TEMPLATE if args.portal else None)
    if template and "{portal}" in template and not args.portal:
        err("that link template needs {portal}: pass --portal NAME")
        return 1
    recs = collect(mods, args.elm, args.profile, args.config,
                   not args.no_devices, template, args.portal)
    level, reasons = derive_risk(recs)
    if args.risk:
        level = args.risk
    err(f"{len(recs)} module(s), risk {level}")

    parts = []
    if args.format in ("email", "all"):
        parts.append(render_email(recs, args, level, reasons))
    if args.format in ("itsm", "all"):
        parts.append(render_itsm(recs, args, level, reasons))
    if args.format in ("md", "all"):
        parts.append(render_md(recs, args, level, reasons))
    print(("\n\n" + "-" * WRAP + "\n\n").join(parts))

    if "<" in "".join(parts):
        err("note: the draft still has <PLACEHOLDER> fields to fill in")
    return 0


if __name__ == "__main__":
    sys.exit(main())
