# Changelog

All notable changes to elm are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- `tools/elm-ask` defaults to the cheapest current model rather than the most capable one: these are lookup questions and every one costs money. `ELM_ASK_MODEL` (or `run.sh -m`) picks another, and the question set in `todo.md` is how to tell whether a dearer model actually answers better. `run.sh` shows the default in [brackets] at the prompt, read from `agent.py` so the script and the code cannot drift apart.
- `tools/elm-ask` answers say what they mean in two places that were muddled: "How I worked this out" is plain words with no raw epochs or internal numbers (it had written "starts 1790310540 seconds in the future"), and a word that means two things has to be said specifically (it had written "its 2 active SDTs, which are both currently inactive" -- an SDT can exist without being in effect, an alert can be open or acknowledged, a device can be not reporting rather than decommissioned).

### Fixed

- `tools/elm-ask` answered "more than 50 alerts are open" because it counted AlertList with `-C`, which that endpoint cannot answer (it returns `>50`), instead of `-c -s0` as the notes say. Two changes, both in code rather than in wording the model may skip: a total that is not a number now comes back as "that is a lower bound, not the answer -- count the rows instead", and the first query against a command in a conversation returns that command's verified notes attached, whether or not `describe_command` was called. The notes cost tokens once per command, not per query.
- `tools/elm-ask` answered in UTC ("next downtime is 2026-09-25 at 04:29 UTC"), because LM returns epochs and the model was only told the UTC time. The page now sends the reader's timezone and offset with each question, and the answer gives local times with the zone named, plus "in about N days" for anything upcoming. Where an answer uses LM's own `...OnLocal` fields, which are in the portal's timezone rather than the reader's, it says so.
- `tools/elm-ask` died with "This model does not support the effort parameter" (HTTP 400) when `ELM_ASK_EFFORT` was set and the chosen model does not take one (the small models refuse it). It now drops the setting for the rest of the run, says so in the progress line, and carries on, so model and effort can be chosen independently. `run.sh` notes which listed model ignores it.

### Added

- `tools/elm-ask`: a **Save as PDF** button on each answer. It prints that answer alone -- the question, the text, the tables expanded (no scrolling box, headings repeated on each page) and the "Queries run" list opened -- through the browser's print dialog, where every browser offers "Save as PDF", with a line naming the profile, the model and the time. No new dependency: a print stylesheet and a few lines of JavaScript, which keeps the container offline and nothing to keep up to date. The CSV download stays for spreadsheet work.
- `tools/elm-ask/run.sh`: a launcher that asks which model and effort to use, then starts the container. The model prompt offers the usual few by number, dearest first, with a line on what each trades away; any other name works too, and Enter keeps the image's default (the list is one array at the top of the script). It checks `ANTHROPIC_API_KEY` and the profile before starting, takes `--model/--effort/--profile/--port`, `--build` to build the image first and `--dry-run` to print the docker command instead of running it, and prompts only for what was not given and only when there is a terminal to ask at. Model and effort are what a question costs, and both change per run without a rebuild.
- A project mark, `elm-logo.svg` (a terminal prompt), shown in the README and used as the page icon for elm-ask.

## [1.10.0] - 2026-09-19

### Added

- A refused command now says how to get it allowed: "To allow it, add 'AdminList' to allowed_commands in ~/.config/...ini", and tells scripts and AI assistants to ask the person rather than switch profiles or edit the file themselves. `elm --ai` and `elm-knowledge.md` say the same, so an assistant that hits the limit reports what it needs instead of working around it.

- `tools/elm-ask/` (prototype): a local web page where people who don't use elm ask questions about a portal in plain English ("what devices have alerting disabled?") and get a short answer, sortable tables with CSV download, caveats, and the exact queries it ran. Claude plans the queries and runs read-only elm commands through five tools (`find_commands`, `describe_command` = `elm COMMAND --info`, `run_elm`, `jq`, `show_table`); rows are kept as jsonl datasets so counting and joining happen in jq, not in the model. It ships as a Docker image that renders elm from `_jnja/` itself, so users need nothing else installed; the port is published on localhost only. Safety: the model can choose only a command and its filter, fields, paging and parameters, never global flags (so not `-f api`/`curl`/`wget`, which print the auth header) or another profile; secret-bearing fields (collector tokens and config blobs, API token keys, unmasked credential properties) are removed before the model, jq or the page see a row; and it runs as the `ai` profile, refusing to answer until `ai.ini` exists and sets `allowed_commands` (`ELM_ASK_ALLOW_UNRESTRICTED=1` overrides). `elm-knowledge.md` goes with every question, which is why that file now has a size budget. Questions and the query results the model reads are sent to the Claude API; see the tool's README.

- A profile can allow only some commands: `allowed_commands = ['MetricsUsage']` (or shell-style patterns such as `'Device*'`) in its `.ini`. It applies to anyone using the profile, so a restricted profile for a documentation job, an automation script or an AI assistant cannot reach other endpoints through a typo or a wrong guess. Any other command stops before a request is sent, with exit code 3 and a message naming the profile and showing the attempted command, so a person can run it deliberately. `--help` and `--info` respect it too (no credentials are needed to read the restriction, so a restricted profile does not advertise commands it cannot run), `elm --help` lists only the allowed commands, `elm --list` shows `(allows: ...)`, and `elm --ai` tells assistants not to switch profiles to get round it. No `allowed_commands` line allows everything and `[]` allows nothing; `None`, `''`, an empty name or an unparseable value is an error rather than a guess (`None` reads as "no commands", so treating it as "no restriction" would be a trap). It is a guard rail rather than a security boundary; the README says to pair it with an API token whose LogicMonitor role matches. New `ai.example.ini` suggests a 44-command profile for AI assistants with the reasons for what is left out, and `elm --list` now skips any `*.example.ini` (previously only `config.example.ini`). New `make testallow` target (offline, part of `make test`).

- `make testdocs` (now part of `make test`) keeps the AI-facing docs from growing back: it fails if `elm-knowledge.md` passes 8,000 characters or any command's `--info` passes 16,000. The build now also fails on a duplicate key in `elm-notes.yaml`, which YAML would otherwise resolve by silently dropping the earlier entry. CLAUDE.md gains an "AI-facing docs: keep them small" section with the rules behind the budgets: one home per fact, don't repeat the swagger, say how a claim was verified, fix rather than append.

- `elm COMMAND --info` describes a command without calling the API or needing credentials: its path, usage and parameters; its entry from `elm-notes.yaml` (tested behaviour, known API bugs, corrected field meanings, example commands); and every response field from the swagger with its type and a one-line description. Notes come first and are marked as taking precedence, because the swagger's descriptions are LogicMonitor's and are sometimes incomplete. Until now the notes were only useful to someone who knew to open `elm-notes.yaml` and search it; `--info` puts them where the command is. The text is built into each command module at `make` time by the new `mkinfo.py` (run from `make init` as the `_info` target), so the PyInstaller binary needs no data files and startup is unchanged; `mkinfo.py` only rewrites definitions whose text changed, so editing one command's notes re-renders only that command. It is written to be short — one line per field, trimmed descriptions — because it is also what AI assistants read: `elm --ai` now tells them to run it before using an unfamiliar command. PyYAML is a new build-time requirement. New `make testbasic` assertions cover the output, a command with a required parameter, and running with no credentials.

### Changed

