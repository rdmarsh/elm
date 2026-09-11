# elm + LogicMonitor Knowledge Base

A living document. Add entries as new patterns, gotchas, and findings are confirmed against the live API.

---

## elm CLI — how it works

### Command structure

```shell
elm [GLOBAL FLAGS] COMMAND [COMMAND FLAGS]
```

Global flags (format, config, head, foot, etc.) **must come before the subcommand name**.

Three short flags are reused on both sides of the command name with different
meanings, so position changes what the flag does — it is not cosmetic:

| Flag | Before COMMAND (global) | After COMMAND (subcommand) | If misplaced |
|------|-------------------------|----------------------------|--------------|
| `-f` | `--format FORMAT` | `--fields FIELD,...` | Errors both ways (`invalid choice` / `no valid fields selected`) |
| `-s` | `--proxy <HOST PORT>` | `--size N` | Errors, but the message names `--proxy` and complains the *command name* is not an integer — `-s` takes two values |
| `-o` | `--filename FILE` | `--offset N` | **Silent.** `elm -o 2000 DeviceList` writes a file named `2000` containing page 1 and exits 0 |

```shell
elm -f csv DeviceList -s 1000 -o 2000   # correct: format global, size/offset per-command
elm DeviceList -f csv -s0               # error: -f here is --fields
elm -o 2000 DeviceList                  # no error, wrong result: file named "2000", page 1
```

Only `-o` fails silently, which makes it the one worth guarding: a pagination
loop that puts `-o` before the command name re-fetches page 1 every iteration
and leaves a trail of files named after the offsets. Verified against a live
portal 2026-08-27.

`-F` (filter), `-S` (sort), `-c`, `-C` are subcommand-only; `-H` (noheader),
`-I` (index), `-p` (profile) are global-only. Those do not collide.

### Key global flags

