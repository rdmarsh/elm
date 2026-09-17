# Datasource Examples

Queries relating to datasources, datasource coverage, and which devices have a datasource applied.

**See also:**
- [devices.md](devices.md) for device filtering patterns
- [collectors.md](collectors.md) for collector-side datasource queries

<!--ts-->
   * [Find devices that don't have a datasource applied](#find-devices-that-dont-have-a-datasource-applied)
   * [Count instances and datapoints on a device](#count-instances-and-datapoints-on-a-device)
      * [Instance count](#instance-count)
      * [Datapoint count](#datapoint-count)
   * [When a datasource applies to more than 1000 devices](#when-a-datasource-applies-to-more-than-1000-devices)
   * [Check a standard set of datasources on each device](#check-a-standard-set-of-datasources-on-each-device)
   * [Get time-series data from a datasource instance](#get-time-series-data-from-a-datasource-instance)
   * [How some datasources collect](#how-some-datasources-collect)
   * [meta](#meta)
<!--te-->

## Find devices that don't have a datasource applied

Use `AssociatedDeviceListByDataSourceId` to get devices that DO have the
datasource, then compare client-side against your target device set to find
those that don't.

Use an exact name filter (`name:`) on `DatasourceList` to avoid retrieving
all datasources — there are typically more than 1000.

```shell
# Step 1: get the datasource ID
ds_id=$(elm DatasourceList -s0 -f id -F name:NTPv4 | jq -r '.DatasourceList[].id')

# Step 2: get IDs of devices that have it
ntp_ids=$(elm AssociatedDeviceListByDataSourceId --id $ds_id -f id | \
  jq '[.AssociatedDeviceListByDataSourceId[].id]')

# Step 3: find Linux devices that don't have it
elm DeviceList -s0 -f id,displayName \
  -F systemProperties.name:system.sysinfo,systemProperties.value~Linux | \
  jq -r --argjson ntp_ids "$ntp_ids" \
    '.DeviceList[] | select(.id as $id | $ntp_ids | contains([$id]) | not) | .displayName' | sort
```

The device filter in step 3 can be swapped for any group or property filter —
`system.sysinfo~Linux` is the reliable way to scope to Linux devices rather
than relying on group membership, which may include non-Linux devices.

To also show host status and collector — useful for triaging whether missing
coverage is because the device is dead or just never had the datasource applied:

```shell
# Step 1: get the datasource ID
ds_id=$(elm DatasourceList -s0 -f id -F name:NTPv4 | jq -r '.DatasourceList[].id')

# Step 2: get IDs of devices that have it
ntp_ids=$(elm AssociatedDeviceListByDataSourceId --id $ds_id -f id | \
  jq '[.AssociatedDeviceListByDataSourceId[].id]')

# Step 3: find Linux devices that don't have it, with status and collector
elm DeviceList -s0 -f id,displayName,hostStatus,collectorDescription \
  -F systemProperties.name:system.sysinfo,systemProperties.value~Linux | \
  jq -r --argjson ntp_ids "$ntp_ids" \
    '.DeviceList[] | select(.id as $id | $ntp_ids | contains([$id]) | not) | [.displayName, .hostStatus, .collectorDescription] | @tsv' | \
  sort | column -t -s$'\t'
```

Devices with `hostStatus: normal` are the real gaps — `dead` or `dead-collector`
devices won't collect NTP data regardless of whether the datasource is applied.

## Count instances and datapoints on a device

These are different things:

- **Instance** — a monitored object, e.g. the filesystem `/var` on a device
- **Datapoint** — an individual metric within an instance, e.g. `SpaceUsed`, `SpaceUsedPercent`

### Instance count

One API call using `-C`:

```shell
elm DeviceInstanceList --id <deviceId> -C
```

### Datapoint count

No single endpoint returns total datapoints. This pipeline groups instances by
datasource, fetches each unique datasource definition once, and multiplies
datapoints × instance count:

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

API calls: 1 (`DeviceInstanceList`) + 1 per unique datasource on the device —
typically much fewer than the total instance count.

Note: this counts all *configured* datapoints. It does not verify that every
instance has active data flowing.

## When a datasource applies to more than 1000 devices

This endpoint caps at 1000 results per page. If a datasource is applied to more than 1000 devices, you won't get them all with `-s0`. Workaround: check each device individually using `DeviceDatasourceList --deviceId` instead — scales better when the device set is smaller than the datasource coverage set.

```shell
# BAD if datasource has >1000 devices:
elm AssociatedDeviceListByDataSourceId --id $ds_id -s0 -f id

# BETTER — check per device:
elm DeviceDatasourceList --deviceId "$devid" -s0 -f id -F dataSourceName:Ping
```

## Check a standard set of datasources on each device

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

A typical Linux set (the `Acme_` ones are org-specific custom datasources — replace with your own):

- `Ping`
- `HostStatus`
- `SNMP_HostUptime_Singleton`
- `Acme_SNMP_Host_Uptime`
- `NetSNMPCPUwithCores`
- `NetSNMP_Memory_Usage`
- `Acme_hrStorage`
- `SNMP_Filesystem_Usage`

## Get time-series data from a datasource instance

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

## How some datasources collect

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

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --hide-footer --skip-header examples/datasources.md
```
