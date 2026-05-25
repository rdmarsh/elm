#!/usr/bin/env bash
# elm-collector-readiness: discover devices in an LM auto-balance collector group
# and render a ready-to-paste Groovy reachability check script to stdout.
#
# Usage:
#   elm-collector-readiness.sh --id GROUP_ID [--profile PROFILE] [--creds]
#   elm-collector-readiness.sh --name GROUP_NAME [--profile PROFILE] [--creds]
#   elm-collector-readiness.sh            # list auto-balance groups and exit
#
# Options:
#   --id GROUP_ID       auto-balance collector group ID
#   --name GROUP_NAME   auto-balance collector group name (resolved to ID)
#   --profile PROFILE   elm credential profile; defaults to 'config' (same
#                       default as elm — reads config.ini)
#   --creds             inject LM API credentials from the elm profile into
#                       the rendered script; uses --profile if set
#
# Output is the rendered Groovy script on stdout. Status messages go to stderr.
# Redirect stdout as needed:
#   elm-collector-readiness.sh --id 42 > /tmp/check.groovy
#   elm-collector-readiness.sh --id 42 --creds | pbcopy
#   elm-collector-readiness.sh --id 42 --creds --profile prod > /tmp/check.groovy
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
# Requires: elm, jq, Jinja2 (via elm venv at ../venv or system python3)
# Requires for --creds: configobj (via elm venv)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CREDS_DIR="$HOME/.config/logicmonitor/credentials"
GROUP_ID=""
GROUP_NAME=""
ELM_FLAGS=()
ELM_PROFILE=""
INJECT_CREDS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --id)         GROUP_ID="$2";     shift 2 ;;
        --name)       GROUP_NAME="$2";   shift 2 ;;
        --profile|-p) ELM_FLAGS+=("-p" "$2"); ELM_PROFILE="$2"; shift 2 ;;
        --creds)      INJECT_CREDS=true; shift ;;
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
    printf 'Usage: %s --id GROUP_ID | --name GROUP_NAME [--profile PROFILE] [--creds]\n\n' "$(basename "$0")"
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
    -f id,displayName,name,autoProperties)

count=$(printf '%s' "$raw" | jq '.DeviceList | length')
printf 'Devices found: %s\n\n' "$count" >&2

if [[ "$count" -eq 0 ]]; then
    printf 'No devices found in this auto-balance group.\n' >&2
    exit 0
fi

# ── Build protocol matrix ─────────────────────────────────────────────────────
# name = the hostname or IP LM uses to connect; not displayName.
# Protocol detection uses autoProperties set by LM Active Discovery:
#   auto.snmp.operational        - "true" when SNMP responds
#   auto.network.listening_tcp_ports - comma-separated list of listening ports
matrix=$(printf '%s' "$raw" | jq '
  [.DeviceList[] |
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
    printf '%-32s %-22s %s\n' "Device" "IP/Hostname" "Protocols"
    printf '%-32s %-22s %s\n' "$(printf '%0.s-' {1..32})" "$(printf '%0.s-' {1..22})" "---------"
    printf '%s' "$matrix" \
        | jq -r '.[] | "\(.displayName)\t\(.ip)\t\(.protocols | join(", "))"' \
        | while IFS=$'\t' read -r name ip protos; do
              printf '%-32s %-22s %s\n' "${name:0:32}" "${ip:0:22}" "$protos"
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

if [[ "$INJECT_CREDS" == "true" ]]; then
    creds_file="${ELM_PROFILE:+$CREDS_DIR/${ELM_PROFILE}.ini}"
    creds_file="${creds_file:-$CREDS_DIR/config.ini}"
    [[ -f "$creds_file" ]] \
        || { printf 'Error: credentials file not found: %s\n' "$creds_file" >&2; exit 1; }
    printf 'Warning: rendered script contains LM API credentials — do not commit or share.\n\n' >&2
else
    creds_file=""
fi

tmpfile=$(mktemp)
printf '%s' "$matrix" > "$tmpfile"

"$python_bin" - "$template" "$tmpfile" "$creds_file" "$GROUP_ID" <<'PYEOF'
import sys, json
import jinja2

template_path = sys.argv[1]
data_path     = sys.argv[2]
creds_path    = sys.argv[3]
group_id      = int(sys.argv[4]) if sys.argv[4] else 0

with open(data_path) as f:
    devices = json.load(f)

tvars = {
    "devices_json": json.dumps(devices, indent=2),
    "group_id":     group_id,
}

if creds_path:
    import configobj
    try:
        cfg = configobj.ConfigObj(creds_path, unrepr=True)
    except Exception:
        cfg = configobj.ConfigObj(creds_path)

    def get(key):
        val = cfg.get(key, "")
        return str(val).strip().strip("\"'")

    tvars.update({
        "access_id":    get("access_id"),
        "access_key":   get("access_key"),
        "account_name": get("account_name"),
    })

with open(template_path) as f:
    tmpl = jinja2.Template(f.read(), undefined=jinja2.Undefined)

print(tmpl.render(**tvars))
PYEOF

rm "$tmpfile"