- `-V` / `--version` — show version and exit
- `-f FORMAT` / `--format FORMAT` — output format (csv, json, md, tab, html, etc.) — goes BEFORE subcommand
- `-l` / `--list` — list available credential profiles and exit; active profile marked with `*`; works without valid credentials
- `-p NAME` / `--profile NAME` — use a named credentials profile (`~/.config/logicmonitor/credentials/<NAME>.ini`)
- `--config PATH` — full path to any .ini credentials file (any directory)
- `-a` / `--account_name` — LM company/account name directly on CLI (already taken — don't reuse for other flags)

### Size flag

`-s 0` returns all results up to 1000. Without it, default is 50.  
`-s 0` and `-s 1000` are equivalent — both return all available records up to the API
maximum of 1000. Confirmed by live test: `CollectorGroupList -s0 -c` and
`CollectorGroupList -s1000 -c` return identical counts on a portal with 97 groups.  
For endpoints returning more than 1000 records, pagination via `--offset` is required.

### Filter operators

| Operator | Meaning |
|----------|---------|
| `:` | Equals (exact match) |
| `~` | Contains |
| `!:` | Does not equal |
| `!~` | Does not contain |
| `>:` | Greater than or equal |
| `<:` | Less than or equal |
| `>` | Greater than |
| `<` | Less than |

Multiple filters can be combined two ways (both produce identical AND logic):
- Comma-separated in one flag: `-F 'field1:val1,field2:val2'`
- Multiple flags: `-F 'field1:val1' -F 'field2:val2'`

Escape literal commas in filter values with a backslash.

### Output formats

`csv`, `tsv`, `html`, `prettyhtml`, `jira`, `json`, `jsonl`, `prettyjson`, `xml`, `prettyxml`, `latex`, `md`, `rst`, `tab`, `gfm`, `pipe`, `values`, `raw`, `txt`, `api`

`values` format: bare values with no headers or padding. Single field: one value per line — use for shell variable assignment. Multiple fields: TSV no-header row — pipe into `cut` or `awk`. Removes jq from simple scalar extraction:

```shell
gid=$(elm -f values DeviceGroupList -f id -F name:"Linux Devices")
elm DeviceList -s0 -F hostGroupIds~${gid}
```

`md`, `gfm` and `pipe` are all real Markdown pipe tables — `md` is an alias for
`gfm`, and `pipe` is the same with alignment markers. `tab` (and `txt`) are
space-aligned plain tables, not Markdown.

Before the fix for issue #55, `md` was tabulate's `simple` style and was
byte-identical to `tab`, so it rendered as a preformatted block rather than a
table anywhere the Markdown was parsed. If you meet an older elm, use `gfm`.

`api` format: prints the encoded API request URL. The request IS made; `response.url` is the source. The HMAC signature expires in minutes — not suitable for sharing or reuse.

---

## Common gotchas

### Never use 2>&1 when piping to jq

elm writes warnings to stderr. Redirecting stderr into stdout (`2>&1`) injects those lines into the JSON stream and causes jq parse errors:

```shell
elm -f json DeviceList -s2 2>&1 | jq '.'    # BAD — stderr corrupts JSON
elm -f json DeviceList -s2 | jq '.'          # correct
```

### No OR filters server-side

The LM API filter does not support OR across multiple values for the same field. To match any of several values, fetch a broader set and filter client-side with jq:

```shell
# Can't do: -F hostStatus:dead OR hostStatus:dead-collector
elm DeviceList -s0 -f displayName,hostStatus | \
  jq -r '.DeviceList[] | select(.hostStatus == "dead" or .hostStatus == "dead-collector") | .displayName'
```

### Empty array check must be client-side

There is no server-side "is empty" operator for array fields. Use jq:

```shell
elm WebsiteList -s0 | jq '.WebsiteList[] | select(.properties | length == 0) | .name'
```

### NOT filter operators are broken on some endpoints

`!:` (not-equals) and `!~` (not-contains) are silently ignored or produce wrong results on several endpoints including AuditLogList and AlertList. elm constructs and sends the correct URL — the bug is in the LM API. Positive operators (`:`, `~`) work reliably everywhere.

Workaround: fetch with a positive filter (or no filter) and exclude client-side with jq:

```shell
# Instead of: elm AuditLogList -F username!:foo
elm -f json AuditLogList -s0 | jq '.AuditLogList[] | select(.username != "foo")'
```

For AlertList use the positive form where possible — `cleared:false` works, `cleared!:true` does not.

### AuditLogList username "(update)" means a literal credential, not a deleted token

If audit log entries show `username: "(update)"`, that is the actual `access_id`
string configured in whatever integration is making those calls. LM logs the
`access_id` as the username — it does not substitute anything for deleted or
revoked tokens. Confirmed by test: `elm -i "(update)" -k "..." DeviceList`
immediately produced a log entry with `username: "(update)"`.

To investigate: the `ip` field shows the source host; `description` shows
which API path it hit:

```shell
elm AuditLogList -F 'username:(update)' -s0
```

### `--format TEXT` on some commands is an LM API parameter, not elm's format flag

Several commands (AuditLogList, ConfigSourceList, DatasourceList, EventSourceList, JobMonitorList, LogSourceList, PropertyRulesList) accept a `--format TEXT` option that is passed directly to the LM API — it is not elm's output format selector. Setting it to `csv` causes a JSONDecodeError because the API returns raw CSV that elm cannot parse. Always use elm's global `-f`/`--format` flag (before the subcommand name) for output formatting.

---

## Counting instances and datapoints on a device

### Instance count vs datapoint count

These are different things:

- **Instance count** — number of monitored objects (e.g. 33 filesystems, processes, interfaces).
  One call: `elm DeviceInstanceList --id <deviceId> -C`

- **Datapoint count** — total individual metrics being collected across all instances
  (e.g. each filesystem instance collects SpaceUsed, SpaceUsedPercent, Inodes... = ~8 datapoints).
  No single endpoint — requires one `DatasourceById` call per unique datasource.

### Count datapoints on a device

Groups instances by datasource so each datasource definition is fetched only once, then
multiplies datapoints × instance count per datasource and sums. Note: counts all *configured*
datapoints — does not verify that all instances have active data collection.

```shell
elm DeviceInstanceList --id <deviceId> -s0 \
  | jq -r '.DeviceInstanceList | group_by(.dataSourceId)[] | "\(.[0].dataSourceId) \(length)"' \
  | while read ds_id inst_count; do
      dp_count=$(elm DatasourceById --id $ds_id -f dataPoints \
        | jq '.DatasourceById[0].dataPoints | length')
      echo $((dp_count * inst_count))
    done \
  | awk '{sum += $1} END {print sum}'
```

API calls: 1 + unique datasources on the device (typically much less than total instance count).

## LM API — key patterns

### Prefer elm native filters over jq

elm has extensive native filter/field/sort support. Always try native first before piping to jq. Examples of things that work natively:

```shell
elm DeviceList -F hostStatus:dead           # filter by exact value
elm CollectorList -F build\<37000 -S build  # filter by numeric comparison
elm AdminList -F apiTokens.status:2         # filter on nested field
```

### Use name: exact match on DatasourceList

There are 1000+ datasources. Always use `name:` (exact) not `name~` (contains) to avoid fetching everything:

```shell
elm DatasourceList -s0 -f id -F name:NTPv4    # good
elm DatasourceList -s0 -f id -F name~NTP      # bad — returns many
```

### AssociatedDeviceListByDataSourceId — pagination limit

This endpoint caps at 1000 results per page. If a datasource is applied to more than 1000 devices, you won't get them all with `-s0`. Workaround: check each device individually using `DeviceDatasourceList --deviceId` instead — scales better when the device set is smaller than the datasource coverage set.

```shell
# BAD if datasource has >1000 devices:
elm AssociatedDeviceListByDataSourceId --id $ds_id -s0 -f id

# BETTER — check per device:
elm DeviceDatasourceList --deviceId "$devid" -s0 -f id -F dataSourceName:Ping
```

### Find devices without a datasource applied (inversion pattern)

Three-step pattern:

```shell
ds_id=$(elm DatasourceList -s0 -f id -F name:NTPv4 | jq -r '.DatasourceList[].id')

covered=$(elm AssociatedDeviceListByDataSourceId --id $ds_id -s0 -f id | \
  jq '[.AssociatedDeviceListByDataSourceId[].id]')

elm DeviceList -s0 -f id,displayName,hostStatus \
  -F systemProperties.name:system.sysinfo,systemProperties.value~Linux | \
  jq -r --argjson covered "$covered" \
    '.DeviceList[] | select(.id as $id | $covered | contains([$id]) | not) | [.displayName, .hostStatus] | @tsv' | \
  sort | column -t -s$'\t'
```

Only use this when the datasource has fewer than 1000 covered devices. Otherwise use the per-device check.

### Standard datasource coverage check (per-device)

Check whether each device has a required set of datasources. Name-based, so portable across portals:

```shell
standard=("Ping" "HostStatus" "NetSNMPCPUwithCores" "NetSNMP_Memory_Usage")

elm DeviceList -s0 -f id,displayName,hostStatus \
  -F systemProperties.name:system.sysinfo,systemProperties.value~Linux | \
  jq -r '.DeviceList[] | "\(.id)\t\(.displayName)\t\(.hostStatus)"' | \
  while IFS=$'\t' read devid name status; do
    for ds in "${standard[@]}"; do
      result=$(elm DeviceDatasourceList --deviceId "$devid" -s0 -f id -F dataSourceName:"$ds" 2>/dev/null)
      count=$(echo "$result" | jq '.DeviceDatasourceList | length' 2>/dev/null)
      [ "${count:-0}" -eq 0 ] && printf '%s\t%s\t%s\n' "$name" "$status" "$ds"
    done
  done | sort | column -t -s$'\t'
```

### Alert patterns

Find all currently active alerts:

```shell
elm AlertList -s0 -F cleared:false -f id,severity,monitorObjectName,dataPointName,alertValue
```

Filter by severity (lower number = more severe):

```shell
elm AlertList -s0 -F cleared:false,severity:2   # critical only
elm AlertList -s0 -F cleared:false,severity:3   # error only
elm AlertList -s0 -F cleared:false,severity:4   # warning only
```

Count active alerts by severity:

```shell
elm -c AlertList -F cleared:false,severity:2   # count of active critical alerts
```

Alerts for a specific device:

```shell
elm AlertListByDeviceId --id <deviceId> -s0 -F cleared:false -f severity,dataPointName,alertValue
```

### Time-series data from a datasource instance

Three steps: find the device-datasource ID, find the instance ID, then fetch data.

```shell
# Step 1 — device-datasource ID (hdsId)
hds_id=$(elm -f json DeviceDatasourceList --deviceId <deviceId> \
  -F dataSourceName:Ping | jq -r '.DeviceDatasourceList[0].id')

# Step 2 — instance ID
inst_id=$(elm -f json DeviceDatasourceInstanceList \
  --deviceId <deviceId> --hdsId "$hds_id" | \
  jq -r '.DeviceDatasourceInstanceList[0].id')

# Step 3 — fetch 1 hour of data for specific datapoints
elm -f json DeviceDatasourceInstanceData \
  --deviceId <deviceId> --hdsId "$hds_id" --id "$inst_id" \
  --period 1 --datapoints average,PingLossPercent
```

Response structure:

- `dataPoints` — list of datapoint name strings (column headers)
- `values` — list of arrays; each array is one time interval in the same order as `dataPoints`; `"No Data"` for missing values
- `time` — list of epoch **milliseconds** (not seconds), newest first — divide by 1000 for epoch seconds

`--period` is in hours (`1.0` ≈ 60 data points, `24.0` ≈ 500 data points).

Valid `--aggregate` values: `none`, `first`, `last`, `average`, `sum`. Anything else returns an API error.

---

## LM API — field gotchas

### lastCollectedTime is unreliable

`lastCollectedTime` on `DeviceDatasourceInstanceList` records returns 0 for many datasources even when data IS being actively collected and threshold alerts are firing. Confirmed broken for:

- SNMP batchscript datasources (e.g. Acme_hrStorage) — returns 0 even with active threshold alerts
- Groovy script datasources (e.g. NTPv4) — returns 0 even when UDP queries confirmed working via SSH

**Do not use `lastCollectedTime == 0` as a proxy for "not collecting."** Use `alertStatus != "none"` instead.

### alertStatus format

`alertStatus` on instance records uses the format: `[confirmationState]-[severity]-[anomalyState]`

Examples:
- `none` — no alert
- `unconfirmed-warn-none` — warning alert, not yet confirmed
- `warn-none` — confirmed warning
- `error-none` — confirmed error

### apiTokens.status values

- `2` = active token
- `1` = disabled token

This applies to both LMv1 and bearer tokens. The `type` field distinguishes token type, not `status`.

### DatasourceById returns an array

`DatasourceById` returns an array even for a single result. Access with `[0]`:

```shell
elm DatasourceById --id <id> | jq '.DatasourceById[0].collectMethod'
```

### SDTList and other commands use string IDs

Several commands use string IDs rather than integers — filtering numerically will not work:

- `SDTList` — `id` is a string, e.g. `H_161`
- `AlertList` — `id` is a string, e.g. `DS395142385`
- `AuditLogList` — `id` is a string
- `OpsNoteList` — `id` is a string
- `CollectorEvents` — `id` is a string

### RecipientGroupList name field

The name field in `RecipientGroupList` is `groupName`, not `name`. Using `-f name` returns empty values:

```shell
elm RecipientGroupList -s0 -f id,groupName    # correct
elm RecipientGroupList -s0 -f id,name         # wrong — name is empty
```

### CollectorGroupList host/instance counts are always 0

`numOfHosts` and `numOfInstances` in `CollectorGroupList` are always 0. Use `CollectorGroupById` to get accurate counts:

```shell
elm CollectorGroupById --id <id> -f numOfHosts,numOfInstances
```

### Collector hostname is `DOMAIN\HOSTNAME`, not a bare name

`CollectorList`'s `hostname` (and usually `description`) is typically the `DOMAIN\HOSTNAME` form (e.g. `CORP\NEWEDGE03`) or an FQDN — not the bare host label. So matching a collector by an exact bare name fails; match by numeric `id`, or by a substring/partial match. (This is why `tools/lm-collector-reachability-run-all.ps1 -Candidate` resolves id → exact hostname/description → unambiguous substring.)

### userPermission — the calling token's effective rights on each object

Many LM list/get responses include a `userPermission` field: a comma-separated
list of what the **calling API token** may do to *that specific object* — e.g.
`read`, `write`, `write,debug`. Bare `read` = read-only; presence of `write` =
manage. It reflects the token's role, so the same object shows different
`userPermission` values to different tokens.

It appears on ~22 object types, including `Collector`, `Device`, `DeviceGroup`,
`Dashboard`(+Group), `Website`(+Group), `Report`(+Group), `Role`, `Admin`,
`APIToken`, `LogQueryGroup`, and `Widget`. Request it like any other field:

```shell
elm CollectorList -s0 -f id,hostname,userPermission
```

Practical use — **gate on `userPermission` instead of probing sensitive blobs.**
A collector's config-file fields (`wrapperConf`, `collectorConf`, `sbproxyConf`,
`watchdogConf`, `websiteConf`) are only returned to a token whose
`userPermission` includes `write`; a `read`-only token gets the literal string
`"{}"` for each. So before a collector-config backup, check `userPermission` per
collector rather than fetching the blobs and inspecting them for `{}`.

