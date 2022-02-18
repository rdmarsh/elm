# elm

> Extract LogicMonitor via API

This is a tool designed to make it simple to run basic queries against
the LogicMonitor API and format the results as csv, html, json, latex,
raw or txt output

## Features

* Retrieve information from LogicMonitor via the LM API.
* Format in csv, html, json, latex, plain text

## Installing

What you need to do to get up and running.

### Quick start

> In a hurry, just do this:

```shell
git clone https://github.com/rdmarsh/elm.git
cd elm
make
make cfg
cp ~./elm/config.example.ini ~./elm/config.ini
vi ~./elm/config.ini
make testbasic
make testverb
```

### Pre-requisites

You will need the following software installed. The Makefile will
check some of this for you by running `make init`.

* `make`
* `curl`
* `jq`
* `awk`
* `tar` -- to back up files during dev
* `git` -- to initially clone the repo
* `jinja2`
* `python3`
* `pip` to install the following:
  * `socks`
  * `click`
  * `click_config_file`
  * `jinja2`
  * `pygments`
  * `packaging`
  * `pandas`
  * `htmlmin`
  * `requests`

### Clone the repo

```shell
git clone https://github.com/rdmarsh/elm.git
cd elm
```

### Initial Configuration

You will need the following items configured:

* A LogicMonitor API id and key associated with your account
* (optional) a config file with the API info (default to `~/.elm/config.ini`)
  * If you don't have this, run `make cfg`
* Pre-requisite software listed above

## Developing

Any changes should be made to the `Makefile` or the templates in
`_jnja/`. Files in `_cmds` and `_defs` are in danger of being
overwritten.

### Building

After cloning, to build the needed files, run the following:

```shell
make
```

This will initialise dirs, get swagger file, create definition files,
create the python files from jinja templates.

### Makefile Help

These are options for the Makefile

```
make help

Usage: make [flags] [option]
  make all           Build everything
  make init          Initialise dirs, get swagger file, create definition files
  make cmds          Make python commands from templates
  make cfg           Create config dir, copy example file and set permissions
  make test          Run all tests
  make testbasic     Run basic elm tests
  make testhelp      Run all commands with help flag
  make testcmds      Run all tests with a valid command
  make testfmts      Run one test with all formats
  make testverb      Test the verbose flags
  make fail          a failing test
  make back          TAR and backup (eg ../name_backup/name.YYYY-MM-DD.tar.gz)
  make clean         Remove generated files
  make nomac         Remove unneeded mac files
  make about         About this Makefile
  make copying       Copyright notice
  make help          Show this help

Useful make flags:
  make -n  dry run
  make -j  run simultaneous jobs
  make -B  force make target
```

## Configuration

> In a hurry? Put your credentials in `~/.elm/config.ini` and secure permissions

You don't need a config file, but to prevent passing values on the command
line to hide them from a process list you can create a file in (default)
`~/.elm/config.ini` with the following contents:

```
* `access_id`
* `access_key`
* `account_name`
```

You can set any cli flag in the file, but they are the three most useful.

The Makefile should create this dir and place an example config file in
it for you:

`~./elm/config.example.ini`

Ensure the permisions for the dir and file are only readable by your
account. Again the Makefile should do this for you, which you can re-run
with `make config`.

* `mkdir ~/.elm`
* `chown -R USER:GROUP ~/.elm`
* `chmod 700 ~/.elm`
* `chmod 600 ~/.elm/config.ini`

Config files use unrepr format:

https://configobj.readthedocs.io/en/latest/configobj.html#unrepr-mode

## Examples

The following are useful examples that show you how to get started:

### Export users by userid

Show the id and username for users with id between 2 and 5, sort by
reverse username, and put in csv format:

```shell
./elm -o csv AdminList -s5 -f id,username -S -username -F id\>:2,id\<:5
```

## General help

