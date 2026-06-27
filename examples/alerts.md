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

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --hide-footer --skip-header examples/alerts.md
```
