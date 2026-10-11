#!/bin/sh
# elm-compare-portals.sh -- a Markdown page comparing several portals, for a wiki or a report.
#
# Usage:
#   tools/elm-compare-portals.sh PROFILE,PROFILE,... [MODULE-NAMES-FILE] > page.md
#
# A Summary table comes first: each section, linked, with its result in short.
# One section per area (sizes, settings, contacts, users and roles, alerting,
# device groups, collectors, LogicModules, SysOID maps), each a table from
# tools/portal-matrix.py with one column per portal, showing only what differs:
# a section where every portal agrees says "No differences". FULL=1 shows the
# whole table for the smaller areas instead, with a "same" column. Then lists
# per portal of things to fix: hardcoded devices in AppliesTo, unused modules,
# stale API tokens (STALE_DAYS, default 90), users suspended on one portal but
# active on another, users never logged in, and a count of idle users. The optional
# file lists module names, one per line, to compare by version and AppliesTo
# (see examples/comparing-portals.md). tools/report-pdf.sh turns the page into a PDF.
#
# DEVICE_GROUPS names the top-level device groups to compare, comma-separated,
# e.g. DEVICE_GROUPS='Standards,Templates': each one and everything under it,
# the groups (AppliesTo) and their custom properties.
# The rest of the tree is usually per-customer and expected to differ. Unset,
# the device groups section is skipped. Quote it: DEVICE_GROUPS='~admin' --
# unquoted, zsh and bash read ~name as a home directory.
#
# MATRIX_OPTS is passed to every portal-matrix call, e.g. for a wiki that
# renders :true: / :false: and readers who know the portals by account name:
#   MATRIX_OPTS='-c account_name --tick :true: --cross :false:' \
#     tools/elm-compare-portals.sh prod,preprod,test critical.txt > page.md
#
# The contacts, token and user sections name people: keep the page
# somewhere only the people who may see them can read it. Progress and each
# table's summary go to stderr. Needs elm on PATH.

set -u
profiles=${1:?usage: $0 PROFILE,PROFILE,... [DATASOURCE-NAMES-FILE] > page.md}
names=${2:-}
matrix="$(dirname "$0")/portal-matrix.py"
opts=${MATRIX_OPTS:-}
full=-d                                # only the rows that differ
min=--min=${MIN:-2}                    # ... and, where noted, only on 2+ portals: one portal's own (a customer's) are expected
[ -n "${FULL:-}" ] && full=-m          # ... or the whole table, with a "same" column

# heading TITLE [NOTE]: a section's heading and what it shows. The title also
# goes to stderr as progress, and names the section in the summary.
heading() {
    current=$1
    echo "$1" >&2
    printf '\n## %s\n\n' "$1"
    [ -n "${2:-}" ] && printf '%s\n\n' "$2"
    return 0
}

# result TEXT: the current section's line in the summary
summary=$(mktemp)
result() { printf '%s\t%s\n' "$current" "$1" >> "$summary"; }

# table PORTAL-MATRIX-ARGS... : the matrix of the rows on stdin, then
# portal-matrix's own count ("3 of 40 rows differ ..."), so a short table, or
# none ("No differences: ..."), cannot be mistaken for "nothing was compared".
# $empty, if set, replaces the note for no rows at all; $found=1 makes the
# summary say how many rows were found, for lists of things to fix; $say
# replaces the summary's text, for counts that are not meant to match. Set them
# before the call and clear them after: a VAR=x prefix on a shell function
# can outlive the call.
errs=$(mktemp)
table() {
    t=$(python3 "$matrix" -o "$profiles" $opts "$@" 2>"$errs")
    rc=$?
    cat "$errs" >&2
    count=$(tail -1 "$errs")
    if [ -n "$t" ]; then
        printf '%s\n\n_%s._\n' "$t" "$count"
    elif [ "$rc" -eq 0 ]; then
        printf '_%s._\n' "$count"          # No differences: N rows the same on M portals
    else
        count=${empty:-Nothing to compare: no rows came back (see the log)}
        echo "_${count}._"
        result "$count"
        return
    fi
    if [ -n "${say:-}" ]; then
        result "$say"
    elif [ -n "${found:-}" ]; then
        result "**$(printf '%s\n' "$count" | sed -E 's/^No differences: //; s/^[0-9]+ of //; s/ rows?.*//')** found"
    else
        result "$count"
    fi
}

