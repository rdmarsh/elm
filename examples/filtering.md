# Filtering Examples

How to use the `-F`/`--filter` flag for server-side filtering. The syntax is
`FIELD` + `OPERATOR` + `VALUE`. elm quotes the VALUE for you — do not add your
own quotes around it. These apply across all `*List` commands.

**See also:**
- [general.md](general.md) for basic usage, output formats, and piping
- [devices.md](devices.md) for device property and group-membership filters

<!--ts-->
   * [Operators](#operators)
   * [The ~ operator (contains)](#the--operator-contains)
   * [Equals vs contains: : vs ~](#equals-vs-contains--vs-)
   * [Combining filters (AND)](#combining-filters-and)
   * [No OR server-side](#no-or-server-side)
   * [Filtering comma-separated string fields](#filtering-comma-separated-string-fields)
   * [Gotchas](#gotchas)
   * [No "is empty" operator](#no-is-empty-operator)
   * [Filters the API silently ignores](#filters-the-api-silently-ignores)
   * [Times and dates](#times-and-dates)
   * [meta](#meta)
<!--te-->

## Operators

| Operator | Meaning | Example |
|----------|---------|---------|
| `:`  | equals (exact) | `-F 'displayName:db01.acme.com'` |
| `~`  | contains (substring, case-insensitive) | `-F 'displayName~db01'` |
| `!:` | not equals | `-F 'hostStatus!:dead'` |
| `!~` | does not contain | `-F 'displayName!~test'` |
| `>` `<` | greater / less than | `-F 'id>1000'` |
| `>:` `<:` | greater / less than or equal | `-F 'id>:1000'` |

## The ~ operator (contains)

`~` is a case-insensitive substring match — "does this field contain this text
anywhere". Case does not matter:

```shell
elm DeviceList -F 'displayName~db'    # matches db01, web-DB, prodDB, ...
elm DeviceList -F 'displayName~DB'    # identical result
```

Spaces in the VALUE are fine — just quote the whole argument so the shell keeps
it as one token:

```shell
elm IntegrationList -F 'name~ServiceNow DEV'
```

## Equals vs contains: : vs ~

Use `:` when you know the exact value (faster, unambiguous); use `~` when you
only know a fragment:

```shell
elm DeviceList -F 'displayName:db01.acme.com'   # exactly db01.acme.com
elm DeviceList -F 'displayName~db01'            # anything containing db01
```

## Combining filters (AND)

Repeated `-F` flags are ANDed together. This is the clearest form:

```shell
elm DeviceList -F 'hostStatus:normal' -F 'displayName~prod'
```

Comma-separating clauses inside a single `-F` is equivalent:

```shell
elm DeviceList -F 'hostStatus:normal,displayName~prod'
```

## No OR server-side

The LM API filter cannot OR multiple values for the same field. Do that
client-side — for example with elm's native output or `jq`:

```shell
# devices that are dead OR in maintenance
elm -f json DeviceList -F 'hostStatus!:normal' | \
  jq '[.[] | select(.hostStatus=="dead" or .hostStatus=="sdt")]'
```

## Filtering comma-separated string fields

Some fields are comma-separated strings rather than arrays (e.g. `hostGroupIds`).
Use `~` to match one value within them, not `:`:

```shell
elm DeviceList -F 'hostGroupIds~42'    # device is a member of group 42
```

## Gotchas

- **Do not double-quote the VALUE** in the filter itself — elm adds the quotes.
  `-F 'name~prod'` is correct; `-F 'name~"prod"'` sends doubled quotes.
- **`!` is special in bash** — single-quote the whole argument (which you should
  do anyway): `-F 'displayName!~test'`.
- **A literal comma in a VALUE must be escaped as `\,`**, because comma separates
  filter clauses:

  ```shell
  elm IntegrationList -F 'name~Smith\, Inc'   # searches for the literal "Smith, Inc"
  ```

- **Backslashes and quotes inside a VALUE are escaped automatically** (v1.8.9+) —
  just type the literal value you want.

## No "is empty" operator

There is no server-side "is empty" operator for array fields. Filter with jq:

```shell
elm WebsiteList -s0 | jq '.WebsiteList[] | select(.properties | length == 0) | .name'
```

## Filters the API silently ignores

Some filters are accepted and then ignored: the API returns every record, with
no error, so the result looks like a valid answer. Known cases:

- `!:` and `!~` on AlertList and AuditLogList (issue #48). They do work on
  DeviceList.
- Most ID fields on AlertList: `monitorObjectId`, `instanceId`,
  `resourceTemplateId` and others (issue #56). Use `monitorObjectName` or
  `AlertListByDeviceId --id N` for one device.
- Every filter on V4Metadata.
- `alertDisableStatus` on DeviceList (positive matches return nothing).

`elm COMMAND --info` lists the known cases for a command. To test any filter,
compare counts with and without it; if the count does not move, it is ignored:

```shell
elm AlertList -c -s0 -F severity:4
elm AlertList -c -s0 -F severity:4,monitorObjectId:123    # same count: ignored
```

Where a not-equals filter is ignored, fetch with a positive filter (or none) and
exclude client-side:

```shell
# Instead of: elm AuditLogList -F username!:foo
elm -f json AuditLogList -s0 | jq '.AuditLogList[] | select(.username != "foo")'
```

## Times and dates

Don't work out epochs: give a time field (`startEpoch`, `createdOn`, ...) one
of these and elm sends the epoch. Every row below is what elm sends when "now"
is Wed 28 Oct 2026 14:30, local time.

**A moment: `now`, plus or minus an amount.** Units are `s` `m` `h` `d` `w`
(fixed lengths) and `M` (calendar months). `m` is minutes, `M` months, as in
Prometheus and Grafana. There are no years: use `12M`.

| You write | elm sends |
|---|---|
| `startEpoch>:now-1h` | `>:` Wed 28 Oct 13:30 |
| `startEpoch>:now-30m` | `>:` Wed 28 Oct 14:00 |
| `startEpoch>:now-7d` | `>:` Wed 21 Oct 14:30 |
| `startEpoch>:now-2w` | `>:` Wed 14 Oct 14:30 |
| `startEpoch>:now-1M` | `>:` Mon 28 Sep 14:30 |
| `startDateTime<:now+7d` | `<:` Wed 4 Nov 14:30 (the future works too) |

**A period: round down with `/d`, `/w` or `/M`.** This turns a moment into the
day, week (Monday to Sunday) or month it falls in.

| You write | elm sends | Which is |
|---|---|---|
| `startEpoch:now/d` | `>:` Wed 28 Oct 00:00 and `<` Thu 29 Oct 00:00 | today |
| `startEpoch:now-1d/d` | `>:` Tue 27 Oct 00:00 and `<` Wed 28 Oct 00:00 | yesterday |
| `startEpoch:now/w` | `>:` Mon 26 Oct 00:00 and `<` Mon 2 Nov 00:00 | this week |
| `startEpoch:now-1w/w` | `>:` Mon 19 Oct 00:00 and `<` Mon 26 Oct 00:00 | last week |
| `startEpoch:now/M` | `>:` Thu 1 Oct 00:00 and `<` Sun 1 Nov 00:00 | this month |
| `startEpoch:now-1M/M` | `>:` Tue 1 Sep 00:00 and `<` Thu 1 Oct 00:00 | last month |

**A date is a period too:** `YYYY`, `YYYY-MM`, `YYYY-MM-DD`, or with a time
`YYYY-MM-DDTHH:MM`. No month names. A bare year counts only on a time field,
so `id:2026` is still the number.

| You write | elm sends | Which is |
|---|---|---|
| `startEpoch:2026` | `>:` Thu 1 Jan 2026 00:00 and `<` Fri 1 Jan 2027 00:00 | 2026 |
| `startEpoch:2026-07` | `>:` Wed 1 Jul 00:00 and `<` Sat 1 Aug 00:00 | July |
| `startEpoch:2026-07-14` | `>:` Tue 14 Jul 00:00 and `<` Wed 15 Jul 00:00 | 14 July |
| `startEpoch:2026-07-14T09:30` | `>:` 09:30 and `<` 09:31 | that minute |

**Round down or round up? The operator decides.** A period has a start and an
end (the start of the next one). `:` means the whole period. With a comparison,
elm picks the end that keeps the meaning of the words. For `now-1M/M`,
September:

```
                         August    |        September         |  October
                                   |##########################|
                              1 Sep 00:00                1 Oct 00:00
                                 start                        end

  startEpoch:now-1M/M              |<------ all of it ------->|
  startEpoch>:now-1M/M  (from)     |------------------------------------->
  startEpoch<now-1M/M   (before) <-|
  startEpoch>now-1M/M   (after)                               |---------->
  startEpoch<:now-1M/M  (up to)  <----------------------------|
```

| You write | Means | elm sends |
|---|---|---|
| `startEpoch:now-1M/M` | in September | `>:` 1 Sep and `<` 1 Oct |
| `startEpoch>:now-1M/M` | from September on | `>:` 1 Sep (rounds down) |
| `startEpoch<now-1M/M` | before September | `<` 1 Sep (rounds down) |
| `startEpoch>now-1M/M` | after September | `>:` 1 Oct (rounds up) |
| `startEpoch<:now-1M/M` | up to the end of September | `<` 1 Oct (rounds up) |
| `startEpoch<:2026-03-31` | up to the end of 31 March | `<` 1 Apr (rounds up) |

This is Elasticsearch's date maths, which Grafana uses too, so Grafana's
"Previous month", `>:now-1M/M,<:now-1M/M`, also sends 1 Sep to 1 Oct.

The end is always "before the next period starts" (`<` 1 Oct), never "up to
30 Sep 23:59:59", so nothing falls in a gap, even in milliseconds.

**Times are local**, daylight saving included: `now-1M/M` starts at local
midnight. Set `TZ` for another zone (`TZ=UTC elm ...`). `s` to `w` are fixed
lengths, so `now-1d` is exactly 24 hours ago even across a clock change; `M`
keeps the time of day.

**Milliseconds:** a few fields hold milliseconds (SDTList `startDateTime`,
AlertList `lastUpdatedOnEpoch`). elm checks one value of the field first and
sends milliseconds where they are needed. That is one extra request per time
field, and none for filters without a time.

**Refused before sending:** `now-1y` (no years), `2026-02-30` (no such date),
and `startEpoch:now` (that would match one second; use `>:` or a period).

**In the results:** `-t` (`--localtime`), before the command, shows epoch
fields as local times, keeping their names:

```shell
$ elm -t -f csv AlertList -F 'startEpoch:now/d' -f id,startEpoch -s2
id,startEpoch
DS123,2026-10-28 09:12:40 AEDT
DS124,2026-10-28 11:03:05 AEDT
```

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --hide-footer --skip-header examples/filtering.md
```
