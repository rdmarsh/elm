# Filtering Examples

How to use the `-F`/`--filter` flag for server-side filtering. The syntax is
`FIELD` + `OPERATOR` + `VALUE`. elm quotes the VALUE for you — do not add your
own quotes around it. These apply across all `*List` commands.

**See also:**
- [general.md](general.md) for basic usage, output formats, and piping
- [devices.md](devices.md) for device property and group-membership filters

<!--ts-->
   * [Operators](#operators)
   * [The ~ operator (contains)](#the--operator-contains)
   * [Equals vs contains: : vs ~](#equals-vs-contains--vs-)
   * [Combining filters (AND)](#combining-filters-and)
   * [No OR server-side](#no-or-server-side)
   * [Filtering comma-separated string fields](#filtering-comma-separated-string-fields)
   * [Gotchas](#gotchas)
   * [No "is empty" operator](#no-is-empty-operator)
   * [Filters the API silently ignores](#filters-the-api-silently-ignores)
   * [meta](#meta)
<!--te-->

## Operators

| Operator | Meaning | Example |
|----------|---------|---------|
| `:`  | equals (exact) | `-F 'displayName:db01.acme.com'` |
| `~`  | contains (substring, case-insensitive) | `-F 'displayName~db01'` |
| `!:` | not equals | `-F 'hostStatus!:dead'` |
| `!~` | does not contain | `-F 'displayName!~test'` |
| `>` `<` | greater / less than | `-F 'id>1000'` |
| `>:` `<:` | greater / less than or equal | `-F 'id>:1000'` |

## The ~ operator (contains)

`~` is a case-insensitive substring match — "does this field contain this text
anywhere". Case does not matter:

```shell
elm DeviceList -F 'displayName~db'    # matches db01, web-DB, prodDB, ...
elm DeviceList -F 'displayName~DB'    # identical result
```

Spaces in the VALUE are fine — just quote the whole argument so the shell keeps
it as one token:

```shell
elm IntegrationList -F 'name~ServiceNow DEV'
```

## Equals vs contains: : vs ~

Use `:` when you know the exact value (faster, unambiguous); use `~` when you
only know a fragment:

```shell
elm DeviceList -F 'displayName:db01.acme.com'   # exactly db01.acme.com
elm DeviceList -F 'displayName~db01'            # anything containing db01
```

## Combining filters (AND)

Repeated `-F` flags are ANDed together. This is the clearest form:

```shell
elm DeviceList -F 'hostStatus:normal' -F 'displayName~prod'
```

Comma-separating clauses inside a single `-F` is equivalent:

```shell
elm DeviceList -F 'hostStatus:normal,displayName~prod'
```

## No OR server-side

The LM API filter cannot OR multiple values for the same field. Do that
client-side — for example with elm's native output or `jq`:

```shell
# devices that are dead OR in maintenance
elm -f json DeviceList -F 'hostStatus!:normal' | \
  jq '[.[] | select(.hostStatus=="dead" or .hostStatus=="sdt")]'
```

## Filtering comma-separated string fields

Some fields are comma-separated strings rather than arrays (e.g. `hostGroupIds`).
Use `~` to match one value within them, not `:`:

```shell
elm DeviceList -F 'hostGroupIds~42'    # device is a member of group 42
```

## Gotchas

- **Do not double-quote the VALUE** in the filter itself — elm adds the quotes.
  `-F 'name~prod'` is correct; `-F 'name~"prod"'` sends doubled quotes.
- **`!` is special in bash** — single-quote the whole argument (which you should
  do anyway): `-F 'displayName!~test'`.
- **A literal comma in a VALUE must be escaped as `\,`**, because comma separates
  filter clauses:

  ```shell
  elm IntegrationList -F 'name~Smith\, Inc'   # searches for the literal "Smith, Inc"
  ```

- **Backslashes and quotes inside a VALUE are escaped automatically** (v1.8.9+) —
  just type the literal value you want.

## No "is empty" operator

There is no server-side "is empty" operator for array fields. Filter with jq:

```shell
elm WebsiteList -s0 | jq '.WebsiteList[] | select(.properties | length == 0) | .name'
```

## Filters the API silently ignores

Some filters are accepted and then ignored: the API returns every record, with
no error, so the result looks like a valid answer. Known cases:

- `!:` and `!~` on AlertList and AuditLogList (issue #48). They do work on
  DeviceList.
- Most ID fields on AlertList: `monitorObjectId`, `instanceId`,
  `resourceTemplateId` and others (issue #56). Use `monitorObjectName` or
  `AlertListByDeviceId --id N` for one device.
- Every filter on V4Metadata.
- `alertDisableStatus` on DeviceList (positive matches return nothing).

`elm COMMAND --info` lists the known cases for a command. To test any filter,
compare counts with and without it; if the count does not move, it is ignored:

```shell
elm AlertList -c -s0 -F severity:4
elm AlertList -c -s0 -F severity:4,monitorObjectId:123    # same count: ignored
```

Where a not-equals filter is ignored, fetch with a positive filter (or none) and
exclude client-side:

```shell
# Instead of: elm AuditLogList -F username!:foo
elm -f json AuditLogList -s0 | jq '.AuditLogList[] | select(.username != "foo")'
```

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --hide-footer --skip-header examples/filtering.md
```
