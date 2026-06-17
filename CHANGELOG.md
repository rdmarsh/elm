# Changelog

All notable changes to elm are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `tools/elm-datasource-matrix.sh` — builds a device-by-datasource usage matrix as a GitHub Flavored Markdown table (each row is a device — device ID then device name — and each datasource is a column; a cell is a tick `✓` where the datasource is applied, blank otherwise) for every datasource whose **name** matches a pattern. Pivots one `AssociatedDeviceListByDataSourceId` (`/setting/datasources/{id}/devices`) call per matching datasource, so the cost is one API call per datasource, not one per device. Matching is **case-sensitive by default** so `NTP` matches `NTPv4`/`Cisco_NTP` but not incidental substrings like `AccessPoi[ntP]erformance` or `OverCurre[ntP]rotectors`; `-i`/`--ignore-case` widens it. **Real devices only:** rows are restricted to actual devices (`deviceType` 0 or 1); LM Services / Service Insight, cloud accounts/resources (AWS, Azure) and Kubernetes resources are excluded (not configurable). Drops datasources with no remaining devices (empty columns) and only lists devices using at least one match. `--csv` emits `id,device,<datasource…>` rows with `1`/`0` cells for spreadsheets; `--profile` selects the portal (defaults to `config`). "Applied" is the live device→datasource association, not the daily `auto.activedatasources` property. Documented under README **Development → Datasource usage matrix**.
- `examples/filtering.md` — a dedicated `-F`/`--filter` reference: operator table (`:`, `~`, `!:`, `!~`, `>`, `<`, `>:`, `<:`), `~` substring-search behaviour (case-insensitive, spaces OK), combining filters with repeated `-F` (AND), the no-OR limitation, comma-separated string fields, and the quoting/comma-escape gotchas. Linked from `examples/README.md` and `EXAMPLES.md`.

## [1.8.9] - 2026-06-11

### Added

- `tools/lm-collector-reachability-run-all.ps1` — PowerShell runner that checks reachability across **every active collector in a collector group at once** (any group with more than one collector — auto-balance or manual) and saves each collector's result as `<hostname>.csv` for diffing between collectors. Self-contained: uses only the `Logic.Monitor` module (no elm, bash, jq, or jinja2) and a single existing LM session. Select the group with `-id` or `-group`; run with no argument to list collector groups that have more than one collector. Discovers group members (`preferredCollectorGroupId`), builds the protocol matrix from `autoProperties`, generates the Groovy inline, submits via Collector Debug, then polls and writes each result as soon as it is ready (CSVs default to a per-run directory under the system temp). When two or more collectors return, it then prints a built-in cross-collector comparison: for every device and protocol it gathers each collector's result and lists only the rows where collectors disagree (e.g. one `pass`, another `FAIL`), scaling to any collector count rather than a single A-vs-B diff. For the two-collector case it also prints a ready-to-run `difft` command (suggested only for exactly two collectors, since `difft` is pairwise). `-Candidate ID|NAME` (repeatable) tests one or more collectors that are **not** in the group against the group's device list — vetting a freshly built collector before moving it in — and prints a per-candidate verdict listing only the device+protocol combinations the candidate fails to reach but an in-group collector does (devices the whole group already cannot reach are not counted against the candidate). A `-Candidate` is resolved by collector id, exact hostname/description, or — failing that — an unambiguous partial/substring match (so `newedge03` resolves an FQDN-named collector like `newedge03.example.com`); a value that cannot be resolved to an active, not-yet-in-group collector aborts the run (before device discovery) rather than silently degrading to a group-only test, listing near-matches when the name was ambiguous. The comparison and candidate-verdict output is colour-coded (green `pass`, red `FAIL`, yellow `TIMEOUT`; disable with `-NoColor`, the `NO_COLOR` env var, or when stdout is redirected) and the verdict rows are column-aligned. Comparison columns are ordered deterministically (incumbent collectors first, sorted by hostname; any candidate on the right) rather than in result-arrival order. Skips devices that are themselves collector hosts (matched via a collector's `collectorDeviceId`) and warns when such hosts are found in an auto-balance group; `-IncludeDead` also tests `hostStatus:dead` devices to reveal relocate candidates. Fails clearly when the LM account lacks Collector Debug permission (a read-only token is denied; Collector Debug needs a Manage-level token).

### Changed

