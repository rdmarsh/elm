# Collector Examples

Queries relating to collectors, collector groups, and auto-balance settings.

**See also:**
- [devices.md](devices.md) for hostgroup/collector group mismatch queries
- [alerts.md](alerts.md) for collector-related SDT queries

<!--ts-->
   * [Collector health report](#collector-health-report)
      * [All collectors overview](#all-collectors-overview)
      * [DOWN collectors with hosts attached](#down-collectors-with-hosts-attached)
      * [Collectors with no backup and hosts attached](#collectors-with-no-backup-and-hosts-attached)
      * [Backup pair health](#backup-pair-health)
   * [Auto-balance groups](#auto-balance-groups)
      * [List auto-balance groups](#list-auto-balance-groups)
      * [Single-collector auto-balance groups](#single-collector-auto-balance-groups)
      * [Multi-collector groups not using auto-balance](#multi-collector-groups-not-using-auto-balance)
      * [Groups with build version mismatch](#groups-with-build-version-mismatch)
   * [Build versions](#build-versions)
      * [List collector build versions](#list-collector-build-versions)
      * [Find collectors running old builds](#find-collectors-running-old-builds)
   * [Find non-auto balanced devices on a collector](#find-non-auto-balanced-devices-on-a-collector)
   * [meta](#meta)

<!-- Created by https://github.com/ekalinin/github-markdown-toc -->

<!--te-->

## Collector health report

### All collectors overview

Full health overview sorted worst-first (DOWN, then by host count descending). Useful as a
starting point before a maintenance window or incident review:

```shell
elm CollectorList -s0 -f id,hostname,isDown,numberOfHosts,numberOfInstances,build,backupAgentId,collectorGroupName,collectorSize | \
  jq '.CollectorList | sort_by((.isDown | not), -.numberOfHosts) | .[]'
```

Key fields to watch:

- `isDown` - collector is not checking in to LM
- `numberOfHosts` - devices assigned to this collector; a DOWN collector with hosts means those devices are unmonitored
- `backupAgentId` - `0` means no failover; devices will be unmonitored if this collector goes down
- `collectorDeviceId` - `0` means no device record in LM; cannot query collector host metrics
- `build` - compare against `CollectorVersionList` to identify patching targets
- `calculatedThreshold` - non-zero only for auto-balance groups; current instance load vs threshold

### DOWN collectors with hosts attached

The most urgent issue: collectors that are down but still have devices assigned:

```shell
elm CollectorList -s0 -F 'isDown:true' -f id,hostname,numberOfHosts,build,backupAgentId,collectorGroupName | \
  jq '.CollectorList[] | select(.numberOfHosts > 0)'
```

### Collectors with no backup and hosts attached

Single points of failure: hosts will be unmonitored if these collectors go down:

```shell
elm CollectorList -s0 -f id,hostname,isDown,numberOfHosts,backupAgentId,collectorGroupName | \
  jq '.CollectorList[] | select(.backupAgentId == 0 and .numberOfHosts > 0) | {id,hostname,isDown,numberOfHosts,collectorGroupName}'
```

### Backup pair health

Check whether both sides of a backup pair are healthy. If both are DOWN, failover
provides no protection:

```shell
elm CollectorList -s0 -f id,hostname,isDown,numberOfHosts,backupAgentId,collectorGroupName | \
  jq '[.CollectorList[] | select(.backupAgentId != 0)] |
      group_by([.id, .backupAgentId] | sort | join("-")) |
      map({
        collectorA: .[0].id,
        collectorB: .[0].backupAgentId,
        group: .[0].collectorGroupName,
        bothDown: (map(.isDown) | all)
      })'
```

## Auto-balance groups

Auto-balance redistributes devices between collectors in a group automatically as
instance counts change. The key threshold is `autoBalanceInstanceCountThreshold` on the
group. When a collector's `numberOfInstances` exceeds the threshold, LM moves devices to
other collectors in the group.

Auto-balance requires at least 2 collectors in the group. A single-collector auto-balance
group has nowhere to rebalance to.

`propertyForBalancing` controls the balancing strategy:
- `""` (empty) - balance by instance count (default)
- a device property name - balance by property value, keeping devices with the same value on
  the same collector (e.g. to pin devices by customer or region)

### List auto-balance groups

```shell
elm CollectorGroupList -s0 -F 'autoBalance:true' -f id,name,autoBalanceInstanceCountThreshold,numOfCollectors,platform,propertyForBalancing
```

To see current instance load on auto-balance collectors (compare against threshold):

```shell
elm CollectorList -s0 -f id,hostname,collectorGroupName,numberOfInstances,calculatedThreshold | \
  jq '.CollectorList[] | select(.calculatedThreshold > 0)'
```

### Single-collector auto-balance groups

Auto-balance is enabled but cannot work because there is only one collector in the group:

```shell
elm -f txt CollectorGroupList -s0 -F 'autoBalance:true,numOfCollectors:1' -f id,name,numOfCollectors,autoBalance
```

### Multi-collector groups not using auto-balance

Groups with 2+ collectors but auto-balance off. These could benefit from auto-balance
but are managing load manually:

```shell
elm -f txt CollectorGroupList -s0 -F 'autoBalance:false,numOfCollectors>:2' -f id,name,autoBalance,numOfCollectors
```

### Groups with build version mismatch

Collectors in the group are on different builds, which can cause inconsistent behaviour
during rolling upgrades:

```shell
elm CollectorGroupList -s0 -F 'mismatchVersion:true' -f id,name,mismatchVersion,numOfCollectors
```

## Build versions

### List collector build versions

Show the collector build version and when it was last updated; sorted by build number.
Oldest builds appear first - anything significantly behind the newest is a patching risk:

```shell
elm CollectorList -f hostname,build,updatedOnLocal -S build,updatedOnLocal
```

### Find collectors running old builds

Find collectors below a specific build number - useful for identifying patching
targets before a maintenance window:

```shell
elm -f csv CollectorList -s0 -f id,hostname,isDown,numberOfHosts,build,collectorGroupName -F 'build<:38000' -S build
```

Replace `38000` with the minimum acceptable build for your environment.

## Find non-auto balanced devices on a collector

```shell
elm DeviceList -f id,name,displayName,autoBalancedCollectorGroupId,collectorDescription -F collectorDescription\~"DESC_HERE",autoBalancedCollectorGroupId:0 -s0
```

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --skip-header examples/collectors.md
```