- `elm-knowledge.md` is cut from 40 KB to 6 KB (about 10,000 tokens to 1,700). AI assistants read it in full before every question, so most of its length was cost: per-command field lists, long recipes and background that only matter for one command. It now holds only rules that apply across commands, and points to `elm COMMAND --info` and `examples/` for the rest. Nothing was dropped without a home: per-command facts moved into `elm-notes.yaml`, where `--info` shows them (deviceType values, alertStatus format, lastCollectedTime, apiTokens status, V4Metadata and PortalInfo entries, AssociatedDeviceListByDataSourceId limits); recipes moved verbatim into `examples/` (alerts, datasources, filtering, and the new `logicmodules.md` and `health-checks.md`); sections that already existed there (Confluence publishing, datapoint counting, devices without a datasource, API token audit) were removed as duplicates. Every code line from the old file was checked against the new homes.

### Fixed

- A config file that cannot be parsed now names the file and the line numbers, but never the lines themselves: "cannot parse ~/.config/logicmonitor/credentials/ai.ini: invalid syntax at line 1, 2, 3. Every value needs quotes...". The old message said only "Parsing failed with several errors. First error at line 1", which does not say which of several profiles was at fault; configobj's per-line errors quote the offending line back ("Invalid line ('access_key = ...')"), which would put a credential into the terminal, a log or a pasted screenshot, so elm now reports line numbers only. The same applies to a profile whose allowed_commands cannot be read. A `make testallow` assertion checks a malformed credential value does not appear in the output, and fails if the line is echoed back.
- `elm -p NAME --help` for a profile whose `allowed_commands` matches nothing had no Commands section at all, which reads as a fault; it now says "(none allowed by this profile)".

- `elm COMMAND --info` cut field descriptions at 90 characters, which removed exactly the useful part of the long ones: `deviceType` and `awsState` lost the list of what their values mean. Descriptions are now shown whole (about 20% more description text).
- `elm-notes.yaml` gave deviceType 1 as "a real device" and 6 as "LM Service"; the swagger's own description says 1 is an APPGROUP device, 3 a service device and 6 a biz_service device, and none of 1 or 3 were on the test portal to check. The table now follows the swagger, and "real devices" is given as deviceType 0 with the open question about 1 noted (`tools/elm-datasource-matrix.py` still keeps 1).
- `elm --ai` said the default `config` profile "points to a safe sandbox/test environment". That is one person's setup, not something elm knows; it now tells assistants not to assume it and to ask which profile to use. It also said responses are "wrapped: {"CommandName": [...]}", which is only true of `json` and `prettyjson` (`jsonl` is one bare record per line); it now describes each format's shape. It also gains a short "keep token use down" section, lists `--info` among the command flags and `sqlite` among the formats, and no longer says the notes are always right.

