#!/usr/bin/env bash
# elm-profile-limit: make PORTAL_SET.ini from PORTAL.ini, a profile that can run
# only the commands in SET. Drops the format line (so output is elm's default)
# and any allowed_commands line, then adds one for SET.
#
# Usage:
#   elm-profile-limit.sh SET PORTAL...              # a set below
#   elm-profile-limit.sh -c CMD,CMD... NAME PORTAL...  # your own list, as PORTAL_NAME.ini
#   elm-profile-limit.sh -l                         # list the sets
#
# Sets:
#   collector  CollectorList CollectorById CollectorGroupList CollectorGroupById
#              CollectorsByGroupId CollectorVersionList
#   rules      AlertRuleList CollectorList EscalationChainList IntegrationList
#              RecipientGroupList ReportList
#
# Options:
#   -c CMDS      comma-separated commands instead of a set (Alert* works, as in elm)
#   -l           list the sets and their commands
#   -h, --help   show this help
#
# Examples:
#   elm-profile-limit.sh collector portal01 portal02  # portal01_collector.ini, portal02_collector.ini
#   elm-profile-limit.sh rules portal01                # portal01_rules.ini
#   elm-profile-limit.sh -c 'DeviceList,Alert*' noc portal01   # portal01_noc.ini
#
# Works in ~/.config/logicmonitor/credentials. Overwrites an existing
# PORTAL_SET.ini, as cp does. The new file is mode 600 and its contents are
# never printed. Add a set by adding a line to SETS below.
#
# Requires: nothing but bash, grep

set -euo pipefail
set -f   # Alert* is a command pattern, not a file glob

# One line per set (bash 3.2, as on macOS, has no associative arrays).
SETS='
collector CollectorList CollectorById CollectorGroupList CollectorGroupById CollectorsByGroupId CollectorVersionList
rules AlertRuleList CollectorList EscalationChainList IntegrationList RecipientGroupList ReportList
'

usage() { sed -n '2,/^# Requires/s/^# \{0,1\}//p' "$0"; }
die() { echo "elm-profile-limit: $1" >&2; exit "${2:-2}"; }

cmds=
while [[ $# -gt 0 ]]; do
  case $1 in
    -c) cmds=${2:?-c needs commands}; cmds=${cmds//,/ }; shift 2 ;;
    -l) echo "$SETS" | sed -n 's/^\([^ ]*\) /\1: /p'; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done
[[ $# -ge 2 ]] || { usage >&2; exit 2; }
name=$1; shift
[[ $name =~ ^[A-Za-z0-9_.-]+$ ]] || die "'$name' is not a profile name"
if [[ -z $cmds ]]; then
  cmds=$(echo "$SETS" | sed -n "s/^$name //p")
  [[ -n $cmds ]] || die "no set '$name' (-l lists them; -c gives your own commands)"
fi
for c in $cmds; do [[ $c =~ ^[A-Za-z0-9*]+$ ]] || die "'$c' is not a command"; done

creds="$HOME/.config/logicmonitor/credentials"
allow="allowed_commands = [$(printf "'%s', " $cmds | sed 's/, $//')]"

for portal in "$@"; do
  portal=${portal%.ini}
  [[ $portal =~ ^[A-Za-z0-9_.-]+$ ]] || die "'$portal' is not a profile name"
  src="$creds/$portal.ini" dst="$creds/${portal}_$name.ini"
  [[ -f $src ]] || die "no $src" 1
  (
    umask 077
    { grep -Ev '^[[:space:]]*(format|allowed_commands)[[:space:]]*=' "$src" || true; echo "$allow"; } > "$dst"
  )
  chmod 600 "$dst"
  echo "$dst"
done
