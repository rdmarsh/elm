#!/usr/bin/env bash
# elm-backup: snapshot LogicMonitor Alerting and Collector configuration to
# JSONL files for auditing, change-tracking, and disaster reference.
#
# This is a config-as-data backup, NOT a restore mechanism. elm is read-only:
# LM has no bulk import, so the value here is a versioned, diffable record of
# what your portal looked like. To write anything back you would use the
# Logic.Monitor PowerShell module (New-/Set-/Import-/Restore- cmdlets) against
# these snapshots; see CLAUDE.md notes on that round-trip's caveats (read-only
# fields, ID remapping, redacted secrets).
#
# Usage:
#   elm-backup.sh [options]
#
# Options:
#   --profile, -p PROFILE  elm credential profile; defaults to 'config'
#                          (same default as elm — reads config.ini)
#   --dir, -d DIR          backup root directory; default $ELM_BACKUP_DIR or
#                          ~/elm-backup. Intentionally OUTSIDE this code repo so
#                          backups (which may contain portal data) are never
#                          accidentally staged/committed. The script refuses to
#                          write inside a git work tree unless --dir is explicit.
#   --date                 nest output under a UTC datestamp subdir
#                          (DIR/ACCOUNT/YYYY-MM-DD/), for keeping history
#   -h, --help             show this help
#
# Output: one JSONL file per endpoint under DIR/ACCOUNT/[DATE/], where ACCOUNT is
# the LM account_name (portal) the profile points at, e.g.
#   ~/elm-backup/acmesandbox/AlertRuleList.jsonl
# The account_name is read from elm itself (the request URL it builds), not from
# the credentials .ini. If it can't be resolved, the profile name is used.
# JSONL (one object per line) is chosen because it diffs cleanly — point a
# separate git repo at the backup dir and `git log -p` shows exactly what
# changed in the portal. Keep that repo OUT of this codebase.
#
# What it captures:
#   Alerting   AlertRuleList, EscalationChainList, ActionChainsList,
#              ActionRulesList, RecipientGroupList, IntegrationList
#   Collectors CollectorList, CollectorGroupList, CollectorVersionList
# Active/historical alerts (AlertList) are deliberately excluded — they are
# transient telemetry, not configuration.
#
# Examples:
#   elm-backup.sh                          # default profile -> ~/elm-backup/<account>/
#   elm-backup.sh --profile prod --date    # prod, history kept by date
#   elm-backup.sh -p preprod -d ~/lm-snapshots
#   ELM_BACKUP_DIR=/srv/lm elm-backup.sh   # set default dir via env
#
# Requires: elm

set -euo pipefail

PROFILE="config"
# Default OUTSIDE the repo so a backup is never accidentally committed.
ROOT="${ELM_BACKUP_DIR:-$HOME/elm-backup}"
ROOT_EXPLICIT=0
USE_DATE=0

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile|-p) PROFILE="$2"; shift 2 ;;
        --dir|-d)     ROOT="$2"; ROOT_EXPLICIT=1; shift 2 ;;
        --date)       USE_DATE=1;   shift ;;
        -h|--help)    usage 0 ;;
        *) echo "elm-backup: unknown argument '$1'" >&2; usage 1 >&2 ;;
    esac
done

# Endpoints to snapshot. Edit these lists to add/remove object types.
ALERTING=(
    AlertRuleList
    EscalationChainList
    ActionChainsList
    ActionRulesList
    RecipientGroupList
    IntegrationList
)
COLLECTORS=(
    CollectorList
    CollectorGroupList
    CollectorVersionList
)

# Safety net: refuse to write backups inside a git work tree unless the user
# explicitly chose the location with --dir. Prevents accidentally committing a
# portal backup into this (or any) repo.
if [[ $ROOT_EXPLICIT -eq 0 ]]; then
    parent="$(cd "$(dirname "$ROOT")" 2>/dev/null && pwd)" || parent=""
    if [[ -n "$parent" ]] && git -C "$parent" rev-parse --is-inside-work-tree &>/dev/null; then
        repo="$(git -C "$parent" rev-parse --show-toplevel)"
        echo "elm-backup: default dir '$ROOT' is inside git repo '$repo'." >&2
        echo "  Refusing to write backups into a code repo. Set ELM_BACKUP_DIR or" >&2
        echo "  pass --dir DIR to a location outside any repo." >&2
        exit 2
    fi
fi

# Label the backup by LM account_name rather than the elm profile name, so the
# directory reflects the portal that was backed up (a profile like 'config' can
# point at different accounts over time). We get account_name from elm itself,
# NOT by reading the credentials .ini: 'elm -f api' prints the request URL it
# builds (https://<account_name>.logicmonitor.com/...), so one cheap probe call
# yields the account name with no .ini parsing. The Authorization line that -f
# api also prints (contains the HMAC signature) is discarded.
LABEL="$PROFILE"
# '|| true' so a failed probe (with pipefail) falls through to the fallback
# below instead of aborting under 'set -e'.
account="$(elm -p "$PROFILE" -f api CollectorList -s1 2>/dev/null \
    | sed -n 's#^https://\([^./]*\)\.logicmonitor\.com/.*#\1#p' | head -1)" || true
if [[ -n "$account" ]]; then
    LABEL="$account"
else
    echo "elm-backup: could not resolve account_name (probe failed); falling" >&2
    echo "  back to profile name '$PROFILE' for the directory." >&2
fi

OUTDIR="$ROOT/$LABEL"
[[ $USE_DATE -eq 1 ]] && OUTDIR="$OUTDIR/$(date -u +%Y-%m-%d)"
mkdir -p "$OUTDIR"

# Dump one endpoint to JSONL. Global flags (-p, -f) come BEFORE the subcommand;
# -s0 (size=0 = all rows, up to 1000) is a subcommand flag and comes after.
# We redirect stdout to the file rather than using elm's -o/--filename, because
# -o after the subcommand is parsed as --offset, not the output filename.
# Status goes to stderr so stdout/the data stream stays clean.
dump() {
    local cmd="$1" out="$OUTDIR/$1.jsonl" err
    printf '  %-22s -> %s\n' "$cmd" "$out" >&2
    # Try paged (-s0 = all). Capture stderr; stdout goes to the file.
    err=$(elm -p "$PROFILE" -f jsonl "$cmd" -s0 2>&1 > "$out") && return 0
    # Some endpoints (e.g. ActionChainsList, ActionRulesList) are not paged and
    # reject -s; retry without it.
    if grep -q 'no such option: -s' <<< "$err"; then
        err=$(elm -p "$PROFILE" -f jsonl "$cmd" 2>&1 > "$out") && return 0
    fi
    echo "  ! $cmd failed${err:+: $err}" >&2
    rm -f "$out"
    return 1
}

echo "elm-backup: profile '$PROFILE' (account '$LABEL') -> $OUTDIR" >&2

rc=0
echo "Alerting:" >&2
for cmd in "${ALERTING[@]}"; do dump "$cmd" || rc=1; done
echo "Collectors:" >&2
for cmd in "${COLLECTORS[@]}"; do dump "$cmd" || rc=1; done

if [[ $rc -eq 0 ]]; then
    echo "elm-backup: done." >&2
else
    echo "elm-backup: finished with errors (see above)." >&2
fi
exit "$rc"
