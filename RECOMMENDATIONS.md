# RECOMMENDATIONS

Agreed follow-up work from the 2026-07 project audit, in priority order
(smallest risk first). Written so that any AI assistant or contributor can
pick up an item and complete it without further context.

## Rules — read before doing ANY item

1. Read `CLAUDE.md` first. The rules there override anything else.
2. **Never edit generated files**: `elm.py`, `engine.py`, `elm-completion.bash`,
   anything in `_cmds/`, `_defs/`, `_build/`, `_dist/`. Fix the source instead:
   `_jnja/*.j2` templates, the `Makefile`, or `swagger.undocumented.json`.
3. After changing a template or the Makefile, rebuild and test:
   `make && make testbasic`. `make testbasic` is fully **offline** — it never
   contacts LogicMonitor — but it does need the built binary
   (`_dist/elm/elm`) and a default `config` profile to exist.
4. Do **one item at a time**. Run `make testbasic` before considering an item
   done. If a test fails and the fix isn't obvious, stop and report — do not
   pile on more changes.
5. Add a CHANGELOG.md entry under `## [Unreleased]` for every user-visible
   change (this project keeps detailed changelog entries — look at existing
   ones for the expected style and level of detail).
6. Never read or print the contents of `~/.config/logicmonitor/credentials/*.ini`
   (real credentials) or `.githooks/leak-patterns.local` (real customer
   tokens). Live API checks use the default `config` profile only (no
   `--profile` flag).

## Status legend

- `[x]` done
- `[ ]` ready to do
- `[defer]` agreed in principle, but do NOT start without the maintainer —
  needs a careful testing window

---

## [x] 1. `make install` fails from a clean tree

Done 2026-07-09. `install` now depends on `init` and re-invokes
`$(MAKE) _render _build _install`, matching the `all`/`build` pattern.
See CHANGELOG `[Unreleased]` → Fixed for the full explanation.

## [ ] 2. Add an HTTP timeout to the API request

**Problem:** `requests.get(...)` in `_jnja/engine.py.j2` (the line inside the
`try:` block, currently `response = requests.get(url, data=data, ...)`) has no
`timeout=` argument. If LogicMonitor or a proxy stops responding, elm hangs
forever instead of erroring.

**Change:** add `timeout=(10, 120)` (10 s to connect, 120 s to read) to that
one `requests.get(...)` call in `_jnja/engine.py.j2`. Nothing else. A timeout
raises `requests.exceptions.Timeout`, which is a subclass of
`requests.RequestException`, so the existing `except` block already handles it
— no new error handling needed.

**Verify:** `make && make testbasic` (offline). Then one live call:
`_dist/elm/elm MetricsUsage` must still return data.

## [ ] 3. Guard `response.json()` against non-JSON responses

**Problem:** in `_jnja/engine.py.j2`, right after the `try/except` block for
the request, the line `obj = response.json()` is unguarded. A 200 response
whose body is not JSON (corporate proxy interception page, LM maintenance
page) produces a raw Python traceback instead of elm's normal red error
message.

**Change:** wrap that line in `try/except ValueError` (requests raises
`requests.exceptions.JSONDecodeError`, a `ValueError` subclass; catching
`ValueError` avoids importing requests at that point). On failure, follow the
same pattern as the existing request-error handler directly above it:
`click.secho('Error: response was not JSON', fg='red', err=True)` plus the
command/path context lines, then `raise click.Abort()` if
`elm.halt_on_api_error` is set, else `return`.

**Verify:** `make && make testbasic` (offline). Then one live call:
`_dist/elm/elm MetricsUsage` must still return data.

## [ ] 4. Make CI actually build and test

**Problem:** `.github/workflows/makefile.yml` never renders the templates,
never builds the binary, and never runs any test — it only exercises helper
targets (`cfg`, `clean`, `help`, ...). A breaking change to a `_jnja/`
template passes CI today.