- Git pre-commit hook (ToC regeneration) is now a tracked file at `.githooks/pre-commit` instead of being emitted as an escaped `printf` string by the `make hooks` target. `make hooks` now just runs `git config core.hooksPath .githooks`, so the hook is normal, reviewable bash. The hook itself now passes `--hide-footer` to `gh-md-toc` (dropping the post-hoc `sed` that stripped the `Added by:` footer) and selects staged Markdown via NUL-delimited `git diff --name-only -z -- '*.md'` (handles paths with spaces/newlines). Because the footer lives inside the `<!--ts-->`/`<!--te-->` block, existing footers are removed automatically the next time a file is staged.
- `## meta` ToC-update commands across the 13 documented Markdown files now include `--hide-footer`, matching the hook so a manual run no longer re-adds the footer.
- Git pre-commit hook now also runs a **leak scan**: it blocks a commit whose staged added lines match a denylist of sensitive customer/portal tokens. The denylist lives in `.githooks/leak-patterns.local` (gitignored, stays local so the tokens are never committed); `.githooks/leak-patterns.example` documents the format. The scan skips cleanly when no local denylist is present, and a genuine false positive can be bypassed once with `LEAK_SCAN_SKIP=1 git commit`.
- `-F`/`--filter` now gives an actionable error when a filter clause has no operator, instead of a cryptic usage dump. The most common cause is an unescaped comma in a value (commas separate filter clauses), so the message names the offending clause and points at the `\,` escape — e.g. `-F 'name~Smith, Inc'` now reports ``filter clause ' Inc' has no operator … to include a literal comma in a value, escape it as '\,'``.

### Fixed

- `-F`/`--filter` values are now escaped before being wrapped in quotes. Previously the raw value was wrapped directly, so a value ending in a backslash escaped elm's own closing quote (e.g. `-F 'hostname~foo\'` produced `hostname~"foo\"`) and an embedded double-quote ended the value early — both yielding a malformed filter and a `400 Bad Request` from the LM API. `validate_filter()` now escapes `\` and `"` in the value, so you type the literal value and elm handles the quoting. Any prior habit of doubling a trailing backslash to work around this is no longer needed (and now means a literal backslash): `-F 'name~foo\\'` matches two backslashes.

- `tools/lm-collector-reachability-run-all.ps1`: detect "not logged in" up front. Previously the only precondition was that the `Logic.Monitor` module was loaded, not that a session was active, so running with no connection spilled the module's multi-line "ensure you are logged in" error mid-listing followed by a misleading `0 of 0 total`. It now checks `Get-LMAccountStatus` (a plain string when logged out, a status object when connected) and, like the module-not-loaded case, fails with a single clean red message and exit code 1 rather than a thrown `Line | NN |` caret block. Also documented that `-Candidate` takes several collectors comma-separated (`-Candidate id1,id2`), each producing its own verdict block.
- `tools/elm-collector-readiness.sh`: device membership filter changed from `autoBalancedCollectorGroupId` to `preferredCollectorGroupId`. `autoBalancedCollectorGroupId` is only populated for devices LM has already auto-placed, so it returned no devices for groups whose members are assigned but not yet balanced (observed: a group with 2 assigned devices reported 0 to test).

## [1.8.8] - 2026-05-29

### Added

- `sqlite` output format (`-f sqlite -o file.sqlite`): appends query results to a local SQLite database. Table name is derived from the command name (e.g. `DeviceList` → `device_list`). Each row gets a `fetched_at` UTC timestamp (ISO8601) as the first column so freshness can be checked at query time. Nested dict/list values are serialised to JSON strings for storage. Repeated runs append new rows — query `WHERE fetched_at = (SELECT MAX(fetched_at) FROM <table>)` for the latest snapshot. Requires `-o`/`--filename`; errors clearly if stdout is requested. Uses stdlib `sqlite3` — no new dependencies.

## [1.8.7] - 2026-05-27

### Added

- `values` output format (`-f values`): emits bare field values with no headers or padding. Single field: one value per line — ideal for shell variable assignment (`gid=$(elm -f values DeviceGroupList -f id -F name:Linux)`). Multiple fields: tab-separated values with no header row — pipes cleanly into `cut`, `awk`, or `column`. Removes jq as a dependency for simple scalar extraction and multi-step command chaining.

