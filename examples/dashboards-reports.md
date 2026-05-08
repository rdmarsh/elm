# Dashboard and Report Examples

Queries relating to dashboards, dashboard groups, and reports.

**See also:**
- [devices.md](devices.md) for device group queries used as dashboard resource groups

<!--ts-->
   * [Find Dashboards that match a defaultResourceGroup](#find-dashboards-that-match-a-defaultresourcegroup)
   * [Find Reports that match a hostsVal](#find-reports-that-match-a-hostsval)
   * [meta](#meta)

<!-- Created by https://github.com/ekalinin/github-markdown-toc -->

<!--te-->

## Find Dashboards that match a defaultResourceGroup

This example will show dashboards that use "Root/Group" as their defaultResourceGroup:

```shell
elm -f txt DashboardList -s0 -F widgetTokens.name:defaultResourceGroup,widgetTokens.value\~Root/Group -f fullName
```

## Find Reports that match a hostsVal

This example will show reports that use "Root/Group" as their hostsVal:

```shell
elm -f txt ReportList -s0 -F hostsVal\~Root/Group -f name
```

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --skip-header examples/dashboards-reports.md
```
