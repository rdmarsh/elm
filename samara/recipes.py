"""Recipes: checked answers to the questions people ask most (recipes.yaml).

A small local model gets these wrong when it plans the queries itself: it
looked devices up by hostname, read counts off a 5-row sample and made up
whole tables (qwen3-8b, 2026-10-29). A recipe fixes the queries, counts in
jq and writes the summary from the data, so the model only has to pick the
recipe, pass the name it was asked about, and repeat what comes back.

Recipes are written and checked against a portal with a bigger model and
elm (see samara/questions.md); the model running Samara cannot change them.

recipes.yaml, one entry per recipe:
  name, asks    the recipe's name and the questions it answers
  topic         its heading in the page's "What can I ask?" guide,
                one of TOPICS, which lists its first ask; none keeps it out
  covers        what it answers, in a few words, shown under the answer: a
                near-miss recipe answering a different question ("this week"
                answered as "now") then says so
  params        lookups, run first: device or group, found by name
  many          a lookup that may match several (find_device): no "which one?"
  lookup        the lookup's filters in the recipe's own order, the first that
                finds anything wins (find_group: names before paths)
  days          how far ahead it looks by default; the model may pass another
                (1 to MAX_DAYS). jq sees it as `days`; title and covers as {days}
  options       choices the model passes as tool arguments (the alerts recipe):
                each value is a filter and words, joined into the step's
                {options} filter and the {alerts}{qual} of covers, title and
                says (jq: `which`, `qual`). `default` when not passed; `sets`
                another's default, which then says nothing; `text` takes a
                name instead of a list of values; `before` puts the words
                before "alerts"; `required` makes the recipe refuse to run
                without it (find_dashboard's title); `many` lets a text option
                take several values (a list, or "a | b"): steps filtered by
                {options} run once per value, each row carrying its value as
                `of`, and jq sees the values as `titles`
  steps         elm queries, each saved as `$<as>` for the jq below. Filters
                and params are str.format templates over the lookups
                ({device[id]}); `size: all` pages past 1000 rows; `when` is a
                jq test that skips the step when false; `each` is jq giving a
                list: the step runs once per item ({row[id]}, at most MAX_EACH,
                or the step's `most`, up to MOST_EACH; `noun` names the items
                for the "only part was checked" note) and every result row
                carries its item as `of`; `narrow` is a list of {filter, covers,
                says} tried in turn while the step's own filter has over OVER
                rows (too many to go through): the first under it is fetched,
                and jq sees its covers as `narrowed.<as>` (null when not narrowed);
                a summary that does not use `narrowed` is prefixed "Over OVER
                <over>, ... only the <covers>", `over` naming the step's rows
                `says` is the step's line in How I worked this out; "" leaves it
                to another step (several queries, one per name, as LM's filters
                have no "or")
  summary       jq giving the answer's text
  table_only    the rows hold free text (properties): the model is not told
                where they are, so planted text reaches only the reader
  table         {title, columns, rows}: jq giving the rows; shown on the page.
                links: {Device: device} makes that column's cells links to the
                device in LM, from each row's Device_id (null: no link);
                {Dashboard: dashboard} links to a dashboard the same way
"""

import json
import re
from pathlib import Path

import yaml

import elm_tools
import router

HERE = Path(__file__).resolve().parent
RECIPES = {r["name"]: r for r in yaml.safe_load((HERE / "recipes.yaml").read_text())}
for _r in RECIPES.values():
    # A bare On, Yes or No is a boolean to YAML: working_on's "On" column came out
    # as True, and every person with rows got an error, not a table (2026-11-08).
    if any(not isinstance(c, str) for c in _r.get("table", {}).get("columns", [])):
        raise ValueError(f"{_r['name']}: quote every table column in recipes.yaml ({_r['table']['columns']})")
for _r in RECIPES.values():   # a chart names its table's columns: a typo fails here, not on the page
    _charts = _r.get("table", {}).get("chart") or []
    for _c in _charts if isinstance(_charts, list) else [_charts]:
        _cols = set(_r["table"]["columns"])
        if not ((_c.get("type") in ("bar", "line") and not {_c.get("x"), _c.get("y")} - _cols)
                or (_c.get("type") == "donut" and _c.get("row") in ("first", "last") and _c.get("slices")
                    and not set(_c["slices"]) - _cols)):
            raise ValueError(f"{_r['name']}: a chart is bar or line with x and y, or donut with row "
                             f"(first or last) and slices, all from the table's columns")
    _links = _r.get("table", {}).get("links", {})
    if set(_links) - set(_r.get("table", {}).get("columns", [])) or set(_links.values()) - {"device", "dashboard"}:
        raise ValueError(f"{_r['name']}: links name the table's columns, each linking to a device or dashboard")
# The guide's headings, in the order the page shows them.
TOPICS = ["Everything at once", "Devices", "Alerts", "Common problems", "Collectors", "Groups and customers", "Dashboards",
          "Downtime and alerting off", "Websites", "People"]
for _r in RECIPES.values():
    if _r.get("topic") not in TOPICS + [None]:
        raise ValueError(f"{_r['name']}: topic is one of {', '.join(TOPICS)}, or none")


