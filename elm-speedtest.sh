#!/usr/bin/env bash
# elm-speedtest: time LM API response for each credential profile
# Credentials are kept in memory only - never written to disk
#
# Usage: elm-speedtest.sh [ENDPOINT ...]
# Default endpoints if none given: AdminList DeviceList AuditLogList
#
# Examples:
#   ./elm-speedtest.sh
#   ./elm-speedtest.sh DeviceList ReportList WebsiteList
#
# Available list endpoints:
#   AdminList AlertRuleList ApiTokenList CollectorGroupList CollectorList
#   ConfigSourceList DashboardGroupList DatasourceList DeviceGroupList
#   DeviceList EscalationChainList EventSourceList IntegrationList
#   NetscanList RecipientGroupList ReportGroupList ReportList RoleList
#   SDTList WebsiteGroupList WebsiteList

RUNS=3
CREDS_DIR="$HOME/.config/logicmonitor/credentials"

# skip config if any other profile has identical credentials
skip_config=false
config_file="$CREDS_DIR/config.ini"
if [ -f "$config_file" ]; then
    while IFS= read -r line; do
        profile="${line:2}"
        [ "$profile" = "config" ] && continue
        if cmp -s "$config_file" "$CREDS_DIR/${profile}.ini"; then
            skip_config=true
            break
        fi
    done < <(elm --list 2>/dev/null)
fi

if [ $# -gt 0 ]; then
    ENDPOINTS=("$@")
else
    ENDPOINTS=("AdminList" "DeviceList" "AuditLogList")
fi

printf "host: %s\n\n" "$(hostname -s)"

# compute column widths: max of endpoint name length and minimum width of 8
declare -a WIDTHS=()
for ep in "${ENDPOINTS[@]}"; do
    w=${#ep}
    [ $w -lt 8 ] && w=8
    WIDTHS+=($w)
done

# header
printf "%-20s" "profile"
for i in "${!ENDPOINTS[@]}"; do
    printf "  %-${WIDTHS[$i]}s" "${ENDPOINTS[$i]}"
done
printf "\n"

printf "%-20s" "-------"
for i in "${!ENDPOINTS[@]}"; do
    printf "  %-${WIDTHS[$i]}s" "$(printf '%*s' "${WIDTHS[$i]}" | tr ' ' '-')"
done
printf "\n"

while IFS= read -r line; do
    profile="${line:2}"
    [ "$profile" = "config" ] && [ "$skip_config" = "true" ] && continue
    printf "%-20s" "$profile"

    for i in "${!ENDPOINTS[@]}"; do
        ep="${ENDPOINTS[$i]}"
        output=$(elm --profile "$profile" -f api "$ep" -s1 -f id 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$output" ]; then
            printf "  %-${WIDTHS[$i]}s" "error"
            continue
        fi

        URL=$(printf '%s\n' "$output" | head -1)
        AUTH=$(printf '%s\n' "$output" | tail -1)
        unset output

        total=0
        for _ in $(seq 1 $RUNS); do
            t=$(curl -s -o /dev/null \
                -w "%{time_total}" \
                -H "$AUTH" -H "Content-Type: application/json" -H "X-Version: 3" \
                "$URL")
            total=$(echo "$total + $t" | bc)
        done
        unset AUTH

        avg=$(printf "%.3fs" "$(echo "scale=3; $total / $RUNS" | bc)")
        printf "  %-${WIDTHS[$i]}s" "$avg"
    done
    printf "\n"

done < <(elm --list 2>/dev/null)
