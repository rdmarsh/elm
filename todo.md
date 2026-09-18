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

## elm-ask: one page for several portals (parked 2026-09-18)

`tools/elm-ask` answers from one profile (`ai` by default), so one container
talks to one portal; the workaround is one container per portal on different
ports. Idea, not started: take a list such as `ELM_PROFILES=ai-prod,ai-preprod`,
require every listed profile to set `allowed_commands`, let the model choose a
profile only from that list (never an arbitrary `--profile`/`--config`), and say
in each answer which portal it came from. Parked until there is a real need.

## elm-ask: a checked question set (next session)

Build a small evaluation set for `tools/elm-ask`: 10-20 questions people really
ask, each with an answer confirmed by hand against a known portal and how it was
confirmed (e.g. open critical alerts = `elm AlertList -c -s0 -F
cleared:false,severity:4`; devices with alerting disabled, counting group-level
disables via `alertDisableStatus`). Include questions that have tripped it up:
severity numbers, alerting disabled by group, "SNMP" alerts, OS detection,
AlertList filters the API ignores. Include questions it should refuse or answer
only partly, with the refusal as the expected answer: "show me a list of the
users" (blocked by allowed_commands; it should say so and point at the LM UI
rather than assembling names from SDT `admin`, alert `ackedBy` or device
`createdBy` fields, which it can reach), and a question needing a command the
profile does not allow (it should name the command it needs, not switch
profiles). Re-run the set after changing the prompt,
`elm-notes.yaml`, `elm-knowledge.md` or the model, and compare. Answers change as
the portal changes, so record the check command, not only the number.

## An elm CLI container image (parked 2026-09-18)

For people who cannot install elm (no Python, locked-down Windows laptops), ship
elm and jq as a container image, run as

    docker run --rm -v "$HOME/.config/logicmonitor/credentials:/creds:ro" elm DeviceList -s0

Most of the work exists already: the first stage of `tools/elm-ask/Dockerfile`
renders elm from `_jnja/` and the committed swagger. This would be a root
`Dockerfile` with `elm` as the entrypoint. Publishing it (e.g. to GHCR from a
GitHub Action on a release tag) would let anyone `docker pull` it; the image must
hold no credentials, and the README should point at the credentials mount and
the Windows path/quoting differences. Parked: useful, not urgent.