```shell
$ ./elm --help
Usage: elm [OPTIONS] COMMAND [ARGS]...

  Extract LogicMonitor

Options:
  --config FILE                   Read configuration from FILE.
  -i, --access_id TEXT            API token access id.
  -k, --access_key TEXT           API token access key.
  -a, --account_name TEXT         LogicMonitor account (company) name.
  -s, --proxy <HOST PORT>         Socks5 proxy address and port.
  -o, --output [csv|html|prettyhtml|json|prettyjson|latex|raw|txt]
                                  Output format.
  -v, --verbose                   Be more verbose, -v is INFO, -vv is DEBUG
  -x, --export FILENAME           Export the query to FILENAME
  --version                       Show the version and exit.
  --help                          Show this message and exit.

Commands:
  AdminById                       Get user.
  AdminList                       Get user list.
  AlertById                       Get alert.
  AlertList                       Get alert list.
  AlertListByDeviceGroupId        Get device group alerts.
  AlertListByDeviceId             Get alerts.
  AlertRuleById                   Get alert rule by id.
  AlertRuleList                   Get alert rule list.
  AllSDTListByDeviceId            Get sdts for a device.
  AllSDTListByWebsiteGroupId      Get a list of sdts for a website group.
  ApiTokenList                    Get a list of api tokens across users.
  ApiTokenListByAdminId           Get api tokens for a user.
  AppliesToFunctionById           Get applies to function.
  AppliesToFunctionList           Get applies to function list.
  AssociatedDeviceListByDataSourceId
                                  Get devices associated with a datasource.
  AuditLogById                    Get audit log by id.
  AuditLogList                    Get audit logs.
  AwsExternalId                   Get aws external id.
  CollectorById                   Get collector.
  CollectorGroupById              Get collector group.
  CollectorGroupList              Get collector group list.
  CollectorInstaller              Get collector installer.
  CollectorList                   Get collector list.
  CollectorVersionList            Get collector version list.
  DashboardById                   Get dashboard.
  DashboardGroupById              Get dashboard group.
  DashboardGroupList              Get dashboard group list.
  DashboardList                   Get dashboard list.
  DataSourceOverviewGraphById     Get datasource overview graph by id.
  DataSourceOverviewGraphList     Get datasource overview graph list.
  DatasourceById                  Get datasource by id.
  DatasourceList                  Get datasource list.
  DebugCommandResult              Get the result of a collector debug command.
  DeviceById                      Get device by id.
  DeviceConfigSourceConfig        Collect a config for a device.
  DeviceConfigSourceConfigById    Get a config for a device.
  DeviceConfigSourceConfigList    Get detailed config information for the
                                  instance.

  DeviceDatasourceById            Get device datasource .
  DeviceDatasourceDataById        Get device datasource data .
  DeviceDatasourceInstanceAlertSettingById
                                  Get device instance alert setting.
  DeviceDatasourceInstanceAlertSettingListOfDSI
                                  Get a list of alert settings for a device
                                  datasource instance.

  DeviceDatasourceInstanceAlertSettingListOfDevice
                                  Get a list of alert settings for a device.
  DeviceDatasourceInstanceById    Get device instance .
  DeviceDatasourceInstanceData    Get device instance data.
  DeviceDatasourceInstanceGraphData
                                  Get device instance graph data .
  DeviceDatasourceInstanceGroupById
                                  Get device datasource instance group .
  DeviceDatasourceInstanceGroupList
                                  Get device datasource instance group list .
  DeviceDatasourceInstanceGroupOverviewGraphData
                                  Get device instance group overview graph
                                  data .

  DeviceDatasourceInstanceList    Get device instance list.
  DeviceDatasourceInstanceSDTHistory
                                  Get device instance sdt history.
  DeviceDatasourceList            Get device datasource list .
  DeviceGroupById                 Get device group.
  DeviceGroupClusterAlertConfById
                                  Get cluster alert configuration by id.
  DeviceGroupClusterAlertConfList
                                  Get a list of cluster alert configurations
                                  for a device group.

  DeviceGroupDatasourceAlertSetting
                                  Get device group datasource alert setting .
  DeviceGroupDatasourceById       Get device group datasource.
  DeviceGroupDatasourceList       Get device group datasource list.
  DeviceGroupList                 Get device group list.
  DeviceGroupPropertyByName       Get device group property by name.
  DeviceGroupPropertyList         Get device group properties.
  DeviceGroupSDTList              Get device group sdts.
  DeviceInstanceGraphDataOnlyByInstanceId
                                  Get device instance data.
  DeviceInstanceList              Get device instance list.
  DeviceList                      Get device list.
  DevicePropertyByName            Get device property by name.
  DevicePropertyList              Get device properties.
  EscalationChainById             Get escalation chain by id.
  EscalationChainList             Get escalation chain list.
  EventSourceList                 Get eventsource list.
  ExternalApiStats                Get external api stats info.
  ImmediateDeviceListByDeviceGroupId
                                  Get immediate devices under group.
  ImmediateWebsiteListByWebsiteGroupId
                                  Get a list of websites for a group.
  MetricsUsage                    Get metrics usage.
  NetflowEndpointList             Get netflow endpoint list.
  NetflowFlowList                 Get netflow flow list.
  NetflowPortList                 Get netflow port list.
  NetscanById                     Get netscan by id.
  NetscanList                     Get netscan list.
  OpsNoteById                     Get opsnote by id.
  OpsNoteList                     Get opsnote list.
  RecipientGroupById              Get recipient group by id.
  RecipientGroupList              Get recipient group list.
  ReportById                      Get report by id.
  ReportGroupById                 Get report group by id.
  ReportGroupList                 Get report group list.
  ReportList                      Get report list.
  RoleById                        Get role by id.
  RoleList                        Get role list.
  SDTById                         Get sdt by id.
  SDTHistoryByDeviceDataSourceId  Get sdt history for the device datasource.
  SDTHistoryByDeviceGroupId       Get sdt history for the group.
  SDTHistoryByDeviceId            Get sdt history for the device.
  SDTHistoryByWebsiteGroupId      Get sdt history for the website group.
  SDTHistoryByWebsiteId           Get sdt history for the website.
  SDTList                         Get sdt list.
  SiteMonitorCheckPointList       Get website checkpoint list.
  TopTalkersGraph                 Get top talkers graph.
  UnmonitoredDeviceList           Get unmonitored device list.
  UpdateReasonListByDataSourceId  Get update history for a datasource.
  WebsiteAlertListByWebsiteId     Get alerts for a website.
  WebsiteById                     Get website by id.
  WebsiteCheckpointDataById       Get data for a website checkpoint.
  WebsiteDataByGraphName          Get website data by graph name.
  WebsiteGraphData                Get website graph data.
  WebsiteGroupById                Get website group.
  WebsiteGroupList                Get website group list.
  WebsiteList                     Get website list.
  WebsitePropertyListByWebsiteId  Get a list of properties for a website.
  WebsiteSDTListByWebsiteId       Get a list of sdts for a website.
  WidgetById                      Get widget by id.
  WidgetDataById                  Get widget data.
  WidgetList                      Get widget list.
  WidgetListByDashboardId         Get widget list by dashboardid.

  default config file: /home/user/.elm/config.ini
```