### Added
- `tools/elm-collector-readiness.sh` — pre-add collector verification tool. Discovers all devices in an LM auto-balance group, detects protocols from `autoProperties` (SNMP, SSH, WMI, HTTP/HTTPS) set by LM Active Discovery, and renders a ready-to-paste Groovy reachability test script to stdout. Supports `--id GROUP_ID` and `--name GROUP_NAME`; profile defaults to `config` (same as elm). Devices with `hostStatus:dead` are skipped; `dead-collector` devices are kept (collector is down but device may be reachable from new collector).
- `tools/lm-collector-reachability-check.groovy.j2` — Jinja2 template for the LM Collector Debug → Script tab. Device list pre-filled by `elm-collector-readiness.sh`. Tests ping (`InetAddress.isReachable`), SNMP (raw UDP 161 probe), and TCP connectivity per device in parallel (one thread per device via `ExecutorService`); outputs CSV with `pass`/`FAIL`/`TIMEOUT`/blank per protocol column.
- `examples/collector-readiness.md` — step-by-step documentation for the collector readiness workflow.
- Makefile: `testfmtcontent` target — asserts each of the 21 output formats actually produces that format (e.g. tsv contains a real tab, json is valid and wrapped in the command-name key, jsonl is valid JSON per line and unwrapped, raw is a Python dict repr, txt has no separator line). `testfmts` only checked exit 0; this catches a format silently producing the wrong structure or being aliased to another. Added to the `test` aggregate; connects to LM.

### Fixed
- `tools/elm-collector-readiness.sh`: was fetching non-existent `categories` field for protocol detection; now uses `autoProperties` (`auto.snmp.operational`, `auto.network.listening_tcp_ports`) which reflects what LM Active Discovery actually measured. Added `hostStatus` field to detect and skip dead devices.
- `tools/elm-collector-readiness.sh`: fails clearly with a helpful message when jinja2 is not importable by the selected Python, rather than producing a raw `ModuleNotFoundError` traceback.
- `tools/lm-collector-reachability-check.groovy.j2`: sequential device testing hit the LM debug console timeout with as few as 6 unreachable devices. Now runs all devices in parallel. Ping switched from spawning an OS process to `InetAddress.isReachable()`. Default timeouts reduced (ping 3000→1500 ms, TCP 2000→1000 ms, SNMP 3000→2000 ms).
- `tools/lm-collector-reachability-check.groovy.j2`: Groovy parsed `println (list).join(",")` as `println(list)` (printing the list object) followed by `.join(",")` on the void return value, throwing `NullPointerException: Cannot invoke method join() on null object`. Fixed by assigning to a variable before printing.

