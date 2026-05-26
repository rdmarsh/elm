#!/usr/bin/env bash
# elm-collector-readiness: discover devices in an LM auto-balance collector group
# and render a ready-to-paste Groovy reachability check script to stdout.
#
# Usage:
#   elm-collector-readiness.sh --id GROUP_ID [--profile PROFILE]
#   elm-collector-readiness.sh --name GROUP_NAME [--profile PROFILE]
#   elm-collector-readiness.sh            # list auto-balance groups and exit
#
# Options:
#   --id GROUP_ID       auto-balance collector group ID
#   --name GROUP_NAME   auto-balance collector group name (resolved to ID)
#   --profile PROFILE   elm credential profile; defaults to 'config' (same
#                       default as elm — reads config.ini)
#
# Output is the rendered Groovy script on stdout. Status messages go to stderr.
# Redirect stdout as needed:
#   elm-collector-readiness.sh --id 42 > /tmp/check.groovy
#   elm-collector-readiness.sh --name "My Group" --profile prod | pbcopy
#
# The rendered script tests device connections using the hostname or IP address
# that LM uses to reach each device (the 'name' field, not 'displayName').
#
# Protocol detection (from device autoProperties set by LM Active Discovery):
#   ping    - always included
#   snmp    - auto.snmp.operational == "true"
#   tcp-22  - 22 in auto.network.listening_tcp_ports
#   tcp-80  - 80 in auto.network.listening_tcp_ports
#   tcp-135 - 135 in auto.network.listening_tcp_ports
#   tcp-443 - 443 in auto.network.listening_tcp_ports
#
# Dead devices (hostStatus:dead) are skipped — the device itself is unreachable,
# testing from a new collector adds no information. Devices with hostStatus:dead-collector
# are kept — the collector is down but the device may be reachable from the new one.
#
# Requires: elm, jq, Jinja2 (via elm venv at ../venv or system python3)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GROUP_ID=""
GROUP_NAME=""
ELM_FLAGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --id)         GROUP_ID="$2";   shift 2 ;;
        --name)       GROUP_NAME="$2"; shift 2 ;;
        --profile|-p) ELM_FLAGS+=("-p" "$2"); shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done

elm_run() { elm "${ELM_FLAGS[@]+"${ELM_FLAGS[@]}"}" "$@"; }

# ── Resolve group name to ID ──────────────────────────────────────────────────
if [[ -n "$GROUP_NAME" && -z "$GROUP_ID" ]]; then
    GROUP_ID=$(elm_run CollectorGroupList -s0 -f id,name \
        | jq -r --arg n "$GROUP_NAME" \
              '.CollectorGroupList[] | select(.name == $n) | .id')
    [[ -z "$GROUP_ID" ]] \
        && { printf 'Error: collector group "%s" not found\n' "$GROUP_NAME" >&2; exit 1; }
fi

# ── No group specified — list auto-balance groups and exit ────────────────────
if [[ -z "$GROUP_ID" ]]; then
    printf 'Usage: %s --id GROUP_ID | --name GROUP_NAME [--profile PROFILE]\n\n' "$(basename "$0")"
    printf 'Auto-balance groups:\n\n'
    elm_run -f txt CollectorGroupList -s0 -F 'autoBalance:true' \
        -f id,name,numOfCollectors,autoBalanceInstanceCountThreshold
    exit 0
fi

# ── Validate group ────────────────────────────────────────────────────────────
all_groups=$(elm_run CollectorGroupList -s0 -f id,name,autoBalance,numOfCollectors)
group_json=$(printf '%s' "$all_groups" \
    | jq --argjson id "$GROUP_ID" '.CollectorGroupList[] | select(.id == $id)')

[[ -z "$group_json" ]] \
    && { printf 'Error: collector group %s not found\n' "$GROUP_ID" >&2; exit 1; }

group_name=$(printf '%s' "$group_json" | jq -r '.name')
auto_balance=$(printf '%s' "$group_json" | jq -r '.autoBalance')
num_cols=$(printf '%s'  "$group_json" | jq -r '.numOfCollectors')

printf 'Group:       %s (id=%s)\n' "$group_name" "$GROUP_ID" >&2
printf 'Collectors:  %s\n' "$num_cols" >&2
printf 'AutoBalance: %s\n\n' "$auto_balance" >&2

if [[ "$auto_balance" != "true" ]]; then
    printf 'Warning: group "%s" does not have autoBalance enabled\n\n' "$group_name" >&2
fi

# ── Fetch devices ─────────────────────────────────────────────────────────────
printf 'Fetching devices in group %s...\n' "$GROUP_ID" >&2
raw=$(elm_run DeviceList -s0 \
    -F "autoBalancedCollectorGroupId:$GROUP_ID" \
    -f id,displayName,name,hostStatus,autoProperties)

