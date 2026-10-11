---
name: release
description: Cut an elm release - choose the version, bump _version.py, turn [Unreleased] in CHANGELOG.md into the release section, commit and push. Use when the user asks to release, cut, bump or tag a version.
---

# Cut an elm release

Only when the user has said to release. Confirm the version number with them
if it isn't obvious.

## 1. Choose the version (semver)

Read `CHANGELOG.md` `[Unreleased]`, then:

- **Major** - something that worked breaks: a flag removed or renamed, output
  of an existing command changed so a script reading it would break, an exit
  code changed, the config format changed.
- **Minor** - new behaviour only (new flags, commands, tools, output
  formats); existing invocations print what they did before.
- **Patch** - fixes and docs only.

Say which and why in one line; the release commit message repeats it.

## 2. Check

- `git status` is clean and `[Unreleased]` is not empty.
- Every entry is user-facing and accurate; fix wording now, not after.
- Tests: `make test` runs on the user's Mac, not in a sandbox (it rewrites
  the macOS `_dist/`). In a sandbox, render with jinja2 and run the offline
  checks, then ask the user to run `make clean && make && make install && make test`.

## 3. Edit

- `_version.py`: `__version__ = 'X.Y.Z'`.
- `CHANGELOG.md`:
  - `## [Unreleased]` becomes `## [X.Y.Z] - YYYY-MM-DD` (today), with its
    headings in the order Added, Changed, Deprecated, Removed, Fixed,
    Security (only those present).
  - Add a fresh, empty `## [Unreleased]` above it.
  - At the bottom, point `[Unreleased]` at `compare/vX.Y.Z...HEAD` and add
    `[X.Y.Z]: https://github.com/rdmarsh/elm/compare/vPREV...vX.Y.Z`.
- Edit with Python `open(f, 'w')` - never `cp` or `sed -i` on the repo mount.

## 4. Commit and push

Commit only those two files as `release: cut X.Y.Z`. The body says what the
edit did and why this is major/minor/patch, ending with the Co-Authored-By
line. Push with:

    git push https://github.com/rdmarsh/elm.git main:main

## 5. Tag (ask first)

Every release is tagged on GitHub. Ask whether to tag; if yes,
`git tag vX.Y.Z` on the release commit and push it with
`git push https://github.com/rdmarsh/elm.git vX.Y.Z`. Never move a pushed tag.