### Changed
- `tools/lm-collector-reachability-check.groovy.j2`: protocol columns now display purpose-based labels (`wmi`, `ssh`, `http`, `https`) instead of port numbers; column order is ping → snmp → wmi → ssh → http → https (defined order, not alphabetical — alphabetical sort was silently putting https before http); failure list and footer notes use the same labels; footer adds a note that `wmi` pass only confirms TCP 135, not the dynamic high ports WMI also requires.
- `tools/elm-collector-readiness.sh`: bash summary table now shows the same purpose-based labels (`wmi`, `ssh`, `http`, `https`) in the Protocols column; protocol order in the device matrix corrected to http before https.
- `tools/elm-collector-readiness.sh`, `tools/lm-collector-reachability-check.groovy.j2`: removed Mode A/B/C code paths — script always generates a native Groovy `[...]` device list (no JSON string embedding); removes credential injection from the rendered script; simplifies the template from ~230 to ~130 lines. Also fixes a Groovy 65535-character string literal limit that crashed with large groups.
- `tools/elm-collector-readiness.sh`, `tools/lm-collector-reachability-check.groovy.j2`: split `tcp-135` (detected from `auto.network.listening_tcp_ports`) and `wmi` (detected from `auto.wmi.operational`) into separate protocol columns — both test TCP 135 but are triggered by different signals.
- `tools/elm-collector-readiness.sh`: added `auto.activedatasources` as fallback for HTTP/HTTPS detection when ports 80/443 are absent from the TCP port scan (handles devices where datasources are applied without an active port listener).
- `tools/lm-collector-reachability-check.groovy.j2`: output changed from fixed-width text table to CSV for diff-friendly comparison between collectors.
- `tools/lm-collector-reachability-check.groovy.j2`: non-applicable protocol columns now output blank instead of `-` for cleaner CSV.
- `tools/lm-collector-reachability-check.groovy.j2`: added device `id` column; renamed `IP/Hostname` to `hostname`; renamed `Device` to `device`.
- `tools/lm-collector-reachability-check.groovy.j2`: result values lowercased — `pass` (was `PASS`) so `FAIL` and `TIMEOUT` stand out in the output.
- `tools/lm-collector-reachability-check.groovy.j2`: prints `Testing N devices from HOSTNAME (parallel)...` at start of output, naming the collector host for easy file labelling when comparing runs.
- `elm-speedtest.sh` moved to `tools/elm-speedtest.sh`. All README references updated.
- `requirements.txt`: grouped into runtime vs build-time dependencies with comments mirroring `setup.py`. Removed `packaging` (no longer imported by elm; still installed transitively via pyinstaller). Build-time tools (`jinja2-cli`, `Jinja2`, `pyinstaller`) are now clearly separated from the runtime deps that mirror `setup.py install_requires`. `PySocks` confirmed as a genuine runtime import (`--proxy` SOCKS5 support), not an optional extra.
- `setup.py`: packaging cleanup. Added `py_modules=['elm', 'engine', '_version']` so the top-level entry-point modules are installed (`find_packages()` alone only picked up `_cmds/` and silently omitted them). Removed `Jinja2` and `jinja2-cli` from `install_requires` (build-time only — used by `make render`, pinned in `requirements.txt`) and `packaging` (no longer imported anywhere). Removed `include_package_data=True` (no `MANIFEST.in`, so it did nothing). Bumped `python_requires` from `>=3.6` to `>=3.9` (pandas 2.3 requires 3.9+). Added comments documenting the build-time-vs-runtime dependency split.
- `elm-notes.yaml`: added full entry for `ImmediateDeviceListByDeviceGroupId` — documents shallow/non-recursive fetch behaviour, `customProperties` all-or-nothing constraint, and a pattern for finding the correct group level to query in hierarchical portal structures.
- `elm-notes.yaml`, `elm-knowledge.md`: documented that `-s0` and `-s1000` are equivalent (confirmed by live test: both return 97 groups on a portal with 97 groups).
- `ai.md`: consolidated principles #11/#12 (both covered SKILLS_USED.md); added uppercase naming convention for AI-created files (CLAUDE.md, SKILLS_USED.md); added principles #12–16 covering instruction precedence, understand-before-modifying, no parallel abstractions, stop-and-ask conditions, and maintainability over speed; added "Verify external APIs" section; strengthened "Working with code" with scope discipline rule.
- `.gitignore`: added `SKILLS_USED.md` (private skills log, not for the repo).
- README restructured: `## Development` is now a top-level section (was `### Development` under Installation); Quick code testing loop and API speed test moved under Development; AdminById help moved under Usage; Installation now contains only install steps.
- `elm-notes.yaml`: expanded `CollectorList` with `backupAgentId`, `enableFailBack`, `calculatedThreshold`, `numberOfWebsites`, `nextUpgradeInfo`, corrected `status` and `collectorSize` notes, added gotchas and patterns.
- `elm-notes.yaml`: expanded `CollectorGroupList` with `propertyForBalancing`, `mismatchVersion`, and a detailed `auto_balance_explained` block covering the device-side `autoBalancedCollectorGroupId` field, single-collector group intent, and over-capacity limits.
- `elm-notes.yaml`: expanded `DeviceList` with `preferredCollectorGroupId`, `preferredCollectorId`, and clarified `autoBalancedCollectorGroupId` (0 = pinned, non-zero = in auto-balance pool).
- `elm-notes.yaml`: expanded `CollectorById` with `backupAgentId`, `enableFailBack`, `calculatedThreshold`, all conf fields (`collectorConf`, `wrapperConf`, `sbproxyConf`, `watchdogConf`, `websiteConf`, `agentConfFields`, `confVersion`, `userChangeOn`), and gotchas documenting that all conf fields are read-only in the API, portal UI config pushes do not populate them, and `confVersion` is a heartbeat tick not a config-change indicator.
- `examples/collectors.md`: added collector health report section (all-collectors overview, DOWN with hosts, no-backup single points of failure, backup pair health); added auto-balance section (explanation, single-collector groups, mismatch groups); restructured build version section.
- README: features bullet updated to "more than 20 formats" (avoids hardcoding a count); curl/wget moved out of format list and into a dedicated feature bullet; first-person removed from Development section; collectors example description updated; dead link reference with typo removed.
- Makefile: removed `back` target and associated `bakdir`/`TAR`/`TARFLAGS` variables; superseded by git.
- Makefile: copyright year bumped to 2026; `AWK-exists` prerequisite check added; `-exists` rules aligned; `# BACKUP` section renamed to `# CLEANUP`; directory creation rule simplified (removed redundant `chown`/`chmod`); `help` target uses `$(AWK)` variable.
- `_jnja/elm.py.j2`: copyright year bumped to 2026.
- README: removed `tar` from pre-requisites; simplified Install in PATH section.

## [1.8.6] - 2026-05-21

### Added
- Unknown field warning: when `-f` includes a field not returned by the API, a
  warning is printed listing the missing field(s) with correct singular/plural
  (`Warning: unknown field: foo` / `Warning: unknown fields: foo, bar`).