### deviceType — distinguishes real devices from cloud, services, and k8s

`deviceType` on `DeviceList`/`DeviceById` records is an integer that classifies what a "device" actually is. LM models many non-device things as `device` objects; this field tells them apart.

| deviceType | Meaning | Confidence |
|-----------|---------|------------|
| 0 | Standard device (the normal case) | confirmed |
| 1 | Device (rare; treat as a real device) | per LM; not seen on test portal |
| 2 | AWS account / cloud resource | confirmed by naming |
| 4 | Azure account / cloud resource | confirmed by naming |
| 6 | LM Service / Service Insight (incl. APM traces) | confirmed by naming |
| 8 | Kubernetes resource (nodes, pods, services) | confirmed by naming |
| 9 | Push Metrics / custom-metric device | observed (names often end `…pushmetric`) |
| 11 | Synthetic / web check (auth checks, Selenium tests) | observed |
| 18 | Synthetic check (returns full schema regardless of `-f`) | observed |

Other values (e.g. 7 = GCP) exist in LM but were not present on the test portal.

**"Real devices only" = `deviceType` 0 or 1.** To exclude everything else (services, cloud, k8s, synthetics), fetch the *non-device* id set in one call and drop those ids client-side:

```shell
elm -f json DeviceList -F 'deviceType!:0' -F 'deviceType!:1' -s0 -f id
```

