#!/usr/bin/env bash
# elm-group-paths: list the full path of every device group (or website group),
# sorted, for one or more portals. Handy for diffing group trees between
# environments.
#
# Usage:
#   elm-group-paths.sh [options]
#
# Options:
#   --profile, -p PROFILE  elm credential profile; repeat for several portals.
#                          Defaults to 'config' (same default as elm).
#   --website              website groups (WebsiteGroupList) instead of device
#                          groups (DeviceGroupList)
#   --out-dir, -d DIR      write one file per profile, DIR/<kind>-group-paths-<PROFILE>.txt,
#                          instead of printing to stdout
#   -h, --help             show this help
#
# Output: one fullPath per line, sorted. The root group (empty path) is left
# out. With several profiles on stdout each line is prefixed "PROFILE<TAB>", so
# the result still sorts and greps cleanly. Progress goes to stderr.
#
# Groups are fetched 1000 at a time (LM's page limit), using -C for the total.
#
# Examples:
#   elm-group-paths.sh
#   elm-group-paths.sh --website -p prod
#   elm-group-paths.sh -p preprod -p prod -d out/
#   diff <(elm-group-paths.sh -p preprod) <(elm-group-paths.sh -p prod)
#
# Requires: elm

set -euo pipefail

PROFILES=()
COMMAND=DeviceGroupList
KIND=device
OUT_DIR=

while [[ $# -gt 0 ]]; do
    case $1 in
        --profile|-p) PROFILES+=("$2"); shift 2 ;;
        --website)    COMMAND=WebsiteGroupList; KIND=website; shift ;;
        --out-dir|-d) OUT_DIR=$2; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed -E 's/^# ?//'
            exit 0
            ;;
        *)            printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done

[[ ${#PROFILES[@]} -eq 0 ]] && PROFILES=(config)
[[ -n "$OUT_DIR" ]] && mkdir -p "$OUT_DIR"

# Print every fullPath for one profile, sorted, root group omitted.
group_paths() {
    local profile=$1 total offset
    total=$(elm -p "$profile" "$COMMAND" -C)
    if ! [[ "$total" =~ ^[0-9]+$ ]]; then
        printf '%s: expected a number of groups from -C, got: %s\n' "$profile" "$total" >&2
        return 1
    fi
    printf '%s: %s %s groups\n' "$profile" "$total" "$KIND" >&2

    for ((offset = 0; offset < total; offset += 1000)); do
        elm -p "$profile" -f values "$COMMAND" -f fullPath -s0 -o "$offset"
    done | grep -v '^$' | sort
}

for profile in "${PROFILES[@]}"; do
    if [[ -n "$OUT_DIR" ]]; then
        out="$OUT_DIR/$KIND-group-paths-$profile.txt"
        group_paths "$profile" > "$out"
        printf '%s: wrote %s lines to %s\n' "$profile" "$(wc -l < "$out" | tr -d ' ')" "$out" >&2
    elif [[ ${#PROFILES[@]} -gt 1 ]]; then
        group_paths "$profile" | sed "s/^/$profile\t/"
    else
        group_paths "$profile"
    fi
done