- Both follow-on warnings suppressed when all requested fields are invalid and
  `output()` has already reported `Error: no valid fields selected`.

### Changed
- `ai.md`: added principle #10 — prefer simple, readable code over clever solutions; added matching bullet to "Working with code" behaviour rules.
- `ai.md`: verification section now explicitly names hallucinated library APIs as the failure mode that "run the code" is defending against.
- `ai.md`: added "Sensitive data in AI sessions" section — covers sanitizing examples before pasting, never pasting credentials, and documenting project-level placeholder conventions.
- `ai.md`: added "Security review of AI-generated code" section — covers vulnerability patterns to check (injection, hardcoded secrets, insecure defaults, dependency vetting) and establishes a regular review cadence, not just point-of-generation checks.
- `ai.md`: principle 6 (isolated sessions) now names the mechanism — context window degradation — not just the symptoms.
- `ai.md`: "Working with code" now includes a note on copyright/IP — avoid reproducing verbatim patterns from known licensed sources.
- `ai.md`: "Scope of authorisation" now instructs the AI to explain suggested shell commands before the user runs them and flag anything destructive.
- Size limit warning reworded to `Warning: results truncated by size limit`.
- Unknown total warning reworded to `Warning: total unknown, results may be truncated`.
- `elm-notes.yaml`: added `appliesTo` filter and active/inactive check patterns to
  `DatasourceList`; noted that `/* */` comments are common disable mechanism and
  Python is more reliable than jq for stripping them.

## [1.8.5] - 2026-05-18

### Added
- `--ai` flag — prints a quick-start guide for AI assistants and exits. Covers
  command structure, key flags, filter operators, output formats, and response
  wrapping; points to `elm-notes.yaml`, `elm-knowledge.md`, and `examples/` in
  the repo for deeper reference. Loads without credentials, same as `--version`
  and `--list`.
- `elm --help` description now includes "AI assistants: run 'elm --ai' for a
  quick-start guide" so a cold-start AI running `--help` finds it immediately.

## [1.8.4] - 2026-05-15

### Added
- `-h` as a short form for `--help` at the global level.

## [1.8.3] - 2026-05-15

### Added
- `curl` output format — prints a ready-to-run `curl -H "Authorization: ..."` command
  for copy-paste use. Makes the API request but outputs the command instead of data.
- `wget` output format — prints a ready-to-run `wget -O - --header="Authorization: ..."`
  command for copy-paste use. `-O -` sends output to stdout. Same caveats as `curl`
  and `api` formats: HMAC signature is time-limited and contains credentials.

## [1.8.2] - 2026-05-15

### Added
- Verbose mode (`-v`) now shows `Elapsed time: Xs` for each API request,
  using `response.elapsed` (server + transfer time only, excludes elm
  processing overhead).

### Fixed
- Verbose log message capitalisation: `Status code`, `Elapsed time`,
  `Total records` now use consistent sentence case.

## [1.8.1] - 2026-05-15

### Added
- `elm-speedtest.sh` (now `tools/elm-speedtest.sh`) — times LM API response per credential profile across
  configurable endpoints. Runs each endpoint N times and reports averages.
  Credentials kept in memory only (never written to disk). Automatically
  skips `config` if any other profile has identical credentials. Shows short
  hostname at top for easy sharing. Column widths adapt to endpoint name
  length. Usage: `tools/elm-speedtest.sh` (defaults: AdminList, DeviceList,
  AuditLogList) or `tools/elm-speedtest.sh ReportList DeviceGroupList WebsiteList`.

### Fixed
- `-C`/`--total` now shows `>N` with a warning when the LM API returns a
  negative sentinel instead of an exact count. Previously printed the raw
  negative number (e.g. `-51`). Affected endpoints: `AlertList`,
  `AuditLogList`. All other list endpoints return a real total and are
  unchanged. Use `-c -s0` as a workaround to count all fetched records
  (accurate when total ≤ 1000).
- Size-limit warning ("there is data you are not seeing") now fires correctly
  for endpoints that return the LM negative total sentinel. Previously the
  `obj['total'] > flags['size']` check was always `False` for negative totals,
  silently suppressing the warning.

## [1.8.0] - 2026-05-14

### Changed
- **Startup time**: elm now uses lazy command loading (`LazyGroup`). Command
  modules in `_cmds/` are imported only when a subcommand is actually invoked,
  not at startup. `--version`, `--help`, `--list`, and tab-completion all run
  without loading any subcommand module. Cold-start time dropped from several
  seconds to ~0.2 s on the compiled binary.