def guide():
    """The page's "What can I ask?": each topic with its recipes' first asks."""
    return [{"topic": t, "asks": [r["asks"][0] for r in RECIPES.values() if r.get("topic") == t]} for t in TOPICS]


MAX_PAGES = 10   # LM stops paging at 10,000 rows
MAX_EACH = 10    # an `each` step's queries, one per item
MOST_EACH = 150  # a step's own `most` (one per DataSource on a device) stops here
MAX_DAYS = 90    # how far ahead a `days` recipe may look
OVER = 9000      # a `narrow` step with more rows than this fetches a narrower filter

# Defined in front of every recipe expression. Times are the reader's (jq
# runs in their timezone); SDT times are milliseconds, so divide first.
PRELUDE = r"""
def sev: {"2": "warning", "3": "error", "4": "critical"}[tostring] // tostring;
def when: strflocaltime("%d %b %Y, %H:%M %Z");
def ago: (. - now) as $s | ($s | fabs) as $a
  | (if $a < 3600 then [($a / 60 | round), "minute", 60] elif $a < 86400 then [($a / 3600 | round), "hour", 24]
     else [($a / 86400 | round), "day", 0] end) as [$n, $unit, $next]
  | (if $n == $next then [1, {"minute": "hour", "hour": "day"}[$unit]] else [$n, $unit] end) as [$n, $unit]
  | "\($n) \($unit)\(if $n == 1 then "" else "s" end)" as $span
  | if $a < 60 then (if $s > 0 then "in under a minute" else "just now" end)
    elif $s > 0 then "in about \($span)" elif $unit == "day" then "\($span) ago" else "about \($span) ago" end;
def at: "\(when), \(ago)";
def commas: if type == "number" and . == floor and fabs >= 1000   # 5421 -> "5,421", as "over 9,000"
  then (if . < 0 then "-" else "" end) + (fabs | tostring | explode | reverse
    | [recurse(.[3:]; length > 0) | .[:3] | reverse | implode] | reverse | join(",")) else tostring end;
def n($word): "\(commas) \($word)\(if . == 1 then "" else "s" end)";
def pct($of): if $of > 0 then (100 * . / $of) as $p   # 3 | pct(4) -> "75%"; a sliver is "<1%", not "0%"
  | if $p > 0 and $p < 1 then "<1%" else "\($p | round)%" end else "" end;
def ack: if .acked | not then "no" else "yes"   # when, the note typed then, and who
  + (if (.ackedEpoch // 0) > 0 then ", \(.ackedEpoch | ago)" else "" end)
  + (if (.ackComment // "") != "" then ": \(.ackComment)" else "" end)
  + (if (.ackedBy // "") != "" then " (\(.ackedBy))" else "" end) end;
def severities: (map(.severity | sev) | group_by(.) | map({key: .[0], value: length}) | from_entries) as $c
  | [("critical", "error", "warning") as $s | select($c[$s]) | "\($c[$s] | commas) \($s)"] | join(", ");
def kind: {"0": "device", "2": "AWS resource", "4": "Azure resource", "6": "service", "7": "GCP resource",
  "8": "Kubernetes resource", "9": "push-metrics device", "11": "synthetic check",
  "18": "synthetic check"}[tostring] // "type \(.)";
def updown: {"normal": "up", "dead": "not responding",
  "dead-collector": "not being monitored: its collector is down"}[.] // .;
def device_id: if .monitorObjectType == "device" then .monitorObjectId else null end;   # an alert's, for links
def path: if .fullPath == "" then "the portal's root group" else .fullPath end;   # the root's is ""
def state: {"normal": "up", "dead": "not responding", "dead-collector": "collector down"}[.] // .;   # for tables
def ver: tostring | "\(.[:-3]).\(.[-3:])";   # collector build "41100" -> 41.100
def disabled_by: [["a group", "its own setting", "some instances"], split("-")] | transpose
  | map(select(.[1] == "disable") | .[0]);   # alertDisableStatus is <group>-<device>-<instance>
"""

# How a name the person typed becomes one record: exact display name, then
# part of it, then part of the hostname or IP (for "is 203.0.113.7 monitored?").
LOOKUPS = {
    "device": ("DeviceList", ['displayName:"{}"', 'displayName~"{}"', 'name~"{}"'],
               ["id", "displayName", "name", "hostStatus", "sdtStatus", "alertDisableStatus",
                "currentCollectorId", "collectorDescription", "deviceType"]),
    # A path ("/Customers/acme") is matched as fullPath, which has no leading
    # slash; ~ ignores case, for "/customers/ACME/".
    "group": ("DeviceGroupList", ['name:"{}"', 'fullPath:"{}"', 'fullPath~"{}"', 'name~"{}"'],
              ["id", "name", "fullPath", "numOfHosts", "groupStatus", "numOfDirectSubGroups", "description"]),
    # Collector names are usually DOMAIN\HOST or an FQDN, so a bare host name
    # needs the contains filters. A number is its id ("collector 281").
    "collector": ("CollectorList", ['id:{}', 'description:"{}"', 'hostname:"{}"', 'description~"{}"', 'hostname~"{}"'],
                  ["id", "description", "hostname", "isDown", "inSDT", "collectorGroupName", "collectorDeviceId",
                   "numberOfHosts", "backupAgentId", "build", "upTime", "watchdogUpdatedOn"]),
}


