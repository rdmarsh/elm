# Changelog

All notable changes to elm are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
[1.0.5]: https://github.com/rdmarsh/elm/compare/v1.0.4...v1.0.5