- **Deferred heavy imports**: `pandas`, `tabulate`, `htmlmin`, `pygments`, and
  `requests` are now imported inside `engine()` and `output()` rather than at
  module load time. This is the other half of the startup speedup; the imports
  only happen when an API call is actually made.
- `_cmds/__init__.py` is now generated by `make render` (`touch` in the
  Makefile). This makes `_cmds` a proper Python package so PyInstaller's
  `--collect-all=_cmds` can enumerate and bundle it correctly.
- PyInstaller build flag `--collect-all=_cmds` added to ensure the compiled
  binary bundles all lazily-loaded command modules.
- `--profile` help text now uses the static path
  `~/.config/logicmonitor/credentials/<NAME>.ini` rather than the runtime-
  expanded `_creds_dir`, preventing the real username from leaking into
  generated documentation.
- Default config file path is now shown prominently in the description block
  of `elm --help` (right after the one-liner), using `~` rather than the
  expanded home directory. Removed the epilog, which was buried after the full
  command list and exposed the real username.

### Fixed
- `make testbasic` now tests every subcommand with `--help` to verify the
  lazy-loading mechanism works for all commands.

## [1.7.10] - 2026-05-14

### Fixed
- Multiple `-F`/`--filter` flags now all apply correctly. Previously, passing
  `-F field1:val1 -F field2:val2` silently dropped all but the last filter —
  only the last one was sent to the LM API, with no error or warning. Fixed by
  adding `multiple=True` to the filter option and handling the resulting tuple
  in `validate_filter`. Comma-separated filters in a single `-F` continue to
  work unchanged. Closes [#49](https://github.com/rdmarsh/elm/issues/49).

### Documentation
- Documented `-i`/`--access_id` and `-k`/`--access_key` global flags in
  `elm-notes.yaml`. These override the config file values; LM logs the
  supplied `access_id` verbatim as the `username` field in `AuditLogList`.
  Confirmed by live test.
- Documented LM API behaviour: `AuditLogList` entries with `username: "(update)"`
  are not redacted or substituted — LM logs the raw `access_id` as the username
  field. The string `(update)` is the literal credential value configured in the
  integration making those calls. Confirmed by live test. Documented in
  `CLAUDE.md`, `elm-knowledge.md`, and `elm-notes.yaml`.
- Documented LM API bug: `!:` (not-equals) and `!~` (not-contains) filter
  operators are silently ignored or misapplied on several endpoints
  (`AuditLogList username`, `AlertList cleared`). elm sends the correct
  URL-encoded filter — the bug is upstream. Workaround: use positive
  operators and filter client-side with jq. Tracked as upstream bug
  [#48](https://github.com/rdmarsh/elm/issues/48).

## [1.7.9] - 2026-05-14

### Added
- `-V` short form for `--version`.
- `elm --list` / `elm -l` lists available credential profiles from the
  credentials directory and exits. The active profile is marked with `* `
  on the left; inactive profiles are indented to align. Works without valid
  credentials (eager flag, exits before auth check). Correctly reflects
  `--profile NAME` when combined: `elm --profile preprod --list` marks
  `preprod`. `config.example.ini` is excluded from the listing.
- `elm-knowledge.md` — team-facing reference covering CLI patterns, common
  gotchas, alert patterns, portal overview, and time-series data access.
  Sanitized for public repo use.

### Changed
- Credential profile convention documented: `config.ini` is the safe
  default (sandbox/test); non-default environments use explicit names
  (`preprod.ini`, `prod.ini`) and require `--profile`.
- `elm-notes.yaml` gains a `_global.flags` block documenting the five key
  global options (`--list`, `--profile`, `--config`, `--format`, `--size`).
- `CLAUDE.md` updated with credential profile workflow using `elm --list`.

## [1.7.8] - 2026-05-14

### Fixed
- `elm-completion.bash` used `_ELM_COMPLETE=bash_complete` (Click 8 style);
  Click 7.x requires `_ELM_COMPLETE=complete`. Completion was silently broken.
- Click 7's completion lowercased all command names (`devicelist`) but elm
  commands are CamelCase (`DeviceList`) — the completed names didn't work.
  Fixed with a hybrid completion: static CamelCase list for command name
  position, dynamic Click completion for flags and values.
- Click 7.1.2 template bug generated `_elm_completionetup` instead of
  `_elm_completion_setup`. Corrected in the template.
- No Makefile target installed the completion file anywhere. Added
  `make completion` which installs to
  `$XDG_DATA_HOME/bash-completion/completions/elm`
  (default `~/.local/share/bash-completion/completions/elm`).
  `make install` now depends on `make completion`.

### Changed
- `elm-completion.bash` is now a generated file rendered from
  `_jnja/elm-completion.bash.j2` by `make render`. Removed from git
  tracking; added to `.gitignore`.

## [1.7.7] - 2026-05-14

### Added
- `tsv` output format: true tab-separated values (`\t` delimiter). Distinct
  from `tab`, which is tabulate's human-readable aligned table format.
  Supports `-H` (hide headers) and `-I` (show index) like `csv`.
- `jsonl` output format: JSON Lines — one JSON object per line, no
  command-name wrapper. Directly readable by DuckDB, jq, and most
  analytics tools without preprocessing.

### Changed
- `--format` help text now uses `metavar='FORMAT'` with a readable list
  instead of the full `[csv|html|...]` choice string, which was overflowing
  the terminal line width.

## [1.7.6] - 2026-05-13

### Added
- `--fields` / `-f` injected universally on all subcommands (was missing from
  the LM swagger but accepted by the API). Mirrors the existing `--sort` injection.
- `--size` / `-s`, `--offset` / `-o`, and `--filter` / `-F` added to 11 list
  subcommands where the LM swagger omits them: `DeviceEventsourceList`,
  `DiagnosticSourcesList`, `JobMonitorList`, `LogAlertGroupsList`,
  `LogQueryGroupList`, `LogSourceList`, `OIDList`, `RemediationSourcesList`,
  `RetentionList`, `TopologySourceList`, `TrackedQueryGroupList`. Also adds
  `fields`/`size`/`offset`/`filter` to `IntegrationList`. Tracked as upstream
  swagger gaps in [#47](https://github.com/rdmarsh/elm/issues/47).

### Fixed
- `--sort` injection in `_jnja/command.py.j2` was always active (comparing a
  string against a list of dicts is always `False`). Fixed to use `opt_names`,
  a proper list of option name strings.

## [1.7.5] - 2026-05-13

### Added
- `-o` short form for `--offset` on all subcommands. Mirrors `-s` for `--size`.

## [1.7.4] - 2026-05-13

### Changed
- `--profile` simplified to a pure path resolver: resolves `NAME` to
  `~/.config/logicmonitor/credentials/<NAME>.ini` and delegates everything
  else to the existing `--config` logic. No separate existence check or
  override warning — behaviour is now fully consistent with `--config`.
- Credentials error message changed from "Default config file:" to "Config file:"
  and now shows the actual file in use (`_resolved_config_file`) rather than
  the compiled-in default.

## [1.7.3] - 2026-05-13

### Added
- `-p` / `--profile NAME` global option: shorthand for `--config ~/.config/logicmonitor/credentials/<NAME>.ini`.
  Strips a trailing `.ini` if supplied. `--config` overrides `--profile` if both are given.
  Closes [#44](https://github.com/rdmarsh/elm/issues/44).

### Fixed
- `--profile foo.ini` no longer produces a double-extension path (`foo.ini.ini`);
  any `.ini` suffix on the profile name is stripped before resolving.

## [1.7.2] - 2026-05-05

### Security
- Config directory and file permissions are now enforced on every run.
  elm will warn and auto-fix if the credentials directory is not `700`
  or the config file is not `600`. If the fix fails, elm aborts.
  Closes [#20](https://github.com/rdmarsh/elm/issues/20).

## [1.7.1] - 2026-05-04

### Fixed
- `-H` / `--noheader` flag (renamed from `--noheaders`) now correctly hides
  column headers in `csv`, `html`, `prettyhtml`, and `latex` formats. The
  pandas `header=` parameter has opposite polarity to the flag, so the value
  was being passed inverted — headers showed when `-H` was given and were
  hidden when it was not. Fixed by passing `not noheader`. Tabulate-based
  formats (`txt`, `jira`, `gfm`, `md`, `pipe`, `rst`, `tab`) were unaffected.

## [1.7.0] - 2026-05-04

### Added
- `truststore` integration: system trust store (macOS Keychain, Windows cert store)
  used automatically for SSL verification, so corporate networks with TLS inspection
  work without manual certificate configuration
- `--cacert PATH` CLI option to specify an explicit CA bundle for SSL verification
- `make docs` target: injects live `elm --help` output into README.md between marker
  comments, replacing `$HOME` so no personal paths appear in the repo
- `CHANGELOG.md` (this file)

### Fixed
- `UnboundLocalError` when a request fails (e.g. SSL error): `response.json()` was
  called unconditionally after the try/except block even when `response` was never
  assigned — added `return` at end of except block
- `setup.py` version pins for lxml, Pygments, and requests were stale and conflicted
  with the versions bumped in 1.6.0
- `make` hanging at parse time on a clean checkout: `NONREQTARGETS :=` forced
  immediate evaluation of `REQSOURCES`, which ran `grep` with no file arguments
  (hanging on stdin) when `_defs/` did not yet exist — changed to `=` (lazy)
- Unterminated `$(grep ...)` make variable reference in `init` recipe (introduced
  Oct 2025) causing `make` to hang when parsing the Makefile

## [1.6.0] - 2026-05-04

### Added
- `make hooks` target to install git pre-commit hook that auto-updates the README
  table of contents when `README.md` is staged

### Changed
- Default config directory changed from `~/.elm` to
  `~/.config/logicmonitor/credentials`

### Fixed
- `REQSOURCES` lazy evaluation bug: `$$` with `:=` caused closing `)` to attach to
  last filename, misclassifying `WidgetListByDashboardId` as not requiring arguments
- `make test` now correctly uses the built binary via `testbin` variable

### Security
- **lxml 5.2.1 → 6.1** — XXE (XML External Entity) injection vulnerability (HIGH).
  Affected any code parsing untrusted XML.
- **Pygments 2.15.0 → 2.20** — ReDoS (Regular Expression Denial of Service)
  vulnerability (LOW).
- **requests 2.32.0 → 2.33** — Insecure temporary file reuse (MEDIUM).
- **pandas** and **pyinstaller** bumped for Python 3.14 compatibility.

## [1.5.0] - 2025-10-17

### Added
- Support for `AllLogPartitions` command
- Undocumented API calls via extended swagger spec (`swagger.undocumented.json`),
  including `CompanySetting`
- `prettyxml`, `gfm` (GitHub Flavored Markdown), and `pipe` output formats

### Changed
- Shell completion file renamed
- Makefile refactored to handle new commands and edge cases

## [1.4.0] - 2025-03-20

### Added
- Support for undocumented LogicMonitor API endpoints via `swagger.undocumented.json`

## [1.3.0] - 2024-11-12

### Added
- Colour-coded output in Makefile

### Changed
- Improved API error handling with specific HTTP status code messages (400, 401, 403,
  404, 429, 500, 503)
- Better debug messages throughout engine

### Fixed
- Exit with non-zero status code when HTTP response is not 200
- Switched from deprecated `htmlmin` to `htmlmin2`

## [1.2.3] - 2024-09-26

### Fixed
- Workaround for unescaped pipes bug in tabulate output affecting jira/gfm/pipe
  formats ([python-tabulate#241](https://github.com/astanin/python-tabulate/issues/241))
- Compact XML output; escape quotes in swagger description parsing

## [1.2.2] - 2024-06-20

### Changed
- Updated pandas and PyInstaller to latest versions

## [1.2.1] - 2024-06-17

### Security
- **requests 2.31.0 → 2.32.0** —
  [CVE-2024-35195](https://nvd.nist.gov/vuln/detail/CVE-2024-35195): proxy
  credentials leaked via HTTP redirect when using a SOCKS5 proxy (MEDIUM). elm's
  `--proxy` flag uses SOCKS5, making this directly applicable.

## [1.2.0] - 2024-04-26

### Changed
- `jinja2-cli` now installed and run from within the venv (previously required a
  global install)

## [1.1.0] - 2024-04-15

### Added
- XML output format
- Moved build system to venv + PyInstaller for self-contained binary distribution
- Censored access_id and access_key in debug output

## [1.0.6] - 2024-02-07

### Added
- API error code documentation in `ERRORS.md`

### Fixed
- Comma-separated filters now correctly handle escaped commas (issue #36)

## [1.0.5] - 2024-02-01

### Changed
- Updated copyright year and README for 2024

## [Older versions]

Versions 1.0.1–1.0.4, 1.0.0, and pre-1.0 (0.9.x) covered initial development:
shell completion (#5), jira/markdown/rst/tab output formats (#11, #13, #15), file
output (#9), filter validation (#18, #3), HTML output, SOCKS5 proxy support, v2/v3
API support, and the initial release.

[Unreleased]: https://github.com/rdmarsh/elm/compare/v1.7.0...HEAD
[1.7.0]: https://github.com/rdmarsh/elm/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/rdmarsh/elm/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/rdmarsh/elm/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/rdmarsh/elm/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/rdmarsh/elm/compare/v1.2.3...v1.3.0
[1.2.3]: https://github.com/rdmarsh/elm/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/rdmarsh/elm/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/rdmarsh/elm/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/rdmarsh/elm/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/rdmarsh/elm/compare/v1.0.6...v1.1.0
[1.0.6]: https://github.com/rdmarsh/elm/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/rdmarsh/elm/releases/tag/v1.0.5
