# Examples

Quick-start examples and reference for common elm queries.
Each topic has its own file in the [examples/](examples/) directory.

<!--ts-->
   * [Topics](#topics)
   * [Scripts](#scripts)
   * [meta](#meta)
<!--te-->

## Topics

| File | Contents |
|------|----------|
| [examples/general.md](examples/general.md) | Basic usage: flags, output formats, piping, writing to file, header/footer |
| [examples/filtering.md](examples/filtering.md) | Using `-F`/`--filter`: operators, `~` substring search, combining filters, gotchas |
| [examples/devices.md](examples/devices.md) | Devices and device groups: OS filtering, custom/system properties, group membership |
| [examples/collectors.md](examples/collectors.md) | Collectors and collector groups: build versions, auto-balance, group mismatches |
| [examples/alerts.md](examples/alerts.md) | Alerts and SDTs: counts by severity, one device's alerts, SNMP alerts, long SDTs, oldest alerts |
| [examples/datasources.md](examples/datasources.md) | Datasource coverage, standard-set checks, time-series data, how some datasources collect |
| [examples/logicmodules.md](examples/logicmodules.md) | LogicModule versions and upgrade status from V4Metadata |
| [examples/health-checks.md](examples/health-checks.md) | Health and security one-liners: alerting disabled, active SDTs, unused tokens, failed API requests |
| [examples/users.md](examples/users.md) | User accounts: export by id, status checks, offboarding |
| [examples/websites.md](examples/websites.md) | Websites: group hierarchy queries, missing required properties |
| [examples/dashboards-reports.md](examples/dashboards-reports.md) | Dashboards and reports: filtering by resource group or hostsVal |

## Scripts

For longer automation, see the scripts in [examples/](examples/):

- [fs_usage_root_pct_alertexpr.sh](examples/fs_usage_root_pct_alertexpr.sh) — outputs a CSV list of the
  alertExpr used for PercentUsed of the root volume for all devices in a group

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --hide-footer --skip-header EXAMPLES.md
```

