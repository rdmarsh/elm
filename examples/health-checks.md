# Health and Security Check Examples

Quick one-liners for spotting common operational and security issues.

**See also:**
- [users.md](users.md) for API token audits and offboarding
- [alerts.md](alerts.md) for alert counts by severity

<!--ts-->
   * [Find devices with a specific credential/property value](#find-devices-with-a-specific-credentialproperty-value)
   * [Audit active API tokens](#audit-active-api-tokens)
   * [Find failed API requests in the audit log](#find-failed-api-requests-in-the-audit-log)
   * [Active SDTs right now](#active-sdts-right-now)
   * [API tokens never used](#api-tokens-never-used)
   * [Devices with alerting disabled](#devices-with-alerting-disabled)
   * [meta](#meta)
<!--te-->

## Find devices with a specific credential/property value

```shell
elm DeviceList -s0 -f displayName,customProperties  -F customProperties.value:YOUR_VALUE_HERE
elm DeviceList -s0 -f displayName,systemProperties  -F systemProperties.value:YOUR_VALUE_HERE
elm DeviceList -s0 -f displayName,autoProperties    -F autoProperties.value:YOUR_VALUE_HERE
```

## Audit active API tokens

```shell
elm -f csv AdminList -s0 -f username,firstName,lastName -F apiTokens.status:2
```

## Find failed API requests in the audit log


```shell
elm AuditLogList -s0 -F description~"Failed API request" -f username,ip,description,happenedOnLocal
```

Use the precise filter `description~"Failed API request"` — not just `description~Failed`, which matches datasource names containing the word "Failed".

AuditLogList is newest first, 1000 records per page; page back with `-o` or filter on `happenedOn`. Fields: `id`, `username`, `ip`, `description`, `happenedOn`, `happenedOnLocal`.

A token appearing repeatedly at a regular interval (e.g. every hour) from the same IP is a scheduled job with a broken or deleted credential. The `username` field is the `access_id` value verbatim — cross-reference with `ApiTokenList` to check if it still exists.

## Active SDTs right now

```shell
elm SDTList -s0 -F isEffective:true -f type,deviceDisplayName,startDateTime,endDateTime,comment
```

Watch for entries with `endDateTime` years in the future — these are "park it and forget it" SDTs that silently suppress alerting.

## API tokens never used

```shell
elm ApiTokenList -s0 -F lastUsedOn:0 -f id,adminName,note,createdOn,status
```

`lastUsedOn: 0` means the token was created but has never authenticated. Old never-used tokens with no `note` are good candidates for revocation.

## Devices with alerting disabled

A device's alerts can be off because of its own setting, or because a group it
is in (or a parent of that group) has alerting disabled. Checking only the
device's own `disableAlerting` misses the second, which is usually most of them
(on one portal: 39 devices by their own setting, 744 in total).

`alertDisableStatus` shows both, as `<group>-<device>-<instance>` with each part
`disable` or `none` (verified 2026-09-17: the middle part matches
`disableAlerting` exactly). It cannot be filtered server-side
(`-F alertDisableStatus~disable` returns nothing), so fetch every device and
filter with jq, paging past 1000:

```shell
total=$(elm DeviceList -C)
for ((o=0; o<total; o+=1000)); do
  elm -f jsonl DeviceList -s0 -o $o -f id,displayName,disableAlerting,alertDisableStatus
done | jq -r '(.alertDisableStatus | split("-")) as $p
  | select($p[0] == "disable" or $p[1] == "disable")
  | [.displayName, .alertDisableStatus] | @tsv'
```

Only the device's own setting, and the groups that disable it for their members:

```shell
elm DeviceList -s0 -F disableAlerting:true -f id,displayName
elm DeviceGroupList -s0 -F disableAlerting:true -f id,fullPath
```

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --hide-footer --skip-header examples/health-checks.md
```
