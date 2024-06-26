# Examples

The following are useful examples that show you how to get started.

For more complex use, see the scripts in [examples](examples) dir.

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
   * [Filter by customProperties, systemProperties, autoProperties etc](#filter-by-customproperties-systemproperties-autoproperties-etc)
   * [Find all the values for a custom property](#find-all-the-values-for-a-custom-property)
   * [Find all the devices belonging to a static group](#find-all-the-devices-belonging-to-a-static-group)
   * [Find all the devices belonging to a dynamic group](#find-all-the-devices-belonging-to-a-dynamic-group)
   * [Find all groups that have a customProperty set](#find-all-groups-that-have-a-customproperty-set)
   * [List collector build versions](#list-collector-build-versions)
   * [Find long SDTs](#find-long-sdts)
   * [Find non-auto balanced devices on a collector](#find-non-auto-balanced-devices-on-a-collector)
   * [Compare devices in two groups](#compare-devices-in-two-groups)
   * [Find Collector Groups that have more than 1 collector but not autobalanced](#find-collector-groups-that-have-more-than-1-collector-but-not-autobalanced)
   * [Dashboards](#dashboards)
      * [Find Dashboards that match a defaultResourceGroup](#find-dashboards-that-match-a-defaultresourcegroup)
   * [Reports](#reports)
      * [Find Reports that match a hostsVal](#find-reports-that-match-a-hostsval)
   * [meta](#meta)

<!-- Created by https://github.com/ekalinin/github-markdown-toc -->
<!-- Added by: davidmarsh, at: Fri 26 Apr 2024 15:08:36 AEST -->

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
./elm DeviceList -s1
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
./elm DatasourceById --id 12345678 | \
jinja2 /path/datasource.jira.j2 - | \
pbcopy
```

## Find all hosts in a group by name

This will show all hosts name and display name in the group "Linux Devices":

```shell
gid=$(./elm DeviceGroupList -f id -F name:"Linux Devices" | \
jq -r '.DeviceGroupList[].id')

./elm DeviceList -s0 -f name,displayName -F hostGroupIds~${gid} | \
jq -r '.DeviceList[] | [.name, .displayName] | @csv'
```

In one line:

```shell
./elm DeviceList -s0 -f name,displayName -F hostGroupIds~$(./elm DeviceGroupList -f id -F name:"Linux Devices" | \
jq -r '.DeviceGroupList[].id') | jq -r '.DeviceList[] | [.name, .displayName] | @csv'
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

## Filter by customProperties, systemProperties, autoProperties etc

If you want to filter the device list by customProperties,
systemProperties, autoProperties etc, filter by X.name and X.value like so:

```shell
./elm DeviceList -f customProperties -F customProperties.name:customer.name,customProperties.value:customerA
```

For caveats, see the comments by [David Bond] on this post: [Get LM DeviceGroup Properties REST API]

> "There is no way to effectively filter by effective property"

## Find all the values for a custom property

If you want to find all the values where the custom property name
matches (eg) "wmi.user". This pipes the output to jq which then selects
only the matching name and returns it's value from the json output:

On an group level:

```shell
./elm -f json DeviceGroupList -F customProperties.name:wmi.user -f customProperties | \
jq -r '.DeviceGroupList[].customProperties[] | select(.name=="wmi.user") | .value' | \
sort -u
```

Same as above, but for all indidual devices:

```shell
./elm -f json DeviceList -F customProperties.name:wmi.user -f customProperties | \
jq -r '.DeviceList[].customProperties[] | select(.name=="wmi.user") | .value' | \
sort -u
```

Another similar way to do this, but also print the device `name` and
`displayName` along with the value of a customProperty (in this case
"snmp.security").

The example will find all devices where displayName contains "foo"
and has the "snmp.security" custom property key set, and then output
the "name", "displayName" and the associated custom property value,
outputing it as a tsv seperated values. The tab values are then swapped
for commas before passing to the unix commands `sort` and `column`.

```shell
./elm -f json DeviceList -F displayName~foo,customProperties.name:snmp.security -f name,displayName,customProperties -s0 | \
jq -r --arg name "snmp.security" '.DeviceList[] | .customProperties[] as $custom | select($custom.name==$name) | [.displayName, .name, $custom.value] | @tsv | gsub("\\t";",")' | \
sort | \
column -t -s,
```

Same as above, but for all groups:

```shell
elm -f json DeviceGroupList -F customProperties.name:foo.bar -f name,customProperties -s0 | jq -r --arg name "foo.bar" '.DeviceGroupList[] | .customProperties[] as $custom | select($custom.name==$name) | [.displayName, .name, $custom.value] | @tsv | gsub("\\t";",")' | sort | column -t -s,
```

## Find all the devices belonging to a static group

Like the custom property above, this solution uses jq to filter the
results:

```shell
./elm -f json DeviceList -F systemProperties.name:system.staticgroups,systemProperties.value\~"Root/Group/Name/" -f name,displayName,systemProperties -s0 | \
jq -r --arg name "system.staticgroups" '.DeviceList[] | .systemProperties[] as $system | select($system.name==$name) | [.displayName, .name, $system.value] | @csv'
```

## Find all the devices belonging to a dynamic group

```shell
./elm -f json DeviceList -F systemProperties.name:system.groups,systemProperties.value\~"Root/Group/Name/" -f name,displayName,systemProperties -s0 | \
jq -r --arg name "system.groups" '.DeviceList[] | .systemProperties[] as $system | select($system.name==$name) | [.displayName, .name, $system.value] | @csv'
```

## Find all groups that have a customProperty set

Like the custom property above, this solution uses jq to filter the
results:

```shell
elm -f json DeviceGroupList -F customProperties.name:ClientID -f name,fullPath,customProperties -s0 | \
jq -r --arg name "ClientID" '.DeviceGroupList[] | .customProperties[] as $custom | select($custom.name==$name) | [.name, .fullPath, $custom.value] | @csv'
```

## List collector build versions

Show the collector build version and when it was last update; sorted by build number and updated time:

```shell
./elm CollectorList -f hostname,build,updatedOnLocal -S build,updatedOnLocal
```

## Find long SDTs

This will find SDTs that don't end for at least one year from the current time:

```shell
./elm SDTList -F endDateTime\>$(( ( $(date +'%s') + 31536000 ) * 1000 )) -f id,deviceGroupFullPath,deviceDisplayName,endDateTimeOnLocal,duration,admin,comment -S endDateTime -s0
```

## Find non-auto balanced devices on a collector

```shell
./elm DeviceList -f id,name,displayName,autoBalancedCollectorGroupId,collectorDescription -F collectorDescription\~"DESC_HERE",autoBalancedCollectorGroupId:0 -s0
```

## Compare devices in two groups

Find all the devices in two groups and then compare them, showing devices that aren't in both groups:

```shell
./elm -f txt -o group_a.txt DeviceList -F systemProperties.name:system.groups,systemProperties.value\~"Root/Group_A" -f displayName -S displayName -s0
./elm -f txt -o group_b.txt DeviceList -F systemProperties.name:system.groups,systemProperties.value\~"Root/Group_B" -f displayName -S displayName -s0
comm -3 group_a.txt group_b.txt
```

## Find Collector Groups that have more than 1 collector but not autobalanced

```shell
elm -f txt CollectorGroupList -F autoBalance:false,numOfCollectors\>1 -f autoBalance,name,numOfCollectors
```

## Dashboards

### Find Dashboards that match a defaultResourceGroup

This example will show dashboards that use "Root/Group" as their defaultResourceGroup:

```shell
elm -f txt DashboardList -s0 -F widgetTokens.name:defaultResourceGroup,widgetTokens.value\~Root/Group -f fullName
```

## Reports

### Find Reports that match a hostsVal

This example will show reports that use "Root/Group" as their hostsVal:

```shell
elm -f txt ReportList -s0 -F hostsVal\~Root/Group -f name
```

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --skip-header EXAMPLES.md
```

[David Bond]: https://community.logicmonitor.com/members/david-bond-6
[Get LM DeviceGroup Properties REST API]: https://community.logicmonitor.com/product-discussions-22/get-lm-devicegroup-properties-rest-api-1473?postid=8985#post8985)

