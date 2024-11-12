# elm

[![CodeQL](https://github.com/rdmarsh/elm/actions/workflows/github-code-scanning/codeql/badge.svg)](https://github.com/rdmarsh/elm/actions/workflows/github-code-scanning/codeql)
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
      * [Makefile Help](#makefile-help)
   * [Configuration](#configuration)
      * [Shell Completion](#shell-completion)
   * [Usage](#usage)
      * [Format](#format)
      * [General Help](#general-help)
      * [AdminById help](#adminbyid-help)
   * [Examples](#examples)
   * [Errors](#errors)
   * [Contributing](#contributing)
   * [Links](#links)
   * [Licensing](#licensing)
   * [meta](#meta)

<!-- Created by https://github.com/ekalinin/github-markdown-toc -->
<!-- Added by: davidmarsh, at: Tue 12 Nov 2024 12:52:02 AEDT -->

<!--te-->

## Features

* Retrieve data from LogicMonitor via the API
* Output in multiple formats: CSV, HTML, JSON, XML, Markdown, and more

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
cp ~/.elm/config.example.ini ~/.elm/config.ini
vi ~/.elm/config.ini
```

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
make clean && make && make install && cp -r _dist/elm/* ~/bin && echo done
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
* (optional) a config file with the API info (default to `~/.elm/config.ini`)
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

Make any changes to the `Makefile` or templates in the `_jinja/`       .
directory Files in `_cmds` and `_defs` may be overwritten during builds.

### Makefile Help

Use the following command to see available options for the `Makefile`:

```text
Usage: make [flags] [option]
  make all           Build everything except install (init, cmds, cfg)
  make init          Check prerequisites, initialise dirs, get swagger file, create definition files
  make cfg           Create config dir, copy example file and set permissions of all config files
  make cmds          Make python commands from templates and install requirements
  make install       (Re)installs the script so it's available in the path
  make reqs          Install python requirements
  make upgrade       Upgrade pip
  make test          Run quick and simple tests
  make testlong      Tests that take a long time to complete
  make testbasic     Test basic flags
  make testtext      Test commands that alter columns, indices, header and footer
  make testhelp      Test all commands with help flag
  make testid        Test a command with an id flag                (connects to LM)
  make testcount     Test 'non-required' commands with count flag  (connects to LM)
  make testtotal     Test 'non-required' commands with total flag  (connects to LM)
  make testfmts      Test a command with all formats               (connects to LM)
  make testH         Test a command and hide headers               (connects to LM)
  make testI         Test a command and show index                 (connects to LM)
  make testHI        Test a command, hide headers and show index   (connects to LM)
  make testhead      Test a command, custom header text            (connects to LM)
  make testfoot      Test a command, custom footer text            (connects to LM)
  make testheadfoot  Test a command, custom header and footer text (connects to LM)
  make testverb      Test the verbose flags                        (connects to LM)
  make fail          A failing test
  make back          TAR and backup (eg ../name_backup/name.YYYY-MM-DD.tar.gz)
  make clean         Remove generated files
  make nomac         Remove unneeded mac files
  make about         About this Makefile
  make copying       Copyright notice
  make help          Show this help

Useful make flags:
  make -n   : dry run
  make -j   : run simultaneous jobs
  make -B   : force make target

You can override Makefile vars like so:
  make apiversion=2
```

## Configuration

For quick setup, place your credentials in `~/.elm/config.ini` and
secure permissions. See `config.example.ini` for details.

You don't need a config file, but to prevent passing API details on the
command line (and hide them from a process list) you can create a file
in (by default) `~/.elm/config.ini` with the following contents:

```ini
access_id = '12345678901234567890'
access_key = '1234567890123456789123456789012345678901'
account_name = 'example'
```

Config files use unrepr format:
https://configobj.readthedocs.io/en/latest/configobj.html#unrepr-mode

You can set any cli option in the config file, but the above are the
three most useful

The `Makefile` should have created this dir and placed an example config
file in it for you:

`~./elm/config.example.ini`

Ensure the permissions for the dir and file are readable only by your
account. Again the `Makefile` should have done this for you. You can
force it to re-run with `make -B cfg`

```shell
mkdir -p ~/.elm
chmod 700 ~/.elm
chmod 600 ~/.elm/*
chown $(id -u):$(id -g) ~/.elm
```
### Shell Completion

To enable shell completion, do the following:

```shell
mkdir -p ~/.elm
cp .elm-complete.bash ~/.elm
echo '. ~/.elm/.elm-complete.bash' >> ~/.bashrc
```

Start a new shell to apply changes. More
information is available in the [shell completion
documentation](https://click.palletsprojects.com/en/8.1.x/shell-completion/)

## Usage

`Usage: elm [OPTIONS] COMMAND [ARGS]...`

* OPTIONS: Options that set access id, key account name, proxy, format and output file
* COMMAND: Command relates to the LogicMonitor operation
* ARGS: Args set flags that relate to the command data, such as
  setting filters, sorting, choosing fields etc

Quickest way to understand how to run is to look at
[EXAMPLES.md](EXAMPLES.md). Common errors are show in
[ERRORS.md](ERRORS.md)

### Format

These format options are available:

| format     | result                                    |
| ---        | ---                                       |
| csv        | comma-separated values                    |
| html       | html table                                |
| prettyhtml | html table with human readable formatting |
| jira       | jira / confluence                         |
| json       | json                                      |
| prettyjson | json with human readable formatting       |
| xml        | xml                                       |
| latex      | latex table                               |
| md         | markdown table                            |
| rst        | reStructuredText table                    |
| tab        | text table                                |
| raw        | python dict                               |
| txt        | pandas text                               |
| api        | just show the encoded url of the api call |

### General Help

To view help `elm --help`

Specific help for commands can be accessed using: `elm COMMAND --help`
(see [AdminById help](#adminbyid-help) below)

```text
Usage: elm [OPTIONS] COMMAND [ARGS]...

  Extract LogicMonitor

Options:
  --config FILE                   Read configuration from FILE.
  -i, --access_id TEXT            API token access id
  -k, --access_key TEXT           API token access key
  -a, --account_name TEXT         LogicMonitor account (company) name
  -s, --proxy <HOST PORT>         Socks5 proxy address and port
  -f, --format [csv|html|prettyhtml|jira|json|prettyjson|xml|latex|md|rst|tab|raw|txt|api]
                                  Format of data  [default: json]
  -H, --noheaders                 Hide the column headers  [default: False]
  -I, --index                     Show the row indices  [default: False]
  -o, --filename FILE             Output to file name  [default: -]
  --head TEXT                     Text to prepend before the output
  --foot TEXT                     Text to append after the output
  -v, --verbose                   Be more verbose, -v is INFO, -vv is DEBUG
  -x, --export FILENAME           Export the query to FILENAME
  --halt-on-api-error             Halt on API response errors
  --version                       Show the version and exit.
  --help                          Show this message and exit.

Commands:
  AdminById                       Get user
  AdminList                       Get user list
  AlertById                       Get alert
  AlertList                       Get alert list
  AlertListByDeviceGroupId        Get device group alerts
  AlertListByDeviceId             Get alerts
  AlertRuleById                   Get alert rule by id
  AlertRuleList                   Get alert rule list
  AllSDTListByDeviceId            Get sdts for a device
  AllSDTListByWebsiteGroupId      Get a list of sdts for a website group
  ApiTokenList                    Get a list of api tokens across users
  ApiTokenListByAdminId           Get api tokens for a user
  AppliesToFunctionById           Get applies to function
  AppliesToFunctionList           Get applies to function list
  AssociatedDeviceListByDataSourceId
                                  Get devices associated with a datasource
  AuditLogById                    Get audit log by id
  AuditLogList                    Get audit logs
  AwsExternalId                   Get aws external id
  CollectorById                   Get collector
  CollectorGroupById              Get collector group
  CollectorGroupList              Get collector group list
  CollectorInstaller              Get collector installer
  CollectorList                   Get collector list
  CollectorVersionList            Get collector version list
  DashboardById                   Get dashboard
  DashboardGroupById              Get dashboard group
  DashboardGroupList              Get dashboard group list
  DashboardList                   Get dashboard list
  DataSourceOverviewGraphById     Get datasource overview graph by id
  DataSourceOverviewGraphList     Get datasource overview graph list
  DatasourceById                  Get datasource by id
  DatasourceList                  Get datasource list
  DebugCommandResult              Get the result of a collector debug command
  DeviceById                      Get device by id
  DeviceConfigSourceConfig        Collect a config for a device
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
  EscalationChainById             Get escalation chain by id
  EscalationChainList             Get escalation chain list
  EventSourceList                 Get eventsource list
  ExternalApiStats                Get external api stats info
  ImmediateDeviceListByDeviceGroupId
                                  Get immediate devices under group
  ImmediateWebsiteListByWebsiteGroupId
                                  Get a list of websites for a group
  MetricsUsage                    Get metrics usage
  NetflowEndpointList             Get netflow endpoint list
  NetflowFlowList                 Get netflow flow list
  NetflowPortList                 Get netflow port list
  NetscanById                     Get netscan by id
  NetscanList                     Get netscan list
  OpsNoteById                     Get opsnote by id
  OpsNoteList                     Get opsnote list
  RecipientGroupById              Get recipient group by id
  RecipientGroupList              Get recipient group list
  ReportById                      Get report by id
  ReportGroupById                 Get report group by id
  ReportGroupList                 Get report group list
  ReportList                      Get report list
  RoleById                        Get role by id
  RoleList                        Get role list
  SDTById                         Get sdt by id
  SDTHistoryByDeviceDataSourceId  Get sdt history for the device datasource
  SDTHistoryByDeviceGroupId       Get sdt history for the group
  SDTHistoryByDeviceId            Get sdt history for the device
  SDTHistoryByWebsiteGroupId      Get sdt history for the website group
  SDTHistoryByWebsiteId           Get sdt history for the website
  SDTList                         Get sdt list
  SiteMonitorCheckPointList       Get website checkpoint list
  TopTalkersGraph                 Get top talkers graph
  UnmonitoredDeviceList           Get unmonitored device list
  UpdateReasonListByDataSourceId  Get update history for a datasource
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
  WidgetDataById                  Get widget data
  WidgetList                      Get widget list
  WidgetListByDashboardId         Get widget list by dashboardid

  default config file: /home/user/.elm/config.ini
```

### AdminById help

This is only one example, but other help messages are similar. The URL
will take you directly to the swagger document relating to that command

`./elm AdminById --help`

```text
Usage: elm AdminById [OPTIONS]

  Get user

  API Path:

  /setting/admins/{id}

  Swagger URL:

  https://www.logicmonitor.com/swagger-ui-master/dist/#/Users/getAdminById

Options:
  --id INTEGER               [required]
  -f, --fields FIELD,...     Only include the listed fields
  -S, --sort [+,-]FIELD,...  Sort by field; inc (+), dec (-)
  -c, --count                Return qty of query objects instead of query data
  -C, --total                Return qty of ALL objects instead of query data
  --help                     Show this message and exit.
```

## Examples

See [EXAMPLES.md](EXAMPLES.md)

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
along with this program. If not, see <https://www.gnu.org/licenses/>

Note: LOGICMONITOR is a trademark of LogicMonitor, Inc. and not
affiliated with this project

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --skip-header README.md
```

[githubs vulnerablity reporting function]: https://github.com/rdmarsh/elm/security