**CORRECTION (2026-07-10) — an earlier draft of this item was wrong.** It
claimed `make testbasic` is "fully offline" and that the `-f api/curl/wget`
tests "build and print the signed URL locally without ever sending it." That is
false, confirmed empirically against the built binary. In
`_jnja/engine.py.j2` the `api`/`curl`/`wget` formats print the URL/command only
*after* `response.raise_for_status()` (line ~125) and `response.json()`
(line ~172) succeed, and the `sqlite` `-o`-required guard likewise fires only
after a successful fetch. So a block of `testbasic` assertions needs a **live
2xx JSON response from a real LM portal**: currently every line from
"multiple -F flags both appear in URL" through "sqlite format requires -o"
(the `-f api`, `-f api` escaping, `-f curl`, `-f wget`, and `-f sqlite` lines).
With dummy `config.example.ini` credentials those requests reach
`example.logicmonitor.com` and return **403**, so the assertions fail. Copying
the example creds into CI is therefore NOT enough to make `make testbasic`
green — it will go red on those lines.

What IS genuinely offline in `testbasic` (verified against the binary): the
help / `--version` / `--list` / `--ai` / `--profile`-resolution assertions (the
first block, up to and including "--help includes --ai") and the per-command
`<cmd> --help` loop at the end. Those pass with no LM access.

**Revised change — do 4a and 4b, in order:**

**4a. Build the binary in CI (highest value, fully offline).** Rendering the
templates and running PyInstaller is what catches template-syntax breakage and
bundling regressions — the biggest gap today, and it needs no LM access. A
green `make` proves every `_jnja/` template renders to valid Python and the
binary links. Replace the `build` job `steps:` with:

```yaml
    steps:
    - uses: actions/checkout@v4

    # A default 'config' profile must exist for the binary to resolve a
    # profile at all. Use the example file's dummy credentials — never real
    # ones. Do NOT expect these to satisfy the live -f api/curl/wget/sqlite
    # assertions (they 403); those are excluded from the CI test step below.
    - name: Create dummy credentials from the example file
      run: |
        mkdir -p ~/.config/logicmonitor/credentials
        cp config.example.ini ~/.config/logicmonitor/credentials/config.ini
        chmod 700 ~/.config/logicmonitor/credentials
        chmod 600 ~/.config/logicmonitor/credentials/*.ini

    - name: Full build (init, render, PyInstaller binary)
      run: make

    - name: Offline test subset
      run: make testbasicoffline
```

Why copy the example file instead of passing `--config config.example.ini`:
the test targets invoke the binary without a `--config` flag throughout, and
some assertions test the default-profile machinery itself (`--list` must print
`* config`, and `elm --list` deliberately hides `config.example.ini`, so
pointing `--config` at it would fail those tests). Copying the example's fake
credentials into the runner's throwaway home directory gives the same safety
with no test changes.

Notes: `ubuntu-latest` already has `jq`, `curl`, `python3`, `binutils`
(objdump, which PyInstaller needs on Linux) and a shared `libpython`; `make`
downloads the LM swagger spec from logicmonitor.com, which works from GitHub
runners. Expect the job to take several minutes (PyInstaller build).

