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
   * [meta](#meta)

<!-- Created by https://github.com/ekalinin/github-markdown-toc -->

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

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --skip-header examples/datasources.md
```
