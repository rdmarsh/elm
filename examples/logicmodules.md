# LogicModule Examples

Module versions, upgrade status and usage, from `V4Metadata` — the feed behind
My Module Toolbox and the LM Exchange.

**See also:**
- [datasources.md](datasources.md) for datasource coverage on devices
- `tools/elm-module-updates.py` and `tools/elm-change-advice.py`

<!--ts-->
   * [About V4Metadata](#about-v4metadata)
   * [It returns a bare JSON array, not the usual envelope](#it-returns-a-bare-json-array-not-the-usual-envelope)
   * [The fields that matter](#the-fields-that-matter)
   * [There is no way to see the version you would upgrade TO](#there-is-no-way-to-see-the-version-you-would-upgrade-to)
   * [Recipe: official, uncustomised datasources with an upgrade waiting](#recipe-official-uncustomised-datasources-with-an-upgrade-waiting)
   * [Instances, devices applied, and devices collecting are three numbers](#instances-devices-applied-and-devices-collecting-are-three-numbers)
   * [Deprecated modules are invisible to an "upgrade" query](#deprecated-modules-are-invisible-to-an-upgrade-query)
   * [Portal UI links](#portal-ui-links)
   * [Module ids are only unique WITHIN a type](#module-ids-are-only-unique-within-a-type)
   * [meta](#meta)
<!--te-->

## About V4Metadata

`V4Metadata` (`GET /setting/logicmodules/metadata`) is the feed behind the
portal's My Module Toolbox and Exchange, and the only place the API reports **update status**
for LogicModules. One unpaginated call returns every installed module *and*
everything installable from the LM Exchange — datasources, propertysources,
configsources, eventsources, logsources, topologysources, SNMP sysOID maps and
appliesTo functions — around 5000 records / ~13 MB on a mature portal. It takes
no `-s`/`-o`/`-F`, so filtering is client-side.

`-S` (sort) *is* offered on the command but is a **no-op** here: elm sends it as
a `sort` query param and this endpoint ignores it (verified — `-S
+originPublishedAtMS` returns the records in API order). `-f` (fields) does
work, because elm also projects fields client-side.

**Do not add `size`/`offset`/`filter` to this endpoint in
`swagger.undocumented.json`.** That override trick works for several list
endpoints whose params the official spec omits (`/setting/action/chains`,
`/setting/logsources`, `/setting/oids`, …) — but it was tested here on
2026-09-11 and this endpoint **ignores all three**. With the params declared and
demonstrably sent (confirmed in `-vv` debug output), every one of `-s 5`,
`-s 100`, `-o 5000`, `-F type:DATASOURCE` and `-F isInUse:true` returned the
full 5147 records. Declaring them would therefore make elm lie: `-s 5` would
look like it worked, and `-F` would silently return unfiltered data. The test
worth reusing on any candidate endpoint is simply to compare `-c` across
variants — if the count never moves, the API is ignoring the param. So with elm alone you can
trim columns but not select or order rows — the selection needs `jq` or
`tools/elm-module-updates.py`. One more `-f` wrinkle: pandas renders
`originPublishedAtMS` as a float (`1596141359861.0`) because the column has
gaps, and output column order does not follow the order you list them in.

## It returns a bare JSON array, not the usual envelope

The body is `[{...}, {...}]` with no `{total, items, ...}`. `ContractInfoByCompany`
(`/usage/contractInfo`) is the only other endpoint known to do this. Do not confuse
it with `MetricsSummary` / `MetricsUsage`, which return a bare JSON **object** —
a single record, which elm has always handled. Three shapes, in other words:

| Response body | Endpoints | elm's `items` |
|---------------|-----------|---------------|
| `{total, items: [...]}` | almost everything | the list, as sent |
| `{...}` (bare object) | `MetricsSummary`, `MetricsUsage`, all `...ById` | `[the object]` — 1 record |
| `[...]` (bare array) | `V4Metadata`, `ContractInfoByCompany` | the list, as sent |

elm handles all three (see CHANGELOG `[Unreleased]` — before that fix the bare
array was wrapped as a single record, so `-c`/`-C` reported `1` and the table
formats rendered one row headed `0,1,2,...`). Anything parsing the **raw**
response must not expect `.items`.

## The fields that matter

| Field | Meaning |
|-------|---------|
| `installationStatuses` | list containing `IS_INSTALLED` (present in this portal), `CAN_UPGRADE` (a newer version is published), `IS_CUSTOMIZED` (locally edited — upgrading overwrites the edits), `CAN_INSTALL` (Exchange-only, not installed), `CAN_SKIP` |
| `originStatus` | `CORE` = LM official. Also `DEPRECATED`, `COMMUNITY`, `SECURITY_REVIEW` |
| `isInUse` | LM's own in-use flag (absent on Exchange-only records) |
| `originVersion` | the version **installed**, e.g. `2.0.0` |
| `originPublishedAtMS` | epoch ms when *that* version was published |
| `upgradeableRegistryId` | registry entry of the newer version — differs from `originRegistryId` whenever `CAN_UPGRADE` is set |
| `associatedCounts` | usage counts, **not uniform across types**: `associatedHostsCount` is hard-wired to 0 for `DATASOURCE`/`CONFIGSOURCE` (use `associatedInstancesCount` there) but real for every other type; `APPLIESTO_FUNCTION` has `useInModulesCount`/`useInHostGroupsCount` instead |
| `type` / `source` | module type; `source: LOCAL` marks an installed record |

## There is no way to see the version you would upgrade TO

`upgradeableRegistryId` names the newer registry entry, but no v3 endpoint
resolves a registry id (`/setting/logicmodules/metadata` is the only
`logicmodules` path in either swagger spec). So "how out of date is this
module" can only be answered as *how old is the version I am running* —
`originPublishedAtMS` ascending. Registry timestamps only begin around
2017-05, so anything published before that bunches at the floor, and a few
modules carry no publish date at all.

## Recipe: official, uncustomised datasources with an upgrade waiting

```shell
elm -f json V4Metadata | jq -r '
  .V4Metadata[]
  | select(.type == "DATASOURCE")
  | select(.originStatus == "CORE")
  | select(.installationStatuses | index("CAN_UPGRADE"))
  | select(.installationStatuses | index("IS_CUSTOMIZED") | not)
  | [.originPublishedAtMS, .isInUse, .originVersion, .id, .name] | @tsv' |
  sort -n
```

`tools/elm-module-updates.py` does this and renders it as a report split by
`isInUse`, sorted most out of date first.

## Instances, devices applied, and devices collecting are three numbers

For `DATASOURCE`/`CONFIGSOURCE` the metadata feed's `associatedInstancesCount`
counts **instances**, and its `associatedHostsCount` is hard-wired to 0 — there
is no device count in the feed at all. Devices come from
`AssociatedDeviceListByDataSourceId`, whose rows carry `hasActiveInstance`, so
one call yields both remaining figures:

| number | where from | example (`HTTP_Page-`) |
|--------|-----------|------------------------|
| instances collected | feed `associatedInstancesCount` | 2 |
| devices applied to | `-C` on the associated-device call | 1205 |
| devices collecting | `hasActiveInstance` true in those rows | 2 |

They diverge wildly — a module can match 1205 devices by `appliesTo` and
collect on 2 — so never present one as the other. Note the `instance` array in
each row is NOT a count of active instances (every row carries one entry
regardless); `hasActiveInstance` is the flag to trust. The row list caps at
1000, so the collecting count is a floor once `-C` exceeds that.

## Deprecated modules are invisible to an "upgrade" query

`originStatus: DEPRECATED` modules are **replaced**, not updated, so they never
carry `CAN_UPGRADE` — a query for upgradable modules can never return one. In
the sandbox portal that hid 371 installed deprecated datasources, 88 of them in
use, including `snmp64_If-` with 1294 instances. Query them on their own terms:

```shell
elm -f json V4Metadata | jq -r '
  .V4Metadata[] | select(.originStatus == "DEPRECATED")
  | select(.installationStatuses | index("IS_INSTALLED"))
  | select(.isInUse) | [.type, .name] | @tsv'
```

The replacement module and end-of-support date are not in the API. They are
published at
<https://www.logicmonitor.com/support/logicmodules/about-logicmodules/deprecated-logicmodules>
as a table of deprecated module -> replacement -> reason -> end-of-support date.

## Portal UI links

No endpoint returns a deep link, but the feed carries both halves of one:
`model` is the toolbox path segment and `id` is the module, so

    https://{portal}.logicmonitor.com/santaba/uiv4/modules/toolbox/{model}/edit/{id}

resolves for every module type (`exchangeDataSources`,
`exchangePropertySources`, `exchangeConfigSources`, `exchangeEventSources`,
`exchangeLogSources`, `exchangeTopologySources`, `exchangeSNMPSysOIDMaps`,
`exchangeAppliesToFunctions`). Confirmed against two module types 2026-09-11.

## Module ids are only unique WITHIN a type

There is no portal-wide module id. In the sandbox portal 329 ids belonged to
more than one type, and id 28 to six of them (a DataSource, an EventSource, a
LogSource, a PropertySource, an SNMP sysOID map and a TopologySource). Always
carry the `type` alongside the `id`.

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --hide-footer --skip-header examples/logicmodules.md
```
