# TODO

Backlog of deferred work. Highest priority first.

Larger, fully-specified work items live in `RECOMMENDATIONS.md` (the 2026-07
audit follow-ups). This file is for everything else.

## `make swagger` cannot fetch the spec (Cloudflare challenge)

Found 2026-08-16. `www.logicmonitor.com` now serves the swagger spec behind a
**Cloudflare bot challenge**: the URL returns HTTP 403 with a ~5.6 KB "Just a
moment..." interstitial instead of JSON. Reproduced from two different
networks. Sending a browser `User-Agent` does not help — it is a JavaScript
challenge, not a UA check. **Do not try to defeat it**: that is bot-protection
evasion, and it would break again on the next Cloudflare change anyway.

This no longer blocks the build. The spec is now a committed snapshot
(`swagger.documented.json`) and `make` never touches the network, so a clean
build works offline. Only *refreshing* the spec is affected.

**To refresh until this is resolved**, fetch it with a real browser (which can
answer the challenge):

1. Open `https://www.logicmonitor.com/swagger-ui-master/api-v3/dist/swagger.json`
   in a browser and save the JSON.
2. `jq . ~/Downloads/swagger.json > swagger.documented.json`
   (pretty-print it — the download is minified onto a single line, and
   committing it that way makes the diff unreadable)
3. `git diff --stat swagger.documented.json` to see what upstream changed,
   then rebuild.

Note: committing the snapshot trips the pre-commit leak scan's private-IP
check. LogicMonitor's spec uses `10.35.41.1-10.35.41.254` as the documented
example value for the netscan `subnet` field, which looks exactly like a real
internal range. It is a false positive, and the file must stay a **verbatim**
copy of upstream — editing it would defeat the point of diffing it. Commit
with the documented bypass:

    LEAK_SCAN_SKIP=1 git commit ...

**Still open:**

- Ask LogicMonitor support for a fetchable spec URL (or check whether an
  authenticated portal endpoint serves it), so `make swagger` can work
  unattended again.
- The Wayback Machine likely has archived copies if an older revision is ever
  needed; `web.archive.org` is blocked by the sandbox network policy, so check
  from a normal machine.

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