The `!:` (not-equals) operator **works correctly on `DeviceList`** — verified: the result count is exactly `total − type0 − type1`. This is unlike AuditLogList/AlertList, where NOT filters are silently broken (see "NOT filter operators are broken on some endpoints"). Excluding the (smaller) non-device set is safer than fetching the device set, which can exceed the 1000-row `-s0` cap on large portals. `tools/elm-datasource-matrix.py` uses exactly this to keep its matrix to real devices.

Note `deviceType` is **not** returned by `AssociatedDeviceListByDataSourceId` even when requested with `-f` — that endpoint only returns `id`/`displayName`/`description`, so classifying its devices requires a separate `DeviceList` lookup.

---

## Scoping to Linux devices

### system.sysinfo~Linux is not reliable alone

The filter `systemProperties.name:system.sysinfo,systemProperties.value~Linux` catches non-Linux devices where the **collector** runs on Linux. The collector's OS bleeds into the monitored device's system properties.

Known false positives observed:
- External HTTP endpoints monitored by a Linux collector (their sysinfo reflects the collector OS)
- Network appliances monitored by a Linux collector (Cisco ASAv, FTDv, firewalls)
- Demo/test environments

**Better approach:** Scope to a device group containing only real Linux servers, in addition to or instead of the sysinfo filter.

