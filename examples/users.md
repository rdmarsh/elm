# User Account Examples

Queries relating to user accounts, API tokens, roles, and offboarding.

**See also:**
- [devices.md](devices.md) for finding devices created by a specific user
- [collectors.md](collectors.md) for finding collectors registered by a specific user

<!--ts-->
   * [Export users by userid](#export-users-by-userid)
   * [Find a user account and check its status](#find-a-user-account-and-check-its-status)
   * [Audit all active API tokens](#audit-all-active-api-tokens)
   * [Offboarding checks — collectors, devices, and API tokens](#offboarding-checks--collectors-devices-and-api-tokens)
   * [meta](#meta)
<!--te-->

## Export users by userid

Show the id and username for users with id between 2 and 5, sort by
reverse username, and put in csv format:

```shell
elm -f csv AdminList -f id,username -S -username -F id\>:2,id\<:5
```

## Find a user account and check its status

Useful when a staff member leaves — check whether their account is suspended,
what roles they hold, and whether they have active API tokens or collectors.

```shell
# Find the account and check status
elm AdminList -s0 -f id,username,firstName,lastName,status,twoFAEnabled | \
  jq '.AdminList[] | select((.firstName + " " + .lastName) | ascii_downcase | contains("acme user"))'
```

Compare against a known-active account to confirm which fields indicate suspension:

```shell
elm AdminList -s0 -f id,username,firstName,lastName,status,twoFAEnabled | \
  jq '.AdminList[] | select(.username == "active.user@acme.com" or .username == "departed.user@acme.com")'
```

## Audit all active API tokens

Find every user who has an active API token — useful as a periodic security
check, especially after staff turnover.

`apiTokens.status` filters natively: `2` = active, `1` = disabled.
This covers both LMv1 keys and bearer tokens — the `type` field distinguishes
them, not the status:

```shell
elm -f csv AdminList -s0 -f username,firstName,lastName -F apiTokens.status:2
```

## Offboarding checks — collectors, devices, and API tokens

After locating the user record above, check for resources they own.

Check for collectors registered by the user:

```shell
elm CollectorList -s0 -f id,hostname,description,createdBy | \
  jq '.CollectorList[] | select((.createdBy // "") | ascii_downcase | contains("acme user"))'
```

Check for devices created by the user:

```shell
elm DeviceList -s0 -f id,displayName,createdBy -F createdBy~"acme user" | \
  jq '.DeviceList[]'
```

The `apiTokens` field on the admin record will be an empty array if none exist.
A suspended account with no API tokens, collectors, or devices is fully offboarded.

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --hide-footer --skip-header examples/users.md
```
