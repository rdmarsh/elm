#!/usr/bin/env bash
# elm-check-access: see which commands a profile's API token is actually allowed
# to run, and print an allowed_commands line that matches.
#
# A profile has two limits that can disagree: allowed_commands in its .ini (what
# elm will run) and the LogicMonitor role behind its API token (what LM will
# answer). This sends one tiny request per command and reports which is which,
# so the two can be lined up -- either widen the role, or drop the commands it
# refuses from allowed_commands.
#
# Usage:
#   elm-check-access.sh [options]
#
# Options:
#   --profile, -p PROFILE  elm credential profile (default: ai)
#   --all                  check every command elm has, not just the allowed ones
#   --quiet, -q            only the summary and the allowed_commands line
#   --json                 machine-readable: each command with its API path and
#                          status, plus the allowed_commands list
#   -h, --help             show this help
#
# Each command is called with -s1 (one row), or plainly where that endpoint
# takes no size, and with no filters. Commands needing an id are reported as "needs id"
# and not counted either way: they cannot be checked without real ids, and a
# role that allows the list form normally allows the by-id form.
#
# Output: one line per command -- ok, denied (LM returned 403), or an error --
# then a summary and an allowed_commands line holding just the commands that
# answered, ready to paste into the profile.
#
# Examples:
#   elm-check-access.sh                  # the ai profile
#   elm-check-access.sh -p ai-preprod
#   elm-check-access.sh --all -q         # what the token can reach at all
#
# Requires: elm

set -euo pipefail

PROFILE=ai
ALL=0
QUIET=0
JSON=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --profile|-p) PROFILE=$2; shift 2 ;;
        --all)        ALL=1; shift ;;
        --quiet|-q)   QUIET=1; shift ;;
        --json)       JSON=1; QUIET=1; shift ;;
        -h|--help)    sed -n '2,/^$/p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
        *)            printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done

say() { [[ $QUIET -eq 1 ]] || printf '%s\n' "$*"; }

# The commands to try: what the profile allows (elm --help lists only those),
# or every command elm has with --all.
if [[ $ALL -eq 1 ]]; then
    mapfile -t COMMANDS < <(elm --help | sed -n '/^Commands:/,/^[A-Za-z]/p' | awk '/^  [A-Z]/ {print $1}')
else
    mapfile -t COMMANDS < <(elm -p "$PROFILE" --help | sed -n '/^Commands:/,/^[A-Za-z]/p' | awk '/^  [A-Z]/ {print $1}')
fi

[[ ${#COMMANDS[@]} -gt 0 ]] || { echo "No commands to check for profile '$PROFILE'." >&2; exit 1; }

say "Checking ${#COMMANDS[@]} commands as profile '$PROFILE' (one small request each)"
say

ok=() denied=() skipped=() failed=()
declare -A STATUS PATHS
for cmd in "${COMMANDS[@]}"; do
    out=$(elm -p "$PROFILE" "$cmd" -s1 2>&1) || true
    # A few commands take no -s (single-record endpoints); ask them plainly.
    case "$out" in *"no such option: -s"*) out=$(elm -p "$PROFILE" "$cmd" 2>&1) || true ;; esac
    case "$out" in
        *"Missing option"*|*"requires"*)   verdict="needs id"; skipped+=("$cmd") ;;
        *403*|*"do not have permission"*|*"Access denied"*)
                                           verdict="denied by LM (403)"; denied+=("$cmd") ;;
        *"is not allowed"*)                verdict="not in allowed_commands"; skipped+=("$cmd") ;;
        *"Error:"*|*Traceback*)            verdict="error: $(printf '%s' "$out" | grep -m1 -E 'Error:|Traceback' | cut -c1-60)"; failed+=("$cmd") ;;
        *)                                 verdict="ok"; ok+=("$cmd") ;;
    esac
    STATUS[$cmd]=${verdict%%:*}
    # The API path each command calls, for lining statuses up with LM role areas.
    [[ $JSON -eq 1 ]] && PATHS[$cmd]=$(elm "$cmd" --info 2>/dev/null | sed -n '2s/^GET //p')
    [[ $QUIET -eq 1 ]] || printf '  %-40s %s\n' "$cmd" "$verdict"
done

if [[ $JSON -eq 1 ]]; then
    printf '{\n  "profile": "%s",\n  "checked": %d,\n  "results": [\n' "$PROFILE" "${#COMMANDS[@]}"
    for i in "${!COMMANDS[@]}"; do
        cmd=${COMMANDS[i]}
        printf '    {"command": "%s", "path": "%s", "status": "%s"}%s\n' \
            "$cmd" "${PATHS[$cmd]:-}" "${STATUS[$cmd]}" "$([[ $i -lt $((${#COMMANDS[@]} - 1)) ]] && echo ,)"
    done
    printf '  ],\n  "allowed_commands": [%s],\n' "$(printf '"%s", ' "${ok[@]}" | sed 's/, $//')"
    printf '  "denied": [%s]\n}\n' "$(printf '"%s", ' "${denied[@]:-}" | sed 's/, $//; s/""//')"
    exit 0
fi

say
printf 'ok: %d, denied by LM: %d, needs id: %d, other errors: %d\n' \
    "${#ok[@]}" "${#denied[@]}" "${#skipped[@]}" "${#failed[@]}"

if [[ ${#denied[@]} -gt 0 ]]; then
    printf '\nDenied by the API token role (widen the role, or drop these):\n'
    printf '  %s\n' "${denied[@]}"
fi

if [[ ${#ok[@]} -gt 0 ]]; then
    printf '\nallowed_commands matching what this token can actually reach\n'
    printf '(commands needing an id are left out -- add them back if you use them):\n\n'
    printf 'allowed_commands = ['
    printf "'%s', " "${ok[@]}" | sed 's/, $//'
    printf ']\n'
fi