### Linux coverage — standard datasource set

These datasources are typically expected on all real Linux servers. The `Acme_` prefixed ones are org-specific custom datasources — replace with your own equivalents:

- `Ping`
- `HostStatus`
- `SNMP_HostUptime_Singleton`
- `Acme_SNMP_Host_Uptime`
- `NetSNMPCPUwithCores`
- `NetSNMP_Memory_Usage`
- `Acme_hrStorage`
- `SNMP_Filesystem_Usage`

---

## Portal overview

`PortalInfo` returns a snapshot of the account. Useful for onboarding or a quick health check:

```shell
elm PortalInfo -f companyDisplayName,numberOfDevices,numberOfOpenAlerts,numberOfApiUsers,numberOfSessionUsers,numOfAWSDevices,numOfAzureDevices
```

Key fields (verified — `numberOfUsers` and `numberOfHosts` do **not** exist):

- `companyDisplayName` — the portal's display name
- `numberOfDevices` — total monitored device count
- `numberOfOpenAlerts` — active alert count
- `numberOfApiUsers` — count of users with API tokens
- `numberOfSessionUsers` — count of interactive (web/SSO) users
- `numOfAWSDevices`, `numOfAzureDevices`, `numOfGcpDevices` — cloud device counts
- `numberOfDatasourceInstances` — total instances being collected
- `numberOfDashboards`, `numberOfWidgets` — dashboard inventory
- `hostGroupsInfo` — breakdown of dynamic vs static device groups and their property counts
- `alertTotalIncludeInAck`, `alertTotalIncludeInSdt` — whether acknowledged/SDT'd alerts count toward totals

