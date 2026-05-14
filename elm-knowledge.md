# elm + LogicMonitor Knowledge Base

A living document. Add entries as new patterns, gotchas, and findings are confirmed against the live API.

---

## elm CLI — how it works

### Command structure

```shell
elm [GLOBAL FLAGS] COMMAND [COMMAND FLAGS]
```

Global flags (format, config, head, foot, etc.) **must come before the subcommand name**. Putting them after will fail silently or error.

```shell
elm -f csv DeviceList -s0    # correct
elm DeviceList -f csv -s0    # -f csv is a field selector here, not format
```

### Key global flags

- `-V` / `--version` — show version and exit
- `-f FORMAT` / `--format FORMAT` — output format (csv, json, md, tab, html, etc.) — goes BEFORE subcommand
- `-l` / `--list` — list available credential profiles and exit; active profile marked with `*`; works without valid credentials
- `-p NAME` / `--profile NAME` — use a named credentials profile (`~/.config/logicmonitor/credentials/<NAME>.ini`)
- `--config PATH` — full path to any .ini credentials file (any directory)
- `-a` / `--account_name` — LM company/account name directly on CLI (already taken — don't reuse for other flags)

### Size flag

`-s 0` returns all results up to 1000. Without it, default is 50.  
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

Multiple filters separated by comma (AND logic). Escape commas in values with backslash.

### Output formats

`csv`, `tsv`, `html`, `prettyhtml`, `jira`, `json`, `jsonl`, `prettyjson`, `xml`, `prettyxml`, `latex`, `md`, `rst`, `tab`, `gfm`, `pipe`, `raw`, `txt`, `api`

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

### `--format TEXT` on some commands is an LM API parameter, not elm's format flag

Several commands (AuditLogList, ConfigSourceList, DatasourceList, EventSourceList, JobMonitorList, LogSourceList, PropertyRulesList) accept a `--format TEXT` option that is passed directly to the LM API — it is not elm's output format selector. Setting it to `csv` causes a JSONDecodeError because the API returns raw CSV that elm cannot parse. Always use elm's global `-f`/`--format` flag (before the subcommand name) for output formatting.

---

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
elm -f prettyjson PortalInfo
```

Key fields:

- `companyDisplayName` — the portal's display name
- `numberOfDevices` — total monitored device count
- `numberOfOpenAlerts` — active alert count
- `numberOfDatasourceInstances` — total instances being collected
- `numberOfDashboards`, `numberOfWidgets` — dashboard inventory
- `hostGroupsInfo` — breakdown of dynamic vs static device groups and their property counts
- `numberOfApiUsers` — users with API tokens
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

---

## Useful field reference

### DeviceList

- `hostStatus`: `normal`, `dead`, `dead-collector`
- `systemProperties`: array of `{name, value}` — use `.name:system.sysinfo` and `.value~Linux` for OS filtering
- `preferredCollectorId`: collector assigned to this device
- `createdBy`: username who added the device

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
