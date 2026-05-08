# Datasource Examples

Queries relating to datasources, datasource coverage, and which devices have a datasource applied.

**See also:**
- [devices.md](devices.md) for device filtering patterns
- [collectors.md](collectors.md) for collector-side datasource queries

<!--ts-->
   * [Find devices that don't have a datasource applied](#find-devices-that-dont-have-a-datasource-applied)
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

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --skip-header examples/datasources.md
```
