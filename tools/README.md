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
- [Datasource usage matrix](#datasource-usage-matrix) — `tools/elm-datasource-matrix.py`
- [Host SDTs](#host-sdts) — `tools/elm-host-sdts.sh`

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
