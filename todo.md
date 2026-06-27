# TODO

Backlog of deferred work. Highest priority first.

## Verify paging on ActionChainsList / ActionRulesList

`swagger.undocumented.json` now declares `size`/`offset`/`filter` for
`/setting/action/chains` and `/setting/action/rules`, so `elm ActionChainsList`
and `elm ActionRulesList` expose `-s/-o/-F` after a rebuild. This was added so
the commands stop erroring on `-s0` (e.g. in `tools/elm-backup.sh`), but it has
**not** been confirmed that the LM API actually honours these params — only that
the CLI no longer rejects them.

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

Context: same class as GitHub issue #47 (LM swagger omits paging params on
several list endpoints).