# Things a question can be about that only some recipes cover. "What
# dashboards rely on groups that have been moved or renamed?" ran
# portal_health, and its summary went out as the answer, about collectors and
# alerts (qwen3-vl-4b, 2026-11-10). Alerts and devices are left out: nearly
# every recipe is about them, said or not.
THINGS = {
    "dashboards": r"dashboards?", "reports": r"reports?", "websites": r"websites?|web ?checks?|web ?sites?",
    "collectors": r"collectors?", "groups": r"groups?|customers?|folders?",
    "downtime": r"downtimes?|sdts?|maintenance", "properties": r"propert(?:y|ies)",
    "DataSources": r"datasources?|data sources?|logicmodules?", "certificates": r"certificates?|certs?|ssl",
    "disks": r"disks?|filesystems?|volumes?|disk space", "clocks": r"clocks?|ntp|time sync",
    "memory": r"memory|ram", "widgets": r"widgets?",
}
_THINGS = {k: re.compile(rf"\b(?:{v})\b", re.I) for k, v in THINGS.items()}


def misses(question, recipe):
    """The THINGS the question names that the recipe's questions and covers never mention."""
    r = RECIPES.get(recipe)
    if not r:
        return []
    said = " ".join(r["asks"] + [r.get("covers", ""), recipe.replace("_", " "), r.get("table", {}).get("title", "")])
    # Not words inside quotes: "Bottom 25 Free Memory Pool" is a widget's title, and
    # find_dashboard was refused as not about memory (qwen3-vl-4b, 2026-11-11).
    question = router.QUOTED.sub('""', question)
    return [k for k, rx in _THINGS.items() if rx.search(question) and not rx.search(said)]


def not_covered(question, recipe):
    """Why a recipe is not run for this question, or None: it is about something else."""
    gone = misses(question, recipe)
    if not gone:
        return None
    what = " and ".join(gone)
    fits = [n for n in RECIPES if not misses(question, n)]
    return (f"Not run: {recipe} answers {RECIPES[recipe].get('covers', recipe)}, not {what}, so its answer "
            f"would not be about the question. "
            + (f"Recipes that mention {what}: {', '.join(fits)}; use one only if it answers this very "
               f"question. " if fits else f"No recipe mentions {what}. ")
            + "Otherwise find the command with find_commands, run it with run_elm, and answer only from "
              "what comes back; if nothing can answer it, say that no check covers it.")


def taking(param):
    """The recipes that take this lookup (device, group), or none (the whole portal)."""
    return [name for name, r in RECIPES.items() if r.get("params", [None])[0] == param]


def tool_description():
    def listed(names):
        return "\n".join(f"- {name}: {'; '.join(RECIPES[name]['asks'])}" for name in names)
    return ("Checked answers to the questions people ask most: the queries, the counting and the summary are "
            "already worked out, so the numbers are right. If one of these fits the question, use it first, "
            "before run_elm.\n\nAbout one device (pass device):\n" + listed(taking("device"))
            + "\n\nAbout one group (pass group):\n" + listed(taking("group"))
            + "\n\nAbout one collector (pass collector):\n" + listed(taking("collector"))
            + "\n\nAbout one person (pass person: the name as written; matched in who acknowledged open alerts "
            "or set downtime, and their notes):\n" + listed(taking("person"))
            + "\n\nAbout the whole portal (pass no name):\n" + listed(taking(None)))


def fetch_all(command, **kw):
    """Every row, a page of 1000 at a time; (lines, shown, cut).

    shown is the first page's command. cut is None when every row came back,
    else what is known of the real total: LM stops paging at 10,000 rows with
    no error, and the last page can fall a little short, so reaching the last
    page means the rows may be cut short. -C says by how much (AlertList gives
    only ">N"), or that nothing was cut after all.
    """
    lines, shown = [], None
    for page in range(MAX_PAGES):
        got, _, _, cmd = elm_tools.fetch(command, size=0, offset=page * elm_tools.MAX_ROWS, **kw)
        lines += got
        shown = shown or cmd
        if len(got) < elm_tools.MAX_ROWS and page < MAX_PAGES - 1:
            return lines, shown, None
    total = elm_tools.fetch(command, total=True, filter=kw.get("filter"), params=kw.get("params"))[0]
    return lines, shown, None if total == str(len(lines)) else total


def nearest(value):
    """(name, kind) of the device, group or collector spelled most like value, or None.

    "amce" found nothing, and the answer never said acme was there (2026-10-31).
    """
    import difflib
    import router
    try:
        known = {name.lower(): (name, kind) for name, kind, _, _ in router.names()}
    except Exception:
        return None
    close = difflib.get_close_matches(value.lower(), list(known), n=1, cutoff=0.7)
    return known[close[0]] if close else None


