# Alert and SDT Examples

Queries relating to active alerts, scheduled downtime (SDT), and alert history.

**See also:**
- [devices.md](devices.md) for device-specific queries
- [collectors.md](collectors.md) for collector-related SDTs

<!--ts-->
   * [Find long SDTs](#find-long-sdts)
   * [Find devices in SDT right now](#find-devices-in-sdt-right-now)
   * [Find the oldest active critical alert](#find-the-oldest-active-critical-alert)
   * [Find unacknowledged active alerts](#find-unacknowledged-active-alerts)
   * [Find time-related alerts (NTP, clock skew)](#find-time-related-alerts-ntp-clock-skew)
   * [Find the oldest WMI alerts for Windows devices](#find-the-oldest-wmi-alerts-for-windows-devices)
   * [Count and list active alerts by severity](#count-and-list-active-alerts-by-severity)
   * [Alerts for one device](#alerts-for-one-device)
   * [Alerts by collection method (SNMP, WMI, script)](#alerts-by-collection-method-snmp-wmi-script)
   * [Linux hrStorage: Cached and Shared memory always at 100%](#linux-hrstorage-cached-and-shared-memory-always-at-100)
   * [meta](#meta)
<!--te-->

## Find long SDTs

This will find SDTs that don't end for at least one year from the current time:

```shell
elm SDTList -F endDateTime\>$(( ( $(date +'%s') + 31536000 ) * 1000 )) -f id,deviceGroupFullPath,deviceDisplayName,endDateTimeOnLocal,duration,admin,comment -S endDateTime -s0
```

## Find devices in SDT right now

Which resources are *currently* in scheduled downtime — actively suppressing
alerts this moment (`isEffective:true`). The `type` column shows whether the SDT
is on the device, a group, or an instance:

```shell
elm SDTList -s0 -F isEffective:true \
  -f type,deviceDisplayName,deviceGroupFullPath,startDateTimeOnLocal,endDateTimeOnLocal,comment
```

## Find the oldest active critical alert

Alert severity: 2=Warning, 3=Error, 4=Critical.

```shell
elm AlertList -s1 -S startEpoch -F severity:4,cleared:false \
  -f id,severity,startEpoch,resourceTemplateName,instanceName,resourceId,resourceName
```

## Find unacknowledged active alerts

Active alerts (`cleared:false`) that nobody has acknowledged yet
(`acked:false`) — the ones still demanding attention, oldest first:

```shell
elm AlertList -s0 -S startEpoch -F cleared:false,acked:false \
  -f id,severity,startEpoch,acked,resourceTemplateName,instanceName,resourceName
```

## Find time-related alerts (NTP, clock skew)

Search for active alerts whose datasource or datapoint name mentions NTP or time:

```shell
elm AlertList -s0 -F cleared:false \
  -f id,severity,startEpoch,resourceTemplateName,dataPointName,resourceName,alertMessage | \
  jq '.AlertList[] | select(
    (.resourceTemplateName | ascii_downcase | test("ntp|time")) or
    (.dataPointName       | ascii_downcase | test("ntp|time|offset|skew"))
  )'
```

## Find the oldest WMI alerts for Windows devices

```shell
elm AlertList -s0 -S startEpoch -F cleared:false \
  -f id,severity,startEpoch,resourceTemplateName,instanceName,resourceName | \
  jq '.AlertList[] | select(.resourceTemplateName | ascii_downcase | test("wmi"))' | \
  jq -s 'sort_by(.startEpoch) | .[0:5]'
```

## Count and list active alerts by severity

Find all currently active alerts:

```shell
elm AlertList -s0 -F cleared:false -f id,severity,monitorObjectName,dataPointName,alertValue
```

Filter by severity (higher number = more severe):

```shell
elm AlertList -s0 -F cleared:false,severity:4   # critical only
elm AlertList -s0 -F cleared:false,severity:3   # error only
elm AlertList -s0 -F cleared:false,severity:2   # warning only
```

Count active alerts by severity:

```shell
elm AlertList -c -s0 -F cleared:false,severity:4   # count of active critical alerts (-c goes after the command)
```

`-C` does not give an exact count for AlertList (LM API limitation) — use `-c -s0` instead, which is exact below 1000.

## Alerts for one device

Alerts for a specific device (AlertList silently ignores `-F monitorObjectId:N`
and returns every alert, so use the device-scoped command or the device name):

```shell
elm AlertListByDeviceId --id <deviceId> -s0 -F cleared:false -f severity,dataPointName,alertValue
```

By name also works: `elm AlertList -s0 -F monitorObjectName:DEVICE`. See issue #56 for the full list of AlertList filter fields the API ignores.

## Alerts by collection method (SNMP, WMI, script)

Alert display names (`resourceTemplateName`) do not say how the data is
collected, so `-F resourceTemplateName~SNMP` misses almost everything. Look up
the datasources by `collectMethod` and match on `resourceTemplateId`:

```shell
elm -f jsonl DatasourceList -s0 -F collectMethod:snmp -f id > snmp-ds.jsonl
elm -f jsonl AlertList -s0 -F cleared:false \
  -f id,monitorObjectName,resourceTemplateId,resourceTemplateType,resourceTemplateName,severity,startEpoch > alerts.jsonl
jq -s --slurpfile ds <(jq -s 'map(.id)' snmp-ds.jsonl) \
  'map(select(.resourceTemplateType == "DS" and (.resourceTemplateId as $i | $ds[0] | index($i))))' alerts.jsonl
```

Only compare `resourceTemplateId` when `resourceTemplateType` is `DS`: EventSource
and other module types have their own id spaces.

## Linux hrStorage: Cached and Shared memory always at 100%

On Linux, `hrStorageTable` reports "Cached memory" (page cache) and "Shared memory" as 100% used. This is normal Linux kernel behaviour — the kernel fills all free RAM with page cache.

The `> 95` threshold on `hrStorageUsedPercent` for these instance types will always fire on Linux. Either:
- Disable alerting on those specific instances, or
- Remove "Cached memory" and "Shared memory" from the threshold scope

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --hide-footer --skip-header examples/alerts.md
```
