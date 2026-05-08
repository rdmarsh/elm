# General Examples

Quick-start examples covering basic elm usage, flags, output formats, and piping.
These apply across all commands and resource types.

**See also:**
- [devices.md](devices.md) for device-specific queries
- [users.md](users.md) for account and admin queries

<!--ts-->
   * [Get metrics](#get-metrics)
   * [Return just one result](#return-just-one-result)
   * [Use a different config file](#use-a-different-config-file)
   * [Use a filter with a space in the VALUE](#use-a-filter-with-a-space-in-the-value)
   * [Pipe stdout to another program](#pipe-stdout-to-another-program)
   * [Write data to a file](#write-data-to-a-file)
   * [Add header and footer custom text](#add-header-and-footer-custom-text)
   * [meta](#meta)

<!-- Created by https://github.com/ekalinin/github-markdown-toc -->

<!--te-->

## Get metrics

A simple query to get usage metrics and show them in formatted json:

```shell
elm -f prettyjson MetricsUsage
```

```json
{
  "MetricsUsage": [
    {
      "numOfAWSDevices": 16,
      "numOfAzureDevices": 6,
      "numOfCombinedAWSDevices": 8,
      "numOfCombinedAzureDevices": 12,
      "numOfCombinedGcpDevices": 0,
      "numOfConfigSourceDevices": 0,
      "numOfGcpDevices": 0,
      "numOfServices": 0,
      "numOfStoppedAWSDevices": 10,
      "numOfStoppedAzureDevices": 0,
      "numOfStoppedGcpDevices": 0,
      "numOfTerminatedAWSDevices": 6,
      "numOfTerminatedAzureDevices": 0,
      "numOfTerminatedGcpCloudDevices": 0,
      "numOfWebsites": 3,
      "numberOfDevices": 126,
      "numberOfKubernetesDevices": 148,
      "numberOfStandardDevices": 106
    }
  ]
}
```

## Return just one result

Use the `-s` flag to limit the results returned:

```shell
elm DeviceList -s1
```

> note: setting size to 0 will return all results (up to 1000)

## Use a different config file

You can have more than one config file. This is handy if you have
multiple API keys or accounts and want to switch between them:

```shell
elm --config ~/.config/logicmonitor/credentials/dev.ini MetricsUsage
```

## Use a filter with a space in the VALUE

To use space in the VALUE of a filter, you will have to quote the VALUE:

```shell
elm DeviceGroupList -f id,name,description -F name:"group with space"
```

## Pipe stdout to another program

You can pipe the data to other programs using standard unix pipes.
STDOUT is the default option. This example shows passing the data into
jinja:

```shell
elm DatasourceById --id 12345678 | \
jinja2 /path/datasource.jira.j2 - | \
pbcopy
```

## Write data to a file

```shell
elm -o filename MetricsUsage
```

## Add header and footer custom text

Useful for adding a warning to the top of text that the data is
automatically generated, and adding a datestamp to the footer. Works
with any output format. The example below is in jira markup:

```shell
elm --head "{warning}This information is automatically generated. Changes may be overwritten!{warning}" --foot "_above extracted at $(date "+%Y-%m-%d %H:%M")_" --format jira MetricsUsage
```

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --skip-header examples/general.md
```
