# TODO

Backlog of deferred work. Highest priority first.

Larger, fully-specified work items live in `RECOMMENDATIONS.md` (the 2026-07
audit follow-ups). This file is for everything else.

## Verify paging on ActionChainsList / ActionRulesList

`swagger.undocumented.json` now declares `size`/`offset`/`filter` for
`/setting/action/chains` and `/setting/action/rules`, so `elm ActionChainsList`
and `elm ActionRulesList` expose `-s/-o/-F` after a rebuild. This was added so
the commands stop erroring on `-s0` (e.g. in `tools/elm-backup.sh`), but it has
**not** been confirmed that the LM API actually honours these params — only that
the CLI no longer rejects them.

**Partial result 2026-08-24** (sandbox portal): both endpoints respond
cleanly and accept `-s0`/`-s1`/`-C` without error, and `-C` returns a real
total rather than an error — but that total is **0**, i.e. this portal has no
action chains or rules configured. So the params are confirmed *accepted*,
while whether LM actually *honours* `-s`/`-F` remains untested. Do not re-run
this on the sandbox portal; it needs an account with data.

When an account with action chains/rules data is available, verify:

- `elm ActionChainsList -s1 -C` — does `-C` return a total, and does `-s1` cap rows?
- `elm ActionChainsList -F name~<substr>` — does server-side filter work?
- Same for `ActionRulesList`.

Outcome:
- If the API honours them, update both `elm-notes.yaml` entries to the standard
  `"Standard list (-s/-o/-F/-f all work)"` wording used by the other
  `swagger.undocumented.json`-patched endpoints.
- If it silently ignores `-s`/`-F` (returns full list regardless), note that as a
  genuine LM API limitation in `elm-notes.yaml` and consider whether
  `tools/elm-backup.sh` needs a client-side `>1000` truncation guard.

**Test method (proven 2026-09-11 on `V4Metadata`):** declare the params in the
endpoint's definition, rebuild, then compare `-c` across `-s 5` / `-s 100` /
`-o <big>` / `-F <field>:<value>`. If the count never moves, the API is ignoring
them — check `-vv` to confirm elm really sent them before concluding anything.
That test settled `/setting/logicmodules/metadata` as a **confirmed no**: it
ignores all three, so the override was deliberately not added there (see
`examples/logicmodules.md` and `elm V4Metadata --info`). It is the same class of
question as this item, so the same method applies once a portal with action
chains/rules data is available.

Context: same class as GitHub issue #47 (LM swagger omits paging params on
several list endpoints).

## Whole numbers print as 1.0 when a column has gaps

pandas turns a number column with any missing value into floats, so ids and
counts print as `1.0`, `2.0` in csv, the tables and jsonl whenever some rows
lack the field. Long-standing (any field absent from some records), but `-e`
makes it common: `-e groups.members` with one empty list prints every member
id as a float (seen 2026-10-11 in a faked test). A fix such as converting
whole-valued float columns to pandas' nullable `Int64` in `output()` changes
existing output, including the jsonl a downstream repo reads, so test it
against current output first; maybe together with pandas 3.

## pandas 3 (needed for Python 3.15)

pandas 2.3 has no Python 3.15 wheels and will not get them, so on 3.15 `make`
tries to compile pandas and fails (`metadata-generation-failed`, found
2026-10-10 when Homebrew moved `python3` to 3.15). The first pandas with 3.15
wheels is 3.0.6. pandas 3.0.0 was released 2026-01-21; 3.0.6 came out
2026-09-17 and 3.1.0rc0 on 2026-09-30, so it is settled. Until this is done,
build with `make PYTHON=python3.14`.

What could change elm's output: text columns become a dedicated `str` dtype
instead of `object` (empty values and NaN may print differently), and
copy-on-write is always on (unlikely to matter: elm only formats). Method:
capture every `-f` format for a few commands with pandas 2.3, rebuild with
pandas 3, and compare byte for byte; `make testfmtcont` covers the shape, the
byte comparison covers the rest. Watch the `jsonl` trailing bytes (a downstream
repo counts lines) and `sqlite` column types.

