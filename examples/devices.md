# Device Examples

Queries relating to devices, device groups, and device properties.
Includes filtering by OS type, custom/system properties, and group membership.

**See also:**
- [collectors.md](collectors.md) for collector assignment and auto-balance queries
- [datasources.md](datasources.md) for datasource coverage across devices
- [alerts.md](alerts.md) for device alert and SDT queries
- [users.md](users.md) for finding devices created by a specific user

<!--ts-->
   * [Find all hosts in a group by name](#find-all-hosts-in-a-group-by-name)
   * [Find Linux devices by OS](#find-linux-devices-by-os)
   * [Hostgroup and Collector Group don't match](#hostgroup-and-collector-group-dont-match)
   * [Filter by customProperties, systemProperties, autoProperties etc](#filter-by-customproperties-systemproperties-autoproperties-etc)
   * [Find all the values for a custom property](#find-all-the-values-for-a-custom-property)
   * [Find all the devices belonging to a static group](#find-all-the-devices-belonging-to-a-static-group)
   * [Find all the devices belonging to a dynamic group](#find-all-the-devices-belonging-to-a-dynamic-group)
   * [Find all groups that have a customProperty set](#find-all-groups-that-have-a-customproperty-set)
   * [Compare devices in two groups](#compare-devices-in-two-groups)
   * [Find dead devices](#find-dead-devices)
   * [Find orphaned device groups](#find-orphaned-device-groups)
   * [Find devices with a specific property value](#find-devices-with-a-specific-property-value)
   * [Scripts](#scripts)
   * [meta](#meta)

<!-- Created by https://github.com/ekalinin/github-markdown-toc -->

<!--te-->

## Find all hosts in a group by name

This will show all hosts name and display name in the group "Linux Devices":

```shell
gid=$(elm DeviceGroupList -f id -F name:"Linux Devices" | \
jq -r '.DeviceGroupList[].id')

elm DeviceList -s0 -f name,displayName -F hostGroupIds~${gid} | \
jq -r '.DeviceList[] | [.name, .displayName] | @csv'
```

In one line:

```shell
elm DeviceList -s0 -f name,displayName -F hostGroupIds~$(elm DeviceGroupList -f id -F name:"Linux Devices" | \
jq -r '.DeviceGroupList[].id') | jq -r '.DeviceList[] | [.name, .displayName] | @csv'
```

## Find Linux devices by OS

Device groups (e.g. "Linux Servers") often contain non-Linux devices.
Use `system.sysinfo` to reliably scope to Linux devices:

```shell
elm DeviceList -s0 -f id,displayName -F systemProperties.name:system.sysinfo,systemProperties.value~Linux | \
  jq -r '.DeviceList[].displayName' | sort
```

## Hostgroup and Collector Group don't match

Useful for matching hosts to collector groups. Assumes you use a similar
naming pattern for both hosts and collector groups (eg foo).

Note: the "!" has to be escaped to stop bash interpreting it

```shell
elm DeviceList -f name,displayName,preferredCollectorGroupName -F displayName~foo,preferredCollectorGroupName\!~foo
```

## Filter by customProperties, systemProperties, autoProperties etc

If you want to filter the device list by customProperties,
systemProperties, autoProperties etc, filter by X.name and X.value like so:

```shell
elm DeviceList -f customProperties -F customProperties.name:customer.name,customProperties.value:customerA
```

For caveats, see the comments by [David Bond] on this post: [Get LM DeviceGroup Properties REST API]

> "There is no way to effectively filter by effective property"

## Find all the values for a custom property

If you want to find all the values where the custom property name
matches (eg) "wmi.user". This pipes the output to jq which then selects
only the matching name and returns it's value from the json output:

On an group level:

```shell
elm -f json DeviceGroupList -F customProperties.name:wmi.user -f customProperties | \
jq -r '.DeviceGroupList[].customProperties[] | select(.name=="wmi.user") | .value' | \
sort -u
```

Same as above, but for all individual devices:

```shell
elm -f json DeviceList -F customProperties.name:wmi.user -f customProperties | \
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
elm -f json DeviceList -F displayName~foo,customProperties.name:snmp.security -f name,displayName,customProperties -s0 | \
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
elm -f json DeviceList -F systemProperties.name:system.staticgroups,systemProperties.value\~"Root/Group/Name/" -f name,displayName,systemProperties -s0 | \
jq -r --arg name "system.staticgroups" '.DeviceList[] | .systemProperties[] as $system | select($system.name==$name) | [.displayName, .name, $system.value] | @csv'
```

## Find all the devices belonging to a dynamic group

```shell
elm -f json DeviceList -F systemProperties.name:system.groups,systemProperties.value\~"Root/Group/Name/" -f name,displayName,systemProperties -s0 | \
jq -r --arg name "system.groups" '.DeviceList[] | .systemProperties[] as $system | select($system.name==$name) | [.displayName, .name, $system.value] | @csv'
```

## Find all groups that have a customProperty set

Like the custom property above, this solution uses jq to filter the
results:

```shell
elm -f json DeviceGroupList -F customProperties.name:ClientID -f name,fullPath,customProperties -s0 | \
jq -r --arg name "ClientID" '.DeviceGroupList[] | .customProperties[] as $custom | select($custom.name==$name) | [.name, .fullPath, $custom.value] | @csv'
```

## Compare devices in two groups

Find all the devices in two groups and then compare them, showing devices that aren't in both groups:

```shell
elm -f txt -o group_a.txt DeviceList -F systemProperties.name:system.groups,systemProperties.value\~"Root/Group_A" -f displayName -S displayName -s0
elm -f txt -o group_b.txt DeviceList -F systemProperties.name:system.groups,systemProperties.value\~"Root/Group_B" -f displayName -S displayName -s0
comm -3 group_a.txt group_b.txt
```

## Find dead devices

Find devices that LM considers dead (no data received from the collector).
Useful for identifying stale resources to investigate or remove:

```shell
elm -f csv DeviceList -s0 -f displayName,hostStatus,collectorDescription -F hostStatus:dead
```

## Find orphaned device groups

Groups with no devices — candidates for cleanup:

```shell
elm DeviceGroupList -s0 -f name,fullPath -F numOfHosts:0
```

## Find devices with a specific property value

Useful for tracking down where a credential, token, or config value is
configured across your estate — for example during a security audit or
after a credential rotation:

```shell
elm DeviceList -s0 -f displayName,customProperties -F customProperties.value:YOUR_VALUE_HERE
```

If you're not sure which property type it's stored under, check all three:

```shell
elm DeviceList -s0 -f displayName,customProperties  -F customProperties.value:YOUR_VALUE_HERE
elm DeviceList -s0 -f displayName,systemProperties  -F systemProperties.value:YOUR_VALUE_HERE
elm DeviceList -s0 -f displayName,autoProperties    -F autoProperties.value:YOUR_VALUE_HERE
```

## Scripts

For more complex device queries see the scripts in this directory:

- [fs_usage_root_pct_alertexpr.sh](fs_usage_root_pct_alertexpr.sh) — outputs a CSV list of the
  alertExpr used for PercentUsed of the root volume for all devices in a group

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --skip-header examples/devices.md
```