def choose(r, given):
    """A recipe's options from the tool arguments: (filter, words before "alerts", words after)."""
    opts = r.get("options", {})
    picked, quiet = {}, set()
    for name, o in opts.items():
        v = str(given.get(name) or "").strip()
        if not v:
            continue
        if "text" in o:
            if re.search(r'["\\,{}]', v):
                raise ValueError(f"{name}: the name as the person wrote it, without quotes or commas")
        elif v not in o["values"]:
            raise ValueError(f"{name} must be one of: {', '.join(o['values'])}")
        picked[name] = v
    missing = [name for name, o in opts.items() if o.get("required") and name not in picked]
    if missing:
        raise ValueError(f"This recipe needs {', '.join(missing)}: {opts[missing[0]]['about']}")
    for name in list(picked):
        for other, v in opts[name].get("sets", {}).items():
            if picked.get(other, v) == v:   # unset, or set to what this already says
                picked[other] = v
                quiet.add(other)   # "that cleared in the last hour" already says cleared
    for name, o in opts.items():
        if name not in picked and "default" in o:
            picked[name] = o["default"]
    filters, before, after = [], "", ""
    for name, o in opts.items():
        if name in picked:
            spec = o["text"] if "text" in o else o["values"][picked[name]]
            # LM's ~ finds nothing with a "(" in the value; "[(]" matches it ("Health
            # [(]Real-time)" found "Azure Resource Health (Real-time)", 2026-11-11).
            value = picked[name].replace("(", "[(]") if "text" in o else picked[name]
            filters.append(spec["filter"].format(value, field=o.get("field", "")))
            if name not in quiet:
                words = o.get("verb", "") + spec["words"].format(picked[name])
                before, after = (before + words, after) if o.get("before") else (before, after + words)
    return ",".join(filters), before, after


CLEARED = re.compile(r"\b(clear(ed|s)?|recover\w*|resolv\w*|closed)\b", re.I)
STARTED = re.compile(r"\b(start\w*|began|begun|new|raised|opened|fired)\b", re.I)
OPEN = re.compile(r"\b(open|still|active|ongoing|unresolved|outstanding|now|current\w*)\b", re.I)
# "errors or worse", "warnings and above": that severity and every one above it.
WORSE = re.compile(r"\b(critical|errors?|warnings?)\s+(?:or|and)\s+(?:worse|above|higher|up|more severe)\b", re.I)
WORSE_IS = {"crit": "critical", "erro": "error_or_critical", "warn": None}
SEVERITY_IS = {r"\bcriticals?\b": "critical", r"\berrors?\b": "error", r"\bwarnings?\b": "warning"}
# Time words WINDOWS has no value for ("since Monday", "in the last 3 days"): the model's window stays.
TIMEISH = re.compile(r"\b(since|ago|before|after|recent\w*|lately|last|past|this|morning|night|week\w*|month\w*|"
                     r"days?|hours?|minutes?|mon|tues|wednes|thurs|fri|satur|sun)(day)?\b", re.I)
HAPPENED = re.compile(r"\b(happen\w*|going on|changed|new)\b", re.I)
ALERT_RECIPES = {"alerts", "open_alerts", "critical_alerts", "alerts_unacknowledged"}
# The health recipe picked for a question its sibling answers: (picked, words, run instead).
SIBLINGS = [
    ("collector_health", re.compile(r"\b(keep(ing)? up|overload\w*|(falling|fallen|fell|gets?) behind|"
                                    r"drop(ping|s|ped)? data|backlog\w*|queue\w*)\b", re.I), "collector_keeping_up"),
    ("device_health", re.compile(r"\b(collecting|no data|missing data|returning nothing)\b", re.I),
     "device_collecting"),
]
# The question's own time window, as the alerts recipe names it; first match wins.
WINDOWS = [
    (r"\bsince\b", None),   # "since yesterday" is yesterday until now, not yesterday: the model's window stays
    (r"\b(last|past)\s+hour\b", "last_hour"),
    (r"\b(last|past)\s+24\s*h(ours?)?\b|\bovernight\b", "last_24_hours"),
    (r"\btoday\b|\bthis morning\b", "today"),
    (r"\byesterday\b", "yesterday"),
    (r"\bthis week\b", "this_week"),
    (r"\b(last|past)\s+(7|seven)\s+days\b", "last_7_days"),
    (r"\blast week\b", "last_week"),
    (r"\bthis month\b", "this_month"),
    (r"\b(last|past)\s+(30|thirty)\s+days\b", "last_30_days"),
    (r"\blast month\b", "last_month"),
]


# "sorted by name", "ordered by devices, largest first": the table's order,
# from the question's own words, for any recipe. Small models drop such
# arguments, so Samara reads it itself, as it does the alert windows below.
SORT = re.compile(r"\b(?:sort(?:ed)?|order(?:ed)?)\s+(?:it\s+|them\s+)?by\s+(?:the\s+)?(?:(most|largest|biggest|highest|"
                  r"fewest|least|smallest|lowest)\s+)?([a-z][\w %-]*?)(?:,?\s+(asc\w*|desc\w*|a-z|z-a|(?:largest|biggest|"
                  r"highest|most|smallest|lowest|fewest|least|newest|oldest) first|reversed?))?\s*[?.!]*\s*$", re.I)
DOWN = re.compile(r"desc|z-a|largest|biggest|highest|most|newest|revers", re.I)
UP = re.compile(r"asc|a-z|smallest|lowest|fewest|least|oldest", re.I)