- The "devices with alerting disabled" recipe (`elm DeviceList -F alertDisableStatus:1`) matched nothing: `alertDisableStatus` is a string, `<group>-<device>-<instance>` with each part `disable` or `none`, and the API ignores positive filters on it. It also missed the point that most devices with alerting off get it from a group: on the test portal 39 devices were disabled by their own setting and 744 in total. `examples/health-checks.md` now has a working recipe (verified: the middle part matches `disableAlerting` exactly), `elm-notes.yaml` explains the field under DeviceList, and the wrong claim under AlertList is removed.
- `elm-notes.yaml` told readers to prefer `system.sysinfo` over OS-named device groups, while `elm-knowledge.md` said `system.sysinfo` cannot be trusted on its own. Both fail in practice (the collector's OS can show through `system.sysinfo`; groups can hold other devices), and the note now says to combine them.

- `elm COMMAND --help` failed with "access_id, access_key or account_name not set" when there was no config file. The group callback that checks credentials ran before the command's own options were parsed, so per-command help was unreachable on a fresh install — only `elm --help` worked. `--help` and the new `--info` are now handled before that check.

- A flag on the wrong side of the command name now says how to fix it. Global flags go before the command name and command flags after it, but a misplaced one failed with a bare `Error: no such option: -c`, which gave neither a person nor an AI assistant anything to act on — and assistants kept writing `elm -c AlertList`, including from a wrong example in `elm-knowledge.md`. Every such error now adds a `Hint:` line, e.g. `Hint: -c is a command option: put it after the command name, e.g. elm AlertList -c`. It covers command-only flags placed before the command (`-c`, `-C`, `-F`, `-S`, `--fields`, ...), global-only flags placed after it (`-p`, `-H`, `-I`, `-v`, `--head`, ...), and the three flags that mean different things on each side (`-f`, `-o`, `-s`), whose value errors now name the other meaning: `elm -s 5 DeviceList` still reports that *DeviceList* is not a valid integer, but adds `for --size put it after the command name`. The hints are derived from the options elm actually defines, so they stay correct as flags are added. Two mix-ups that did not error now get caught: `elm DeviceList -f csv` (an output format passed as `--fields`) is refused before the request is sent, where it used to make the call and then report `no valid fields selected`; and `elm -o 2000 DeviceList`, valid syntax for writing page 1 to a file named `2000`, now warns when the filename is all digits. New `make testbasic` assertions cover each case.
- `elm --ai` told assistants to "prefer `-C`" for counting with no exception, but AlertList and AuditLogList return no real total, so `-C` prints a warning and `>50` (verified live against 621 uncleared alerts). The guide now names both commands and says to use `-c -s0` for them, and lists which flags are global-only and command-only rather than only the three that collide.
- The sqlite examples in `examples/general.md` and `elm-notes.yaml` put `-f sqlite -o lm.sqlite` after the command name, where they mean `--fields` and `--offset`, so the commands failed as written. Found by parsing every `elm` command line in the docs with elm's own parser.

- `tools/elm-change-advice.py`'s "what to expect" section said only that monitoring would be briefly interrupted. LogicMonitor's [LogicModule Updates](https://www.logicmonitor.com/support/logicmodules/about-logicmodules/keeping-your-datasources-up-to-date) page documents a far more serious consequence that an approver reading "brief interruption" has not been told about: **historical data can be lost permanently** — when a datapoint is renamed or removed, when Active Discovery rediscovers instances under different names, or when an AppliesTo change stops the module applying to a device even temporarily, which discards all history for that module on those devices. The notice now spells all three out and cites the page. Each module also carries its `originLocator` (e.g. `FJJGMW`), and the implementation plan opens by looking each module up in the Exchange by that locator to read the target version and review the diff — the API cannot supply the target version, so that lookup is what establishes what is actually changing. Terminology corrected throughout: the module library is **LogicMonitor Exchange**, not the "module toolbox" (which survives only where it names a literal URL path segment).

- `tools/elm-change-advice.py` told you to export every module before upgrading it. That is unnecessary friction for the normal case, and friction is what makes people skip a backout step: an unmodified official module is a published registry version, so the version you upgraded from can simply be reinstalled from the module toolbox — and the notice already lists that version against each module, which is what makes the rollback actionable. The export advice now appears only where it is actually needed, naming the specific modules: a **locally customised** module's content exists nowhere but the portal, so reinstalling a published version will not bring its edits back. With no customised modules in scope the implementation plan loses the export step entirely.

- `tools/elm-change-advice.py` reported elm's `Warning: no data found` as an error, once per module. A module applied to no devices returns empty stdout, exit 0, and that warning on stderr — a normal result, since most modules are applied to nothing — but the JSON parse failed and the handler printed elm's stderr as though the call had failed, producing a wall of warnings during a long run. Empty stdout with a zero exit is now read as "no records"; real failures (non-zero exit, or unparseable output that is not empty) still report as before.
- `tools/elm-change-advice.py` had no guard on the volume of device lookups, so piping a whole `elm-module-updates.py --json` report in — the obvious thing to try — silently began 2392 API calls for 1196 modules, around 40 minutes of work for a notice that would have claimed every module in the portal was being changed on one day. `--max-device-calls` (default 100, two calls per module) now refuses before making any of them and says how to narrow the input. `elm-module-updates.py` has had the same guard since its device columns were added.

### Changed

- `tools/elm-change-advice.py` names the affected devices **under the module they belong to**, instead of pooling every module's devices into one list at the end of the notice. With several modules in one change, a single pooled list cannot answer the question a reader actually has — who is affected by this change to *this* module. Names appear only where there are few enough to read: `--list-devices-under N`, default 10, replacing `--max-devices` (which capped the pooled list at 25 names). Past the threshold the device count already on the module's line stands on its own; raise it to name more, or pass `0` to never name them. In the Markdown format the per-module lists become a `## Devices` section, since they will not fit in the table.

## [1.9.0] - 2026-09-12

### Fixed

- `make swagger` works again. LogicMonitor served the spec from behind a Cloudflare bot challenge from 2026-08-16 (HTTP 403 and a "Just a moment..." interstitial instead of JSON, reproduced from two networks); as of 2026-09-11 it returns HTTP 200 and ~833 KB of `application/json`, confirmed from two independent networks, and the download is byte-identical to the committed snapshot — so upstream has not changed the spec in that time either. The docs that said the target "currently fails" (`README.md`, `CLAUDE.md`) now describe it as the normal path, with `make swaggerfile` as the fallback, and the `todo.md` item tracking the block is closed (the outcome is recorded under CLAUDE.md's Resolved list so it is not re-investigated).

- `V4Metadata` (`/setting/logicmodules/metadata`) and `ContractInfoByCompany` (`/usage/contractInfo`) were unusable in every format but `json`, and crashed with a traceback even then. Both return a **bare JSON array** rather than the usual `{total, items, ...}` envelope, and `engine.py`'s fallback for an envelope-less response is the one written for single-record `...ById` queries: it wrapped the whole array as a single item, so `items` became `[[{...}]]`. (Note this is *not* the same shape as `MetricsSummary` and `MetricsUsage`, which return a bare JSON **object** — one record — and which that fallback has always handled correctly.) Downstream, `-c` and `-C` reported `1` instead of 5147, the table formats rendered one row whose headers were the column *numbers* `0,1,2,...`, and the post-output field check ran `obj['items'][0].keys()` on a list and raised `AttributeError` — after the JSON had already been printed, so the command exited 1 on output that was actually fine. The fallback now tests for a list first and uses it as `items` directly. Verified live: `V4Metadata -c` and `-C` both report 5147 and `ContractInfoByCompany -c` reports 6 (each previously `1`), `-f csv` emits real column names for both, and `-f json` exits 0; `DeviceList -c`, `MetricsSummary` and `DatasourceById --id 14` are unchanged. The `elm-notes.yaml` entries for both commands documented the symptoms ("CSV output broken: column headers are numeric", "returns nested `[[...]]` array") and have been corrected — the nesting was elm's, not the API's.

- `elm --ai` and `elm-knowledge.md` warned that global flags must precede the subcommand, but only illustrated it with `-f` (`--format` vs `--fields`). Two more short flags are reused on both sides with different meanings and were undocumented, which is exactly what trips up AI assistants driving elm: `-s` is `--proxy <HOST PORT>` globally but `--size N` per-command, and `-o` is `--filename` globally but `--offset N` per-command. Verified live: `-f` and `-s` misplacement both error (`-s` misleadingly, since it takes two values, so `elm -s 1000 DeviceList` reports that *DeviceList* is not a valid integer and names `--proxy`), but **`-o` fails silently** — `elm -o 2000 DeviceList` exits 0, writes a file literally named `2000`, and returns page 1. A pagination loop with `-o` on the wrong side therefore re-fetches page 1 every iteration while leaving files named after the offsets. Both docs now carry the full three-flag table and single out `-o` as the silent one.

- `-f jsonl` emitted a trailing blank line, so every jsonl stream carried one more line than it had records. `DataFrame.to_json(orient='records', lines=True)` already newline-terminates the **last** record, and `click.echo()` then appended its own newline, ending the stream with `\n\n`. The `csv`/`tsv` branches have always stripped that duplicate (`output[:-1]`); the `jsonl` branch never did. Anything counting lines rather than parsing them saw a phantom record — a paginated fetch of 2686 groups at `-s 1000` reported 1001/1001/687 instead of 1000/1000/686 — and a per-line consumer that extracted a field from the blank line got an empty value (in the reported case, a file named after an empty id). Confirmed live: `-f jsonl DeviceList -s 3` now writes 3 lines, and a two-page fetch of a 1576-device portal sums to exactly 1576. `latex` had the identical trailing newline and is stripped the same way (cosmetic there — a blank line after `\end{tabular}`).
- `Warning: results truncated by size limit` fired on every page of a paginated fetch, including the last one, because it tested `total > size` while ignoring `--offset`. `total` is LogicMonitor's count for the whole filtered query, not the records remaining after the offset, so with 1576 devices and `-s 1000` both `-o 0` and `-o 1000` warned even though the second page completed the set. It now compares `offset + rows returned` against `total` and only warns when records genuinely remain (the negative-`total` case, where LM cannot compute an exact count, still warns as before). Note `-c`/`-C` are unaffected — they never reach this branch.
- `ERRORS.md` documented this warning under a heading that was not the message elm actually prints (`size limit is less than total records`), so grepping the observed text found nothing. Renamed to the real string and expanded with the offset-aware behaviour.

- The README's per-command help sample is now generated rather than hand-pasted, and shows `DeviceList` instead of `AdminById`. `AdminById` was a poor choice of example: it is a by-id endpoint, so its help has no `-s`, `-o` or `-F` at all — the paging and filtering flags the surrounding prose discusses, and it therefore omitted the full `-F` operator table that every list command prints inline, which is the most useful part of a per-command help. `make docs` grew a `DOCS_BLOCKS` list of `<marker>:<elm args>` pairs and now loops over them, so the block is refreshed from the real binary alongside the top-level `elm --help` block and cannot silently rot again. Two new guards: a missing marker in README.md is now an error rather than a silent no-op, and the existing "produced no usage output" check names which invocation failed.
- README carried the same `-c`/`-C` problems in two more places, neither of which the earlier fix reached. The "Counting records" paragraph repeated the bad `-c -s0` advice as a general technique, and the `elm AdminById --help` sample block still showed the old option text (it is hand-pasted, not regenerated by `make docs`, which only refreshes the top-level `elm --help` block between its markers). The paragraph now leads with `-C` and explains that `-c` is `min(-s, matches)`; the sample block was regenerated from the current templates, which also picked up `-h, --help` where it had been showing a stale bare `--help`.
- Each command's `-c`/`-C` help text rewritten as a contrasting pair, because the old wording (`Return qty of query objects instead of query data` / `Return qty of ALL objects instead of query data`) did not say what either actually counts. Now `-c` reads `Count rows returned by this query (limited by -s, max 1000)` and `-C` reads `Count all rows matching -F (LM's total; not limited by -s)`, so the difference that matters is the one the reader sees.
- `elm --ai` and every command's `--help` claimed `-C`/`--total` "ignores -s and -F". The `-F` half is wrong: `-C` **respects** filters. Verified 2026-08-24 against a live portal -- `DeviceList -C` returns 1576 unfiltered and 1024 with a `-F` filter applied, and matches the exact row count on filters narrow enough to cross-check. Mechanically it could not be otherwise: `engine.py`'s `_output_only` set means `-c`/`-C` are never sent as query params, so the filter still reaches LogicMonitor and `-C` simply prints `obj['total']` for that filtered query. The "ignores -s" half is correct, since a total is independent of page size. Both help strings now say `respects -F, ignores -s`.
- The same mistake made `elm-notes.yaml` recommend a workaround that returns a wrong answer. It suggested `-c -s0` for a "real count", but `-c` counts the rows actually fetched and a page caps at 1000 -- so for the filtered set above it reports 1000 instead of 1024, silently under-reporting rather than erroring. The note now scopes that workaround to the only case it is needed (`AlertList`/`AuditLogList`, which return LM's negative sentinel instead of a total, and only when the true count is under 1000), and `--ai` now tells the reader to prefer `-C` for counting.

### Added

- `tools/elm-module-updates.py` with `--devices` is now a **running order, least risky first** — work down the list, doing the safe changes before the ones that can hurt, with age breaking ties. Without `--devices` the order stays most-out-of-date-first, since the risk score cannot be trusted without a device count. The `--sort` option introduced earlier in this cycle is gone: these are the only two orderings that mean anything, and choosing between them is what `--devices` already says. The device lookups are also **no longer capped by default** (`--max-device-calls` defaults to 0) — the full list is worth waiting for — and only **in-use** modules are looked up, which is what makes that practical: a module nothing is collecting has no history to lose, so its risk is near zero however many devices its appliesTo matches, and the lookup cannot change where it lands. On the test portal that is 186 lookups rather than 1196, minutes rather than half an hour, for the same order. The run prints a time estimate before it starts.

- `tools/elm-module-updates.py`: a **risk** column, 0-10, combining how much breaks with how likely that is. Consequence is breadth and depth, log-scaled, breadth counting about twice depth — 1 instance on 1000 devices outranks 1000 instances on 1 device, because LogicMonitor's worst documented outcome (an AppliesTo change that stops a module applying) destroys history *per device*, and alert storms scale with devices. Likelihood is age: every year behind adds 0.15, since a bigger version gap folds in more released change and more chance of a renamed datapoint or restructured discovery. Age is a proxy for the size of the diff, not a measure of it — the API exposes neither the target version nor what changed — so it is weighted modestly, contributing at most ~1.4 of the 10: a nine-year-old module on one device scores 2.3, a six-month-old one on 300 devices scores 8.0. All three inputs stay in their own columns so the score is auditable, and the coefficients are a one-line change.

- `tools/elm-module-updates.py`: a **status** column carrying the module's `originStatus`, so a widened listing shows which rows are `CORE` and which are `DEPRECATED` / `COMMUNITY` / `SECURITY_REVIEW` instead of leaving them indistinguishable. It appears in the Markdown report only when the selection actually contains more than one status — the default report is entirely `CORE` and the `Selected:` line above the table already says so, the same reason `type` and `usage_of` are dropped when constant. `--csv`/`--json` carry it always, renamed from `origin_status` to `status` to match the `--status` flag that filters on it.

- `examples/general.md`: a **Publish to a Confluence page with mark** section — the copy-paste form of the `--head` metadata block, in both the write-a-file and the one-command process-substitution shapes, with the reasons each flag is there. No wrapper script and no new elm format: `--head` already supplies exactly the block `mark` wants. Both commands were run verbatim against `mark --compile-only` before being written down.

- `elm-knowledge.md`: a section on publishing elm output to Confluence with [`mark`](https://github.com/kovetskiy/mark), which needs nothing added to elm — `--head` supplies the metadata block and `-f md` the table. Covers the two things that catch people out: mark reads **files, not stdin** (`-f`/`--files` takes paths and globs; only `--password -` reads stdin), so a pipe fails while a process substitution works (`-f <(...)`, which mark processes as `/dev/fd/63`); and bare elm output has no H1, so `--title-from-h1` needs one supplied via `--head` or a `<!-- Title: -->` comment — the `tools/` reports already emit one. Also records why `-f tab` must not be used for this: piped through `mark --compile-only`, its dashes become an `<hr />` and the rows collapse into a single paragraph. Verified against mark 16.19.0.

- `elm-knowledge.md`: `-f md` is **not** a Markdown pipe table — it is tabulate's `simple` style, space-aligned columns under a row of dashes, which renders as a preformatted block rather than a table anywhere the Markdown is actually parsed (a wiki page, a PR body, a Confluence page via `mark`). `gfm` and `pipe` are the pipe-table formats. The name makes `md` the obvious pick for those destinations and it is the wrong one, so the distinction is now written down with a side-by-side example.

- `tools/elm-change-advice.py` — drafts the change notice for a LogicModule upgrade: what is changing, when, who is affected, what to expect, and what happens if it goes wrong, with the impact filled in from the live portal. Pairs with `elm-module-updates.py` (`--from` reads its `--csv`/`--json` output, `--id` takes ids directly). Three shapes via `--format`: `email` (plain text wrapped to 72 columns with a subject line), `itsm` (summary / risk / impact / implementation / backout / test plan for a change record), `md`, or `all`. **It drafts only** — nothing is sent, no mail is configured, no ticket is raised, and it never performs the upgrade it describes; the notice goes to stdout for a human to edit and send. Site-specific fields (window, approver, reference, contact) are `<ANGLE BRACKET>` placeholders so an unedited draft is obviously unfinished. Risk is derived and explained rather than asserted: a deprecated module makes it High (it cannot be upgraded at all, only replaced — the change is a migration), a customised module Medium (upgrading overwrites local edits), and a wide blast radius is quoted with its numbers. Two impact counts are deliberately never merged: instances actually *collected*, and the devices the module *applies to* — one module in the test portal collects 2 instances but applies to 1205 devices. Since `AssociatedDeviceListByDataSourceId` caps at 1000 rows per page (a module with 1205 devices silently returns exactly 1000, which reads as a real figure), the count comes from `-C` and the names are treated as a sample, capped by `--max-devices` and labelled as incomplete when it is. `--portal NAME` links each module to itself in the portal, sharing the template and `--url-template` override with `elm-module-updates.py`: a Markdown link on the name in `md`, and the URL on its own line beneath each module in `email` and `itsm`, since plain text has no inline links. Documented in `tools/README.md` (Change advice).

- `make swaggerfile FILE=<path>` — installs a browser-saved copy of the LM swagger spec as `swagger.documented.json`. `make swagger` downloads and installs in one step, but when the download is blocked there was no target for the half that still works — validating and installing a file fetched some other way. That was the situation from 2026-08-16, when LogicMonitor put the spec behind a Cloudflare **JavaScript** bot challenge `curl` cannot answer (a browser UA does not help); the block has since cleared and `make swagger` works again, so this is now the fallback for if it returns, and for refreshing the spec on a machine with no route to logicmonitor.com. The manual `jq . ~/Downloads/swagger.json > swagger.documented.json` it replaces would happily overwrite the snapshot with whatever was in the file. This target refuses: a saved Cloudflare interstitial (not JSON — the error prints the leading bytes and names the likely cause), JSON without `paths`, a spec whose `info.version` is not `3.x` (elm is v3-only), or a file that has lost more than a quarter of its endpoints, which is what a truncated or partial save looks like. It also warns on an unexpected `basePath`, prints the endpoint-count delta before writing (`paths: 220 -> 221   added 1, removed 0`), pretty-prints via `jq .` so the committed snapshot stays diffable against upstream's minified original, and writes through a temp file so a failed run — or passing the snapshot as its own `FILE=` — cannot truncate the existing spec. On success it prints the review, rebuild, and `LEAK_SCAN_SKIP=1` commit steps. `make swagger`'s failure message now points at it, and `README.md` documents both paths. Both targets also say what they are doing before they do it — `make swagger` prints `[INFO] fetching <url>` before the (silent, retrying) `curl` and reports what landed on success (`[OK] swagger (220 paths, 1399409 bytes written)` — the pretty-printed size, not the ~833 KB minified download), and `make swaggerfile` prints `[INFO] reading <file>`. This is the first use of the Makefile's long-defined but unused `IN_STRING`.

- `tools/elm-module-updates.py` — reports LogicModules with a newer version waiting in the LM Exchange. The default report answers "which stock modules am I running an old version of, and does anything use them?": **DataSources** that are LM official (`originStatus` `CORE`), **not** locally customised, and upgradable, split into two sections — *not in use* then *in use* — each sorted **most out of date first**. It costs **one API call** regardless of portal size: `elm V4Metadata` (`GET /setting/logicmodules/metadata`), the feed behind the portal's module toolbox, which returns every installed module plus everything installable from the Exchange along with per-module `installationStatuses` (`IS_INSTALLED`, `CAN_UPGRADE`, `IS_CUSTOMIZED`, `CAN_INSTALL`), `originStatus`, `isInUse`, the installed `originVersion`, and `originPublishedAtMS`. **Ordering caveat:** LM exposes an `upgradeableRegistryId` pointing at the newer registry entry but no v3 endpoint resolves it, so the version you would upgrade *to* is not obtainable; ranking is by how old the version you are **running** is (`originPublishedAtMS` ascending), and the `version`/`age` columns describe the installed version, not the available one. Registry publish timestamps only begin around 2017-05, so older modules bunch at that floor and cannot be ranked against each other, and the few with no publish date are listed last. The usage count is **not one field**: `associatedHostsCount` is hard-wired to `0` for DataSources and ConfigSources (so those use `associatedInstancesCount`), every other type has a real host count, and appliesTo functions use `useInModulesCount` — so the Markdown column is headed with its unit (`instances`, `hosts`, `modules`) while `--csv`/`--json` carry both a `usage` number and a `usage_of` label for a stable schema. A module can be in use with a count of `0`. `-t`/`--type` takes another module type, several comma-separated, or `ALL` — the same single call already covers property/config/event/log/topology sources, SNMP sysOID maps and appliesTo functions at no extra cost, and with more than one type each section is split into a table per type; `--status` widens past `CORE` (`DEPRECATED`, `COMMUNITY`, `SECURITY_REVIEW`, or `ALL`); `--include-customised` and `--include-current` relax the other two filters; `--csv` emits one flat table of both sections with `in_use`/`customised`/`upgrade`/`origin_status` columns and `--json` the same rows as JSON; `--portal NAME` turns each module name into a link to that module in the portal's toolbox — the REST API exposes no UI link, but the feed supplies both halves of one (`model` is the toolbox path segment, `id` the module), so one template covers every module type; `--url-template` overrides it. The subdomain is deliberately not auto-detected, because the only ways to get it out of elm are `-f api` (which also prints the Authorization header) and `-vv` (which prints a truncated access key fingerprint). The report also now reports what it cannot show: **deprecated** modules are replaced rather than updated, so they never carry `CAN_UPGRADE` and can never appear — in the test portal that silently hid 371 installed deprecated datasources, 88 of them in use — so a stderr note gives the count, the `--status DEPRECATED --include-current` command to list them (without `--include-current` the report is empty, and the tool now explains why rather than saying "nothing matches"), and a link to LogicMonitor's published replacement/end-of-support table. `--tag TAG,...` filters on the modules' own tags (3303 of 3906 installed modules in the test portal are tagged, across 1383 distinct tags), and a `tags` column is shown three-at-a-time in Markdown and in full in `--csv`/`--json`. `--devices` answers "instances or devices?" — for datasources and configsources the usage column counts **instances**, and the feed has no device count for them at all, so this adds `devices` (how many the module's appliesTo matches, from `-C`) and `active` (how many are actually collecting, from `hasActiveInstance` on `AssociatedDeviceListByDataSourceId`) at the cost of one call per module. The three are genuinely different numbers — one module collects 2 instances, applies to 1205 devices, and is collecting on 2 of them — so none substitutes for another; a trailing `+` on `active` marks the >1000-device cases where the API's page cap makes it a floor, and `--max-device-calls` (default 100) refuses a run that would make too many calls. `type` is now always present in `--csv`/`--json`, because module ids are only unique *within* a type (329 ids in the test portal belong to several types; id 28 to six), which would otherwise make piping into `elm-change-advice.py` ambiguous. `-p`/`--profile` or `-c`/`--config` selects the portal. Report on stdout, progress and counts on stderr. The report cannot be produced by elm alone — `V4Metadata` takes no `-F`, and the `-S` it does accept is silently ignored by that endpoint — so selection and ordering are client-side. Documented in `tools/README.md` (Module updates).

- `make testpage` — a regression target for the two pagination fixes above: asserts `-f jsonl` writes exactly one line per record (piping to `wc -l` rather than through `$(...)`, which strips the very trailing newlines the bug produced), that the truncation warning still fires when records remain, and that it does *not* fire on the last page (`-o $((total - 1))`). Added to the `test` aggregate; connects to LM.

### Removed

- `ai.md`: the "Track skills you personally develop in SKILLS_USED.md" principle, and `SKILLS_USED.md` from the recommended project structure. The advice was aimed at the human reader — keep a private, dated record of what you personally built, debugged and decided, so AI assistance does not quietly stand in for your own skill development — but `ai.md` is read mostly by AI assistants, which consistently misread it as an instruction to maintain the file themselves. A principle that reliably produces the opposite of its intent is worse than no principle. `SKILLS_USED.md` is gitignored and unaffected; keeping one is still a fine idea, it just is not something to ask an assistant to do.

- `tools/elm-module-updates.py` now reports deprecated modules by default: `--status` defaults to `CORE,DEPRECATED`, and a module qualifies if it is upgradable **or** deprecated. The second half matters — a deprecated module can never carry `CAN_UPGRADE`, because it is replaced by a different module rather than updated, so simply adding `DEPRECATED` to the status filter would have let through exactly nothing. These are the modules that most need looking at (they have an end-of-support date), and they were invisible: the default report went from 852 matches to 1196, and from 106 in use to 186, on the test portal. The run summary counts them and links LM's replacement/end-of-support table, and because the selection now spans two statuses the `status` column appears by default. `--status CORE` restores the old behaviour and reports how many modules it dropped.

- `tools/elm-module-updates.py`: the `tags` column shows every tag rather than the first three, and the `active` column is no longer `2+` in machine-readable output. The `+` marks the >1000-device rows where the API's page cap makes the count a floor, but putting it in the number made the whole column non-numeric for anything consuming the CSV or JSON. The marker now only appears in the rendered Markdown table; `--csv`/`--json` keep `active` a plain number and carry the caveat in a separate `active_capped` column, the same split already used by `usage`/`usage_of`.

### Changed

- **`-f md` now emits a real Markdown pipe table** (issue #55). A sweep found three more places describing the old behaviour, all corrected: `examples/general.md` ("`md` and `tab` ... currently produce identical output"); `elm-notes.yaml`, whose `md` entry called it "Tabulate 'simple' format — same as tab" with the note "may be a bug or historical alias" — it was; and `elm --ai`, which listed the format names with no indication of which are Markdown, now says so in a line. The `make testfmtcont` assertion for `md` was also vacuous rather than wrong: it grepped for `-----`, which a GitHub table's `|------|` separator still contains, so it passed without being able to tell the new format from the old. It now asserts a pipe table (`^|-`), the same check `gfm` gets. It was tabulate's `simple` style — space-aligned columns under a row of dashes — which renders as a preformatted block rather than a table anywhere the Markdown is parsed: a wiki page, a PR body, a Confluence page via `mark`. It was also byte-identical to `-f tab`, so the name bought nothing. `md` is now an alias for `gfm`, sharing its branch so the two cannot drift apart again (and picking up the pipe-escaping `gfm` needs and `simple` did not — an unescaped `|` in a value breaks a pipe table). **This changes the output of `-f md`**: if you were relying on the old format, it is unchanged under its accurate name, `-f tab`. There was a historical defence — tabulate's `simple` is Pandoc's `simple_tables` — but nothing that parses CommonMark or GFM renders it as a table.

## [1.8.10] - 2026-08-16

### Removed

- `-x` / `--export` (export a query as a standalone Python script). It was a never-finished stub carried over from an older project: the handler referenced an `elm.flags` attribute that was never set on the context object, used `jinja2.FileSystemLoader`/`Environment` without importing them, and rendered a `save_query.py.j2` template that does not exist — so the advertised flag raised an exception on any use. The reproduce-a-request need it was meant to cover is already served by `-f api` (which prints the exact request URL and `Authorization` header) plus the standalone PyInstaller binary. Removed from `_jnja/elm.py.j2`, `_jnja/engine.py.j2`, and the README options list.

### Added

- `tools/elm-host-sdts.sh` — lists the SDTs (scheduled downtime) affecting each host in a list (one `displayName` per line from a file, from stdin via `-`, or as positional arguments; hosts are de-duplicated preserving first-seen order, and blank lines dropped). Resolves each host to a device id via `DeviceList`, then queries `AllSDTListByDeviceId` (`/device/devices/{id}/sdts`), which performs the SDT inheritance join **server-side**: it returns device, instance, and inherited group SDTs that actually apply to the device — correctly excluding a group SDT scoped to a datasource/instance the device does not have — so no manual `deviceGroupId`/`dataSourceId` cross-referencing is needed. Output is one aligned table per host with columns `TYPE` (the LM `sdtType`: `oneTime`/`daily`/`weekly`/`monthly`/`monthlyByWeek`), `ACTIVE` (the LM `isEffective` field, `yes`/`no`), `GROUP`/`HOST`/`INSTANCE` (only the scope the SDT applies to is filled, others show `-`; a group SDT shows its full path plus the limiting datasource in brackets when scoped to one), `FROM`/`TO` (`startDateTimeOnLocal`/`endDateTimeOnLocal`, rendered in the **portal's** timezone with abbreviation — not the local machine's), `DURATION` (the `duration` field rendered as e.g. `5h`, `1h30m`, `45m`), and `COMMENT`. Rows are sorted active-first then by `FROM` ascending. `--active` limits to currently-effective SDTs; `--exact` switches host matching from contains (`displayName~`) to exact (`displayName:`); `-p`/`--profile` selects the portal (defaults to `config`). Requires `elm`, `jq`, and `column`.
- `tools/elm-datasource-matrix.py` — builds a device-by-datasource usage matrix as a GitHub Flavored Markdown table (each row is a device — device ID then device name — and each datasource is a column; a cell is a tick `✓` where the datasource is applied, blank otherwise) for every datasource whose **name** matches a pattern. Pivots one `AssociatedDeviceListByDataSourceId` (`/setting/datasources/{id}/devices`) call per matching datasource, so the cost is one API call per datasource, not one per device. Matching is **case-insensitive by default**; `-s`/`--case-sensitive` (the same flag as ripgrep) narrows it so `NTP` matches `NTPv4`/`Cisco_NTP` but not incidental substrings like `AccessPoi[ntP]erformance` or `OverCurre[ntP]rotectors`. `-x`/`--regex` treats the pattern as a Python regex (anchor with `^`/`$` to match only the start/end of the name, e.g. `'^NTP|NTP$'`); to stay efficient it derives a literal substring from the pattern (e.g. `NTP`) to push as the server-side `name~` filter and refines with the full regex client-side, so the full datasource list (which can be thousands of entries) is never downloaded. Top-level `|` alternatives OR several patterns in one run (e.g. `'NTP|Ping'`) — since LM ANDs repeated `-F` filters, each branch becomes its own server-side `name~` call and the results are unioned. A size guard aborts before the per-datasource calls if more than `--max-cols` datasources match (default 20; each is also one API call) and before rendering if more than `--max-rows` devices would be rows (default 1000, LM's per-request `-s0` row cap, beyond which the underlying device lists truncate anyway); `0` disables a limit. GFM cells are padded so the raw Markdown source lines up too. **Real devices only:** rows are restricted to actual devices (`deviceType` 0 or 1); LM Services / Service Insight, cloud accounts/resources (AWS, Azure) and Kubernetes resources are excluded (not configurable). Drops datasources with no remaining devices (empty columns) and only lists devices using at least one match. `--csv` emits `id,device,<datasource…>` rows with `1`/`0` cells for spreadsheets; `-p`/`--profile` selects the portal (defaults to `config`). "Applied" is the live device→datasource association, not the daily `auto.activedatasources` property. Documented in `tools/README.md` (Datasource usage matrix).
- `examples/filtering.md` — a dedicated `-F`/`--filter` reference: operator table (`:`, `~`, `!:`, `!~`, `>`, `<`, `>:`, `<:`), `~` substring-search behaviour (case-insensitive, spaces OK), combining filters with repeated `-F` (AND), the no-OR limitation, comma-separated string fields, and the quoting/comma-escape gotchas. Linked from `examples/README.md` and `EXAMPLES.md`.

### Changed

- Build pipeline (no change to shipped CLI behaviour): PyInstaller now runs at `--log-level WARN`, shrinking build logs from ~5,200 lines of `INFO` chatter to the handful of real warnings. The bundled binary is ~20% smaller (119M → 96M) thanks to a post-build prune that drops pandas/numpy's own test suites (`*/pandas/tests`, `*/numpy/*/tests`), which elm never imports. The binary target now lists its real rendered inputs (`engine.py`, `elm.py`, `_cmds/__init__.py`) as prerequisites with `reqs` demoted to order-only, so a full `make && make install && make docs` builds the binary **once** instead of three times — previously the phony `reqs` prerequisite forced a fresh PyInstaller run on every invocation. `--exclude-module` was deliberately *not* used to drop the test suites: with `--collect-all` in play it registers each test submodule as a hidden import that the exclude then removes, emitting thousands of spurious `ERROR: Hidden import not found` lines.

- Two Makefile test targets renamed so their names fit the `make help` column: `testcountdebug` → `testcountdbg` and `testfmtcontent` → `testfmtcont`. The help recipe's name field was also widened from `%-12s` to `%-14s`, which straightens the alignment and leaves headroom for future targets — previously any name over 12 characters pushed its description out of the column and broke the whole list's alignment. The `test` aggregate and the CLAUDE.md testing notes were updated to match.
- README gained a **Development → Swagger specs and generated commands** section documenting the two committed specs and how they become commands. It spells out the distinction that is easy to get backwards — `swagger.*` files are raw swagger documents, the `commands.*.json` files derived from them are the stripped form — diagrams the `swagger.* → commands.*.json → _defs/<Command>.json → _cmds/<Command>.py` pipeline, and explains why 189 commands render to 176 modules (13 names appear in both specs and the undocumented one wins, which is the mechanism by which it patches the official spec). A "Refreshing the official spec" subsection covers `make swagger`, the Cloudflare block and the browser workaround, and why the snapshot is committed pretty-printed — so a refresh yields a reviewable diff of which endpoints changed rather than one unreadable ~800 KB line.
- README hero reworked to lead with use-cases — a "What can I use it for?" bullet list and an aligned table + CSV example block (replacing the single jsonl one-liner), so the front page answers "what can I use this for?" at a glance. The curl/wget bullet was dropped (niche) and "never" emphasised in the read-only note.
- `examples/alerts.md` — added "Find devices in SDT right now" (`SDTList -F isEffective:true`) and "Find unacknowledged active alerts" (`AlertList -F cleared:false,acked:false`), backing the new README use-cases ("missing a datasource" was already in `datasources.md`).
- `elm-notes.yaml` — corrected the `-f api`/curl auth expiry note: the LMv1 signature window is long and inconsistent across environments (measured valid 3h22m on one sandbox, yet under 2h elsewhere), not "within minutes/seconds".
- Standalone helper scripts in `tools/` are now documented in a dedicated `tools/README.md` rather than the main `README.md`. The **API speed test** and **Datasource usage matrix** sections moved there, an entry for `elm-host-sdts.sh` was added, and the main README now carries a short **Development → Tools** pointer. These scripts are out of scope of the elm program itself — not part of the CLI, and not built or installed by `make` — so keeping them out of the main README keeps it focused on elm.
- Git pre-commit hook's leak scan gained a second, always-on check independent of the manually-curated `.githooks/leak-patterns.local` denylist: it now blocks any `10.x.x.x` (except `10.0.x.x`, the range already used by this repo's own documentation examples) or `172.16.x.x`–`172.31.x.x` literal in newly staged lines, without needing the specific value to be added to the denylist first. `192.168.x.x` and the RFC 5737 documentation-only ranges (`192.0.2.x`/`198.51.100.x`/`203.0.113.x`) are deliberately left unblocked, since those aren't real internal addresses. Shares the existing `LEAK_SCAN_SKIP=1 git commit ...` bypass for genuine false positives. The scan logic was refactored into a reusable `scan_added_lines()` helper so both checks share one implementation.

- `SECURITY.md`'s "Supported Versions" table no longer enumerates version numbers. It listed 1.8.9 and 1.8.8 as supported, which both went stale every release and directly contradicted the sentence above it ("Only the latest release is supported. There is no backport policy"). The table now states the policy as a rule — `Latest release` supported, `Anything older` not — so it never needs editing again. The prose is unchanged.
- `.github/workflows/action.yml` renamed to `.github/workflows/markdown-link-check.yml`. The generic filename said nothing about what the workflow does; GitHub identifies workflows by the `name:` key inside the file (`Check Markdown links`), so nothing else needed updating — the README badges reference `dependency-review.yml` and `makefile.yml`, not this file.
- `.gitignore` now lists `_build/` and `_dist/` explicitly in the "ELM project compiled files" section. Both were previously ignored only by accident: the bare `elm` pattern happened to match the `elm/` subdirectory PyInstaller creates inside each. Should PyInstaller ever change that layout, build artefacts would have started showing up as untracked files.

### Fixed

- The official LogicMonitor swagger spec is now a **committed snapshot**, `swagger.documented.json`, rather than a file downloaded during every build. It sits alongside the `swagger.undocumented.json` that was already committed (`swagger.*` files are raw spec documents; the `commands.*` files derived from them by jq are the stripped form). `_defs/swagger.json` is now just a copy of the snapshot, so **`make` no longer touches the network at all** — builds are reproducible, work offline, and cannot be silently altered by an upstream change. Refreshing the spec is now the deliberate, separate `make swagger`. The snapshot is stored pretty-printed (1.4 MB, 50,622 lines) rather than as the minified single line upstream serves, so a refresh produces a reviewable diff of exactly which endpoints changed instead of one unreadable 833 KB line. Prompted by LogicMonitor putting the spec behind a Cloudflare bot challenge, which broke every build from a clean tree.
- Building against LM REST API v2 is no longer supported; elm targets API v3 only (`X-Version: 3`). `SWAGGER_V2_URL` and the version-conditional spec selection are gone, as is the dead v2 branch in `_jnja/command.py.j2` that generated per-command "Swagger URL" doc links. `make apiversion=<anything but 3>` now fails with an explicit error rather than silently producing a hybrid build — a v3 spec sent with a v2 version header — which is what removing the URL alone would have caused. The `make help` example that advertised `make apiversion=2` now shows `make PYTHON=python3.12` instead.
- The swagger download (now `make swagger`) no longer destroys the build when LogicMonitor returns something that is not the spec. `curl` was called with no `-f`, so an HTTP error page was written straight over the target and the failure only surfaced two steps later as a confusing `jq: parse error: Invalid numeric literal at line 1, column 10`. This is not hypothetical: `www.logicmonitor.com` now serves the spec behind a Cloudflare bot challenge, returning a 5.6 KB HTML interstitial with a 403. The target now downloads to a `mktemp` file with `curl -fsSL --retry 2`, validates the result is actually a swagger document (`jq -e 'has("paths")'`) before installing it, and reports the byte count and the first 60 bytes of whatever came back instead. `swagger.documented.json` is left untouched on failure, and the error explains how to fetch the spec with a browser. See `todo.md` for the still-open upstream problem — this makes the failure legible, it does not restore unattended downloading.
- The Makefile now sets `.DELETE_ON_ERROR:`. Without it, a recipe that failed part-way left its half-written target on disk, newer than its prerequisites, so the next `make` accepted the garbage as up to date — the reason a failed swagger download left an empty `_defs/commands.documented.json` that would have yielded a binary with none of the documented commands and no error.
- `make docs` no longer writes to the fixed paths `/tmp/elm_help.txt` and `/tmp/README_tmp.md`, which collide between users on a shared machine (and are a symlink-attack surface in a world-writable directory). Both are now created with `mktemp` and removed via a shell `trap` on `EXIT`/`INT`/`TERM`, so they are cleaned up even if the target fails part-way.
- `make docs` could silently destroy the help block in `README.md`. The help text is generated by the pipeline `elm --help | sed ...`, whose exit status is `sed`'s, not elm's — so if the binary failed or printed nothing (a broken build, a wrong `testbin` path), the pipeline still "succeeded" with an empty file, and the awk pass then rewrote `README.md` with the entire block between the `elm-help-start`/`elm-help-end` markers replaced by an empty code fence. The recipe now checks the captured output actually contains a `Usage:` line and aborts with a red `[ERROR]` leaving `README.md` untouched; the `mv` into place is also chained with `&&` so a failed awk pass can no longer overwrite the file.

- The LogicMonitor API request (`requests.get` in `_jnja/engine.py.j2`) now sets `timeout=(10, 120)` — a 10-second connect timeout and a 120-second read (between-bytes) timeout. Previously the call had no timeout, so if LogicMonitor or an intervening proxy stopped responding, elm would hang indefinitely instead of erroring. A timeout raises `requests.exceptions.Timeout`, a subclass of `requests.RequestException`, so the existing request-error handler reports it as elm's normal red `Error: request failed` message with no new error-handling code. The read timeout is per-gap, not a total-request budget, so a large but steadily-streaming result is still tolerated.

- `make install` from a clean tree failed with `[ERROR] venv/bin/jinja2 not found`. The `install` target's prerequisite chain (`$(bindir)/elm` → PyInstaller binary → rendered sources → `JINJA-exists`) never ran `init`, which is the only target that creates the venv and installs jinja2-cli — so `make install` only worked after a prior `make`. `install` now runs `init` and then re-invokes make (`$(MAKE) _render _build _install`), the same pattern `all` and `build` use; the re-invocation is required because from a clean tree `CMDTARGETS` is computed before `init` creates `_defs/`, so a plain prerequisite chain would also have built a binary with no command modules. The usual `make && make install` flow is unchanged (the second invocation finds everything up to date).

- Collector reachability/move-readiness tooling (`tools/lm-collector-reachability-run-all.ps1`, `tools/lm-collector-move-readiness-run-all.ps1`, `tools/elm-collector-readiness.sh`, `tools/lm-collector-reachability-check.groovy.j2`) mislabelled its TCP-port checks. `auto.network.listening_tcp_ports` containing `135` and `auto.wmi.operational == "true"` are two independent discovery signals that both triggered the exact same test (`tcpOk(ip, 135, ...)` — identical code in every version of the Groovy), so a device with both flags set got two protocol columns (`tcp-135` and `wmi`) that always agreed. Squashed into one `tcp-135` signal. Separately, the port-135/22/80/443 checks are all bare socket-connect tests with no protocol handshake or credentials, so labelling them `wmi`/`ssh`/`http`/`https` overclaimed what was verified — a passing `ssh` column didn't mean SSH auth would succeed, only that TCP port 22 accepted a connection. Renamed to the port numbers (`135`/`22`/`80`/`443`); `ping` and `snmp` keep purpose names since they're real protocol tests (ICMP, and an actual SNMP `GetRequest`), not bare connects. See `RECOMMENDATIONS.md` item 17 and `collector-debug-notes.md` for the fuller investigation (including why a real credentialed WMI test isn't a viable replacement for this tooling's specific use case).

- The same tooling's `snmp TIMEOUT` guidance only mentioned a wrong community string as the cause. In practice an SNMPv3-only device is likely the bigger cause and wasn't mentioned at all: the probe is hardcoded SNMPv2c/`public`, so it cannot succeed against v3 regardless of reachability, and gets no response either way (indistinguishable `TIMEOUT` for both causes). The failure-footer text (all three Groovy sources) and `examples/collector-readiness.md`'s "SNMP TIMEOUT" section now call out SNMPv3 explicitly and point at the collector debug console's `!snmpdiagnose version=v3 <host>` (documented in the new `collector-debug-notes.md`) to actually diagnose a specific device instead of guessing from a blind `TIMEOUT`.

- That SNMPv3 hint (previous entry) never actually printed for the case it was meant to help: the failure-footer block in all three Groovy sources was gated on `if (failures)`, but `failures` only collects `result == "FAIL"` — an snmp `TIMEOUT` is a distinct result value, so a device with only an SNMP timeout (everything else passing) never touched `failures`, the whole block was skipped, and the script printed "All checks passed" instead. Added a separate `timeouts` list (populated on `result == "TIMEOUT"`) and gated the block on `failures || timeouts`; timed-out device/protocol pairs are now also listed explicitly, the same way `FAILURES` are. Verified with a real Groovy interpreter (not just PowerShell here-string syntax checks) against a synthetic TIMEOUT-only device.

- Even fixed, that hint only reached the raw per-collector `.csv` files written to `OutputDir` (the Groovy's own footer text) — never the PowerShell scripts' own aggregate console output (the Comparison table, Move verdict, or Candidate verdict sections), which is what a user actually reads and where real runs showed `snmp TIMEOUT` repeatedly with no explanation anywhere on screen. Added the same hint directly to `lm-collector-reachability-run-all.ps1`'s Candidate verdict and `lm-collector-move-readiness-run-all.ps1`'s Move verdict, printed once at the end if any device shows `snmp`/`TIMEOUT` anywhere in that run's results. Verified with a synthetic PowerShell test reproducing the real scenario (SNMP timing out identically on every target collector).

- The port-number relabelling from two entries above (`wmi`→`135`, `ssh`→`22`, `http`→`80`, `https`→`443`) is reverted, per maintainer preference: purpose names are easier to scan than bare port numbers, especially across a wide device list. The "these are bare TCP connect checks, not credential/protocol verification" caveat is kept, but now as a printed legend line (`Protocol legend: wmi=135, ssh=22, http=80, https=443 -- ...`) at the top of every run's output — all four sources (both `.ps1` runners' summary table and embedded Groovy, `elm-collector-readiness.sh`'s summary table, and the standalone `.groovy.j2`) plus `examples/collector-readiness.md`. The `tcp-135`/`wmi` signal squash from two entries above is unaffected — that stays merged into one `wmi` column.

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

[Unreleased]: https://github.com/rdmarsh/elm/compare/v1.10.0...HEAD
[1.10.0]: https://github.com/rdmarsh/elm/compare/v1.9.0...v1.10.0
[1.9.0]: https://github.com/rdmarsh/elm/compare/v1.8.10...v1.9.0
[1.8.10]: https://github.com/rdmarsh/elm/compare/v1.8.9...v1.8.10
[1.8.9]: https://github.com/rdmarsh/elm/compare/v1.8.8...v1.8.9
[1.8.8]: https://github.com/rdmarsh/elm/compare/v1.8.7...v1.8.8
[1.8.7]: https://github.com/rdmarsh/elm/compare/v1.8.6...v1.8.7
[1.8.6]: https://github.com/rdmarsh/elm/compare/v1.8.5...v1.8.6
[1.8.5]: https://github.com/rdmarsh/elm/compare/v1.8.4...v1.8.5
[1.8.4]: https://github.com/rdmarsh/elm/compare/v1.8.3...v1.8.4
[1.8.3]: https://github.com/rdmarsh/elm/compare/v1.8.2...v1.8.3
[1.8.2]: https://github.com/rdmarsh/elm/compare/v1.8.1...v1.8.2
[1.8.1]: https://github.com/rdmarsh/elm/compare/v1.8.0...v1.8.1
[1.8.0]: https://github.com/rdmarsh/elm/compare/v1.7.10...v1.8.0
[1.7.10]: https://github.com/rdmarsh/elm/compare/v1.7.9...v1.7.10
[1.7.9]: https://github.com/rdmarsh/elm/compare/v1.7.8...v1.7.9
[1.7.8]: https://github.com/rdmarsh/elm/compare/v1.7.7...v1.7.8
[1.7.7]: https://github.com/rdmarsh/elm/compare/v1.7.6...v1.7.7
[1.7.6]: https://github.com/rdmarsh/elm/compare/v1.7.5...v1.7.6
[1.7.5]: https://github.com/rdmarsh/elm/compare/v1.7.4...v1.7.5
[1.7.4]: https://github.com/rdmarsh/elm/compare/v1.7.3...v1.7.4
[1.7.3]: https://github.com/rdmarsh/elm/compare/v1.7.2...v1.7.3
[1.7.2]: https://github.com/rdmarsh/elm/compare/v1.7.1...v1.7.2
[1.7.1]: https://github.com/rdmarsh/elm/compare/v1.7.0...v1.7.1
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