## CI: build and test on every platform elm should run on

`.github/workflows/makefile.yml` builds the binary and runs `make
testoffline` on Ubuntu with Python 3.14 (since 2026-10-11). Goal: the same on:

- macOS (arm64; Intel while GitHub still offers it) and Ubuntu: native runners.
- Debian and RHEL (Rocky/Alma or UBI): containers on the Ubuntu runner.
  PyInstaller binaries need a glibc at least as new as the one they were built
  on, so build releases on the oldest supported distro and test elsewhere.
- Python 3.12, 3.13, 3.14, plus the next Python as an allowed-to-fail job: it
  would have caught the pandas/3.15 break above before a rebuild did.
- Docker: build the image from the item below and run `--version` / `--help`.
- Windows: expect real work, not just a runner. The Makefile and tests are
  bash; and `enforce_config_perms` (in `_jnja/elm.py.j2`) checks Unix modes
  700/600, which Windows `os.chmod` cannot set, so elm likely exits "cannot
  secure" there. Not yet tried on Windows; WSL works as Linux.

Later: live tests against a sandbox portal with a read-only token in a GitHub
secret, and release binaries attached to a tag.

## elm-ask: one page for several portals (parked 2026-09-18)

`tools/elm-ask` answers from one profile (`ai` by default), so one container
talks to one portal; the workaround is one container per portal on different
ports. Idea, not started: take a list such as `ELM_PROFILES=ai-prod,ai-preprod`,
require every listed profile to set `allowed_commands`, let the model choose a
profile only from that list (never an arbitrary `--profile`/`--config`), and say
in each answer which portal it came from. Parked until there is a real need.

## elm-ask: grow the checked question set

Started 2026-10-26 in `tools/elm-ask/questions.md` (injection tests and the
memory case, with results). Next: confirm the "Not run yet" answers by hand
against a known portal and add their check commands, then aim for 10-20.

## An elm CLI container image (parked 2026-09-18)

For people who cannot install elm (no Python, locked-down Windows laptops), ship
elm and jq as a container image, run as

    docker run --rm -v "$HOME/.config/logicmonitor/credentials:/creds:ro" elm DeviceList -s0

Most of the work exists already: the first stage of `tools/elm-ask/dockerfile`
renders elm from `_jnja/` and the committed swagger. This would be a root
`dockerfile` with `elm` as the entrypoint. Publishing it (e.g. to GHCR from a
GitHub Action on a release tag) would let anyone `docker pull` it; the image must
hold no credentials, and the README should point at the credentials mount and
the Windows path/quoting differences. Parked: useful, not urgent.

## elm-ask: show the allowed commands in the page (idea)

The footer says "44 allowed commands" but not which. Cheapest version: a title
attribute so hovering lists them; fuller version: make it a link to a small
page or panel listing each allowed command with its summary (the data is
already in `profile_status()["allowed"]` and `_defs/commands.json`). Only worth
it if people ask "what can I ask about?".

## elm-ask: other model providers, and Claude Code (idea)

elm-ask calls the Claude API directly, so it needs API credit even for someone
who already pays for Claude Code or ChatGPT. Two ways round that, neither
started:

- **An MCP server** wrapping `tools/elm-ask/elm_tools.py` (the read-only elm
  tools, secret stripping and the allowed_commands check). Claude Code and
  Claude Desktop could then query LM through a subscription instead of API
  tokens, with no web page to host. Probably the cheapest useful next step.
- **Other providers** (OpenAI and friends): tool-calling APIs are close enough
  that swapping the client and reshaping the tool definitions is most of the
  work, but each provider needs its own testing against the question set.
  `ANTHROPIC_BASE_URL` already covers an Anthropic-compatible gateway.