def sort_from(question):
    """(column words, "asc" | "desc" | None) the question asks the table sorted by, or None."""
    m = SORT.search(question or "")
    if not m:
        return None
    how = " ".join(filter(None, (m[1], m[3])))
    return m[2].strip(), "desc" if DOWN.search(how) else "asc" if UP.search(how) else None


def sorted_rows(expression, columns, sort):
    """The table's jq with a sort on the column sort names; (expression, what to tell the model)."""
    words, way = sort
    want = words.lower().rstrip("s")
    plain = {c: c.lower().rstrip("s") for c in columns}
    col = (next((c for c, p in plain.items() if p == want), None)
           or next((c for c, p in plain.items() if p.startswith(want) or want.startswith(p)), None)
           or next((c for c, p in plain.items() if want in p or p in want), None))
    if col is None and want in ("name", "alphabetical", "alphabet"):
        col = columns[0]   # the thing listed: Group, Device, Collector ...
    if col is None:
        return expression, f"There is no {words!r} column to sort by (columns: {', '.join(columns)}); the table keeps its order."
    c = json.dumps(col)
    # Unless the question says which way: numbers largest first (a count), text A to Z.
    down = {"desc": "true", "asc": "false"}.get(way, f"([.[][{c}] | select(. != null)][0] | type) == \"number\"")
    return (f"({expression}) | sort_by(.[{c}] | if type == \"string\" then ascii_downcase else . end)"
            f" | if {down} then reverse else . end", f"The table is sorted by {col}, as asked.")


def from_question(question, args):
    """The recipe's arguments, with what the question's own words settle put right.

    Any recipe: the sort the question asks for. The alerts recipe:

    The model picks the options, and small ones pick the wrong window: "What
    alerts cleared in the last hour?" came as started=last_hour, state=cleared
    (qwen3-vl-4b), and "How many alerts started yesterday?" as state=open, which
    left out the 129 that had cleared (qwen3-8b), both on the 2026-11-01 eval.
    """
    if not isinstance(args, dict) or not question:
        return args
    args = dict(args)
    if sort_from(question):
        args["sort"] = sort_from(question)
    title = router.QUOTED.search(question)
    if title and (re.search(r"\bwidgets?\b", question, re.I) or args.get("recipe") == "find_dashboard"
                  or (re.search(r"\bdashboards?\b", question, re.I)
                      and args.get("recipe") != "group_dashboards_reports")):   # 'what dashboards does "acme" have?'
        # A widget or dashboard title in quotes is find_dashboard's, whatever the
        # model picked: "Show me the widgets that have the title "Top Cisco ASAs by
        # Connections (Trend)"" ran find_group on Cisco ASA (qwen3-vl-4b, 2026-11-11).
        quoted = [t.strip() for t in router.QUOTED.findall(question) if t.strip()]
        args = {"recipe": "find_dashboard", "title": quoted if len(quoted) > 1 else quoted[0],
                **({"sort": args["sort"]} if "sort" in args else {})}
    for picked, words, instead in SIBLINGS:
        if args.get("recipe") == picked and words.search(question):
            # "is collector COLLECTOR keeping up?" ran collector_health on every ask on
            # qwen3-vl-4b, and "has DEVICE stopped collecting data?" device_health on
            # qwen3-8b (2026-11-07): the question's own words name the other recipe.
            args["recipe"] = instead
    worse = WORSE.search(question)
    if worse and args.get("recipe") in ALERT_RECIPES:
        # "show me errors or worse" ran critical_alerts on two models, and a
        # third left out the severity (2026-11-05): the alerts recipe, at that
        # severity and up, is the answer.
        args["recipe"] = "alerts"
    window = next((v for k, v in WINDOWS if re.search(k, question, re.I)), None)
    if args.get("recipe") == "new_alerts" and window not in (None, "last_24_hours"):
        # new_alerts is the last 24 hours, whatever was asked: "what's happened in
        # the last hour?" is the alerts recipe over that hour.
        args = {"recipe": "alerts", "started": window, **({"sort": args["sort"]} if "sort" in args else {})}
    if args.get("recipe") in ("alerts_unacknowledged", "open_alerts") and CLEARED.search(question):
        # "How many alerts cleared yesterday?" ran alerts_unacknowledged, which
        # only has open ones (qwen3-vl-4b, 2026-11-05).
        args["recipe"] = "alerts"
    if args.get("recipe") != "alerts":
        return args
    if worse:
        args["severity"] = WORSE_IS[worse[1].lower()[:4]]
        if args["severity"] is None:
            args.pop("severity")   # "warnings or worse": everything but info
    elif (only := [v for k, v in SEVERITY_IS.items() if re.search(k, question, re.I)]) and len(only) == 1:
        args["severity"] = only[0]   # "how many warnings are open?" came with no severity (qwen3-4b)
    if window is None and not TIMEISH.search(question):
        # No time in the question, so none in the answer: "how many warnings are
        # open?" came as started=today, and 6 is not 130 (qwen3-vl-4b, 2026-11-05).
        args.pop("started", None)
        args.pop("ended", None)
    elif window and CLEARED.search(question) and not STARTED.search(question):
        # "How many alerts cleared yesterday?" came as started=yesterday,
        # ended=last_hour (qwen3-4b-instruct-2507, 2026-11-05).
        args.pop("started", None)
        args["ended"] = window
    elif window and not args.get("started") and not args.get("ended") and HAPPENED.search(question):
        # "what's happened in the last hour?" with no window would be every open alert.
        args["started"] = window
    if args.get("state") == "open" and (args.get("started") or args.get("ended")) and not OPEN.search(question):
        del args["state"]   # the window's own state applies: any for started, cleared for ended
    return args


