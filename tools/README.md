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
- [Backups](#backups) — `tools/elm-backup.sh`, `tools/elm-collector-config-backup.py`
- [Change advice](#change-advice) — `tools/elm-change-advice.py`
- [Collector health check](#collector-health-check) — `tools/lm-collector-run-groovy.ps1`
- [Datasource usage matrix](#datasource-usage-matrix) — `tools/elm-datasource-matrix.py`
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

`tools/elm-module-updates.py` lists LogicModules that have a newer version
waiting in the LM Exchange — by default, **DataSources** that are LM official
(`originStatus` `CORE`), **not** customised locally, and upgradable — split into
two sections, *not in use* then *in use*, each sorted **most out of date first**.
`-t`/`--type` switches to any other module type, several comma-separated, or
`ALL` — the same single call already carries propertysources, configsources,
eventsources, logsources, topologysources, SNMP sysOID maps and appliesTo
functions, so other types cost nothing extra; with more than one type each
section gets a table per type.

It costs **one API call** regardless of portal size: `elm V4Metadata`
(`GET /setting/logicmodules/metadata`), the feed behind the portal's module
toolbox. That one response carries every installed module *and* everything
installable from the Exchange, with per-module `installationStatuses`
(`IS_INSTALLED`, `CAN_UPGRADE`, `IS_CUSTOMIZED`, `CAN_INSTALL`), `originStatus`,
`isInUse`, the installed `originVersion`, and `originPublishedAtMS`.

```shell
# the default report: official, uncustomised, upgradable datasources
tools/elm-module-updates.py

# another portal, saved as Markdown
tools/elm-module-updates.py -p prod > module-updates.md

# flat CSV of both sections, with in_use / customised / upgrade / origin_status
tools/elm-module-updates.py --csv

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
**Instances are not devices.** For datasources and configsources the usage
column counts *instances* — discovered objects — and the feed has no device
count for them at all. `--devices` adds two more columns at the cost of one
`AssociatedDeviceListByDataSourceId` call per module: `devices` (how many the
module's appliesTo matches) and `active` (how many of those are actually
collecting, from `hasActiveInstance`). The three genuinely differ — one module
here collects **2 instances**, applies to **1205 devices**, and is collecting on
**2** of them — so none of them is a substitute for the others. A trailing `+`
on `active` means the module applies to more than 1000 devices, the API's
per-page cap, so the count is a floor. `--max-device-calls` (default 100)
refuses a run that would make too many calls; narrow it with `--tag`, `-t` or
`--status` first.

**Tags** come from the module itself and are shown three-at-a-time in the
Markdown table (`+N` for the rest), in full in `--csv`/`--json`. `--tag
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
to that module in the portal's toolbox. The REST API exposes no UI link, but
the feed supplies both halves of one: `model` (`exchangeDataSources`,
`exchangePropertySources`, …) is the toolbox path segment and `id` is the
module, so a single template covers every module type
(`.../santaba/uiv4/modules/toolbox/{model}/edit/{id}`) — override it with
`--url-template` if your portal differs. The subdomain is **not** auto-detected
on purpose: the only ways to get it out of elm are `-f api`, which also prints
the Authorization header, and `-vv`, which prints a truncated access key
fingerprint — neither is something a tool should capture just to build a URL.

**Deprecated modules never appear in this report**, and the tool says so on
stderr with a count. They are replaced rather than updated, so they never carry
`CAN_UPGRADE` — in one test portal 371 installed datasources were deprecated
and 88 of those were in use, invisible to every run of the default report. List
them with `--status DEPRECATED --include-current` (without `--include-current`
you get an empty report, and the tool explains why), and look up the
replacement and end-of-support date in [LogicMonitor's deprecated LogicModules
list](https://www.logicmonitor.com/support/logicmodules/about-logicmodules/deprecated-logicmodules).

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

**Two counts, never merged.** "Collected" is real instances; "applies to" is
the appliesTo match, which can be far larger — one module here collects 2
instances but applies to 1205 devices. The device names come from
`AssociatedDeviceListByDataSourceId`, which caps at 1000 rows per page, so the
count comes from `-C` (LM's true total) while the names are treated as a
sample; `--max-devices N` caps how many are listed (default 25) and the notice
says when the sample is incomplete.

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

Risk is derived, not asserted, and `--risk` overrides it: a **deprecated**
module makes it High (it cannot be upgraded at all — it is replaced by a
different module on LM's timetable, so the change is a migration), a locally
customised module makes it Medium (upgrading overwrites the local edits), and a
wide blast radius is called out with the numbers behind it.
