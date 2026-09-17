# elm examples

Topic-specific example files for common elm queries.
See [../EXAMPLES.md](../EXAMPLES.md) for the full index.

| File | Contents |
|------|----------|
| [general.md](general.md) | Basic usage: flags, output formats, piping, writing to file, header/footer |
| [filtering.md](filtering.md) | Using `-F`/`--filter`: operators, `~` substring search, combining filters, gotchas |
| [devices.md](devices.md) | Devices and device groups: OS filtering, custom/system properties, group membership |
| [collectors.md](collectors.md) | Collectors and collector groups: build versions, auto-balance, group mismatches |
| [alerts.md](alerts.md) | Alerts and SDTs: counts by severity, one device's alerts, SNMP alerts, long SDTs, oldest alerts |
| [datasources.md](datasources.md) | Datasource coverage, standard-set checks, time-series data, how some datasources collect |
| [logicmodules.md](logicmodules.md) | LogicModule versions and upgrade status from V4Metadata |
| [health-checks.md](health-checks.md) | Health and security one-liners: alerting disabled, active SDTs, unused tokens, failed API requests |
| [users.md](users.md) | User accounts: export by id, status checks, offboarding |
| [websites.md](websites.md) | Websites: group hierarchy queries, missing required properties |
| [dashboards-reports.md](dashboards-reports.md) | Dashboards and reports: filtering by resource group or hostsVal |

## Scripts

- [fs_usage_root_pct_alertexpr.sh](fs_usage_root_pct_alertexpr.sh) — outputs a CSV list of the
  alertExpr used for PercentUsed of the root volume for all devices in a group
