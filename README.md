# elm

[![Dependency Review](https://github.com/rdmarsh/elm/actions/workflows/dependency-review.yml/badge.svg)](https://github.com/rdmarsh/elm/actions/workflows/dependency-review.yml)
[![Makefile CI](https://github.com/rdmarsh/elm/actions/workflows/makefile.yml/badge.svg)](https://github.com/rdmarsh/elm/actions/workflows/makefile.yml)

![GitHub last commit](https://img.shields.io/github/last-commit/rdmarsh/elm)
![GitHub](https://img.shields.io/github/license/rdmarsh/elm)
![OSS Lifecycle](https://img.shields.io/osslifecycle/rdmarsh/elm)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg)](CODE_OF_CONDUCT.md)

> A cli tool for extracting LogicMonitor data via the API

This tool simplifies running basic read-only queries against the
LogicMonitor API, formatting the output in various formats, including
CSV, HTML, JSON, XML, Markdown, and more.

**elm is intentionally read-only.** It only performs GET requests —
it cannot create, modify, or delete anything in your LogicMonitor
account. This makes it safe to hand to anyone: the worst outcome is a
slow query or confusing output, never an accidental change to your
platform.

<!--ts-->
   * [Features](#features)
   * [Installation](#installation)
      * [Quick Start](#quick-start)
      * [Quick code testing loop](#quick-code-testing-loop)
      * [Pre-requisites](#pre-requisites)
      * [Clone the Repo](#clone-the-repo)
      * [Building](#building)
      * [Initial Configuration](#initial-configuration)
      * [Install in PATH](#install-in-path)
      * [Development](#development)
      * [AdminById help](#adminbyid-help)
   * [Examples](#examples)
   * [Errors](#errors)
   * [Contributing](#contributing)
   * [Links](#links)
   * [Licensing](#licensing)
   * [meta](#meta)

<!-- Created by https://github.com/ekalinin/github-markdown-toc -->

<!--te-->

## Features

* Retrieve data from LogicMonitor via the API
* Output in multiple formats: CSV, HTML, JSON, XML, Markdown, and more
* Read-only — GET requests only, no risk of accidental changes

## Installation

What you need to do to get up and running

### Quick Start

In a hurry? Just do this:

```shell
git clone https://github.com/rdmarsh/elm.git
cd elm
make
make install
```

Next, copy the binary to a directory included in your PATH:

```shell
  mkdir -p ~/bin
  cp -r _dist/elm/* ~/bin
  vi ~/.bash_profile
append the following line:
  export PATH="${HOME}/bin:${PATH}"
  source ~/.bash_profile
```

API credentials can be placed in an ini file:

```shell
cp ~/.config/logicmonitor/credentials/config.example.ini ~/.config/logicmonitor/credentials/config.ini
vi ~/.config/logicmonitor/credentials/config.ini
```

elm enforces secure permissions on the credentials directory (`700`) and
config file (`600`) on every run. If the permissions are too open, elm
will warn and fix them automatically. If it cannot fix them, it will
abort.

*You may need to restart your terminal session*

Now you can run 'elm' from anywhere on the cli

*Note:* The first run will take longer than normal.

You can also run tests:

```shell
make testbasic
make testverb
```

### Quick code testing loop

While I'm testing, I often do this loop:

```shell
make clean && make && make install && echo done
```

### Pre-requisites

Ensure the following software is installed (you can check some of these
are present by running `make init`)

* `make`
* `curl`
* `jq`
* `awk`
* `tar` -- to back up files during dev
* `git` -- to initially clone the repo
* `python3`

### Clone the Repo

To clone the repository, use:

```shell
git clone https://github.com/rdmarsh/elm.git
cd elm
```

### Building

After cloning, run:

```shell
make
```

This will:

* Initialise needed dirs
* Get json swagger file from LogicMonitor
* Create json definition files
* Create the python files from jinja templates
* Create config dir
* Copy example config file
* Install the required python packages

### Initial Configuration

You will need the following items to run the program after building:

* A LogicMonitor API id and key associated with your account
* (optional) a config file with the API info (default to `~/.config/logicmonitor/credentials/config.ini`)
  * If you don't have this, run `make cfg` and follow the directions
* Pre-requisite software listed above

See [Configuration](#configuration) below for more details

### Install in PATH

To make the script accessible in your PATH, run:

* `make install`

which will execute:

```shell
venv/bin/python3 -m pip install --editable .
venv/bin/pyinstaller  --workpath _build --distpath _dist --noconfirm --clean elm.py
```

(Note the trailing ".")

You could run the binary from `_dist/elm/elm` if you want, but it is
recommended to copy the binary to a dir that you can add to PATH. See
steps under the "Quick Start" section above.

### Development

After cloning, install the git hooks:

```shell
make hooks
```

This sets up a pre-commit hook that automatically regenerates the README
table of contents when `README.md` is staged for a commit.

Make any changes to the `Makefile` or templates in the `_jnja/` directory.
Files in `_cmds` and `_defs` may be overwritten during builds.

After changing any CLI options in `_jnja/elm.py.j2`, run the full build
cycle followed by `make docs` to keep the `elm --help` output in this
README in sync:

```shell
make clean && make && make install && make docs
```

`make docs` injects the live `elm --help` output into the README between
the `<!-- elm-help-start -->` and `<!-- elm-help-end -->` marker comments,
```text
Usage: elm [OPTIONS] COMMAND [ARGS]...

  A cli interface for extracting LogicMonitor data via the api

  See https://github.com/rdmarsh/elm for more information

Options:
  --config FILE            Read configuration from FILE.
  -l, --list               List available credential profiles and exit
  -p, --profile NAME       Credentials profile name — shorthand for --config /
                           Users/davidmarsh/.config/logicmonitor/credentials/<
                           NAME>.ini

  -i, --access_id TEXT     API token access id
  -k, --access_key TEXT    API token access key
  -a, --account_name TEXT  LogicMonitor account (company) name
  -s, --proxy <HOST PORT>  Socks5 proxy address and port
  -f, --format FORMAT      Output format: csv, tsv, json, jsonl, prettyjson,
                           xml, prettyxml, html, prettyhtml, gfm, pipe, jira,
                           latex, md, rst, tab, raw, txt, api  [default: json]

  -H, --noheader           Hide the column headers  [default: False]
  -I, --index              Show the row indices  [default: False]
  -o, --filename FILE      Output to file name  [default: -]
  --head TEXT              Text to prepend before the output
  --foot TEXT              Text to append after the output
  -v, --verbose            Be more verbose, -v is INFO, -vv is DEBUG
  -x, --export FILENAME    Export the query to FILENAME
  --halt-on-api-error      Halt on API response errors
  --cacert FILE            Path to CA certificate bundle for SSL verification
  -V, --version            Show the version and exit.
  --help                   Show this message and exit.

Commands:
  AccessGroupById                 Get access group by id
  AccessGroupList                 Get access group list
  AdminById                       Get user
  AdminList                       Get user list
  AlertById                       Get alert
  AlertList                       Get alert list
  AlertListByDeviceGroupId        Get device group alerts
  AlertListByDeviceId             Get alerts
  AlertRuleById                   Get alert rule by id
  AlertRuleList                   Get alert rule list
  AllLogPartitions                Retrieve a list of all log partitions
  AllSDTListByDeviceId            Get sdts for a device
  AllSDTListByWebsiteGroupId      Get a list of sdts for a website group
                                  (response may contain extra fields depending
                                  upon the type of sdt)

  ApiTokenList                    Get a list of api tokens across users
  ApiTokenListByAdminId           Get api tokens for a user
  AppliesToFunctionById           Get applies to function by id
  AppliesToFunctionList           Get applies to function list
  AssociatedDeviceListByDataSourceId
                                  Get devices associated with a datasource
  AuditLogById                    Get audit log by id
  AuditLogList                    Get audit logs
  AwsAccountId                    Get aws account id
  AwsExternalId                   Get aws external id
  CollectorAgentLogLevelByComponent
                                  Get collector agent log level by component
  CollectorAgentLogLevels         Get collector agent log levels
  CollectorById                   Get collector
  CollectorEvents                 Get collector events
  CollectorGroupById              Get collector group
  CollectorGroupList              Get collector group list
  CollectorInstaller              Get collector installer
  CollectorList                   Get collector list
  CollectorStatusCheck            Get collector status check
  CollectorVersionList            Get collector version list
  ConfigSourceById                Get config source by id
  ConfigSourceList                Get config source list
  ContractInfoByCompany           Get contract info by company
  DashboardById                   Get dashboard
  DashboardGroupById              Get dashboard group by id
  DashboardGroupList              Get dashboard group list
  DashboardList                   Get dashboard list
  DataSourceOverviewGraphById     Get datasource overview graph by id
  DataSourceOverviewGraphList     Get datasource overview graph list
  DatasourceById                  Get datasource by id
  DatasourceList                  Get datasource list
  DebugCommandResult              Get the result of a collector debug command
                                  using sessionid

  DeltaDevices                    Get delta devices using deltaid
  DeltaIdWithDevices              Get filter matched devices with new deltaid
  DeviceById                      Get device by id
  DeviceConfigSourceConfigById    Get a config for a device
  DeviceConfigSourceConfigList    Get detailed config information for the
                                  instance

  DeviceDatasourceById            Get device datasource
  DeviceDatasourceDataById        Get device datasource data
  DeviceDatasourceInstanceAlertSettingById
                                  Get device instance alert setting
  DeviceDatasourceInstanceAlertSettingListOfDSI
                                  Get a list of alert settings for a device
                                  datasource instance

  DeviceDatasourceInstanceAlertSettingListOfDevice
                                  Get a list of alert settings for a device
  DeviceDatasourceInstanceById    Get device instance
  DeviceDatasourceInstanceData    Get device instance data
  DeviceDatasourceInstanceGraphData
                                  Get device instance graph data
  DeviceDatasourceInstanceGroupById
                                  Get device datasource instance group
  DeviceDatasourceInstanceGroupList
                                  Get device datasource instance group list
  DeviceDatasourceInstanceGroupOverviewGraphData
                                  Get device instance group overview graph
                                  data

  DeviceDatasourceInstanceList    Get device instance list
  DeviceDatasourceInstanceSDTHistory
                                  Get device instance sdt history
  DeviceDatasourceList            Get device datasource list
  DeviceEventsourceList           Get device eventsource list
  DeviceGroupById                 Get device group
  DeviceGroupClusterAlertConfById
                                  Get cluster alert configuration by id
  DeviceGroupClusterAlertConfList
                                  Get a list of cluster alert configurations
                                  for a device group

  DeviceGroupDatasourceAlertSetting
                                  Get device group datasource alert setting
  DeviceGroupDatasourceById       Get device group datasource
  DeviceGroupDatasourceList       Get device group datasource list
  DeviceGroupList                 Get device group list
  DeviceGroupPropertyByName       Get device group property by name
  DeviceGroupPropertyList         Get device group properties
  DeviceGroupSDTList              Get device group sdts
  DeviceInstanceGraphDataOnlyByInstanceId
                                  Get device instance data
  DeviceInstanceList              Get device instance list
  DeviceList                      Get device list
  DevicePropertyByName            Get device property by name
  DevicePropertyList              Get device properties
  DiagnosticSourcesById           Get diagnostics sources by id
  DiagnosticSourcesList           Get diagnostics sources list
  EscalationChainById             Get escalation chain by id
  EscalationChainList             Get escalation chain list
  EventSourceById                 Get event source by id
  EventSourceList                 Get event source list
  ExternalApiStats                Get external api stats info
  ImmediateDeviceListByDeviceGroupId
                                  Get immediate devices under group
  ImmediateWebsiteListByWebsiteGroupId
                                  Get a list of websites for a group (response
                                  may contain extra fields depending upon the
                                  type of check { pingcheck | webcheck} being
                                  added)

  IntegrationAuditLogs            Get integration audit logs list
  IntegrationList                 Get integration list
  JobMonitorById                  Get jobmonitor by id
  JobMonitorList                  Get jobmonitor list
  LogAlertGroupById               Retrieve a logalertgroup by id
  LogAlertGroupsList              Retrieve all logalertgroups
  LogAlerts                       Retrieve all logalerts
  LogAlertsById                   Retrieve a logalerts by id
  LogQueriesByGroupId             Get log queries by group id
  LogQueryGroupById               Get log query group by id
  LogQueryGroupList               Get log query group list
  LogQueryGroupListByGroupType    Get log query groups by grouptype
  LogSourceById                   Get log source
  LogSourceList                   Get log source list
  MetricsSummary                  Get metrics usage with company settings
                                  summary

  MetricsUsage                    Get metrics usage
  NetflowEndpointList             Get netflow endpoints
  NetflowFlowList                 Get netflow flows
  NetflowPortList                 Get netflow ports
  NetscanById                     Get netscan by id
  NetscanList                     Get netscan list
  OIDList                         Get oids list
  OidById                         Get oid by id
  OpsNoteById                     Get opsnote by id
  OpsNoteList                     Get opsnote list
  PartitionById                   Retrieve details of a specific log partition
  PortalInfo                      Get portal info
  PropertyRulesById               Get property rules by id
  PropertyRulesList               Get property rules list
  RecipientGroupById              Get recipient group by id
  RecipientGroupList              Get recipient group list
  RecommendationById              Get recommendation by id
  RecommendationCategoriesList    Get recommendation category list
  RecommendationsList             Get recommendation list
  RemediationSourcesById          Get remediation sources by id
  RemediationSourcesList          Get remediation sources list
  ReportById                      Get report by id
  ReportGroupById                 Get report group by id
  ReportGroupList                 Get report group list
  ReportList                      Get report list
  ReportUsingTaskId               Get report for task id
  RetentionList                   Retrieve the list of log retentions
  RoleById                        Get role by id
  RoleList                        Get role list
  SDTHistoryByDeviceDataSourceId  Get sdt history for the device datasource
  SDTHistoryByDeviceGroupId       Get sdt history for the group
  SDTHistoryByDeviceId            Get sdt history for the device
  SDTHistoryByWebsiteGroupId      Get sdt history for the website group
                                  (response may contain extra fields depending
                                  upon the type of sdt)

  SDTHistoryByWebsiteId           Get sdt history for the website (response
                                  may contain extra fields depending upon the
                                  type of sdt)

  SDTList                         Get sdt list
  SdtById                         Get sdt by id (response may contain extra
                                  fields depending upon the type of sdt of
                                  given id)

  SiteMonitorCheckPointList       Get website checkpoint list
  TopTalkersGraph                 Get top talkers graph
  TopologySourceById              Get topologysource by id
  TopologySourceList              Get topologysource list
  TrackedQueryGroupById           Get tracked query group by id
  TrackedQueryGroupList           Get tracked query group list
  UnmonitoredDeviceList           Get unmonitored device list
  UpdateReasonListByConfigSourceId
                                  Get update history for a configsource
  UpdateReasonListByDataSourceId  Get update history for a datasource
  V4Metadata                      Get metadata
  WebsiteAlertListByWebsiteId     Get alerts for a website
  WebsiteById                     Get website by id
  WebsiteCheckpointDataById       Get data for a website checkpoint
  WebsiteDataByGraphName          Get website data by graph name
  WebsiteGraphData                Get website graph data
  WebsiteGroupById                Get website group
  WebsiteGroupList                Get website group list
  WebsiteList                     Get website list
  WebsitePropertyListByWebsiteId  Get a list of properties for a website
  WebsiteSDTListByWebsiteId       Get a list of sdts for a website
  WidgetById                      Get widget by id
  WidgetDataById                  Get widget data (based upon widget type the
                                  response may contain additional attributes.
                                  please refer models corresponding to
                                  specific widget type at the bottom of this
                                  page to check the attributes)

  WidgetList                      Get widget list
  WidgetListByDashboardId         Get widget list by dashboardid

  default config file:
  /home/user/.config/logicmonitor/credentials/config.ini
```
<!-- elm-help-start -->
```text
```
<!-- elm-help-end -->

### AdminById help

This is only one example, but other help messages are similar. The URL
will take you directly to the swagger document relating to that command

`elm AdminById --help`

```text
Usage: elm AdminById [OPTIONS]

  Get user

  API Path:

  /setting/admins/{id}

  Swagger URL:

  https://www.logicmonitor.com/swagger-ui-master/api-v3/dist/#/Users/getAdminById

Options:
  --id INTEGER               [required]
  -f, --fields FIELD,...     Only include the listed fields
  -S, --sort [+,-]FIELD,...  Sort by field; inc (+), dec (-)
  -c, --count                Return qty of query objects instead of query data
  -C, --total                Return qty of ALL objects instead of query data
  --help                     Show this message and exit.
```

## Examples

See [EXAMPLES.md](EXAMPLES.md) for the full index, or jump directly to a topic:

- [General usage](examples/general.md) — flags, output formats, piping, writing to file
- [Devices](examples/devices.md) — OS filtering, custom/system properties, group membership
- [Collectors](examples/collectors.md) — build versions, auto-balance, group mismatches
- [Alerts and SDTs](examples/alerts.md) — long SDTs, oldest alerts, time-related alerts
- [Datasources](examples/datasources.md) — finding devices without a datasource applied
- [Users](examples/users.md) — export by id, status checks, offboarding
- [Websites](examples/websites.md) — group hierarchy queries, missing required properties
- [Dashboards and reports](examples/dashboards-reports.md) — filtering by resource group or hostsVal

## Errors

See [ERRORS.md](ERRORS.md)

## Contributing

To contribute, please fork the repository and use a feature branch. Pull
requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for more
details.

This project adheres to the Contributor Code of Conduct.
By participating, you agree to abide by its terms. See
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

## Links

- Project Homepage: https://github.com/rdmarsh/elm
- Repository: https://github.com/rdmarsh/elm
- Issue Tracker: https://github.com/rdmarsh/elm/issues
- Security Vulnerabilities: [SECURITY.md](SECURITY.md)
- Related projects and pages:
    - https://www.logicmonitor.com  
    - https://www.logicmonitor.com/support/rest-api-change-log
    - https://www.logicmonitor.com/support/rest-api-developers-guide/v2/rest-api-v2-overview
    - https://www.logicmonitor.com/support/ansible-integration
    - https://docs.ansible.com/ansible/2.9/modules/logicmonitor_module.html

## Licensing

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details

You should have received a copy of the GNU General Public License
along with this program. If not, see https://www.gnu.org/licenses/

Note: LOGICMONITOR is a trademark of LogicMonitor, Inc. and not
affiliated with this project

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --skip-header README.md
```

[githubs vulnerablity reporting function]: https://github.com/rdmarsh/elm/security