total=$(printf '%s' "$raw" | jq '.DeviceList | length')
dead=$(printf '%s' "$raw" | jq '[.DeviceList[] | select(.hostStatus == "dead")] | length')
testable=$(( total - dead ))

printf 'Devices found: %s' "$total" >&2
if [[ "$dead" -gt 0 ]]; then
    printf ' (%s dead — skipped, %s to test)' "$dead" "$testable" >&2
fi
printf '\n\n' >&2

if [[ "$testable" -eq 0 ]]; then
    printf 'No testable devices in this auto-balance group (all dead).\n' >&2
    exit 0
fi

# ── Build protocol matrix ─────────────────────────────────────────────────────
# Skip hostStatus:dead — device itself is unreachable, testing adds no information.
# Keep hostStatus:dead-collector — the collector is down but the device may be fine;
# that is exactly the scenario this script is designed to catch.
#
# Protocol detection uses autoProperties set by LM Active Discovery:
#   auto.snmp.operational        - "true" when SNMP responds
#   auto.network.listening_tcp_ports - comma-separated list of listening ports
matrix=$(printf '%s' "$raw" | jq '
  [.DeviceList[] |
    select(.hostStatus != "dead") |
    (
      .autoProperties // [] |
      map(select(.name == "auto.network.listening_tcp_ports")) |
      first | .value // "" | split(",")
    ) as $tcp |
    (
      .autoProperties // [] |
      map(select(.name == "auto.snmp.operational")) |
      first | .value // "false"
    ) as $snmp |
    {
      id:          .id,
      displayName: .displayName,
      ip:          .name,
      hostStatus:  .hostStatus,
      protocols: (
        ["ping"] +
        (if $snmp == "true"           then ["snmp"]    else [] end) +
        (if $tcp | contains(["135"])  then ["tcp-135"] else [] end) +
        (if $tcp | contains(["22"])   then ["tcp-22"]  else [] end) +
        (if $tcp | contains(["80"])   then ["tcp-80"]  else [] end) +
        (if $tcp | contains(["443"])  then ["tcp-443"] else [] end)
      )
    }
  ]
')

# ── Summary table (stderr) ────────────────────────────────────────────────────
{
    printf '%-32s %-22s %-16s %s\n' "Device" "IP/Hostname" "Status" "Protocols"
    printf '%-32s %-22s %-16s %s\n' "$(printf '%0.s-' {1..32})" "$(printf '%0.s-' {1..22})" "----------------" "---------"
    printf '%s' "$matrix" \
        | jq -r '.[] | "\(.displayName)\t\(.ip)\t\(.hostStatus)\t\(.protocols | map(if . == "tcp-135" then "wmi" elif . == "tcp-22" then "ssh" elif . == "tcp-80" then "http" elif . == "tcp-443" then "https" else . end) | join(", "))"' \
        | while IFS=$'\t' read -r name ip status protos; do
              printf '%-32s %-22s %-16s %s\n' "${name:0:32}" "${ip:0:22}" "$status" "$protos"
          done
} >&2

# ── Render Groovy script to stdout ────────────────────────────────────────────
template="$SCRIPT_DIR/lm-collector-reachability-check.groovy.j2"
[[ -f "$template" ]] || { printf 'Error: template not found: %s\n' "$template" >&2; exit 1; }

venv_python="$SCRIPT_DIR/../venv/bin/python3"
if [[ -x "$venv_python" ]] && "$venv_python" -c 'import jinja2' 2>/dev/null; then
    python_bin="$venv_python"
elif command -v python3 &>/dev/null && python3 -c 'import jinja2' 2>/dev/null; then
    python_bin="python3"
else
    printf 'Error: jinja2 not found. Run "make" in the elm project root to build the venv.\n' >&2
    exit 1
fi

tmpfile=$(mktemp)
printf '%s' "$matrix" > "$tmpfile"

"$python_bin" - "$template" "$tmpfile" <<'PYEOF'
import sys, json
import jinja2

template_path = sys.argv[1]
data_path     = sys.argv[2]

with open(data_path) as f:
    devices = json.load(f)

def groovy_str(s):
    return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"') + '"'

def device_to_groovy(d):
    protos = '[' + ', '.join(groovy_str(p) for p in d['protocols']) + ']'
    return (f'[id: {d["id"]}, displayName: {groovy_str(d["displayName"])}, '
            f'ip: {groovy_str(d["ip"])}, hostStatus: {groovy_str(d["hostStatus"])}, '
            f'protocols: {protos}]')

devices_groovy = '[\n' + ',\n'.join('    ' + device_to_groovy(d) for d in devices) + '\n]'

with open(template_path) as f:
    tmpl = jinja2.Template(f.read())

print(tmpl.render(devices_groovy=devices_groovy))
PYEOF

rm "$tmpfile"