The `contacts` array contains names, email addresses, and phone numbers of portal contacts — do not share `PortalInfo` output publicly or commit it to version control.

`MetricsSummary` is an alternative that includes cloud device breakdowns (AWS/Azure/GCP) and Kubernetes counts but omits the contact PII.

---

## Datasource collection methods

### NTPv4

- Collect method: Groovy script
- Sends a raw UDP NTPv4 mode-3 (client) packet to the device on port 123
- Expects response byte[0] == `0x24` (LI=0, VN=4, Mode=4/Server)
- Collects: `peerClockStratum`, `peerPollingInterval`, `peerClockPrecision`, `rootDelayMilliSec`, `rootDispersionMilliSec`
- Restriction: ntpsec's `restrict default noquery` does NOT block mode 3/4 time exchanges — only mode 6/7 control queries

### Acme_hrStorage

- Collect method: Groovy batchscript
- SNMP walk on `hrStorageTable` OID `.1.3.6.1.2.1.25.2.3.1`
- Collects per storage entry: `hrStorageAllocationUnits`, `hrStorageSize`, `hrStorageUsed`, `hrStorageAllocationFailures`
- Computes `hrStorageUsedPercent` from size/used

### LinuxNewProcesses-

- Monitors process existence via SNMP process table
- Instance name is the process path (e.g. `/usr/sbin/ntpd`)
- "No Data" means SNMP process table isn't returning data for that process, not necessarily that the process isn't running

---

## LogicModule versions and updates (V4Metadata)

`V4Metadata` (`GET /setting/logicmodules/metadata`) is the feed behind the
portal's module toolbox, and the only place the API reports **update status**
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

### It returns a bare JSON array, not the usual envelope

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

### The fields that matter

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

### There is no way to see the version you would upgrade TO

`upgradeableRegistryId` names the newer registry entry, but no v3 endpoint
resolves a registry id (`/setting/logicmodules/metadata` is the only
`logicmodules` path in either swagger spec). So "how out of date is this
module" can only be answered as *how old is the version I am running* —
`originPublishedAtMS` ascending. Registry timestamps only begin around
2017-05, so anything published before that bunches at the floor, and a few
modules carry no publish date at all.

