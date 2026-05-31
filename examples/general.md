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
   * [Build a local SQLite database](#build-a-local-sqlite-database)
   * [Count results matching a filter](#count-results-matching-a-filter)
   * [Use --format api to debug the API call](#use---format-api-to-debug-the-api-call)
   * [Output formats for tables and documents](#output-formats-for-tables-and-documents)
   * [Add header and footer custom text](#add-header-and-footer-custom-text)
   * [meta](#meta)
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

## Build a local SQLite database

`-f sqlite` appends query results to a SQLite database file. It is a **running
database**, not a new file per run — each call adds rows to the same table so
data accumulates over time.

The table name is derived from the command name by converting CamelCase to
snake\_case (e.g. `DeviceList` → `device_list`, `AlertList` → `alert_list`).
Multiple endpoints can share one file — each lands in its own table.

Every row gets a `fetched_at` column (UTC ISO8601, e.g. `2026-05-29T01:44:25Z`)
as its first column so you can tell how old each row is.

```shell
# Accumulate snapshots over time — re-run daily, weekly, whenever
elm DeviceList -s0 -f sqlite -o lm.sqlite
elm AlertList  -s0 -f sqlite -o lm.sqlite
```

elm prints a confirmation to stderr and produces no stdout output:

```
Appended 1567 rows to table 'device_list' in lm.sqlite
```

Query with any SQLite-compatible tool:

```shell
# sqlite3 CLI
sqlite3 lm.sqlite "SELECT displayName, hostStatus FROM device_list LIMIT 5"
sqlite3 lm.sqlite ".tables"

# DuckDB (can query SQLite files natively)
duckdb lm.sqlite "SELECT * FROM alert_list WHERE fetched_at > '2026-05-28'"
```

To see just the **latest snapshot** when you have multiple runs in the database:

```sql
SELECT *
FROM device_list
WHERE fetched_at = (SELECT MAX(fetched_at) FROM device_list);
```

To compare **two snapshots** — e.g. devices that appeared between runs:

```sql
SELECT id, displayName
FROM device_list
WHERE fetched_at = (SELECT MAX(fetched_at) FROM device_list)
  AND id NOT IN (
    SELECT id FROM device_list
    WHERE fetched_at < (SELECT MAX(fetched_at) FROM device_list)
  );
```

> **Note:** `-o`/`--filename` is required. `-f sqlite` cannot write to stdout
> and will error if you omit `-o`. Nested API fields (e.g. `customProperties`)
> are serialised to JSON strings for storage and can be parsed with
> `json_extract()` in DuckDB or `json_each()` in SQLite.

## Count results matching a filter

Use `-c` to return the count of items in the current query (affected by the `-s` size limit),
or `-C` to return the API's total count of all matching records regardless of size limit:

```shell
# How many results does this filter match?
elm DeviceList -F displayName~foo -C

# How many items came back in this page?
elm DeviceList -F displayName~foo -s50 -c
```

`-C` is usually what you want — it queries the API's `total` field, which reflects all
matching records. `-c` counts only what was returned in the current request.

## Use --format api to debug the API call

`-f api` makes the request and then prints the URL and Authorization header
instead of the response data. Useful for seeing exactly what call elm made,
or for reproducing it with curl.

> **Warning:** the Authorization header contains your access_id and a signed
> token. Do not share this output or commit it to version control.

```shell
elm -f api DeviceList -s1 -F displayName~foo
```

Example output (values are illustrative — yours will contain real credentials):

```
https://acme.logicmonitor.com/santaba/rest/device/devices?&size=1&filter=displayName%7Efoo
Authorization: LMv1 abcd1234:<hmac-signature>:<epoch-ms>
```

The signature is time-stamped and expires within minutes — run curl immediately
after elm if you want to replay the request.

## Output formats for tables and documents

In addition to `json`/`csv`, elm supports several table and markup formats:

```shell
elm -f gfm      DeviceList -s5 -f id,displayName   # GitHub Flavored Markdown table
elm -f pipe     DeviceList -s5 -f id,displayName   # Markdown pipe table (right-aligns numbers)
elm -f prettyhtml DeviceList -s5 -f id,displayName # Syntax-highlighted HTML (terminal display)
elm -f prettyxml  DeviceList -s5 -f id,displayName # Indented XML
elm -f rst      DeviceList -s5 -f id,displayName   # reStructuredText grid table
elm -f latex    DeviceList -s5 -f id,displayName   # LaTeX tabular environment
```

Note: `md` and `tab` both use tabulate `simple` format internally and currently produce
identical output — verify with `-H` (noheader) if you need to rely on that. Use `gfm` or
`pipe` for Markdown you intend to paste into GitHub or a wiki.

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
gh-md-toc --insert --no-backup --hide-footer --skip-header examples/general.md
```
