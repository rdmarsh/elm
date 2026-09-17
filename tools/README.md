# elm tools

This directory holds standalone helper scripts that live alongside elm but are
**out of scope of the elm program itself**. They are handy things built on top of
elm and on learnings about the LogicMonitor API — one-off utilities, small
reports, and checks. They are **not** part of the elm CLI, are not built or
installed by `make`, and are intentionally **not documented in the main README**
(which stays focused on elm). Most accept `-p`/`--profile` to pick a credential
profile, the same as elm (default `config`).

This file documents the general-purpose tools. The collector readiness /
reachability tooling has its own walkthrough under
[`examples/collector-readiness.md`](../examples/collector-readiness.md), and every
script also responds to `-h`/`--help`.

## Contents

- [API speed test](#api-speed-test) — `tools/elm-speedtest.sh`
- [Ask in plain English](#ask-in-plain-english) — `tools/elm-ask/`
- [Backups](#backups) — `tools/elm-backup.sh`, `tools/elm-collector-config-backup.py`
- [Change advice](#change-advice) — `tools/elm-change-advice.py`
- [Collector health check](#collector-health-check) — `tools/lm-collector-run-groovy.ps1`
- [Datasource usage matrix](#datasource-usage-matrix) — `tools/elm-datasource-matrix.py`
- [Group paths](#group-paths) — `tools/elm-group-paths.sh`
- [Host SDTs](#host-sdts) — `tools/elm-host-sdts.sh`
- [Module updates](#module-updates) — `tools/elm-module-updates.py`

## API speed test

`tools/elm-speedtest.sh` times the LM API response for each credential profile
across a set of endpoints. Useful for comparing latency across portals or
networks. Credentials are kept in memory only, never written to disk. If
any profile has identical credentials to `config`, `config` is skipped
automatically to avoid duplicate results.

```shell
# default endpoints (AdminList, DeviceList, AuditLogList)
tools/elm-speedtest.sh

# custom endpoints
tools/elm-speedtest.sh ReportList DeviceGroupList WebsiteList
```

Available list endpoints:
`AdminList` `AlertRuleList` `ApiTokenList` `CollectorGroupList` `CollectorList`
`ConfigSourceList` `DashboardGroupList` `DatasourceList` `DeviceGroupList`
`DeviceList` `EscalationChainList` `EventSourceList` `IntegrationList`
`NetscanList` `RecipientGroupList` `ReportGroupList` `ReportList` `RoleList`
`SDTList` `WebsiteGroupList` `WebsiteList`

## Ask in plain English

`tools/elm-ask/` is a prototype web page, packaged as a Docker container, where
people who don't use elm can ask questions such as "what devices have alerting
disabled?". Claude answers using read-only elm queries and shows the queries it
ran. Setup, the safety model and settings are in
[`tools/elm-ask/README.md`](elm-ask/README.md).

## Backups

Two read-only snapshotters that record what a portal looks like for auditing and
change-tracking. Neither is a **restore** mechanism — elm is read-only and LM has
no bulk import; the value is a diffable record of what the portal looked like.
The tools do **not** version anything themselves — each run overwrites the
previous snapshot in place. To get history you either version it yourself (point
a separate git repo at the backup dir and commit after each run, then `git log
-p` shows exactly what changed) or pass `--date`, which writes each run under a
UTC datestamp subdir (`.../YYYY-MM-DD/`) so different days don't overwrite each
other. Both label output by LM **account name** (resolved from elm's own request
URL, not the credentials `.ini`), default their root to `$ELM_BACKUP_DIR` or
`~/elm-backup` (**outside** this code repo so a backup is never committed), and
refuse to write inside a git work tree unless `--dir` is given explicitly.

`tools/elm-backup.sh` dumps configuration **objects** — alerting (alert rules,
escalation/action chains, action rules, recipient groups, integrations) and
collectors (collector/group/version lists) — one JSONL file per endpoint
(`<endpoint>.jsonl`). Active/historical alerts are excluded (transient telemetry,
not config).

```shell
tools/elm-backup.sh                       # default profile -> ~/elm-backup/<account>/
tools/elm-backup.sh -p prod --date        # prod, history kept by date
ELM_BACKUP_DIR=/srv/lm tools/elm-backup.sh
```

`tools/elm-collector-config-backup.py` captures the thing `elm-backup.sh` leaves
out: each collector's actual **config files** (`collectorConf`, `wrapperConf`,
`sbproxyConf`, `watchdogConf`, `websiteConf`), decoded into a per-collector tree
(`collectors/<id>-<hostname>/<conf>`) — one text file per non-empty conf, so diffs
are clean. Those fields are permission-gated: LM only returns them to a token
whose `userPermission` on the collector includes `write` (Manage); a read-only
token gets `"{}"`. The tool reads `userPermission` up front, so it **skips**
read-only collectors (reporting a summary) and RBAC-scoped tokens back up exactly
what they can. If **no** collector is readable it aborts (exit 3) and writes
nothing rather than leaving a tree of empty files.

```shell
tools/elm-collector-config-backup.py               # default profile
tools/elm-collector-config-backup.py -p prod --date
```

## Collector health check

`tools/lm-collector-run-groovy.ps1` runs an arbitrary Groovy script on one or
more LM collectors via Collector Debug and prints (or saves) each collector's
output. It is a **generic** runner — `-Script` points at a `.groovy` file of
your own (e.g. a collector health-check script that reports JVM heap, disk,
and task queue stats from the collector itself); no such script ships with
elm or lives in this repo. Unlike the elm-based tools above it is
**self-contained** — only the Logic.Monitor PowerShell module and one
`Connect-LMAccount` session are needed, no elm, bash, jq, or jinja2. Collector
Debug requires a Manage-level API token (a read-only token gets "Access
denied").

```pwsh
# run your own health-check script against one collector, save its output
./tools/lm-collector-run-groovy.ps1 -Script ~/lm-collector-toolkit/CollectorHealthCheck.groovy `
    -Collector collector01 -OutFile ./collector01.txt

# run against a list of collectors; one output file per collector
./tools/lm-collector-run-groovy.ps1 -Script ~/lm-collector-toolkit/CollectorHealthCheck.groovy `
    -Collector collector01,collector02,collector03 `
    -OutputDir ~/logicmonitor/collector_health
```

Collectors are matched by numeric id, hostname, or description — an
unambiguous substring is enough (e.g. `collector01` resolves against
`CORP\COLLECTOR01`). `-Device` can be used instead of, or alongside,
`-Collector`: each device name is resolved to the collector it currently runs
on, which is handy when you think in terms of monitored hosts rather than
collector hostnames. See `-h`/`--help` (or the script's own comment header)
for `-WithHostProps` (binds a device's real host properties, for
device-scoped rather than collector-scoped scripts) and other options.

There is no built-in "every collector" or pattern flag — `-Collector` always
wants an explicit list. Build that list yourself with `Get-LMCollector` (the
same cmdlet the script uses internally), then pass its output straight
through. This stays self-contained — one `Connect-LMAccount` session, no
elm needed:

```pwsh
# every active collector
$targets = (Get-LMCollector -BatchSize 1000 | Where-Object { $_.status -eq 1 }).hostname
./tools/lm-collector-run-groovy.ps1 -Script ~/lm-collector-toolkit/CollectorHealthCheck.groovy `
    -Collector $targets -OutputDir ~/logicmonitor/collector_health

# only collectors matching a pattern (hostname or description)
$targets = (Get-LMCollector -BatchSize 1000 | Where-Object {
    $_.status -eq 1 -and ($_.hostname -like '*edge*' -or $_.description -like '*edge*')
}).hostname
./tools/lm-collector-run-groovy.ps1 -Script ~/lm-collector-toolkit/CollectorHealthCheck.groovy `
    -Collector $targets -OutputDir ~/logicmonitor/collector_health
```

## Datasource usage matrix

`tools/elm-datasource-matrix.py` builds a device-by-datasource usage matrix for
every datasource whose **name** matches a pattern, as a GitHub Flavored Markdown
table. Each row is a device (device ID, then device name); each remaining column
is a matching datasource; a cell holds a tick (✓) where the datasource is
applied and is blank otherwise. It pivots one `AssociatedDeviceListByDataSourceId`
call per matching datasource, so the cost is one API call per datasource — not
one per device.

```shell
# all NTP datasources on the sandbox (case-insensitive by default)
tools/elm-datasource-matrix.py NTP

# against another portal
tools/elm-datasource-matrix.py -p prod NTP

# case-sensitive match, and CSV output for spreadsheets
tools/elm-datasource-matrix.py -s NTP
tools/elm-datasource-matrix.py --csv NTP

# regex (-x): match NTP only at the start or end of the name
tools/elm-datasource-matrix.py -x '^NTP|NTP$'

# regex OR: NTP or Ping in one run (LM can't OR repeated -F, so each
# branch becomes its own server call and the results are unioned)
tools/elm-datasource-matrix.py -x 'NTP|Ping'
```

Example output (columns are padded so the raw Markdown lines up):

```text
|  ID | Device | Cisco_NTP | NTPv4 | Acme_Cisco_NTP_Peer |
| --: | ------ | :-------: | :---: | :-----------------: |
| 101 | host-a |           |   ✓   |                     |
| 102 | host-b |           |   ✓   |                     |
| 103 | host-c |     ✓     |       |          ✓          |
```

The match is **case-insensitive by default**, so `ntp`, `NTP` and `Ntp` all
match `NTPv4` and `Cisco_NTP`. Pass `-s`/`--case-sensitive` (the same flag as
ripgrep) to narrow it — then `NTP` no longer matches incidental substrings such
as `AccessPoi`*`ntP`*`erformance` or `OverCurre`*`ntP`*`rotectors`. Pass
`-x`/`--regex` to treat the pattern as a Python regular expression; anchor with
`^` and `$` to match only at the start or end of the name, so `'^NTP|NTP$'`
matches `NTP`, `NTPv4` and `Cisco_NTP` but not a mid-string `Cisco_NTP_Stats`.
(Regex mode still narrows server-side: it derives a literal substring from the
pattern — e.g. `NTP` from `'^NTP|NTP$'` — for the `name~` filter, then refines
with the full regex client-side, so the full datasource list is never
downloaded.) `--csv` emits `id,device,<datasource…>` rows with `1`/`0` cells for
spreadsheets. To avoid an unusably large matrix, the tool aborts if more than
`--max-cols` datasources match (default 20 — each is also one API call, checked
before any are made) or more than `--max-rows` devices would be rows (default
1000, LM's per-request row cap — every call uses `-s0`, a single max-size page,
so beyond ~1000 the underlying device lists truncate anyway); narrow the pattern
or pass `--max-cols N` / `--max-rows N` (`0` = unlimited).
**Real devices only:** rows are restricted to actual devices (`deviceType` 0 or
1); everything else LM models as a "device" — LM Services / Service Insight,
cloud accounts and resources (AWS, Azure), Kubernetes resources — is excluded,
and this is not configurable. Datasources with no remaining devices are dropped
(empty columns), and only devices using at least one matching datasource appear
as rows. "Applied" is the live device→datasource association, not the daily
`auto.activedatasources` property.

## Group paths

`tools/elm-group-paths.sh` prints the full path of every device group, or every
website group with `--website`, one per line and sorted. It pages through groups
1000 at a time using `-C` for the total, and leaves out the root group (whose
path is empty). Useful for comparing group trees between portals.

```shell
# device groups on the default profile
tools/elm-group-paths.sh

# website groups on another portal
tools/elm-group-paths.sh --website -p prod

# what differs between two portals
diff <(tools/elm-group-paths.sh -p preprod) <(tools/elm-group-paths.sh -p prod)

# one file per portal: out/device-group-paths-<profile>.txt
tools/elm-group-paths.sh -p preprod -p prod -d out/
```

With several profiles and no `-d`, each line is prefixed with the profile name
and a tab.

## Host SDTs

`tools/elm-host-sdts.sh` lists the SDTs (scheduled downtime) affecting each host
in a list — including SDTs the host **inherits from a group**. Hosts are given
one display name per line (from a file, from stdin via `-`, or as arguments) and
are de-duplicated. Each host is resolved to a device id via `DeviceList`, then
`AllSDTListByDeviceId` (`/device/devices/{id}/sdts`) is queried — that endpoint
does the inheritance join server-side, returning device, instance, and applicable
group SDTs (and correctly excluding a group SDT scoped to a datasource/instance
the device doesn't have), so there is no manual cross-referencing.

```shell
# SDTs for one host
tools/elm-host-sdts.sh host1

# a list of hosts, one display name per line
tools/elm-host-sdts.sh hosts.txt

# from stdin
printf 'host1\nhost2\n' | tools/elm-host-sdts.sh -

# only currently-active SDTs, against another portal
tools/elm-host-sdts.sh -p prod --active hosts.txt
```

Example output (one aligned table per host):

```text
--- host1 ---
TYPE     ACTIVE  GROUP               HOST   INSTANCE  FROM                      TO                        DURATION  COMMENT
weekly   yes     -                   host1  -         2026-06-26 14:29:00 AEST  2026-06-26 15:29:59 AEST  1h        patch window
oneTime  no      Customers/acme/All  -      -         2026-06-26 18:55:22 AEST  2026-06-27 15:02:59 AEST  20h7m     change freeze
```

Each SDT fills only the scope column(s) it applies to — `GROUP` (full path, plus
the limiting datasource in brackets when scoped to one), `HOST`, or `INSTANCE` —
others show `-`. `TYPE` is the LM `sdtType`
(`oneTime`/`daily`/`weekly`/`monthly`/`monthlyByWeek`); `ACTIVE` is the
`isEffective` field (`yes` = suppressing alerts right now). `FROM`/`TO` are in the
**portal's** timezone (with abbreviation, e.g. `AEST`), not the local machine's.
Rows are sorted active-first, then by `FROM`. `--active` limits output to
currently-active SDTs; `--exact` switches host matching from contains
(`displayName~`) to exact (`displayName:`); `-p`/`--profile` selects the portal
(defaults to `config`). Requires `elm`, `jq`, and `column`.

## Module updates

`tools/elm-module-updates.py` lists LogicModules that need attention — by
default, **DataSources** that are LM official (`originStatus` `CORE` or
`DEPRECATED`), **not** customised locally, and either upgradable **or
deprecated** — split into two sections, *not in use* then *in use*, each sorted
**most out of date first**. Deprecated modules are included because they can
never be upgraded (they are replaced by a different module on LM's timetable),
so requiring an upgrade would hide the ones that most need looking at: in one
test portal that was 371 installed deprecated datasources, 88 of them in use.
`--status CORE` drops them again, and says how many it dropped.
`-t`/`--type` switches to any other module type, several comma-separated, or
`ALL` — the same single call already carries propertysources, configsources,
eventsources, logsources, topologysources, SNMP sysOID maps and appliesTo
functions, so other types cost nothing extra; with more than one type each
section gets a table per type.

It costs **one API call** regardless of portal size: `elm V4Metadata`
(`GET /setting/logicmodules/metadata`), the feed behind the portal's module
Toolbox and the Exchange. That one response carries every installed module *and* everything
installable from the Exchange, with per-module `installationStatuses`
(`IS_INSTALLED`, `CAN_UPGRADE`, `IS_CUSTOMIZED`, `CAN_INSTALL`), `originStatus`,
`isInUse`, the installed `originVersion`, and `originPublishedAtMS`.

```shell
# the default report: official, uncustomised, upgradable datasources
tools/elm-module-updates.py

# another portal, saved as Markdown
tools/elm-module-updates.py -p prod > module-updates.md

# flat CSV of both sections, with status / in_use / customised / upgrade
tools/elm-module-updates.py --csv

# the running order: least risky first, work down the list
tools/elm-module-updates.py --devices

# other module types — one, several, or all
tools/elm-module-updates.py -t PROPERTYSOURCE
tools/elm-module-updates.py -t DATASOURCE,PROPERTYSOURCE
tools/elm-module-updates.py -t ALL

# widen the selection
tools/elm-module-updates.py --status ALL --include-customised
tools/elm-module-updates.py --include-current      # up-to-date ones too
```

Example output (trimmed):

```text
## Not in use (746)

| published | age | version | id  | name                | group | instances |
|---|---|---|---|---|---|---|
| 2017-06-06 | 9.3 | 1.1.0 | 877 | HP_MSA_GlobalStatus |       | 0         |
| 2017-11-27 | 8.8 | 1.4.0 | 544 | AWS_SQS             |       | 0         |

## In use (106)

| published | age | version | id | name           | group | instances |
|---|---|---|---|---|---|---|
| 2018-07-09 | 8.2 | 2.0.0 | 28 | NetSNMPdiskIO- | Disks | 767       |
```

With `-t ALL` (or any comma list) each section is split by type instead:

```text
## Not in use (884)

### DATASOURCE (746)
...
### PROPERTYSOURCE (48)
...
```

**How the ordering works, and what it does not tell you.** LM exposes an
`upgradeableRegistryId` pointing at the newer registry entry but no v3 endpoint
resolves it, so the version you would upgrade *to* is not available. Ranking is
therefore by how old the version you are **running** is — `originPublishedAtMS`
ascending — and `version`/`age` describe the installed version, not the
available one. Registry publish timestamps only begin around 2017-05, so
anything older bunches up at that floor and cannot be ranked against its peers;
a handful of modules carry no publish date at all and are listed last.
**With `--devices` the report is a running order, least risky first.** That is
the main way to use it: work down the list, doing the safe changes before the
ones that can hurt, with age breaking ties so equally-risky modules come
oldest-first. Without `--devices` the order falls back to most out of date
first, because the risk score cannot be trusted without a device count. There
is no sort option — these are the only two orderings that mean anything.

The device lookups are **not capped by default** (`--max-device-calls 0`): the
full list is worth waiting for. Only **in-use** modules are looked up, which is
what makes that practical — a module nothing is collecting has no history to
lose, so its risk is already near zero however many devices its appliesTo
matches, and the lookup cannot change where it lands in the order. On one test
portal that is 186 lookups rather than 1196, minutes rather than half an hour,
for the same running order. The estimate is printed before it starts.

A **risk** column scores 0-10, combining how much breaks with how likely that
is.

*Consequence* is breadth and depth, both log-scaled, with breadth counting
about twice depth — so 1 instance on 1000 devices outranks 1000 instances on 1
device. That ordering is deliberate: LogicMonitor's worst documented outcome,
an AppliesTo change that stops a module applying, destroys history *per
device*, and alert storms scale with devices too. Depth is the volume of
history at stake on one host, so it carries half the weight rather than none.

*Likelihood* is age: every year behind adds 0.15. The further behind you are,
the more released change is folded into a single jump, and the more chance it
contains a renamed datapoint, restructured Active Discovery or an AppliesTo
change. Age is a **proxy for the size of the diff, not a measure of it** — the
API cannot tell us the target version, let alone what changed on the way — so
it is weighted modestly: at most ~1.4 of the 10. A nine-year-old module on one
device still scores 2.3, while a six-month-old one on 300 devices scores 8.0.

All three inputs stay in their own columns, so the score is auditable, and the
coefficients are a one-line change. Breadth uses devices actually collecting
where known, falling back to devices applied; with no device count the
consequence half rests on instances alone, and the legend says so.

**Instances are not devices.** For datasources and configsources the usage
column counts *instances* — discovered objects — and the feed has no device
count for them at all. `--devices` adds two more columns at the cost of one
`AssociatedDeviceListByDataSourceId` call per module: `devices` (how many the
module's appliesTo matches) and `active` (how many of those are actually
collecting, from `hasActiveInstance`). The three genuinely differ — one module
here collects **2 instances**, applies to **1205 devices**, and is collecting on
**2** of them — so none of them is a substitute for the others. A trailing `+`
on `active` in the Markdown table means the module applies to more than 1000
devices, the API's per-page cap, so the count is a floor. `--csv`/`--json` keep
`active` a plain number and carry that caveat in a separate `active_capped`
column, so the column stays sortable. `--max-device-calls` (default 100)
refuses a run that would make too many calls; narrow it with `--tag`, `-t` or
`--status` first.

**Tags** come from the module itself and are shown in full. `--tag
linux,windows` keeps modules carrying at least one of the given tags, which is
the easy way to scope both a report and a change: 3303 of 3906 installed
modules in one test portal are tagged, across 1383 distinct tags.

The usage column is **not one field**: `associatedHostsCount` is hard-wired to
`0` for DataSources and ConfigSources, so those use `associatedInstancesCount`,
while every other type has a real host count and appliesTo functions use
`useInModulesCount`. The Markdown column is therefore headed with its unit —
`instances`, `hosts` or `modules` — and `--csv`/`--json` carry both a `usage`
number and a `usage_of` label so the schema stays stable. A module can be in use
with a count of `0`. "In use" is LM's own `isInUse` flag: something
references the module, not that anyone reads the data. `--portal NAME` turns each module name into a link
to that module in My Module Toolbox. The REST API exposes no UI link, but
the feed supplies both halves of one: `model` (`exchangeDataSources`,
`exchangePropertySources`, …) is the toolbox path segment and `id` is the
module, so a single template covers every module type
(`.../santaba/uiv4/modules/toolbox/{model}/edit/{id}`) — override it with
`--url-template` if your portal differs. The subdomain is **not** auto-detected
on purpose: the only ways to get it out of elm are `-f api`, which also prints
the Authorization header, and `-vv`, which prints a truncated access key
fingerprint — neither is something a tool should capture just to build a URL.

A **status** column (the module's `originStatus`) appears in the Markdown report
whenever the selection contains more than one — with `--status ALL`, say, or a
deprecated listing. When every row has the same status the column is dropped and
the `Selected:` line above the table names it instead, the same way `type` is
dropped from a single-type report. `--csv`/`--json` always carry it.

The run summary says how many of the matches are deprecated, and points at
[LogicMonitor's deprecated LogicModules
list](https://www.logicmonitor.com/support/logicmodules/about-logicmodules/deprecated-logicmodules)
for the replacement module and end-of-support date, which are not in the API.
`--status DEPRECATED` on its own lists only those.

`-p`/`--profile` selects
the portal (default `config`), or `-c`/`--config` takes a full path to an
`.ini`; `--json` emits the report rows instead of tables. **This report cannot
be produced by elm alone:** `V4Metadata` takes no `-F`, and the `-S` it does
accept is silently ignored by that endpoint (elm sends it as a query param the
API drops), so row selection and ordering have to happen client-side — here, or
in `jq`. The same legend is
printed at the foot of every Markdown report. Upgrading is done in the portal —
elm is read-only.

## Change advice

`tools/elm-change-advice.py` drafts the change notice for a LogicModule
upgrade — what is changing, when, who is affected, what to expect and what
happens if it goes wrong — with the impact filled in from the live portal
instead of guessed. It pairs with the [module updates](#module-updates) report:
that one tells you what needs upgrading, this one writes the notice.

**It drafts only.** Nothing is sent, no mail is configured, no ticket is
raised, and it never performs the upgrade it describes. The notice goes to
stdout for a human to read, edit and send.

```shell
# straight from the update report
tools/elm-module-updates.py --csv | head -20 > batch.csv
tools/elm-change-advice.py --date 2026-10-02 --from batch.csv

# or by id, all three formats at once
tools/elm-change-advice.py --date 2026-10-02 --window '19:00-20:00 AEST' \
  --id 28,107 --ref CHG0012345 --contact monitoring@example.com --format all
```

`--format` picks the shape: `email` (default — plain text wrapped to 72
columns with a suggested subject line), `itsm` (field-per-line for a change
record: summary, risk, impact, implementation plan, backout plan, test plan),
`md` (Markdown for a wiki page or ticket), or `all`.

Filled in from the API: module names, installed versions and publish dates,
collection method and interval, whether each module is locally customised or
deprecated, the instances actually collected, and the devices each module
applies to. Left to you as `<ANGLE BRACKET>` placeholders so an unedited draft
is obviously unfinished: the window, approver, change reference and contact.

**Give it a shortlist, not a whole report.** The notice is for the modules you
are actually changing on the day. Piping an unnarrowed
`elm-module-updates.py --json` in means a device lookup for every match — two
API calls each — so `--max-device-calls` (default 100) refuses the run and says
how to narrow it. Filter the report first (`--tag`, `-t`, `--status`), name the
modules with `--id`, or pass `--no-devices` to skip the lookups entirely.

**Devices are named under the module they affect**, not pooled into one list at
the end: what a reader needs is who is hit by this change to *this* module.
They are named only when there are few enough to be worth reading —
`--list-devices-under N`, default 10 — and past that the count alone stands.
Raise it to name more (`--list-devices-under 50`), or pass `0` to never name
them.

**Two counts, never merged.** "Collected" is real instances; "applies to" is
the appliesTo match, which can be far larger — one module here collects 2
instances but applies to 1205 devices. The device names come from
`AssociatedDeviceListByDataSourceId`, which caps at 1000 rows per page, so the
count comes from `-C` (LM's true total) while the names are treated as a
sample; The names are treated as a sample when
that cap bites.

**Ids are only unique within a type.** In one test portal 329 ids belonged to
several types at once and id 28 to six of them, so a bare `--id 28` means
"`--type`'s id 28" (default `DATASOURCE`) and anything else needs `TYPE:ID`,
e.g. `TOPOLOGYSOURCE:28`. An id that exists under a different type is skipped
with a message naming the types that do have it. The `--csv`/`--json` output of
`elm-module-updates.py` always carries a `type` column for exactly this reason,
so `--from` is never ambiguous.

`--portal NAME` links each module to itself in the portal, exactly as in the
[module updates](#module-updates) report and with the same `--url-template`
override: a Markdown link on the module name in `md`, and the URL on its own
line beneath each module in `email` and `itsm`, since plain text has no inline
links. Worth setting — the point of the notice is that someone reads it and
goes and looks.

Each module carries its **locator** (e.g. `FJJGMW`), the LogicMonitor Exchange
lookup key. The API does not expose the version an upgrade goes *to*, so the
implementation plan's first step is to look each module up by locator, read the
target version and review the diff — that is the step that establishes what is
actually changing.

**What to expect** is taken from LogicMonitor's own
[LogicModule Updates](https://www.logicmonitor.com/support/logicmodules/about-logicmodules/keeping-your-datasources-up-to-date)
page rather than invented, and the notice cites it. It names the case an
approver most needs to hear and would not otherwise be told: historical data
can be lost **permanently** — when a datapoint is renamed or removed, when
Active Discovery rediscovers instances under new names, or when an AppliesTo
change stops the module applying to a device even temporarily, which discards
all history for that module on those devices. Thresholds set at device or
device group level survive; anything set on the module itself does not.

The backout plan follows what is in scope. An unmodified official module is a
published registry version, so the plan is to reinstall the version listed
against it — no export needed, and the notice carries that version number for
exactly this reason. Only **locally customised** modules get the "export this
first" step, named individually, because their content exists nowhere but the
portal and reinstalling a published version will not bring the local edits back.

Risk is derived, not asserted, and `--risk` overrides it: a **deprecated**
module makes it High (it cannot be upgraded at all — it is replaced by a
different module on LM's timetable, so the change is a migration), a locally
customised module makes it Medium (upgrading overwrites the local edits), and a
wide blast radius is called out with the numbers behind it.
