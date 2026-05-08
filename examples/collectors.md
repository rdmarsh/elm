# Collector Examples

Queries relating to collectors, collector groups, and auto-balance settings.

**See also:**
- [devices.md](devices.md) for hostgroup/collector group mismatch queries
- [alerts.md](alerts.md) for collector-related SDT queries

<!--ts-->
   * [List collector build versions](#list-collector-build-versions)
   * [Find non-auto balanced devices on a collector](#find-non-auto-balanced-devices-on-a-collector)
   * [Find collectors running old builds](#find-collectors-running-old-builds)
   * [Find Collector Groups that have more than 1 collector but not autobalanced](#find-collector-groups-that-have-more-than-1-collector-but-not-autobalanced)
   * [meta](#meta)

<!-- Created by https://github.com/ekalinin/github-markdown-toc -->

<!--te-->

## List collector build versions

Show the collector build version and when it was last updated; sorted by build number and updated time.
Oldest builds appear first — anything significantly behind the newest is a patching risk:

```shell
elm CollectorList -f hostname,build,updatedOnLocal -S build,updatedOnLocal
```

## Find non-auto balanced devices on a collector

```shell
elm DeviceList -f id,name,displayName,autoBalancedCollectorGroupId,collectorDescription -F collectorDescription\~"DESC_HERE",autoBalancedCollectorGroupId:0 -s0
```

## Find collectors running old builds

Find collectors below a specific build number — useful for identifying patching
targets before a maintenance window:

```shell
elm -f csv CollectorList -s0 -f hostname,build,updatedOnLocal -F build\<37000 -S build
```

Replace `37000` with the minimum acceptable build for your environment.

## Find Collector Groups that have more than 1 collector but not autobalanced

```shell
elm -f txt CollectorGroupList -F autoBalance:false,numOfCollectors\>1 -f autoBalance,name,numOfCollectors
```

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --skip-header examples/collectors.md
```
