#!/bin/sh
# compare-portals.sh -- a Markdown page comparing several portals, for a wiki or a report.
#
# Usage:
#   examples/compare-portals.sh PROFILE,PROFILE,... [DATASOURCE-NAMES-FILE] > page.md
#
# One section per area (sizes, settings, contacts, users and roles, alerting,
# device groups, collectors, LogicModules), each a table from tools/portal-matrix.py
# with one column per portal, showing only what differs: a section where every
# portal agrees says "No differences". FULL=1 shows the whole table for the
# smaller areas instead, with a "same" column. The optional file lists
# datasource names, one per line, to compare by checksum (see
# examples/comparing-portals.md). examples/report-pdf.sh turns the page into a PDF.
#
# DEVICE_GROUPS names the top-level device groups to compare, comma-separated,
# e.g. DEVICE_GROUPS='Standards,Templates': each one and everything under it.
# The rest of the tree is usually per-customer and expected to differ. Unset,
# the device groups section is skipped.
#
# MATRIX_OPTS is passed to every portal-matrix call, e.g. for a wiki that
# renders :true: / :false: and readers who know the portals by account name:
#   MATRIX_OPTS='-c account_name --tick :true: --cross :false:' \
#     examples/compare-portals.sh prod,preprod,test critical.txt > page.md
#
# The contacts section lists names, emails and phone numbers: keep the page
# somewhere only the people who may see them can read it. Progress and each
# table's summary go to stderr. Needs elm on PATH.

set -u
profiles=${1:?usage: $0 PROFILE,PROFILE,... [DATASOURCE-NAMES-FILE] > page.md}
names=${2:-}
matrix="$(dirname "$0")/../tools/portal-matrix.py"
opts=${MATRIX_OPTS:-}
full=-d                                # only the rows that differ
[ -n "${FULL:-}" ] && full=-m          # ... or the whole table, with a "same" column

# print stdin, or a note when a differences-only table came out empty
shown() {
    t=$(cat)
    if [ -n "$t" ]; then printf '%s\n' "$t"; else echo '_No differences._'; fi
}

# section TITLE NOTE ELM-ARGS... -- PORTAL-MATRIX-ARGS...
section() {
    title=$1 note=$2
    shift 2
    echo "$title" >&2
    elm_args=''
    while [ "$1" != -- ]; do elm_args="$elm_args $(printf '%s' "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/\$/'/")"; shift; done
    shift
    # shellcheck disable=SC2086  # opts is meant to split
    printf '\n## %s\n\n%s\n\n' "$title" "$note"
    eval "elm -p '$profiles' -f jsonl $elm_args" | python3 "$matrix" $opts "$@" | shown
}

printf '# Portal comparison\n\nProfiles: %s. Generated %s by elm.' "$profiles" "$(date '+%Y-%m-%d %H:%M')"
[ -z "${FULL:-}" ] && printf ' Differences only: rows that are the same on every portal are left out.'
echo

# -C prints one total per portal; jq adds which command it counted. Sizes are
# expected to differ, so this is always the plain table, no "same" column.
echo 'Sizes' >&2
printf '\n## Sizes\n\nHow many devices and websites each portal has.\n\n'
for c in DeviceList WebsiteList; do
    elm -p "$profiles" -f jsonl "$c" -C | jq -c --arg c "$c" '{command: $c} + .'
done | python3 "$matrix" $opts -k command -v total

# account settings that should match (counts, contract limits and timers left out)
settings=requireTwoFA,configurable2FAOptions,requireTwoFAForRemoteSession,sessionTimeoutInSeconds
settings=$settings,allowConcurrentLogins,enableKeepMeSignedIn,keepMeSignedInConfigurableDays,enableRemoteSession
settings=$settings,enableCollectorDebug,enableTestScript,enableScriptsInTextWidget,allowExecutionForDiagnosticSource
settings=$settings,allowExecutionForRemediationSource,applyCspPolicyOnDashboard,allowSharedReports,tokenDisabledDays
settings=$settings,userSuspendDays,timestampWindowOfApiUsersInSec,enableUserDetailsEmailNotification
settings=$settings,tenantIdentifierPropertyName,enableUpdateOfTenantIdentifierProperty,accountDomainWhitelist
settings=$settings,whiteList,alertTotalIncludeInAck,alertTotalIncludeInSdt,timezone
section 'Account settings' 'Two-factor, sessions, remote session, scripts, token and user expiry, tenant property, allowlists, alert totals.' \
    PortalInfo -f "$settings" -- "$full"