# list_table FIELD...: a plain Markdown table of the jsonl rows on stdin, one
# column per field, for lists that are per portal rather than compared
list_table() {
    jq -rs --args '. as $rows | $ARGS.positional as $f
        | if ($rows | length) == 0 then empty else
          ("| " + ($f | join(" | ")) + " |"), ("|" + ($f | map("---") | join("|")) + "|"),
          ($rows[] | "| " + ([.[$f[]] | if . == null then "" else tostring | gsub("\\|"; "\\|") end] | join(" | ")) + " |")
          end' "$@"
}

# section TITLE NOTE ELM-ARGS... -- PORTAL-MATRIX-ARGS...
section() {
    heading "$1" "$2"
    shift 2
    elm_args=''
    while [ "$1" != -- ]; do elm_args="$elm_args $(printf '%s' "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/\$/'/")"; shift; done
    shift
    eval "elm -p '$profiles' -f jsonl $elm_args" | table "$@"
}

# and_list MARK LIST: "a, b and c" from "a,b,c", each item between MARK (** for bold); empty items dropped
and_list() {
    printf '%s' "$2" | awk -F, -v m="$1" '{
        n = 0; for (i = 1; i <= NF; i++) if ($i != "") item[++n] = $i
        for (i = 1; i <= n; i++) s = s (i == 1 ? "" : i == n ? " and " : ", ") m item[i] m; print s }'
}
portal_list=$(and_list '**' "$profiles")
printf '# Portal comparison\n\nComparing %s, %s.\n' "$portal_list" "$(date '+%-d %B %Y at %H:%M')"
[ -z "${FULL:-}" ] && printf '\nOnly what differs is shown: rows that are the same on every portal are left out.\n'
[ "${MIN:-2}" -gt 1 ] && printf '\nUsers, roles, alerting, integrations, collector groups and LogicModules that only one portal has (a customer'"'"'s own) are left out too; the count under each table says how many, per portal. MIN=1 shows them.\n'

# The sections go to a temporary file first, so the summary linking to each
# of them can come before them.
body=$(mktemp)
trap 'rm -f "$body" "$errs" "$summary" "${mods:-}"' EXIT
exec 3>&1 >"$body"

# -C prints one total per portal; jq adds which command it counted. Sizes are
# expected to differ, so this is always the plain table, no "same" column, with
# a total across the portals.
heading 'Sizes' 'How many of each, per portal.'
for c in DeviceList DeviceGroupList CollectorList AdminList DashboardList WebsiteList; do
    elm -p "$profiles" -f jsonl "$c" -C | jq -c --arg c "$c" '{command: $c} + .'
done | { say='Counts per portal'; table -k command -v total -t; }

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
    RoleList -s0 -f name -- -k name "$full" "$min"

section 'Role privileges' 'Only the privileges that differ: the operation each role has on each object.' \
    -e privileges RoleList -s0 -f name,privileges.objectType,privileges.objectName,privileges.operation \
    -- -k name,privileges.objectType,privileges.objectName -v privileges.operation -d "$min"

section 'Users' 'Only the users whose status differs, or who are missing somewhere.' \
    AdminList -s0 -f username,status -- -k username -v status -d "$min"

section 'User groups' 'Which user groups exist where.' \
    AdminGroupList -s0 -f name -- -k name "$full" "$min"

section 'Escalation chains' 'Which escalation chains exist where.' \
    EscalationChainList -s0 -f name -- -k name "$full" "$min"

section 'Alert rules' 'Only the alert rules that differ: priority / level / escalation chain.' \
    AlertRuleList -s0 -f name,priority,levelStr,escalatingChain.name \
    -- -k name -v priority,levelStr,escalatingChain.name -d "$min"

section 'Recipient groups' 'Which recipient groups exist where.' \
    RecipientGroupList -s0 -f groupName -- -k groupName "$full" "$min"

section 'Integrations' 'Which integrations exist where, and their type.' \
    IntegrationList -s0 -f name,type -- -k name -v type "$full" "$min"

