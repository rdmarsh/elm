#!/usr/bin/env bash
# elm-host-sdts: list the SDTs (scheduled downtime) affecting each host in a
# list, including SDTs the host inherits from a group.
#
# Usage:
#   elm-host-sdts.sh [options] FILE      # one hostname (displayName) per line
#   elm-host-sdts.sh [options] -         # read hosts from stdin
#   elm-host-sdts.sh [options] HOST...   # hosts as arguments
#
# Options:
#   --profile, -p PROFILE  elm credential profile; defaults to 'config'
#                          (same default as elm — reads config.ini)
#   --exact                exact host match (displayName:HOST) instead of the
#                          default contains match (displayName~HOST)
#   --active               only SDTs currently active (isEffective == true)
#   -h, --help             show this help
#
# How it works: each host's displayName is resolved to a device id via
# DeviceList, then AllSDTListByDeviceId (/device/devices/{id}/sdts) is queried.
# That endpoint does the inheritance join server-side — it returns device SDTs,
# instance SDTs, AND inherited group SDTs that actually apply to the device
# (it correctly excludes a group SDT scoped to a datasource/instance the device
# does not have). So no manual deviceGroupId/dataSourceId cross-referencing is
# needed.
#
# Output: one block per host, an aligned table with columns:
#   TYPE  ACTIVE  GROUP  HOST  INSTANCE  FROM  TO  DURATION  COMMENT
# Each SDT fills only the scope column(s) it applies to (group / host /
# instance); the others show "-". FROM/TO are startDateTimeOnLocal /
# endDateTimeOnLocal as returned by LM — i.e. in the PORTAL's timezone (the
# abbreviation, e.g. AEST, is shown), NOT necessarily your machine's local time.
# All SDTs (active and scheduled) are listed; use --active to limit to active.
#
# Examples:
#   elm-host-sdts.sh hosts.txt
#   elm-host-sdts.sh --profile prod --active hosts.txt
#   printf 'host1\nhost2\n' | elm-host-sdts.sh -
#   elm-host-sdts.sh host1
#
# Requires: elm, jq, column

set -euo pipefail

ELM_FLAGS=()
OP="~"          # contains match by default
ONLY_ACTIVE=0
HOSTS=()
FROM_STDIN=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --profile|-p) ELM_FLAGS+=("-p" "$2"); shift 2 ;;
        --exact)      OP=":"; shift ;;
        --active)     ONLY_ACTIVE=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed -E 's/^# ?//'
            exit 0
            ;;
        -)            FROM_STDIN=1; shift ;;
        --)           shift; HOSTS+=("$@"); break ;;
        -*)           printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
        *)            HOSTS+=("$1"); shift ;;
    esac
done

# Collect hosts from a file, stdin, or positional args.
if [[ $FROM_STDIN -eq 1 ]]; then
    mapfile -t HOSTS < <(cat -)
elif [[ ${#HOSTS[@]} -eq 1 && -f "${HOSTS[0]}" ]]; then
    mapfile -t HOSTS < "${HOSTS[0]}"
fi

# De-duplicate hosts (preserve first-seen order) and drop blank lines.
declare -A _seen
deduped=()
for h in "${HOSTS[@]}"; do
    [[ -z "${h//[[:space:]]/}" ]] && continue
    [[ -n "${_seen[$h]:-}" ]] && continue
    _seen[$h]=1
    deduped+=("$h")
done
HOSTS=("${deduped[@]}")

if [[ ${#HOSTS[@]} -eq 0 ]]; then
    sed -n '2,/^$/p' "$0" | sed -E 's/^# ?//'
    exit 1
fi

# Run elm with the chosen profile. Filter the benign "no data found" warning
# from stderr (it fires for hosts with no match / no SDTs and is handled below);
# any other stderr — real auth/API errors — still passes through.
elm_run() {
    elm "${ELM_FLAGS[@]+"${ELM_FLAGS[@]}"}" "$@" \
        2> >(grep -v -F 'Warning: no data found' >&2)
}

# Emit one tab-separated row per SDT from an AllSDTListByDeviceId payload:
#   TYPE \t ACTIVE \t GROUP \t HOST \t INSTANCE \t FROM \t TO \t DURATION \t COMMENT
# Only the scope column(s) the SDT applies to are filled; others are "-".
# Group SDTs append the limiting datasource in brackets when scoped to one.
# TYPE is the LM `sdtType` field (oneTime / daily / weekly / monthly /
# monthlyByWeek). ACTIVE is the LM `isEffective` field (yes = the SDT is
# suppressing alerts right now; no = not currently in a window).
# DURATION is the SDT's nominal length (the `duration` field, minutes) rendered
# as e.g. 5h, 1h30m, 45m.
format_rows() {
    jq -r --argjson only_active "$ONLY_ACTIVE" '
        (.AllSDTListByDeviceId // [])[]
        | select($only_active == 0 or .isEffective == true)
        | (.sdtType // "oneTime") as $sdttype
        | (if .isEffective then "yes" else "no" end) as $active   # the ACTIVE column
        | (if (.type | test("Group"))
             then .deviceGroupFullPath
                  + (if (.dataSourceId // 0) != 0 then " [" + (.dataSourceName // "") + "]" else "" end)
             else "-" end) as $group
        | (if (.type | test("Group")) then "-" else (.deviceDisplayName // "-") end) as $host
        | (.dataSourceInstanceName // "-") as $inst
        | (.duration // 0) as $m
        | (($m / 60) | floor) as $h | ($m - $h * 60) as $mm
        | (if $h > 0 and $mm > 0 then "\($h)h\($mm)m"
           elif $h > 0 then "\($h)h"
           else "\($mm)m" end) as $dur
        | [ $sdttype, $active, $group, $host, $inst,
            (.startDateTimeOnLocal // "-"), (.endDateTimeOnLocal // "-"), $dur, (.comment // "") ]
        | @tsv
    '
}

for h in "${HOSTS[@]}"; do
    printf -- '--- %s ---\n' "$h"

    # Resolve displayName -> device id(s). A contains match may hit several.
    ids=$(elm_run -f json DeviceList -s0 -F "displayName${OP}${h}" -f id \
          | jq -r '.DeviceList[]?.id')

    if [[ -z "$ids" ]]; then
        printf '(no matching device)\n'
        continue
    fi

    # Gather rows across all matched device ids, then render one aligned table.
    rows=""
    while read -r id; do
        [[ -z "$id" ]] && continue
        out=$(elm_run -f json AllSDTListByDeviceId --id "$id" | format_rows)
        [[ -n "$out" ]] && rows+="${out}"$'\n'
    done <<< "$ids"

    if [[ -z "${rows//[$'\n']/}" ]]; then
        printf '(no SDTs)\n'
    else
        # Sort rows: ACTIVE (field 2) descending so "yes" leads, then FROM
        # (field 6) ascending. FROM is portal-local in a fixed format, so a
        # lexical sort is chronological. Header is printed separately, unsorted.
        { printf 'TYPE\tACTIVE\tGROUP\tHOST\tINSTANCE\tFROM\tTO\tDURATION\tCOMMENT\n'
          printf '%s' "$rows" | sort -t $'\t' -k2,2r -k6,6
        } | column -t -s $'\t'
    fi
    printf '\n'   # blank line between host blocks
done