section 'Contacts' 'Portal contacts (PortalInfo).' \
    -e contacts PortalInfo -f contacts -- -k contacts.email "$full"

section 'Roles' 'Which roles exist where.' \
    RoleList -s0 -f name -- -k name "$full"

section 'Role privileges' 'Only the privileges that differ: the operation each role has on each object.' \
    -e privileges RoleList -s0 -f name,privileges.objectType,privileges.objectName,privileges.operation \
    -- -k name,privileges.objectType,privileges.objectName -v privileges.operation -d

section 'Users' 'Only the users whose status differs, or who are missing somewhere.' \
    AdminList -s0 -f username,status -- -k username -v status -d

section 'User groups' 'Which user groups exist where.' \
    AdminGroupList -s0 -f name -- -k name "$full"

section 'Escalation chains' 'Which escalation chains exist where.' \
    EscalationChainList -s0 -f name -- -k name "$full"

section 'Alert rules' 'Only the alert rules that differ: priority / level / escalation chain.' \
    AlertRuleList -s0 -f name,priority,levelStr,escalatingChain.name \
    -- -k name -v priority,levelStr,escalatingChain.name -d

section 'Recipient groups' 'Which recipient groups exist where.' \
    RecipientGroupList -s0 -f groupName -- -k groupName "$full"

section 'Integrations' 'Which integrations exist where, and their type.' \
    IntegrationList -s0 -f name,type -- -k name -v type "$full"

# only the named subtrees: the ~ filter finds fullPaths containing the name,
# jq keeps the group itself and what is under it
echo 'Device groups' >&2
printf '\n## Device groups\n\n'
if [ -z "${DEVICE_GROUPS:-}" ]; then
    echo '_Skipped: set DEVICE_GROUPS to the top-level groups to compare, e.g. DEVICE_GROUPS=Standards,Templates._'
else
    printf 'Only the groups in %s (and under them) that differ: missing, or with another AppliesTo.\n\n' "$DEVICE_GROUPS"
    old_ifs=$IFS; IFS=,
    for g in $DEVICE_GROUPS; do
        IFS=$old_ifs
        elm -p "$profiles" -f jsonl DeviceGroupList -s0 -F "fullPath~$g" -f fullPath,appliesTo \
            | jq -c --arg g "$g" 'select(.fullPath == $g or (.fullPath | startswith($g + "/")))'
    done | python3 "$matrix" $opts -k fullPath -v appliesTo -d | shown
    IFS=$old_ifs
fi

section 'Root group properties' 'Custom properties set on the root device group (inherited by everything).' \
    -e customProperties DeviceGroupById --id 1 -f customProperties \
    -- -k customProperties.name -v customProperties.value "$full"

section 'Collector groups' 'Which collector groups exist where.' \
    CollectorGroupList -s0 -f name -- -k name "$full"

section 'Collector builds' 'Which collector builds are running where.' \
    CollectorList -s0 -f build -- -k build "$full"

if [ -n "$names" ]; then
    echo 'Critical datasources' >&2
    printf '\n## Critical datasources\n\nChecksum of each datasource in %s.\n\n' "$(basename "$names")"
    while read -r ds; do
        [ -n "$ds" ] && elm -p "$profiles" -f jsonl DatasourceList -F "name:$ds" -f name,checksum
    done < "$names" | python3 "$matrix" $opts -k name -v checksum "$full" | shown
fi

echo 'Other LogicModules' >&2
printf '\n## Other LogicModules\n\nOnly the ConfigSources, EventSources, PropertySources, TopologySources and AppliesTo functions that differ, by checksum.\n\n'
for c in ConfigSourceList EventSourceList PropertyRulesList TopologySourceList AppliesToFunctionList; do
    elm -p "$profiles" -f jsonl "$c" -s0 -f name,checksum | jq -c --arg t "$c" '{type: $t} + .'
done | python3 "$matrix" $opts -k type,name -v checksum -d | shown