def run_recipe(session, recipe=None, device=None, group=None, collector=None, person=None, days=None, sort=None,
               **options):
    """Run one recipe; return (text for the model, [step and table events]).

    With no recipe named and one thing to look at, it is that thing's health
    recipe: recipe(group="acme") came back as a Python TypeError, retried until
    the turn gave up (qwen3.5-4b, 2026-11-01)."""
    given = {k: v for k, v in {"device": device, "group": group, "collector": collector, "person": person}.items() if v}
    if not recipe and len(given) == 1:
        recipe = router.HEALTH[next(iter(given))]
    r = RECIPES.get(recipe)
    if not r:
        raise ValueError(f"No recipe {recipe!r}. Recipes: {', '.join(RECIPES)}")
    # Options on a recipe without them are ignored, as days is.
    # A `many` option with several values: one query per value (LM's filters
    # have no "or"), and the words name them all.
    many = next((n for n, o in r.get("options", {}).items() if o.get("many")), None)
    values = options.get(many) if many else None
    if isinstance(values, str):
        values = values.split(" | ")
    values = list(dict.fromkeys(str(v).strip() for v in values or [] if str(v).strip()))
    per = [(v, choose(r, {**options, many: v})[0]) for v in values] if len(values) > 1 else None
    chosen, before, after = choose(r, {**options, many: values[0]} if values else options)
    if per:
        joined = '", "'.join(values[:-1]) + '" or "' + values[-1]
        after = after.replace(r["options"][many]["text"]["words"].format(values[0]),
                              r["options"][many]["text"]["words"].format(joined))
    # days on a recipe without it is ignored: the answer says what it covers.
    ahead = None
    if "days" in r:
        try:
            ahead = min(max(int(days or r["days"]), 1), MAX_DAYS)
        except (TypeError, ValueError):
            ahead = r["days"]
    fill = {"days": ahead, "alerts": f"{before}alerts", "Alerts": f"{before}alerts".capitalize(), "qual": after}
    covers = r.get("covers", "").format(**fill) or None
    given = {"device": device, "group": group, "collector": collector, "person": person}
    for param, value in given.items():
        if value and param not in r.get("params", []):
            # A small model asked about one device's downtime ran the portal's
            # and reported every SDT as the device's (qwen3-8b, 2026-10-29).
            return (f"Not run: {recipe} is not about one {param}, so it cannot answer a question about {value}. "
                    f"Use one of these with {param}={value!r}: {', '.join(taking(param))}; "
                    f"or, if none fits, run_elm."), []
    names, records, events = {}, {}, []   # names: step name -> dataset id
    cut, skipped = [], set()   # steps LM's 10,000-row limit cut short; steps whose `when` was false
    narrowed = {}              # step name -> what its narrower filter covers
    says_now = {}              # step name -> its says, when narrowed
    capped = []                # `each` steps that stopped at their limit

    def keep(name, lines, shown, what, command):
        ds_id = session.add(lines, f"recipe {recipe}: {what}", command)
        names[name] = ds_id
        events.append({"type": "step", "command": shown, "result": f"{len(lines)} rows", "dataset": ds_id})

    def jq(expression):
        # $device -> $d3: the page's rerun script binds datasets by id.
        for name, ds_id in names.items():
            expression = re.sub(rf"\${name}\b", f"${ds_id}", expression)
        return (PRELUDE + (f"def days: {ahead};\n" if ahead else "")
                + f"def which: {json.dumps(before + 'alert')}; def qual: {json.dumps(after)};\n"
                + f"def narrowed: {json.dumps(narrowed)};\n"
                + f"def titles: {json.dumps(values)};\n"
                # "No critical alerts are open." under "only those that started
                # today" said there were none at all (2026-11-10)
                + 'def nothing($t): if narrowed == {} then $t else "None of those." end;\n' + expression)

    try:
        for param in r.get("params", []):
            value = (given.get(param) or "").strip()
            if not value or '"' in value:
                raise ValueError(f"Recipe {recipe} needs {param}: the name as the person wrote it, without quotes.")
            if param == "person":
                # Nothing in LM to look up: the name is matched in the recipe's rows ($person[0].name).
                names[param] = session.add([json.dumps({"name": value})], f"recipe {recipe}: person {value}")
                records[param] = {"name": value}
                continue
            command, filters, fields = LOOKUPS[param]
            filters = r.get("lookup", filters)   # the recipe's own order, as find_group's
            if param == "group":
                value = value.strip("/")
            if not value.isdigit():
                filters = [f for f in filters if not f.startswith("id:")]
            for f in filters:
                lines, _, _, shown = elm_tools.fetch(command, filter=f.format(value), fields=fields, size=20)
                if lines:
                    break
            keep(param, lines, shown, f"{param} {value}", command)
            found = [json.loads(line) for line in lines]
            if not found and param == "device":
                # "What's alerting in Customers/acme?" was looked up as a device
                # every time it lacked the word "group" (qwen3-8b, 2026-10-30).
                command, filters, fields = LOOKUPS["group"]
                for f in filters:
                    groups = elm_tools.fetch(command, filter=f.format(value.strip("/")), fields=fields, size=20)[0]
                    if groups:
                        paths = ", ".join(json.loads(line)["fullPath"] for line in groups)
                        return (f"No device has a name like {value!r}, but these groups do: {paths}. "
                                f"Use a group recipe with group={value!r}."), events
            if not found:
                # Shown as the answer and its How I worked this out, so the reader
                # sees what was looked for: a bare "couldn't find web01" from a
                # second machine said nothing about which name or portal (2026-10-30).
                how = {"device": "display name, then part of it, then hostname or IP",
                       "group": "name, then path, then part of either",
                       "collector": "id, then description, then hostname"}[param]
                # How many this profile sees at all: a token whose role hides a group
                # finds collectors but not that group's devices (a second machine's
                # ai.ini, 2026-10-30), and "not found" alone reads as "not monitored".
                try:
                    seen = elm_tools.fetch(LOOKUPS[param][0], total=True)[0]
                except elm_tools.Refused:
                    seen = ""
                where = elm_tools.portal() or "this portal"
                among = f" (this profile can see {seen} {param}s there)" if seen.isdigit() else ""
                near = nearest(value)
                events.append({"type": "worked", "lines": [f"Looked for a {param} named {value!r} by {how}: none found."]
                               + ([f"Counted the {param}s this profile can see: {seen}."] if seen.isdigit() else []),
                               "summary": f"No {param} in {where} has a name like {value!r}{among}."
                                          + (f" Did you mean the {near[1]} {near[0]!r}?" if near else ""),
                               "covers": None})
                return f"No {param} has a name like {value!r}. Say so; do not guess another {param}.", events
            if len(found) > 1 and not r.get("many"):
                listed = ", ".join(d.get("displayName") or d.get("fullPath") or d.get("description") or d.get("name")
                                   for d in found)
                some = "At least " if len(found) == 20 else ""
                return (f"{some}{len(found)} {param}s have a name like {value!r}: {listed}. Ask which one "
                        f"is meant, then use the recipe again with its exact name."), events
            records[param] = found[0]

        for step in r.get("steps", []):
            if "when" in step and elm_tools._jq(session, jq(step["when"])).strip() != "true":
                names[step["as"]] = session.add([], f"recipe {recipe}: {step['as']} (skipped)")   # still bound for jq
                skipped.add(step["as"])
                continue
            if "each" in step:
                items = json.loads(elm_tools._jq(session, jq(step["each"])))
                most = min(step.get("most", MAX_EACH), MOST_EACH)
                if len(items) > most:
                    capped.append(f"checked the first {most} of {len(items)} {step.get('noun', 'items')}")
                items = items[:most]
                lines, shown = [], f"{step['run']}: nothing to fetch"
                for i, row in enumerate(items):
                    params = {k: str(v).format(**records, row=row) for k, v in step.get("params", {}).items()}
                    got, _, _, one = elm_tools.fetch(step["run"], fields=step.get("fields"), params=params, size=0)
                    lines += [json.dumps(json.loads(line) | {"of": row}) for line in got]
                    shown = one if i == 0 else f"{shown.split('  # ')[0]}  # and {i} more like it"
                keep(step["as"], lines, shown, step["as"], step["run"])
                continue
            if per and "{options}" in step.get("filter", ""):
                lines, shown = [], None
                for i, (value, option) in enumerate(per):
                    got, first, total = fetch_all(step["run"], filter=step["filter"].format(**records, options=option),
                                                  fields=step.get("fields"))
                    if total:
                        cut.append(f"{step['as']} {value!r}: {len(got)} rows, "
                                   + ("possibly more" if total.startswith(">") else f"of {total}"))
                    lines += [json.dumps(json.loads(line) | {"of": value}) for line in got]
                    shown = first if i == 0 else f"{shown.split('  # ')[0]}  # and {i} more like it"
                keep(step["as"], lines, shown, step["as"], step["run"])
                continue
            wanted = step["filter"].format(**records, options=chosen) if "filter" in step else None
            if "narrow" in step:
                # 9,991 open alerts gave a summary of counts "possibly too low",
                # from rows LM picked (2026-11-10). Over OVER is too many to go
                # through anyway: one row at that offset says whether a filter
                # is, in one request. A narrower filter still over is still
                # fetched last, and cut short as any other.
                for n in [None] + step["narrow"]:
                    tried = n["filter"].format(**records, options=chosen) if n else wanted
                    over, _, _, check = elm_tools.fetch(step["run"], filter=tried, fields=step.get("fields"),
                                                        size=1, offset=OVER)
                    events.append({"type": "step", "command": check,
                                   "result": f"{'over' if over else 'under'} {OVER:,}"})
                    if not over:
                        break
                if n:
                    wanted = tried
                    narrowed[step["as"]] = n["covers"]
                    says_now[step["as"]] = n["says"]
            kw = {"filter": wanted,
                  "fields": step.get("fields"),
                  "params": {k: str(v).format(**records) for k, v in step.get("params", {}).items()} or None}
            if step.get("size") == "all":
                lines, shown, total = fetch_all(step["run"], **kw)
                if total:
                    cut.append(f"{step['as']}: {len(lines)} rows, " +
                               ("possibly more" if total.startswith(">") else f"of {total}"))
            else:
                lines, _, _, shown = elm_tools.fetch(step["run"], size=step.get("size", 0), **kw)
            keep(step["as"], lines, shown, step["as"], step["run"])
    except elm_tools.Refused as exc:
        text, step = exc.args
        events.append(step)
        # Samara's words, not the model's: the reason is what someone can act on.
        reason = step["result"].removeprefix("failed: ")
        events.append({"type": "worked", "lines": [f"Asked {elm_tools.portal() or 'the portal'}: the query failed."],
                       "summary": elm_tools.cannot_answer(reason),
                       "covers": None})
        return f"The recipe could not run: {text}", events

    summary = json.loads(elm_tools._jq(session, jq(r["summary"])))
    if "narrowed" not in r["summary"]:
        # A summary that does not word it itself (portal_health does) gets one
        # line in front: its counts are of the narrower rows only.
        for step in r.get("steps", []):
            if step["as"] in narrowed:
                summary = (f"Over {OVER:,} {step.get('over', 'rows')}, too many to go through, so this covers "
                           f"only the {narrowed[step['as']]}. {summary}")
    if cut:
        # The counts are over the rows that came back, so they may be too low.
        summary = (f"Only part of the data could be fetched ({'; '.join(cut)}: LogicMonitor returns at most "
                   f"10,000 rows), so the counts below may be too low. {summary}")
    if capped:
        summary = f"Only part was checked ({'; '.join(capped)}), so the counts below may be too low. {summary}"
    # Only the summary goes to the model. The table and How I worked this out
    # are Samara's: a small model copied instructions about them into its
    # answers word for word, and listed queries that never ran.
    text = f"Answer with this, keeping its facts and numbers exactly:\n\n{summary}\n\n"
    if covers:
        text += (f"This recipe answers only: {covers}. If the question asked for more (another time, "
                 f"place or measure), say what you could not check; add nothing else.\n\n")
    if r.get("table_only"):
        text += "The values are for the reader to read in the table, not for you: add nothing else."
    else:
        data = ", ".join(f"${ds_id} ({name})" for name, ds_id in names.items())
        text += (f"If the question asks something this does not cover, get it from the recipe's rows with jq "
                 f"({data}); add nothing else.")
    if "table" in r:
        t = r["table"]
        rows = jq(t["rows"])
        if isinstance(sort, (list, tuple)) and len(sort) == 2:   # from from_question, never the model
            rows, said = sorted_rows(rows, t["columns"], sort)
            text += "\n\n" + said
        note, table = elm_tools.show_table(session, t["title"].format(**records, **fill), rows, t["columns"],
                                           t.get("links"))
        if t.get("chart") and table["total"]:
            # Drawn by the page from these rows, so a chart can only show what the portal returned.
            table["chart"] = t["chart"] if isinstance(t["chart"], list) else [t["chart"]]
        if table["total"]:
            events.append(table)
    worked = [f"Found the {p} by name." for p in r.get("params", [])]
    says = [says_now.get(step["as"], step.get("says", step["as"])).format(**fill)
            for step in r.get("steps", []) if step["as"] not in skipped]
    says = [line for line in says if line]   # "": said by another step (one query per name)
    worked += [line[:1].upper() + line[1:] + "." for line in says]
    events.append({"type": "worked", "lines": worked, "summary": summary, "covers": covers})
    return text, events