**4b. Add a `testbasicoffline` target and call it from CI.** Split the LM-free
assertions of `testbasic` into a new `make testbasicoffline` target: the first
block (help / `--version` / `--list` / `--ai` / `--profile` strip / `--list`
marks `* config`) plus the trailing `$(TSTTARGETS)` `<cmd> --help` loop —
i.e. everything EXCEPT the `-f api`, `-f curl`, `-f wget`, and `-f sqlite`
lines. Leave the full `testbasic` as-is for local runs against the default
`config` profile (which has real creds on the maintainer's machine). Do NOT
call full `make testbasic` from CI expecting green.

**Optional, needs maintainer sign-off (design change, do separately):** the
`-f api/curl/wget` formats could print the request WITHOUT sending it — the
URL, auth header and query params are all fully computed *before*
`requests.get` is called, so those formats could short-circuit and print
before the request. That would make them genuinely offline (and arguably
better matches their "reproduce a request" intent), letting CI cover them too.
But it changes documented behaviour (CLAUDE.md: "api makes the request then
prints the URL and Authorization header"), so decide deliberately — do not fold
it into this CI item.

**Verify:** push to a branch, open a PR, confirm the workflow goes green; then
break something trivial in `_jnja/elm.py.j2` on a scratch branch and confirm
the workflow goes red (delete the scratch branch afterwards).

## [ ] 5. Version numbering cleanup

**Problem:** `_version.py` says `1.8.10`, but `CHANGELOG.md`'s newest release
heading is `[1.8.9]` (current work sits under `[Unreleased]`), and
`SECURITY.md`'s supported-versions table still lists 1.8.9/1.8.8. The table
goes stale every release.

**Change (two parts):**

1. In `SECURITY.md`, delete the whole "Supported Versions" markdown table and
   keep just the existing sentence ("Only the latest release is supported...").
   Nothing else in the file changes.
2. At the next release: rename `## [Unreleased]` to `## [1.8.10] - <date>` in
   `CHANGELOG.md` and add a fresh empty `## [Unreleased]` above it. (Do not do
   this part as routine cleanup — only when the maintainer says a release is
   happening.)

**Verify:** proofread; no build needed for part 1.

## [ ] 6. Rename the markdown link-check workflow file

**Problem:** `.github/workflows/action.yml` is the "Check Markdown links"
workflow, but its generic filename says nothing about what it does.

**Change:** `git mv .github/workflows/action.yml .github/workflows/markdown-link-check.yml`.
No content changes. GitHub identifies workflows by the `name:` inside the
file, so nothing else needs updating (the README badges reference
`dependency-review.yml` and `makefile.yml`, not this file).

**Verify:** after push, the "Check Markdown links" workflow still runs.

## [ ] 7. Add a scheduled pip-audit workflow

**Problem:** `dependency-review.yml` only runs on pull requests, so a
vulnerability published for an *already-pinned* dependency never triggers
anything.

**Change:** create `.github/workflows/pip-audit.yml`:

```yaml
name: pip-audit

on:
  schedule:
    - cron: '0 6 * * 1'   # Mondays 06:00 UTC
  workflow_dispatch:        # allow manual runs

permissions:
  contents: read

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install pip-audit
        run: python3 -m pip install pip-audit
      - name: Audit pinned requirements
        run: python3 -m pip_audit -r requirements.txt
```

**Verify:** trigger it once via the Actions tab (workflow_dispatch) and check
it completes. A finding makes the job fail — that's the alert mechanism.

## [ ] 8. Ignore `_build/` and `_dist/` explicitly

**Problem:** `.gitignore` has no entry for `_build/` or `_dist/` — they are
only ignored by luck, because the bare `elm` pattern happens to match the
`elm/` subdirectory PyInstaller creates inside each. If PyInstaller ever
changes its layout, build artefacts would show up as untracked files.

**Change:** in `.gitignore`, in the `# ELM project compiled files` section,
add two lines: `_build/` and `_dist/`.

**Verify:** `git status` still shows a clean tree after a build.

## [ ] 9. Replace deprecated `datetime.utcnow()`

**Problem:** the sqlite branch of `output()` in `_jnja/engine.py.j2` uses
`datetime.datetime.utcnow()`, deprecated since Python 3.12.

**Change:** in that one line, use
`datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')`.
Note the result now ends in `+00:00`, and the code currently appends a literal
`'Z'` — replace the string concatenation so the stored value ends in `Z` with
no `+00:00` (e.g. `.replace('+00:00', 'Z')` on the isoformat result, and drop
the manual `+ 'Z'`). The `make testsqlite` test asserts `fetched_at` ends with
`Z`, so it will catch a mistake here.

**Verify:** `make && make testbasic`, then `make testsqlite` (needs live LM,
default profile).

## [ ] 10. Friendlier error when a sqlite table's schema changed

**Problem:** `-f sqlite` appends with `df.to_sql(..., if_exists='append')`.
If the API returns different columns than the existing table has (LM added or
removed a field between runs), pandas raises a cryptic exception.

**Change:** in `_jnja/engine.py.j2`, wrap the `df.to_sql(...)` call in
`try/except Exception`; on failure print
`Error: table '<table>' in <filename> has a different schema (the API fields changed); write to a new file or delete the old table`
via `click.secho(..., fg='red', err=True)`, close the connection, and
`raise click.Abort()`.

**Verify:** `make && make testsqlite`. For the failure path: run
`-f sqlite -o /tmp/t.sqlite MetricsUsage` once, then
`-f sqlite -o /tmp/t.sqlite MetricsUsage -f numberOfDevices` (fewer columns)
— expect the new red error, not a traceback.

## [ ] 11. Guard against bare-array API responses

**Problem:** in `_jnja/engine.py.j2`, the block `if 'items' not in obj:`
assumes `obj` is a dict. If an endpoint ever returns a bare JSON array
(`[...]`), `'items' not in obj` is a membership test over the list and the
code then misrenders the whole array as a single item.

**Change:** before that block, add: if `isinstance(obj, list)`, set
`obj = {"total": len(obj), "items": obj, "searchId": None, "isMin": False}`.
The existing `if 'items' not in obj:` block stays as-is beneath it.

**Verify:** `make && make testbasic`, plus one live `MetricsUsage` call.

## [ ] 12. Use mktemp in the Makefile `docs` target

**Problem:** the `docs` target writes to fixed paths `/tmp/elm_help.txt` and
`/tmp/README_tmp.md` — collision-prone on shared machines.

**Change:** in the `docs` recipe, generate both paths with `mktemp` into shell
variables and use those. Remember Makefile recipes need `$$` for shell
variables and each line runs in its own shell, so join the lines with `; \`.

**Verify:** `make docs` still injects the help text into README.md
(`git diff README.md` should show no change if help output is unchanged).

## [ ] 13. URL-encode query parameter values — DO THIS ITEM LAST

**Problem:** in `_jnja/engine.py.j2`, query parameters are glued into a string
(`queryParams += '&' + flag + '=' + str(flags[flag])`) and passed to
`requests.get(..., params=queryParams)`. When `params` is a *string*, requests
appends it almost verbatim — it does NOT properly encode URL-special
characters. So a filter value containing `&` silently splits into a bogus
extra parameter, `+` is decoded by the server as a space, and `#` truncates
the URL. The user gets wrong results with no error.

**Change:** build a dict instead — `queryParams = {}` and
`queryParams[flag] = str(flags[flag])` inside the loop (keep skipping the
`_output_only` names) — and pass that dict as `params=`. requests then
percent-encodes every value correctly. This CANNOT break authentication: the
LMv1 signature covers only the resource path, never the query string.

**But be careful — two knock-on effects:**

1. Characters that previously passed through raw (`~`, `:`, `,` inside the
   filter expression) will now arrive percent-encoded (`%7E`, `%3A`, `%2C`).
   LogicMonitor should decode these identically, but this MUST be confirmed
   against a live portal before merging.
2. Two `make testbasic` assertions grep for exact encodings in the `-f api`
   URL (search the Makefile for `filter=hostname~%22`); if the encoding of
   `~` changes, update those grep patterns to match the new (correct) URL.

**Verify (in this order):**

1. Before changing anything, record baseline URLs:
   `_dist/elm/elm -f api DeviceList -F 'hostStatus:normal' -s5`,
   same with `-F 'displayName~foo'`, with two `-F` flags, with `--sort +id`,
   and with `-f name,id` (fields). Save the printed URLs.
2. Make the change, `make`, and diff the same commands' URLs against the
   baseline — differences must be *only* percent-encoding, never structure.
3. `make testbasic` (update the two grep patterns if needed, per note above).
4. Live checks with the default profile: repeat each command WITHOUT `-f api`
   and confirm each returns the same data as before the change; then confirm
   the fix works: `-F 'displayName~R&D'` and `-F 'name~a+b'` must reach LM as
   one filter (0 results is fine — no error, and `-f api` shows `%26`/`%2B`).
5. Update `CLAUDE.md`: the "Current state → Resolved" bullet claiming query
   params are "sent structured ... not hand-concatenated" is wrong today —
   after this change it becomes true; reword it to describe the dict-based
   `params=` and reference this fix.

## [defer] 14. Falsy option values (booleans and id 0)

The `flags = {k: v for k, v in kwargs.items() if v}` filter in
`_jnja/engine.py.j2` drops every falsy value. Consequences: `--dont-<flag>`
boolean options are silently never sent (the server default always applies),
and a path parameter of `0` crashes with a KeyError traceback (cosmetic — no
real LM object has id 0). Agreed to fix eventually; needs a careful testing
window because it changes which parameters get sent. Do not start without the
maintainer.

## [defer] 15. Retry/backoff on HTTP 429 (rate limiting)

LM does rate-limit. engine.py already reads the `X-Rate-Limit-*` headers (debug
log only). A single retry that waits out the window on 429 would make looping
tools (e.g. `tools/elm-datasource-matrix.py`) robust. Needs live testing
against a real rate limit; design (max retries, wait cap, message to stderr)
to be agreed with the maintainer first.

## [defer] 16. Dependency upgrades (click 7→8, tabulate 0.8→0.9)

`click~=7.1.2` is a 2020 release and no longer receives fixes; `tabulate` 0.9
may make the manual pipe-escaping workaround in `output()` unnecessary (check
astanin/python-tabulate#241 first). Upgrading touches every command's CLI
parsing (click) and most output formats (tabulate), so it needs the full
`make test` + `make testlong` suite against a live portal, and
`click_config_file` compatibility must be confirmed. Do not start without the
maintainer.

## [ ] 17. Label reachability-check columns by what they actually test

**Problem:** in the collector reachability/move-readiness tooling
(`tools/lm-collector-reachability-run-all.ps1`,
`tools/lm-collector-move-readiness-run-all.ps1`,
`tools/elm-collector-readiness.sh`,
`tools/lm-collector-reachability-check.groovy.j2`), the TCP-based checks
(port 135, 22, 80, 443) are all bare `Socket.connect()`/`tcpOk()` calls — no
protocol handshake, no credentials, nothing beyond "did the TCP port accept a
connection." But they are labelled with purpose names — `wmi`, `ssh`, `http`,
`https` — which overclaim what was actually tested. A passing `ssh` column
does not mean SSH auth would succeed, or even that an SSH server is listening
(some other service could be bound to 22); it means TCP port 22 accepted a
connection.

This also caused a real duplicate-output bug (fixed 2026-08, see CHANGELOG):
`auto.network.listening_tcp_ports` containing `135` and
`auto.wmi.operational == "true"` are two *independent* discovery signals that
both trigger the exact same test (`tcpOk(ip, 135, ...)` — verified identical
in every version of the Groovy), so a device with both flags set got two
protocol-list entries (`tcp-135` and `wmi`) that always agree, printed as two
separate columns. The immediate fix (matching `elm-collector-readiness.sh`'s
label to the already-correct `port-135` used elsewhere) only stopped the
*display* collision; the redundant double-test is still there.

**Change — two parts, do together:**

**17a. Squash `tcp-135` and `wmi` into one signal.** In each protocol-detection
function/block, combine the two independent conditions into a single
`tcp-135` entry instead of two:

- PowerShell (`Get-DeviceProtocols` in both `.ps1` files): replace
  ```powershell
  if ($tcp -contains '135') { $protocols.Add('tcp-135') }
  if ($wmi -eq 'true')      { $protocols.Add('wmi') }
  ```
  with
  ```powershell
  if (($tcp -contains '135') -or ($wmi -eq 'true')) { $protocols.Add('tcp-135') }
  ```
- Bash/jq (`elm-collector-readiness.sh`, inside the `matrix=$(... jq '...')` protocol list): replace the two independent `tcp-135` / `wmi` branches with one:
  `(if ($tcp | contains(["135"])) or ($wmi == "true") then ["tcp-135"] else [] end) +`

**17b. Rename the TCP-only labels to port numbers, drop the now-dead `wmi`
label.** These checks test "is the port open," nothing more, so the label
should say that plainly instead of implying a real protocol test happened:

| internal token | old display label | new display label |
|---|---|---|
| `tcp-135` | `port-135` (or `wmi`, inconsistently — see above) | `135` |
| `tcp-22`  | `ssh`  | `22`  |
| `tcp-80`  | `http` | `80`  |
| `tcp-443` | `https`| `443` |

Apply in: each `$protoLabel` hashtable in the two `.ps1` files (both the
PowerShell-side one used for the summary table, and the one inside the
embedded `$groovyTemplate` here-string); the `protoLabel` map inside
`tools/lm-collector-reachability-check.groovy.j2`; and the jq label-mapping
line in `elm-collector-readiness.sh`'s summary table (already touched once
for the duplicate fix — finish the job by changing `"port-135"`/`"ssh"`/
`"http"`/`"https"` to `"135"`/`"22"`/`"80"`/`"443"`). Remove the now-unreachable
`case "wmi":` branch from `runTest()` in both Groovy sources (dead code once
17a means the `wmi` token is never emitted). Update the failure-footer text
("port-135/wmi pass only confirms TCP 135 ...") and
`examples/collector-readiness.md` (the `### WMI (tcp-135)` section heading and
any sample output blocks showing `wmi`/`ssh`/`http`/`https` column headers) to
match the new `135`/`22`/`80`/`443` labels and to state plainly that a pass
means "TCP port open," not "protocol/credentials verified."

**Leave `ping` and `snmp` as purpose-named, not renamed.** `ping` is a real
ICMP test, not port-based. `snmp` already sends an actual SNMPv2c `GetRequest`
payload (community `public`) and checks for a real response, not just a raw
socket connect — UDP has no connection handshake, so there is no equivalent
"is the port open" signal to fall back to; a judgment call, not mandatory, if
someone later wants to reconsider this.

**Verify:** re-run the synthetic verdict test pattern used for the 2026-08
protoLabel bug fix (a device with both `tcp-135` and `wmi` conditions true
must appear as ONE `135` entry, not two) plus a live run of each of the three
scripts against a small group — column headers should read `135`/`22`/`80`/
`443` instead of `wmi`/`ssh`/`http`/`https`, and no protocol column should be
duplicated. Add a CHANGELOG.md entry under `## [Unreleased]`.

## [defer] 18. New idea: single-device WMI/WinRM/SNMPv3 diagnostic tool

**Not a fix to the existing reachability/move-readiness scripts** — a
different, smaller tool idea that surfaced while investigating item 17.

LogicMonitor's Collector Debug console has built-in commands that do real,
credentialed protocol tests, richer than anything the current Groovy checks
attempt:

- `!wmi [username=foo password=bar] h=<host> <wmi query>` — a real WMI query.
  If no username/password is given, "the agent will use wmi.user/wmi.pass
  properties of the host" (per the command's own `help` text).
- `!winrm host=<host> [auth=] [useSSL=] [certCheck=] [username=] [password=]
  [query=] [timeout=]` — a real WinRM test; falls back to `wmi.user`/`wmi.pass`
  if credentials are omitted.
- `!snmpdiagnose host [oid...]` with `version=v1|v2c|v3`, and for v3:
  `auth=MD5|SHA|SHA224|SHA256|SHA384|SHA512`, `authToken=`, `priv=DES|AES|...`,
  `security=` (security name), `contextName=` — a real SNMP test with the
  device's actual configured community/v3 credentials, not a hardcoded guess.
  Confirmed live (2026-08): the exact same typed command
  (`!snmpdiagnose version=v3 <host>`, no explicit credentials) resolved to a
  generic `securityName=logicmonitor`/`noAuthNoPriv` (which failed with
  "Unknown user name") when run from one collector, and to the device's real
  `securityName=<real-security-name> authProto=SHA privProto=AES` (which succeeded, full
  `sysInfo` returned) when run from a different collector — same device, same
  command, different result.

**Why this does NOT fix the existing scripts:** that last point is the
catch. The credential auto-resolution is scoped to *"devices this collector
currently monitors"* — confirmed both by the live test above and by the
`WMI.queryAll()` Groovy-API javadoc, which states outright it only applies
"to the host which is monitored by current collector." The reachability/
move-readiness scripts exist specifically to test collectors that do **not**
yet monitor the device (a candidate being vetted, a target group's collectors
before a move) — exactly the case where this auto-resolution does not apply.
Running `!wmi`/`!snmpdiagnose` from a non-owning collector falls back to the
same generic-default failure the current hand-rolled checks already produce.
Supplying real credentials explicitly would work, but WMI/SNMPv3 credential
properties are masked (`********`) in every LM API response, so elm/these
tools cannot fetch them programmatically — and embedding real secrets in a
debug script is the same anti-pattern already removed from this project (the
old "Mode C" credential-in-script flow, see the 2026-08 doc cleanup).

**Where it WOULD be a real win:** a *different*, single-device tool — "why is
monitoring failing for this device on its **current** collector" — where
auto-resolution works and gives actual diagnostics (a real WMI result set, or
a specific SNMPv3 error like "Unknown user name — check snmp.security host
property") instead of a blind pass/FAIL/TIMEOUT. That is a genuinely useful,
separate tool, not a rewrite of the existing three scripts. Needs maintainer
scoping (which debug commands, what output format, one host vs. a list) before
any implementation — do not start without the maintainer.