# subtree_rows ELM-ARGS... : DeviceGroupList rows for the groups named in
# DEVICE_GROUPS and everything under them. The ~ filter finds fullPaths
# containing the name; jq keeps the group itself and what is under it.
subtree_rows() {
    old_ifs=$IFS; IFS=,
    for g in $DEVICE_GROUPS; do
        IFS=$old_ifs
        case $g in
            '') continue ;;     # a,,b: an empty name would match the root group (fullPath "")
            /*) # no LM group path starts with /: the shell expanded a ~name
                echo "DEVICE_GROUPS: $g is a directory, not a group; the shell expanded a ~ in it." \
                     "Quote the value: DEVICE_GROUPS='~admin,...'" >&2
                continue ;;
        esac
        elm -p "$profiles" -f jsonl "$@" DeviceGroupList -s0 -F "fullPath~$g" -f "fullPath,$fields" \
            | jq -c --arg g "$g" 'select(.fullPath == $g or (.fullPath | startswith($g + "/")))'
    done
    IFS=$old_ifs
}

heading 'Device groups'
if [ -z "${DEVICE_GROUPS:-}" ]; then
    echo '_Skipped: set DEVICE_GROUPS to the top-level groups to compare, e.g. DEVICE_GROUPS=Standards,Templates._'
    result 'Skipped: DEVICE_GROUPS not set'
else
    printf 'Only the groups in %s (and under them) that differ: missing, or with another AppliesTo.\n\n' "$(and_list '' "$DEVICE_GROUPS")"
    fields=appliesTo subtree_rows | table -k fullPath -v appliesTo -d

    # one row per group and property; groups with none are left out (whether a
    # group exists is the section above). Secrets read ******** everywhere.
    heading 'Device group properties' 'Only the custom properties of those groups that differ: missing somewhere, or another value.'
    fields=customProperties subtree_rows -e customProperties \
        | jq -c 'select(.["customProperties.name"] != null)' \
        | { empty='No custom properties set on these groups'; table -k fullPath,customProperties.name -v customProperties.value -d; }
    empty=
fi

section 'Root group properties' 'Custom properties set on the root device group (inherited by everything).' \
    -e customProperties DeviceGroupById --id 1 -f customProperties \
    -- -k customProperties.name -v customProperties.value "$full"

section 'Collector groups' 'Which collector groups exist where.' \
    CollectorGroupList -s0 -f name -- -k name "$full" "$min"

section 'Collector builds' 'Which collector builds are running where.' \
    CollectorList -s0 -f build -- -k build "$full"

# LogicModules: each cell is the version as a date (which copy is newest) and
# the checksum's first 6 characters (whether the content differs: the same date
# with another checksum is a local edit). AppliesTo functions have no version.
module='{module: ((if .version then (.version | if . > 99999999999 then ./1000 else . end | floor | todate[:10]) + " " else "" end) + .checksum[:6])}'

# The other module types, fetched once: the critical list looks names up here
# too, and the Other LogicModules section is made from it. LIST:TYPE:FIELDS,
# types by their LM names; not every type has a version or an AppliesTo.
types='ConfigSourceList:ConfigSource:name,version,checksum,appliesTo
EventSourceList:EventSource:name,version,checksum,appliesTo
PropertyRulesList:PropertySource:name,version,checksum,appliesTo
TopologySourceList:TopologySource:name,version,checksum,appliesTo
DiagnosticSourcesList:DiagnosticSource:name,version,checksum,appliesTo
RemediationSourcesList:RemediationSource:name,checksum,appliesTo
JobMonitorList:JobMonitor:name,checksum,appliesTo
LogSourceList:LogSource:name,checksum
AppliesToFunctionList:AppliesToFunction:name,checksum'
mods=$(mktemp)
for c in $types; do
    list=${c%%:*} rest=${c#*:}
    elm -p "$profiles" -f jsonl "$list" -s0 -f "${rest#*:}" 2>/dev/null | jq -c --arg t "${rest%%:*}" '{type: $t} + .'
done > "$mods"

if [ -n "$names" ]; then
    heading 'Critical LogicModules' "Each module in $(basename "$names"): its version date and checksum, and its AppliesTo (the part most often changed on one portal), each a row."
    hits=$(mktemp) one=$(mktemp)
    # a datasource by that name, else any other module type by that name
    while read -r ds; do
        [ -n "$ds" ] || continue
        elm -p "$profiles" -f jsonl DatasourceList -F "name:$ds" -f name,version,checksum,appliesTo 2>/dev/null \
            | jq -c '{type: "DataSource"} + .' > "$one"
        if [ -s "$one" ]; then cat "$one"; else jq -c --arg n "$ds" 'select(.name == $n)' "$mods"; fi
    done < "$names" | tee "$hits" \
        | jq -c "del(.version, .checksum, .appliesTo) as \$row | (\$row + {field: \"version\", value: ($module).module}), (select(has(\"appliesTo\")) | \$row + {field: \"appliesTo\", value: .appliesTo})" \
        | table -k type,name,field -v value "$full"
    # a name no portal has (a typo, or not the exact name) would otherwise just be absent
    unknown=$(while read -r ds; do
        [ -n "$ds" ] && ! jq -e --arg n "$ds" 'select(.name == $n)' "$hits" >/dev/null && printf '%s,' "$ds"
    done < "$names")
    [ -n "$unknown" ] && printf '\n_Not found on any portal (check the exact name): %s._\n' "$(and_list '' "$unknown")"
    rm -f "$hits" "$one"
fi

heading 'Other LogicModules' 'Every ConfigSource, EventSource, PropertySource, TopologySource, DiagnosticSource, RemediationSource, JobMonitor, LogSource and AppliesTo function, by version date and checksum: only the ones that differ.'
jq -c "del(.version, .checksum, .appliesTo) + ($module)" "$mods" | table -k type,name -v module -d "$min"

# SysOID maps set categories from a device's SNMP OID, and many AppliesTo test
# categories: a map that differs changes which modules a device gets
heading 'SysOID maps' 'The categories each SNMP sysOID gives a device, where they differ. Many AppliesTo test those categories, so a map that differs changes which modules a device gets.'
elm -p "$profiles" -f jsonl OIDList -s0 -f oid,categories | table -k oid -v categories -d "$min"

# Every module and device group whose AppliesTo picks out single devices, by
# id or by name (==, not =~ patterns), on every portal whether or not the
# portals agree: it means one device on one portal, and stops matching when
# the device is replaced or renamed.
heading 'Hardcoded devices' 'Modules and device groups whose AppliesTo picks devices by `system.deviceId`, and modules that pick them by `system.hostname`, `system.displayname` or `system.ips` with `==`, with the values on each portal. An id is one device on one portal; a name stops matching when the device is renamed. A property or category on the devices does the same job and lasts. Not counted: commented-out text, a disabled AppliesTo (`false()`), and groups by name, which customers use for maintenance windows. A module for an API, such as `system.hostname == "api.example.com"`, is LM'"'"'s own pattern and fine.'
# ids anywhere; names in modules only; /* comments */ and false() ignored
picks='(.appliesTo // "" | gsub("/\\*[^*]*\\*/"; "")) as $a
    | if ($a | test("^\\s*false\\(\\)")) then [] else
      [$a | scan("(?i)system\\.(deviceid|hostname|displayname|ips)\\s*==\\s*\"?([^\"\\s)|&]+)")
        | select((.[0] | ascii_downcase) == "deviceid" or $type != "DeviceGroup")
        | if (.[0] | ascii_downcase) == "deviceid" then .[1] else (.[0] | ascii_downcase) + " " + .[1] end] end'
{
    for f in deviceId system.hostname system.displayname system.ips; do
        elm -p "$profiles" -f jsonl DatasourceList -s0 -F "appliesTo~$f" -f name,appliesTo 2>/dev/null \
            | jq -c '{type: "DataSource"} + .'
        elm -p "$profiles" -f jsonl DeviceGroupList -s0 -F "appliesTo~$f" -f fullPath,appliesTo 2>/dev/null \
            | jq -c '{type: "DeviceGroup", name: .fullPath} + del(.fullPath)'
    done
    cat "$mods"
} | jq -c ".type as \$type | {profile, account_name, type, name, picks: ($picks)} | select(.picks | length > 0) | .picks |= join(\", \")" \
  | jq -sc 'unique_by(.profile, .type, .name)[]' \
  | { found=1 empty='None: no AppliesTo names a single device'; table -k type,name -v picks; }
