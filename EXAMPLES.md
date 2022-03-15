# Examples

The following are useful examples that show you how to get started:

<!--ts-->
* [Get metrics](#get-metrics)
* [Return just one result](#return-just-one-result)
* [Export users by userid](#export-users-by-userid)
* [Use a different config file](#use-a-different-config-file)
* [Use a filter with a space in the VALUE](#use-a-filter-with-a-space-in-the-value)
* [Pipe stdout to another program](#pipe-stdout-to-another-program)
* [Find all hosts in a group by name](#find-all-hosts-in-a-group-by-name)
* [Write data to a file](#write-data-to-a-file)
* [Hostgroup and Collector Group don't match](#hostgroup-and-collector-group-dont-match)
* [Add header and footer custom text](#add-header-and-footer-custom-text)
<!--te-->

## Get metrics

A simple query to get usage metrics and show them in formatted json:

```shell
./elm -f prettyjson MetricsUsage
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
./elm DeviceList -s 1
```

> note: setting size to 0 will return all results (up to 1000)

## Export users by userid

Show the id and username for users with id between 2 and 5, sort by
reverse username, and put in csv format:

```shell
./elm -f csv AdminList -f id,username -S -username -F id\>:2,id\<:5
```

## Use a different config file

You can have more than one config file. This is handy if you have
multiple API keys or accounts and want to switch between them:

```shell
./elm --config ~/.elm/dev.ini MetricsUsage
```

## Use a filter with a space in the VALUE

To use space in the VALUE of a filter, you will have to quote the VALUE:

```shell
./elm DeviceGroupList -f id,name,description -F name:"group with space"
```

## Pipe stdout to another program

You can pipe the data to other programs using standard unix pipes.
STDOUT is the default option. This example shows passing the data into
jinja:

```shell
./elm DatasourceById --id 12345678 | jinja2 /path/datasource.jira.j2 - | pbcopy
```

## Find all hosts in a group by name

This will show all hosts name and display name in the group "Linux Devices":

```shell
gid=$(./elm DeviceGroupList -f id -F name:"Linux Devices" | jq -r '.DeviceGroupList[].id')
./elm DeviceList -s 0 -f name,displayName -F hostGroupIds~${gid} | jq -r '.DeviceList[] | [.name, .displayName] | @csv'
```

In one line:

```shell
./elm DeviceList -s 0 -f name,displayName -F hostGroupIds~$(./elm DeviceGroupList -f id -F name:"Linux Devices" | jq -r '.DeviceGroupList[].id') | jq -r '.DeviceList[] | [.name, .displayName] | @csv'
```

## Write data to a file

```shell
./elm -o filename MetricsUsage
```

## Hostgroup and Collector Group don't match

Useful for matching hosts to collector groups. Assumes you use a similar
naming pattern for both hosts and collector groups (eg foo)

Note: the "!" has to be escaped to stop bash interperating it

```shell
./elm DeviceList -f name,displayName,preferredCollectorGroupName -F displayName~foo,preferredCollectorGroupName\!~foo
```

## Add header and footer custom text

Useful for adding a warning to the top of text that the data is
automatically generated, and adding a datestamp to the footer. The
example below is in jira markup:

```shell
./elm --head "{warning}This information is automatically generated. Changes may be overwritten!{warning}" --foot "_above extracted at $(date "+%Y-%m-%d %H:%M")_" --format jira MetricsUsage
```