# Every recipe's options, as tool arguments: an enum of their values, or a name.
OPTIONS = {}
for _r in RECIPES.values():
    for _name, _o in _r.get("options", {}).items():
        OPTIONS[_name] = {"type": "string", "description": f"For {_r['name']}: {_o['about']}"} | (
            {} if "text" in _o else {"enum": list(_o["values"])})

# Registered with the other tools, first, so a model reading the list in
# order meets it before run_elm. Importing this module is what adds it.
elm_tools.HANDLERS["recipe"] = run_recipe
elm_tools.RECIPE_NAMES.update(RECIPES)
elm_tools.TOOLS.insert(0, {
    "name": "recipe",
    "description": tool_description(),
    "input_schema": {
        "type": "object",
        "properties": {
            "recipe": {"type": "string", "enum": list(RECIPES), "description": "The recipe's name"},
            "device": {"type": "string", "description": "For a device recipe: the device's name as the person wrote it"},
            "group": {"type": "string", "description": "For a group recipe: the group's name or path as the person wrote it"},
            "collector": {"type": "string", "description": "For a collector recipe: the collector's name or number as the person wrote it"},
            "person": {"type": "string", "description": "For a person recipe: the person's name as written"},
            **OPTIONS,
            "days": {"type": "integer", "description": "For downtime: how many days ahead to look, "
                     "if the question says (\"next 3 days\" is 3); leave it out otherwise"},
        },
        "required": ["recipe"],
    },
})