### Recipe: official, uncustomised datasources with an upgrade waiting

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

### Instances, devices applied, and devices collecting are three numbers

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

### Deprecated modules are invisible to an "upgrade" query

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

### Portal UI links

No endpoint returns a deep link, but the feed carries both halves of one:
`model` is the toolbox path segment and `id` is the module, so

    https://{portal}.logicmonitor.com/santaba/uiv4/modules/toolbox/{model}/edit/{id}

resolves for every module type (`exchangeDataSources`,
`exchangePropertySources`, `exchangeConfigSources`, `exchangeEventSources`,
`exchangeLogSources`, `exchangeTopologySources`, `exchangeSNMPSysOIDMaps`,
`exchangeAppliesToFunctions`). Confirmed against two module types 2026-09-11.

### Module ids are only unique WITHIN a type

There is no portal-wide module id. In the sandbox portal 329 ids belonged to
more than one type, and id 28 to six of them (a DataSource, an EventSource, a
LogSource, a PropertySource, an SNMP sysOID map and a TopologySource). Always
carry the `type` alongside the `id`.

## Publishing elm output to Confluence with `mark`

[`mark`](https://github.com/kovetskiy/mark) publishes Markdown to Confluence.
Nothing needs to be added to elm for this — `--head` supplies the metadata
block mark expects and `-f md` supplies the table. Verified against mark
16.19.0 on 2026-09-11.

### It reads files, not stdin — but process substitution works

`-f`/`--files` takes file paths (with glob patterns); the only thing mark reads
from stdin is `--password -`. A pipe therefore does not work, but a process
substitution does — mark opened `/dev/fd/63` without complaint:

```shell
mark --title-from-h1 --drop-h1 -f <(
  printf '<!-- Space: OPS -->\n<!-- Parent: Monitoring -->\n\n'
  tools/elm-module-updates.py --tag linux
)
```

Use `--compile-only` to see the Confluence storage format it would upload,
without publishing anything. It is the cheapest way to check a page before it
is real.

### Use `-f md` (or `gfm`), never `tab`

This is where the old `md` format bit hardest (issue #55). Same query, piped
through `mark --compile-only`:

```html
-f md   ->  <table><thead><tr><th>id</th><th>hostname</th>...
-f tab  ->  <p>id  hostname</p><hr /><p>128  collector-a  2  collector-b</p>
```

The plain-text table is not merely unstyled: the dashes under the header become
an `<hr />` and every row collapses into one paragraph, so the data is mangled.

### Titles

`--title-from-h1` takes the page title from a leading `# H1` and `--drop-h1`
keeps that heading out of the body, since Confluence displays the title itself.
`<!-- Space: KEY -->` is still required either way.

Bare elm output has **no H1** — `-f md` emits just a table — so with
`--title-from-h1` mark falls back to needing `<!-- Title: ... -->`. Either give
it one:

```shell
elm --head '<!-- Space: OPS -->
<!-- Title: Collector inventory -->' -f md CollectorList -s0
```

or emit an H1 in the `--head` block and let mark lift it. The report tools in
`tools/` already start with one (`# Upgradable datasources`,
`# Monitoring change - <date>`), so they pair with `--title-from-h1` directly.

## Known false positive alerts

### hrStorage — Cached memory and Shared memory at 100% on Linux

On Linux, `hrStorageTable` reports "Cached memory" (page cache) and "Shared memory" as 100% used. This is normal Linux kernel behaviour — the kernel fills all free RAM with page cache.

The `> 95` threshold on `hrStorageUsedPercent` for these instance types will always fire on Linux. Either:
- Disable alerting on those specific instances, or
- Remove "Cached memory" and "Shared memory" from the threshold scope

---

## Security patterns

### Find devices with a specific credential/property value

```shell
elm DeviceList -s0 -f displayName,customProperties  -F customProperties.value:YOUR_VALUE_HERE
elm DeviceList -s0 -f displayName,systemProperties  -F systemProperties.value:YOUR_VALUE_HERE
elm DeviceList -s0 -f displayName,autoProperties    -F autoProperties.value:YOUR_VALUE_HERE
```

### Audit active API tokens

```shell
elm -f csv AdminList -s0 -f username,firstName,lastName -F apiTokens.status:2
```

### Find failed API requests in audit log

```shell
elm AuditLogList -s0 -F description~"Failed API request" -f username,ip,description,happenedOnLocal
```

AuditLogList max: 1000 records. Fields: `id`, `username`, `ip`, `description`, `happenedOn`, `happenedOnLocal`.

Use the precise filter `description~"Failed API request"` — not just `description~Failed`, which matches datasource names containing the word "Failed".

---

## Environment health checks

Quick one-liners for spotting common operational issues.

### Active SDTs right now

```shell
elm SDTList -s0 -F isEffective:true -f type,deviceDisplayName,startDateTime,endDateTime,comment
```

Watch for entries with `endDateTime` years in the future — these are "park it and forget it" SDTs that silently suppress alerting.

### API tokens never used

```shell
elm ApiTokenList -s0 -F lastUsedOn:0 -f id,adminName,note,createdOn,status
```

`lastUsedOn: 0` means the token was created but has never authenticated. Old never-used tokens with no `note` are good candidates for revocation.

### Active alert count by severity

```shell
elm AlertList -c -s0 -F cleared:false   # total uncleared alerts (accurate when ≤ 1000)
elm AlertList -s0 -F cleared:false -f id,severity | \
  jq '[.AlertList[].severity] | group_by(.) | map({severity:.[0], count:length})'
```

`-C` does not give an exact count for AlertList (LM API limitation) — use `-c -s0` instead.

### Devices with alerting disabled

```shell
elm DeviceList -s0 -F alertDisableStatus:1 -f id,name,alertDisableStatus
```

### Failed API requests in audit log

```shell
elm AuditLogList -s0 -F "description~Failed API request" -f username,ip,description,happenedOn
```

A token appearing repeatedly at a regular interval (e.g. every hour) from the same IP is a scheduled job with a broken or deleted credential. The `username` field is the `access_id` value verbatim — cross-reference with `ApiTokenList` to check if it still exists.

---

## Useful field reference

### DeviceList

- `hostStatus`: `normal`, `dead`, `dead-collector`
- `systemProperties`: array of `{name, value}` — use `.name:system.sysinfo` and `.value~Linux` for OS filtering
- `preferredCollectorId`: collector assigned to this device
- `preferredCollectorGroupId`: the collector group the device is assigned to — use this to list a group's members. `autoBalancedCollectorGroupId` only fills in once LM has *actively placed* the device, so filtering on it can return 0 for a group whose devices are assigned but not yet balanced.
- `createdBy`: username who added the device

To find which devices in a group are themselves collector hosts, match a device `id` against each collector's `collectorDeviceId` (`CollectorList`). Collector and device names need not match, so the id join is the only reliable signal. Running Collector Debug commands on a collector needs a Manage-level token — a read-only token returns "Access denied".

### AdminList

- `apiTokens.status`: 2=active, 1=disabled
- `apiTokens.type`: distinguishes LMv1 from bearer tokens
- `status`: account status (active/suspended)
- `twoFAEnabled`: boolean

### AlertList

- `type`: `dataSourceAlert` (threshold), `websiteAlert`, etc.
- `severity`: numeric — **lower number = more severe**: 2=critical, 3=error, 4=warning (verified live)
- `alertValue`: the actual collected value that triggered the alert
- `threshold`: the threshold expression (e.g. `> 95`)
- `cleared`: boolean — false means still active
- `monitorObjectName`: device display name
- `resourceTemplateName`: datasource name
- `instanceName`: instance within the datasource
- `dataPointName`: specific metric
- `startEpoch`: when the alert fired (Unix timestamp)
