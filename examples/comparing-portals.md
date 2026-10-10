# Comparing Portals

Keeping several LogicMonitor portals configured alike -- production,
pre-production, test, or one per customer -- and finding out which one is out
of step. Every command here is read-only.

All names below are placeholders: profiles `prod`, `preprod` and `test`,
accounts `acme`, `acmepreprod` and `acmetest`, people `@example.com`. The
tables are illustrations of the shape, not real output.

**See also:**
- [README: several portals at once](../README.md#several-portals-at-once) and
  [nested fields](../README.md#nested-fields--e-and-dotted--f) for the flags
- [tools/README: portal matrix](../tools/README.md#portal-matrix) for the
  table tool's options
- [compare-portals.sh](compare-portals.sh) builds a whole comparison page

<!--ts-->
   * [The pieces](#the-pieces)
   * [Before you start](#before-you-start)
   * [Quick checks with elm alone](#quick-checks-with-elm-alone)
   * [Reading a matrix](#reading-a-matrix)
   * [Account settings and contacts](#account-settings-and-contacts)
   * [Users, roles and access](#users-roles-and-access)
   * [Alerting](#alerting)
   * [Groups and properties](#groups-and-properties)
   * [Collectors](#collectors)
   * [LogicModules](#logicmodules)
   * [A whole page for a wiki](#a-whole-page-for-a-wiki)
   * [Scripting and scheduled checks](#scripting-and-scheduled-checks)
   * [Choosing keys and values](#choosing-keys-and-values)
   * [Caveats](#caveats)
   * [meta](#meta)
<!--te-->

## The pieces

| Piece | What it does |
|-------|--------------|
| `elm -p prod,preprod,test ...` | runs one query on each portal; the rows come back as one table with `profile` and `account_name` columns first |
| `elm -d` | keeps only the rows that are not identical on every portal |
| `elm -o FILE` | with several profiles, writes `<profile>-FILE` per portal |
| `elm -e FIELD` | one row per item of a list field (`contacts`, `privileges`, `customProperties`) |
| `-f a.b` | a dotted field name picks part of a nested field |
| `tools/portal-matrix.py` | pivots elm's rows into one row per item and one column per portal |

## Before you start

```shell
elm --list                     # the profiles you have; * is the default
elm -p prod,preprod,test PortalInfo -f companyDisplayName   # one call each: do they all work?
```

Every profile must allow the command (see `allowed_commands` in the README),
or nothing is sent to any of them. Each profile's API token sees only what its
role allows: two portals can look different because the tokens differ, not
the configuration.

## Quick checks with elm alone

How big is each portal? `-C` gives one total per portal:

```shell
elm -p prod,preprod,test -f csv DeviceList -C
```

```text
profile,account_name,total
prod,acme,1192
preprod,acmepreprod,1190
test,acmetest,87
```

Which roles are not on every portal? `-d` drops the rows they all share:

```shell
elm -p prod,preprod,test -d -f csv RoleList -s0 -f name
```

```text
profile,account_name,name
prod,acme,helpdesk
preprod,acmepreprod,helpdesk
```

`helpdesk` shows for prod and preprod, so test lacks it. A row shown for every
portal would mean its values differ. `-d` exits 0 when they all match, 1 when
something differs, 2 when it could not compare everything.

One file per portal, then a plain `diff`:

```shell
elm -p prod,preprod -f csv -o roles.csv RoleList -s0 -f name
diff prod-roles.csv preprod-roles.csv
```

## Reading a matrix

`tools/portal-matrix.py` reads elm's output on a pipe (jsonl, json or
prettyjson, so `-f` can be left out) and lays it out one column per portal:

```shell
elm -p prod,preprod,test RoleList -s0 -f name | tools/portal-matrix.py -k name -m
```

```text
| name          | prod | preprod | test | same |
| ------------- | :--: | :-----: | :--: | :--: |
| administrator |  ✓   |    ✓    |  ✓   |  ✓   |
| helpdesk      |  ✓   |    ✓    |  —   |  ✗   |
```

- `-k` names the field(s) that identify a row. ✓ means the portal has it, —
  that it does not.
- `-v FIELD` puts that field's value in each cell instead of a tick.
- `-d` shows only the rows that differ; `-m` keeps them all and adds `same`.
- `-c account_name` heads the columns with account names instead of profile
  names, for readers who know the portals that way.
- `--csv` for a spreadsheet; `--tick`, `--cross` and `--missing` change the
  marks. In a terminal the marks are coloured; piped or redirected they are
  plain.
- Without `-k`: when each portal returns one record, one row per field (see
  the next section); otherwise every field together identifies a row.

Use the matrix's `-d`, not elm's, in the same pipe: elm's `-d` drops the rows
a portal shares with all the others, and a portal left with nothing would
vanish from the table, hiding what it lacks.

## Account settings and contacts

Settings side by side. `PortalInfo` returns one record per portal, so without
`-k` there is one row per field:

```shell
elm -p prod,preprod,test PortalInfo -f timezone,tenantIdentifierPropertyName,email \
  | tools/portal-matrix.py -m
```

```text
| field                        | prod             | preprod          | test             | same |
| ---------------------------- | ---------------- | ---------------- | ---------------- | :--: |
| timezone                     | Australia/Sydney | Australia/Sydney | Australia/Sydney |  ✓   |
| tenantIdentifierPropertyName | company          | company          | customer         |  ✗   |
| email                        | ops@example.com  | ops@example.com  | ops@example.com  |  ✓   |
```

`elm PortalInfo --info` lists the other fields. Leave out the counts
(`numberOfDevices` and the like), the committed and limit figures (they follow
each contract) and the `disable...EpochTime` timers: they differ for reasons
that are not configuration.

All the account settings worth keeping alike -- two-factor, sessions, remote
session, scripts, token and user expiry, the tenant property, allowlists and
alert totals -- in one table, differences only:

```shell
settings=requireTwoFA,configurable2FAOptions,requireTwoFAForRemoteSession,\
sessionTimeoutInSeconds,allowConcurrentLogins,enableKeepMeSignedIn,keepMeSignedInConfigurableDays,\
enableRemoteSession,enableCollectorDebug,enableTestScript,enableScriptsInTextWidget,\
allowExecutionForDiagnosticSource,allowExecutionForRemediationSource,applyCspPolicyOnDashboard,\
allowSharedReports,tokenDisabledDays,userSuspendDays,timestampWindowOfApiUsersInSec,\
enableUserDetailsEmailNotification,tenantIdentifierPropertyName,enableUpdateOfTenantIdentifierProperty,\
accountDomainWhitelist,whiteList,alertTotalIncludeInAck,alertTotalIncludeInSdt,timezone

elm -p prod,preprod,test PortalInfo -f "$settings" | tools/portal-matrix.py -d
```

```text
| field                   | prod  | preprod | test  |
| ----------------------- | ----- | ------- | ----- |
| enableRemoteSession     | false | false   | true  |
| sessionTimeoutInSeconds | 14400 | 14400   | 86400 |
```

`configurable2FAOptions` is a list of options; the matrix sorts lists of plain
values, so the same options in another order count as the same.

Who are the portal contacts? Explode the list, key on the email:

```shell
elm -p prod,preprod,test -e contacts PortalInfo -f contacts \
  | tools/portal-matrix.py -k contacts.email -m
```

```text
| contacts.email   | prod | preprod | test | same |
| ---------------- | :--: | :-----: | :--: | :--: |
| joe@example.com  |  ✓   |    ✓    |  ✓   |  ✓   |
| fred@example.com |  ✓   |    —    |  ✓   |  ✗   |
```

Add `-v contacts.name,contacts.phone` to compare their details too. Contacts
are names, emails and phone numbers: keep the output where only the people who
may see them can read it.

## Users, roles and access

Users missing somewhere, or with a different status:

```shell
elm -p prod,preprod,test AdminList -s0 -f username,status \
  | tools/portal-matrix.py -k username -v status -d
```

Which roles each user has, per portal (one row per user and role):

```shell
elm -p prod,preprod,test -e roles AdminList -s0 -f username,roles.name \
  | tools/portal-matrix.py -k username,roles.name -d
```

Role privileges that differ: one row per role and object, the operation in
each cell. `objectId` is left out on purpose: for groups and dashboards it is
an id, different on every portal, and would make every row differ.

```shell
elm -p prod,preprod,test -e privileges RoleList -s0 \
    -f name,privileges.objectType,privileges.objectName,privileges.operation \
  | tools/portal-matrix.py -k name,privileges.objectType,privileges.objectName -v privileges.operation -d
```

```text
| name     | privileges.objectType | privileges.objectName | prod | preprod | test  |
| -------- | --------------------- | --------------------- | ---- | ------- | ----- |
| helpdesk | setting               | opsnote               | read | read    | write |
| helpdesk | host_group            | Linux Servers         | read | read    | —     |
```

User groups, and how many API tokens each portal has:

```shell
elm -p prod,preprod,test AdminGroupList -s0 -f name | tools/portal-matrix.py -k name -m
elm -p prod,preprod,test -f csv ApiTokenList -C
```

The same portal under two profiles, with tokens of different roles, shows what
each token can see:

```shell
elm -p acme_admin,acme_readonly -f csv RoleList -C
```

## Alerting

```shell
# escalation chains and recipient groups: which exist where
elm -p prod,preprod,test EscalationChainList -s0 -f name | tools/portal-matrix.py -k name -m
elm -p prod,preprod,test RecipientGroupList -s0 -f groupName | tools/portal-matrix.py -k groupName -m

# alert rules that differ in priority, level or escalation chain
# (escalatingChain is a nested record; the dotted name picks its name)
elm -p prod,preprod,test AlertRuleList -s0 -f name,priority,levelStr,escalatingChain.name \
  | tools/portal-matrix.py -k name -v priority,levelStr,escalatingChain.name -d

# integrations and their type
elm -p prod,preprod,test IntegrationList -s0 -f name,type | tools/portal-matrix.py -k name -v type -m
```

## Groups and properties

Device groups missing somewhere, or with a different AppliesTo. `fullPath` is
the key: names repeat under different parents.

```shell
elm -p prod,preprod,test DeviceGroupList -s0 -f fullPath,appliesTo \
  | tools/portal-matrix.py -k fullPath -v appliesTo -d
```

Custom properties on the root group (id 1), which every device inherits:

```shell
elm -p prod,preprod,test -e customProperties DeviceGroupById --id 1 -f customProperties \
  | tools/portal-matrix.py -k customProperties.name -v customProperties.value -m
```

LM masks secret values (`********`), so a secret shows as the same everywhere
even when it is not.

Dashboard, report and website groups:

```shell
elm -p prod,preprod,test DashboardGroupList -s0 -f fullPath | tools/portal-matrix.py -k fullPath -d
elm -p prod,preprod,test ReportGroupList -s0 -f name | tools/portal-matrix.py -k name -d
elm -p prod,preprod,test WebsiteGroupList -s0 -f fullPath | tools/portal-matrix.py -k fullPath -d
```

## Collectors

```shell
# collector groups: which exist where
elm -p prod,preprod,test CollectorGroupList -s0 -f name | tools/portal-matrix.py -k name -m

# which collector builds are running where (a tick: at least one collector on it)
elm -p prod,preprod,test CollectorList -s0 -f build | tools/portal-matrix.py -k build
```

Collectors themselves are usually different on each portal (one per site), so
compare their groups and builds rather than the collectors.

## LogicModules

Compare by `checksum`: it changes whenever the module's content does. `version`
is a timestamp, not a version number.

Which datasources are in use where, with how many instances each:
`PortalInfo`'s `numberOfInstancesPerDS` maps every datasource with instances
to its count, so one call per portal covers them all. Exploding it gives one
row per datasource:

```shell
elm -p prod,preprod,test -e numberOfInstancesPerDS PortalInfo -f numberOfInstancesPerDS \
  | tools/portal-matrix.py -d
```

```text
| field                                  | prod | preprod | test |
| -------------------------------------- | ---- | ------- | ---- |
| numberOfInstancesPerDS.Ping            | 1180 | 1175    | 85   |
| numberOfInstancesPerDS.WinAutoServices | 2250 | 2250    | —    |
```

Counts differ wherever portals differ in size, so read — (not in use there at
all) rather than the numbers.

**Picking the critical datasources.** The same field ranks them by use. The
top 30 across all the portals, into a file:

```shell
elm -p prod,preprod,test -f jsonl PortalInfo -f numberOfInstancesPerDS \
  | jq -rs 'map(.numberOfInstancesPerDS | to_entries[]) | group_by(.key)
            | map({key: .[0].key, n: (map(.value) | add)}) | sort_by(-.n) | .[:30][].key' \
  > critical.txt
```

It counts instances, not devices: a datasource with many instances per device
(interfaces, services, disks) ranks above one on every device with one
instance each. Edit the list by hand afterwards; it only has to be made once.

Then compare those datasources by checksum, one name per line in the file
(there are thousands of datasources, and `-F` has no OR, so this is one query
per name):

```shell
# critical.txt
Ping
HTTPS-
SNMP_Network_Interfaces
```

```shell
while read -r ds; do
  elm -p prod,preprod,test -f jsonl DatasourceList -F "name:$ds" -f name,checksum
done < critical.txt | tools/portal-matrix.py -k name -v checksum -m
```

```text
| name                    | prod     | preprod  | test     | same |
| ----------------------- | -------- | -------- | -------- | :--: |
| Ping                    | 7afd6b6a | 7afd6b6a | 7afd6b6a |  ✓   |
| HTTPS-                  | 064d1e21 | 064d1e21 | 9c41a0e2 |  ✗   |
| SNMP_Network_Interfaces | f6ca565d | f6ca565d | —        |  ✗   |
```

(Real checksums are 32 characters.) — means the portal does not have it.

Every datasource whose name contains something:

```shell
elm -p prod,preprod,test DatasourceList -s0 -F name~Cisco_ -f name,checksum \
  | tools/portal-matrix.py -k name -v checksum -d
```

One query fetches at most 1000 rows; narrow with `-F` if elm warns that
results were truncated.

The other module types in one table, with jq adding which list each came from:

```shell
for c in ConfigSourceList EventSourceList PropertyRulesList TopologySourceList AppliesToFunctionList; do
  elm -p prod,preprod,test -f jsonl "$c" -s0 -f name,checksum | jq -c --arg t "$c" '{type: $t} + .'
done | tools/portal-matrix.py -k type,name -v checksum -d
```

Portal sizes in one table, the same way:

```shell
for c in DeviceList DeviceGroupList CollectorList AdminList DashboardList WebsiteList; do
  elm -p prod,preprod,test -f jsonl "$c" -C | jq -c --arg c "$c" '{command: $c} + .'
done | tools/portal-matrix.py -k command -v total -m
```

## A whole page for a wiki

[compare-portals.sh](compare-portals.sh) runs most of the above and writes one
Markdown page, a section per area. Big areas show only what differs; small
ones the whole table:

```shell
examples/compare-portals.sh prod,preprod,test critical.txt > comparison.md
```

For a wiki that renders `:true:` and `:false:`, with account names as the
column headings:

```shell
MATRIX_OPTS='-c account_name --tick :true: --cross :false:' \
  examples/compare-portals.sh prod,preprod,test critical.txt > comparison.md
```

A single table with a heading of your own:

```shell
{ echo '## Roles'; echo
  elm -p prod,preprod,test RoleList -s0 -f name | tools/portal-matrix.py -k name -m --tick :true: --cross :false:
} >> comparison.md
```

## Scripting and scheduled checks

Both `elm -d` and `portal-matrix.py` exit like `diff`: 0 when the same, 1 when
something differs, 2 when it could not tell. In a pipeline the shell reports
the last command, so test the matrix:

```shell
if elm -p prod,preprod RoleList -s0 -f name | tools/portal-matrix.py -k name -d > roles-diff.md; then
  echo 'roles match'
else
  echo 'roles differ:'; cat roles-diff.md
fi
```

A nightly check that only speaks up when something changed (cron mails any
output):

```shell
elm -p prod,preprod,test AlertRuleList -s0 -f name,priority,levelStr,escalatingChain.name \
  | tools/portal-matrix.py -k name -v priority,levelStr,escalatingChain.name -d 2>/dev/null
```

## Choosing keys and values

- **Key on something that means the same on every portal**: a name or a
  `fullPath`, never an `id`. Ids are allocated per portal.
- **Values**: compare what should match (`checksum`, `appliesTo`, `priority`),
  not what always differs (`id`, timestamps, counts, `objectId`).
- **Keys are case-sensitive**: `Joe@example.com` and `joe@example.com` are two
  rows.
- **Lists**: without `-e` a list is compared whole, so the same items in
  another order count as different. Explode it and key on the item.
- **More than 1000 rows**: one query fetches at most 1000 (`-s0`). Narrow with
  `-F`, or compare a chosen list (as with the critical datasources).
- **One row per key per portal**: if a key matches several rows on one portal,
  its cell lists each distinct value once, comma-separated. Add fields to `-k`
  until each key is unique.

## Caveats

- What a token cannot see is missing from its portal's column: check that
  every profile's token has a role that can see what you are comparing.
- `AccessGroupList` returns 400 on some account types (see `elm AccessGroupList --info`).
- `-d` on several profiles needs every portal to answer: one failure, and it
  exits 2 without a comparison.
- `PortalInfo` contacts and `AdminList` hold personal details: do not commit
  or share the output beyond the people who need it.

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --hide-footer --skip-header examples/comparing-portals.md
```