### AdminById help

This is only one example, but other help messages are similar. The URL
will take you directly to the swagger document relating to that command.

```
$ ./elm AdminById --help
Usage: elm AdminById [OPTIONS]

  Get user.

  API Path:

  /setting/admins/{id}

  Swagger URL:

  https://www.logicmonitor.com/swagger-ui-master/dist/#/Users/getAdminById

Options:
  --id INTEGER               [required]
  -f, --fields FIELD,...     Only include the listed fields.
  -S, --sort [+,-]FIELD,...  Sort by field; inc (+), dec (-)
  -c, --count                Return count of objects instead of data.
  -C, --total                Return qty of all objects instead of data.
  --help                     Show this message and exit.
```

## Contributing

[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg)](code_of_conduct.md)

If you'd like to contribute, please fork the repository and use a feature
branch. Pull requests are welcome.

Please note that this project is released with a Contributor Code of
Conduct. By participating in this project you agree to abide by its
terms. See `CODE_OF_CONDUCT.md`

## Links

- Project homepage: https://github.com/rdmarsh/elm
- Repository: https://github.com/rdmarsh/elm
- Issue tracker: https://github.com/rdmarsh/elm/issues
    - In case of sensitive bugs like security vulnerabilities, please contact
      rdmarsh@gmail.com directly instead of using issue tracker. We value your effort
      to improve the security and privacy of this project!
- Related projects:
    - https://www.logicmonitor.com/support/rest-api-developers-guide/v2/rest-api-v2-overview
    - https://www.logicmonitor.com/support/ansible-integration
    - https://docs.ansible.com/ansible/2.9/modules/logicmonitor_module.html

## Licensing

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

