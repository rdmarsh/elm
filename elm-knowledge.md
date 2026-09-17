# elm + LogicMonitor Knowledge Base

Rules that apply across commands. Kept short on purpose: AI assistants (and
`tools/elm-ask`) read all of it before every question.

- One command's parameters, tested gotchas, example commands and fields:
  `elm COMMAND --info` (built from `elm-notes.yaml` and the swagger).
- Longer recipes and background: [`examples/`](examples/).

Add a finding here only if it holds for more than one command. Otherwise add it
to the command's entry in `elm-notes.yaml`, where `--info` shows it. The budget
is 8,000 characters (`make testdocs`): replace or delete, don't just append.

---

## Running elm

`elm [GLOBAL FLAGS] COMMAND [COMMAND FLAGS]`: which side a flag is on matters.

| Side | Flags |
|------|-------|
| Global only (before COMMAND) | `-p` `-l` `-H` `-I` `-v` `-i` `-k` `-a` `-V` `--config` `--head` `--foot` `--cacert` `--halt-on-api-error` `--ai` |
| Command only (after COMMAND) | `-F` filter, `-S` sort, `-c` count, `-C` total, `--info`, and the command's own parameters (`--id`, `--deviceId`, ...) |
| Both, with different meanings | `-f` format / fields, `-o` filename / offset, `-s` proxy / size |

```shell
elm -f jsonl DeviceList -s 1000 -o 2000 -f id,displayName    # correct
```

A misplaced flag fails with a `Hint:` naming the fix: move the flag, don't drop
it. The one exception runs: `elm -o 2000 DeviceList` writes page 1 to a file
named `2000`, with a warning.

**Exit code 3 means the profile doesn't allow that command** (`allow_commands`;
`elm --list` shows it). Nothing was sent. Don't switch profiles to get round
it: tell the person and show the command.

- **Before using a command, run `elm COMMAND --info`.** No credentials, no API call.
- **Paging:** 50 rows by default; `-s0` gives up to 1000, the API's maximum per
  page. Beyond that page with `-o 1000`, `-o 2000`, ... and check pages differ.
- **Counting:** `-C` is LM's total and ignores `-s`. `-c` counts the rows
  fetched, so use `-c -s0`, exact only below 1000. AlertList and AuditLogList
  return no real total: `-C` prints `>N` with a warning, so use `-c -s0`.
- **Formats for scripts and AI:** `-f jsonl` (one record per line, joins and
  greps cleanly) and `-f values` (bare values). `-f api`, `curl` and `wget`
  send the request and print the signed auth header: don't share the output.
- **stderr carries warnings.** Never `2>&1` into jq.
- **`--format TEXT` after the command** (AuditLogList, ConfigSourceList,
  DatasourceList, EventSourceList, JobMonitorList, LogSourceList,
  PropertyRulesList) is an LM API parameter, not elm's format; setting it breaks
  parsing.

## Filters

Operators: `:` equals, `~` contains, `!:` not equals, `!~` not contains, `>:`
`<:` `>` `<`. Clauses are ANDed, as `-F 'a:1,b:2'` or repeated `-F`. Escape a
literal comma with `\,`.

- **The API can silently ignore a filter** and return everything, with no
  error. Known: most ID fields on AlertList (`monitorObjectId`, `instanceId`,
  `resourceTemplateId`, ... issue #56), `!:` and `!~` on AlertList and
  AuditLogList, every filter on V4Metadata, and `alertDisableStatus` on
  DeviceList. `--info` lists known cases. To test a filter: compare `-c` with
  and without it; a count that doesn't move means it is ignored.
- **No OR, no "is empty".** Fetch a broader set and filter with jq. For OR
  across fields, run one query per condition and union by id.
- **Prefer positive operators** and exclude client-side where `!:` is
  unreliable. (`!:` does work on DeviceList.)
- **String IDs** on SDTList (`H_161`), AlertList (`DS395142385`), AuditLogList,
  OpsNoteList and CollectorEvents: don't compare them numerically.
- Native filters handle more than they look: numeric comparison
  (`-F 'build<37000' -S build`) and nested fields (`-F apiTokens.status:2`).

## Reading results

- **"None found" is only true for the range you fetched.** If a result hit the
  1000-row cap, or the list is newest first (1000 AuditLogList entries can
  cover a few days), page or filter on the time field before answering "never"
  or "none", and say what range was covered.
- **Response shapes:** most endpoints return `{total, items}`; `...ById`,
  MetricsSummary and MetricsUsage return one object; V4Metadata and
  ContractInfoByCompany return a bare array. elm normalises all three, but raw
  responses differ.
- **`userPermission`**, on about 22 object types, is the calling token's rights
  on that object (`read`, `write`, `write,debug`). Check it rather than probing
  for data a read-only token cannot see.
- **Secrets:** CollectorList and CollectorById include bearer tokens and config
  blobs: empty for a read-only token, real with write permission. Always pass
  `-f`, and never paste raw output into tickets, chats or AI tools. Device
  credential properties (`*.pass`, `snmp.community`) come back masked.

## What the data means

- **Alert severity:** 2 = warning, 3 = error, 4 = critical. Without a `cleared`
  filter AlertList returns only active alerts.
- **Alerting disabled** can come from the device or from a group it is in, and
  the group case is usually most of them. DeviceList `alertDisableStatus`
  (`<group>-<device>-<instance>`) shows both; SDTs also silence alerts. Recipe:
  [examples/health-checks.md](examples/health-checks.md).
- **Not every "device" is a device.** DeviceList includes cloud resources,
  services, Kubernetes objects and synthetic checks; real devices are
  `deviceType` 0 (`elm DeviceList --info` has the table and the open question
  about type 1).
- **Operating system:** `system.sysinfo` can report the collector's OS, not the
  device's (seen on Linux and Windows collectors: HTTP endpoints, network
  appliances, out-of-band hardware), and OS-named groups can hold other
  devices. Combine the two and sanity-check against device and datasource names.
- **How data is collected** isn't in alert or datasource display names. For
  "SNMP alerts", find datasources by `collectMethod` and match alerts on
  `resourceTemplateId` where `resourceTemplateType` is `DS`. Recipe:
  [examples/alerts.md](examples/alerts.md).
- **Applied, collecting and instances are different numbers.** A datasource can
  apply to 1205 devices and collect on 2; an instance collects several
  datapoints; `lastCollectedTime` 0 does not mean "not collecting". See
  `--info` on AssociatedDeviceListByDataSourceId and
  DeviceDatasourceInstanceList, and
  [examples/datasources.md](examples/datasources.md).