found= empty=

# Clean-up: per portal, not compared. Things to remove or check, and how
# stale counts as stale.
days=${STALE_DAYS:-90}
pcol=profile
case " $opts " in *account_name*) pcol=account_name ;; esac

heading 'Unused LogicModules' "How many modules of each type no device uses, per portal (LM's own included: many are never used). Candidates for removal, especially where one portal has many more than the rest."
for c in DatasourceList:DataSource $types; do
    list=${c%%:*} rest=${c#*:}
    [ "$list" = AppliesToFunctionList ] && continue        # no isInUse
    elm -p "$profiles" -f jsonl "$list" -F isInUse:false -C 2>/dev/null | jq -c --arg t "${rest%%:*}" '{type: $t} + .'
done | jq -sc '[group_by(.type)[] | select(all(.total == 0)) | .[0].type] as $none
        | .[] | select(.type as $t | $none | index($t) | not)' \
     | { say='Counts per type, per portal'; table -k type -v total; }       # a type no portal has any of is left out

heading 'Stale API tokens' "Active API tokens not used in the last $days days, or never (STALE_DAYS changes it). Each one still works: revoke the ones nobody needs."
elm -p "$profiles" -f jsonl ApiTokenList -s0 -f adminName,accessId,status,createdOn,lastUsedOn,note 2>/dev/null \
    | jq -c --argjson d "$days" --arg p "$pcol" 'select(.status == 2 and (.lastUsedOn == 0 or .lastUsedOn < now - $d * 86400))
        | {portal: .[$p], user: .adminName, token: (.accessId[:8] + "…"), created: (.createdOn | todate[:10]),
           "last used": (if .lastUsedOn == 0 then "never" else .lastUsedOn | todate[:10] end), note}' \
    | jq -sc 'sort_by(.portal, .user)[]' > "$body.tok"
n=$(grep -c . "$body.tok")
if [ "$n" -gt 0 ]; then list_table portal user token created 'last used' note < "$body.tok"; printf '\n_%s found._\n' "$n"; result "**$n** found"
else echo "_None: every active token was used in the last $days days._"; result 'None'; fi
rm -f "$body.tok"

# the users of every portal, fetched once for the three sections below
admins=$(mktemp)
elm -p "$profiles" -f jsonl AdminList -s0 -f username,status,apionly,lastLoginOn,createdBy 2>/dev/null > "$admins"

# someone suspended on one portal is usually someone who has left, and should
# be suspended on all of them
heading 'Suspended users' 'Users suspended on one portal but active on another: usually someone who has left, still able to log in somewhere.'
jq -sc 'group_by(.username)[] | select(any(.status == "suspended") and any(.status == "active"))[]
        | {profile, account_name, username, status}' "$admins" \
    | { found=1 empty='None: everyone suspended somewhere is suspended everywhere they have an account'; table -k username -v status; }

heading 'Users never logged in' "Active users, not API-only, who have never logged in: accounts made for someone who never used them."
jq -c --arg p "$pcol" 'select(.status == "active" and (.apionly | not) and .lastLoginOn == 0)
        | {portal: .[$p], user: .username, "created by": .createdBy}' "$admins" \
    | jq -sc 'sort_by(.portal, .user)[]' > "$body.usr"
n=$(grep -c . "$body.usr")
if [ "$n" -gt 0 ]; then list_table portal user 'created by' < "$body.usr"; printf '\n_%s found._\n' "$n"; result "**$n** found"
else echo "_None: every active user has logged in._"; result 'None'; fi
rm -f "$body.usr"

# a count, not a list: on a portal whose users sign in through SAML there can
# be hundreds, and following them up is another report's job
heading 'Users not logged in' "Active users, not API-only, by when they last logged in, per portal. A count only: the account setting userSuspendDays suspends idle users automatically."
jq -sc --argjson d "$days" 'now as $now | ["\($d) days to 1 year", "1 to 2 years", "over 2 years"] as $b
    | group_by(.profile)[] | map(select(.status == "active" and (.apionly | not) and .lastLoginOn > 0)) as $u
    | ($now - $d * 86400) as $stale | ($now - 365 * 86400) as $y1 | ($now - 730 * 86400) as $y2
    | .[0] as $first | $b[] as $bucket
    | {profile: $first.profile, account_name: $first.account_name, "last login": $bucket,
       users: ($u | map(.lastLoginOn | if $bucket == $b[0] then (. < $stale and . >= $y1)
                                       elif $bucket == $b[1] then (. < $y1 and . >= $y2) else . < $y2 end)
               | map(select(.)) | length)}' "$admins" \
    | { say='Counts per portal'; table -k 'last login' -v users -t; }
rm -f "$admins"

# The summary comes first: one row per section, linked, with its result in
# short ("12 of 40 differ"). Anchors as pandoc and GitHub make them.
exec 1>&3 3>&-
printf '\n## Summary\n\n| Section | Result |\n| --- | --- |\n'
while IFS='	' read -r t r; do
    r=$(printf '%s\n' "$r" | sed -E \
        -e 's/^([0-9]+) of ([0-9]+) rows? differs? across [0-9]+ portals?/**\1** of \2 differ/' \
        -e 's/^No differences: ([0-9]+) rows? the same on [0-9]+ portals?/none of \1 differ/' \
        -e 's/; ([0-9]+) rows? on (only one portal|fewer than [0-9]+ portals) left out.*/; \1 on \2 left out/')
    printf '| [%s](#%s) | %s |\n' "$t" "$(printf '%s' "$t" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9_.-')" "$r"
done < "$summary"
cat "$body"
