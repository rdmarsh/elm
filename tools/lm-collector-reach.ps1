#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Can these collectors reach these devices? Test devices from the collectors that would
    monitor them, and save each collector's result as <hostname>.csv.

.DESCRIPTION
    Self-contained: uses ONLY the Logic.Monitor PowerShell module (one
    Connect-LMAccount connection). No elm, bash, jq, jinja2 or external template
    is required — device discovery, the protocol matrix, and the Groovy script
    are all built in PowerShell.

    -Group (or -Collector) is the existing setup: its devices and its collectors. At most
    one -With... or -To... option says what changes:

      -Group G                     Do G's collectors agree? Tests G's devices from G's
                                   collectors and lists every device and check where they differ.
      -Group G -WithCollector X    Can collector X join G? Tests G's devices from X too, and
                                   lists what X fails that a current collector passes.
      -Group G -ToGroup H          Can G's devices move to group H? Tests them from H's collectors.
      -Group G -WithDevice D       Can device D move into G? Tests D from G's collectors.

      -Collector X                 Do X's devices answer X? (several collectors: do they agree?)
      -Collector X -WithCollector Y  Can Y take over X's devices (a one-for-one replacement)?
      -Collector X -ToGroup H      Can X's devices (e.g. a collector being retired) go to H?
      -Collector X -WithDevice D   Can device D be pinned to collector X?

    -ToGroup and -WithDevice end with READY / PARTIAL / BLOCKED per device. Each also tests
    from the devices' current collectors, and says when a device is not reached from those
    either, so an already-unreachable device is not blamed on the move.

    Everything that names a collector, group or device takes a number as an id and text as
    a name (collectors also match an unambiguous part of their hostname).

    Workflow:
      1. Resolve the setup and what changes.
      2. Find the devices (preferredCollectorGroupId for -Group, preferredCollectorId for
         -Collector, or the -WithDevice list). hostStatus 'dead' is skipped unless
         -IncludeDead; 'dead-collector' is kept, since another collector may reach it.
      3. Choose each device's checks from its autoProperties (ping/snmp/wmi/ssh/http/https --
         see the printed legend for what these actually test), or test -Port instead.
      4. Generate a Groovy reachability script and submit it to every collector involved
         that is up.
      5. Wait, retrieve each result, and save <hostname>.csv in OutputDir.
      6. Compare the current collectors, then print the verdict.

    For one device from a few collectors, `lm-collector-debug.ps1 -Group ... -Command
    '!ping ...'` is quicker.

    Requires PowerShell 7.

.PARAMETER Group
    The existing setup: a collector group, by id or name. Its assigned devices are tested
    from its collectors (or, with -WithDevice, those devices are).

.PARAMETER Collector
    The existing setup as one or more collectors instead of a group: the devices currently
    on them, tested from them if they are up. Use it for a collector being retired, which
    need not be in a group and may be down. With -WithDevice, these are the collectors the
    devices would be pinned to.

.PARAMETER WithCollector
    One or more collectors that would join the setup, tested against its devices: "will
    this freshly built collector reach everything before I add it?" Each gets a verdict
    listing any device+check it fails but a current collector passes.

.PARAMETER ToGroup
    A group the setup's devices would move to; its collectors test them. Ends with READY /
    PARTIAL / BLOCKED per device.

.PARAMETER WithDevice
    One or more devices that would move into the setup, tested from its collectors. Ends
    with READY / PARTIAL / BLOCKED per device. Cannot be combined with -WithCollector or
    -ToGroup.

.PARAMETER Port
    Test these TCP ports, on every device, INSTEAD of the built-in checks (ping, snmp, and
    the ports discovery found). E.g. -Port 5985,5986 for WinRM.

.PARAMETER PassThru
    Also send one object per device, check and collector down the pipeline (Device,
    DeviceId, Address, Source, Check, Collector, Role, Result, Verdict), for Where-Object,
    Export-Csv and the like. The report still goes to the screen. Role is current (monitors
    the device today), joining (a -WithCollector) or destination (where the device would go);
    Verdict is set for -ToGroup and -WithDevice only.

.PARAMETER OutputDir
    Directory for the per-collector CSV files. Defaults to a per-run directory under
    the system temp dir, e.g. <temp>/lm-reach/<groupid>-<timestamp>.

.PARAMETER WaitSeconds
    Maximum seconds to poll for results before giving up. Polling saves each collector's
    result as soon as it is ready, so this is only a cap, not a fixed wait. By default it is
    worked out from the number of devices (each collector tests 20 at a time, up to about
    8 seconds each when nothing answers), and is at least 180.

.PARAMETER IncludeDead
    Also test devices with hostStatus 'dead' (skipped by default). They are down from
    their current collector, but may be reachable from another — testing reveals relocate
    candidates, or whether a move would fix them. Dead devices show 'dead' in the Status
    column so you can tell them apart.

.PARAMETER NoColor
    Disable ANSI colour in the comparison and verdict output.

.EXAMPLE
    ./lm-collector-reach.ps1
    List collector groups and exit.

.EXAMPLE
    ./lm-collector-reach.ps1 -Group "Acme Auto-Balance Group"
    Do the group's collectors all reach the group's devices?

.EXAMPLE
    ./lm-collector-reach.ps1 -Group 191 -OutputDir ./results

.EXAMPLE
    ./lm-collector-reach.ps1 -Group 191 -WithCollector newedge02,newedge03
    Would new collectors newedge02 and newedge03 (not yet in group 191) reach everything
    the group's existing collectors reach? Each gets its own verdict.

.EXAMPLE
    ./lm-collector-reach.ps1 -Group "Old Site" -ToGroup "New Site"
    Would every device assigned to "Old Site" be reachable from the collectors in "New Site"?

.EXAMPLE
    ./lm-collector-reach.ps1 -Group "Site A" -WithDevice server01,server02
    Would server01 and server02 be reachable from Site A's collectors if moved there?

.EXAMPLE
    ./lm-collector-reach.ps1 -Collector legacy01 -ToGroup "Consolidated Collectors"
    Would the devices currently on legacy01 be reachable from "Consolidated Collectors"?

.EXAMPLE
    ./lm-collector-reach.ps1 -Group "Site A" -Port 5985,5986 -PassThru | Where-Object Result -ne pass
    Test WinRM from every collector in Site A, and keep just the failures as objects.

.NOTES
    Prerequisite: Logic.Monitor module loaded and Connect-LMAccount already
    called for the target portal. There is no -profile flag — the portal is
    whatever you connected to. Collector Debug needs a Manage-level API token.

#>
[CmdletBinding()]
param(
    [string]$Group,                     # the setup: a group (id or name)...
    [string[]]$Collector,               # ...or collector(s)
    [string[]]$WithCollector,            # collector(s) that would join the setup
    [string]$ToGroup,                  # a group the setup's devices would move to
    [string[]]$WithDevice,               # device(s) that would move into the setup
    [ValidateRange(1, 65535)]
    [int[]]$Port,                       # test these TCP ports instead of the built-in checks
    [switch]$PassThru,                  # also emit one object per result to the pipeline

    [string]$OutputDir,                 # defaults to a per-run dir under the system temp
    [int]$WaitSeconds,                  # cap; default worked out from the device count
    [switch]$IncludeDead,               # also test hostStatus:dead devices (flagged in output)

    [switch]$NoColor                    # disable ANSI colour in the comparison/verdict output
)

$ErrorActionPreference = 'Stop'

# ── Preconditions ─────────────────────────────────────────────────────────────
# Precondition failures use a clean red one-liner + exit, not throw: a thrown error from a
# script file prints a "Line | NN | ..." caret block, which is noise for "you forgot to log in".
function Stop-WithMessage {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
    exit 1
}

if (-not (Get-Command Get-LMDevice -ErrorAction SilentlyContinue)) {
    Stop-WithMessage ("Logic.Monitor module not loaded. Establish an LM session first " +
                      "(Connect-LMAccount, or your own connection wrapper), then re-run.")
}

# The module can be loaded but with no active session. Get-LMAccountStatus returns a
# plain string ("Not currently logged into any LogicMonitor portals.") when logged out
# and a status object when connected. Check it here so the data cmdlets below don't spew
# a multi-line "ensure you are logged in" error mid-listing (and a misleading "0 of 0").
$lmStatus = Get-LMAccountStatus
if ($null -eq $lmStatus -or $lmStatus -is [string]) {
    Stop-WithMessage ("Not connected to a LogicMonitor portal. Run Connect-LMAccount " +
                      "(or your connection wrapper) first, then re-run.")
}

# ── Shared helpers: identical in lm-collector-debug.ps1 and lm-collector-reach.ps1 ──
# A collector's `status` is 1 for every registered collector, up or down; isDown is the
# real health flag (verified 2026-10: 27 of 37 sandbox collectors were down, all status 1).
function Test-CollectorUp([object]$Col) { -not $Col.isDown }

# Resolve one collector token: numeric -> id; otherwise exact hostname/description
# (case-insensitive), then an unambiguous substring, so a bare 'newedge03' still resolves
# from 'CORP\NEWEDGE03' or an FQDN. Returns the collector, or a string saying why not.
function Resolve-Collector {
    param([string]$Token, [object[]]$All)
    if ($Token -match '^\d+$') {
        $exact = @($All | Where-Object { $_.id -eq [int]$Token })
        if ($exact.Count -eq 1) { return $exact[0] }
        return "collector id $Token not found"
    }
    $exact = @($All | Where-Object { $_.hostname -eq $Token -or $_.description -eq $Token })
    if ($exact.Count -eq 1) { return $exact[0] }
    if ($exact.Count -gt 1) { return "'$Token' matched $($exact.Count) collectors exactly - use the numeric id" }
    $partial = @($All | Where-Object { $_.hostname -like "*$Token*" -or $_.description -like "*$Token*" })
    if ($partial.Count -eq 1) {
        Write-Host "Collector '$Token' resolved to '$($partial[0].hostname)' (id=$($partial[0].id)) by partial match."
        return $partial[0]
    }
    if ($partial.Count -gt 1) {
        $names = ($partial | ForEach-Object { "$($_.hostname) (id=$($_.id))" }) -join ', '
        return "'$Token' matched no collector exactly and $($partial.Count) partially ($names) - use the exact hostname or numeric id"
    }
    return "'$Token' not found - no collector hostname or description contains it"
}

# Resolve a collector group by numeric id or exact name (case-insensitive). Returns the
# group, or a string saying why not.
function Resolve-CollectorGroup {
    param([string]$Token, [object[]]$All)
    $g = if ($Token -match '^\d+$') {
        @($All | Where-Object { $_.id -eq [int]$Token })
    } else {
        @($All | Where-Object { $_.name -eq $Token })
    }
    if ($g.Count -eq 1) { return $g[0] }
    return "collector group '$Token' not found - run with no arguments to list the groups"
}

# Resolve one device token: numeric -> id; otherwise its display name, then its name (the
# address LM uses to reach it), both exact. Returns the device, or a string saying why not.
# Names go through -Filter rather than -Name/-DisplayName, whose presence varies across
# module versions and would raise a binding error -ErrorAction can't suppress.
function Resolve-Device {
    param([string]$Token)
    if ($Token -match '^\d+$') {
        $d = @(Get-LMDevice -Id ([int]$Token) -ErrorAction SilentlyContinue)
    } else {
        $d = @(Get-LMDevice -Filter "displayName -eq `"$Token`"" -ErrorAction SilentlyContinue)
        if ($d.Count -eq 0) { $d = @(Get-LMDevice -Filter "name -eq `"$Token`"" -ErrorAction SilentlyContinue) }
    }
    $d = @($d | Where-Object { $_ })
    if ($d.Count -eq 1) { return $d[0] }
    if ($d.Count -gt 1) { return "device '$Token' matched $($d.Count) devices - use its id" }
    return "device '$Token' not found"
}

# No target given: say how to call the script, list the collector groups, and stop.
function Show-Usage([string]$Usage) {
    Write-Host "Usage: $Usage"
    Write-Host ""
    # -BatchSize 1000 forces full pagination (older module versions can default to 50).
    $groups = @(Get-LMCollectorGroup -BatchSize 1000)
    Write-Host "Collector groups: $($groups.Count)"
    $groups | Select-Object id, name, numOfCollectors, autoBalance | Sort-Object id | Format-Table -AutoSize | Out-Host
    exit 0
}

# Get-LMCollectorDebugResult returns the command output TEXT directly (the module does
# `Return $Response.output`) - NOT an object with an .output property - and `output` stays
# empty until the command completes, so non-empty output means "done". Handle a plain
# string, an object that still carries .output, and string[], for robustness across
# module versions.
function Get-DebugText($result) {
    if ($result -is [string]) { return $result }
    if ($result -and $result.PSObject.Properties['output']) { return [string]$result.output }
    return ($result | Out-String)
}

# Collector Debug wraps every result in a 2-line envelope before the command's own output:
#     returns <n>
#     output:
#     <the command's stdout...>
# Strip it so callers get only the command's output. Anchored at the start and matched
# defensively, so a result in a different shape is left untouched. The completion check
# must run on the RAW text (the envelope is non-empty even when nothing was printed).
function Remove-DebugEnvelope([string]$Text) {
    return ($Text -replace '^\s*returns\s+-?\d+\r?\noutput:\r?\n?', '')
}

# ── Nothing to test — list groups and exit ────────────────────────────────────
if (-not $Group -and -not $Collector) {
    if ($WithCollector -or $ToGroup -or $WithDevice) {
        Write-Warning "-WithCollector, -ToGroup and -WithDevice change a setup given by -Group or -Collector; listing groups."
    }
    Show-Usage ("./lm-collector-reach.ps1 -Group ID|NAME | -Collector ID|NAME[,...] " +
                "[-WithCollector ID|NAME[,...] | -ToGroup ID|NAME | -WithDevice ID|NAME[,...]] " +
                "[-Port N[,...]] [-PassThru] [-OutputDir DIR] [-WaitSeconds N] [-IncludeDead]")
}
if ($WithDevice -and ($WithCollector -or $ToGroup)) {
    Stop-WithMessage "-WithDevice tests devices moving into the setup; -WithCollector and -ToGroup test the setup's own devices. Pass one."
}

# -BatchSize 1000 forces full pagination — missing collectors here would both drop
# collectors from the run and leave gaps in the collector-host (collectorDeviceId) set.
$allCollectors = @(Get-LMCollector -BatchSize 1000)
$allGroups     = @(Get-LMCollectorGroup -BatchSize 1000)
$problems      = [System.Collections.Generic.List[string]]::new()

# Where the devices come from: a label, and either a device filter or a resolved device.
$sources    = [System.Collections.Generic.List[object]]::new()
# The collectors that test, each with its role:
#   current     - monitors the devices today (the baseline)
#   joining     - a -WithCollector joining the setup
#   destination - would monitor the devices after the move (-ToGroup's, or with -WithDevice the setup's)
$testers    = [System.Collections.Generic.List[object]]::new()
$testerIds  = [System.Collections.Generic.HashSet[int]]::new()
function Add-Tester([object]$Col, [string]$Role, [string]$Why) {
    if (-not (Test-CollectorUp $Col)) {
        Write-Warning "Collector '$($Col.hostname)' (id=$($Col.id)) is down - not testing from it ($Why)."
        return
    }
    if (-not $testerIds.Add([int]$Col.id)) { return }
    $testers.Add([PSCustomObject]@{ Collector = $Col; Role = $Role })
}

# The setup's collectors test as 'current', or as 'destination' when -WithDevice brings devices in.
$setupRole = if ($WithDevice) { 'destination' } else { 'current' }
$setupName = $null

# $grp, not $group: PowerShell names are case-insensitive, so $group IS the [string]$Group
# parameter and assigning the group object to it would turn the object into a string.
$grp = $null
if ($Group) {
    $grp = Resolve-CollectorGroup -Token $Group -All $allGroups
    if ($grp -is [string]) {
        $problems.Add($grp); $grp = $null
    } else {
        $setupName = $grp.name
        if (-not $WithDevice) {
            $sources.Add([PSCustomObject]@{ Label = $grp.name; Desc = "group $($grp.name) (id=$($grp.id))"; Filter = "preferredCollectorGroupId -eq $($grp.id)"; Device = $null })
        }
        foreach ($c in @($allCollectors | Where-Object { $_.collectorGroupId -eq $grp.id } | Sort-Object hostname)) {
            Add-Tester $c $setupRole "in group '$($grp.name)'"
        }
    }
}
foreach ($t in $Collector) {
    $m = Resolve-Collector -Token $t -All $allCollectors
    if ($m -is [string]) { $problems.Add($m); continue }
    $setupName = if ($setupName) { "$setupName, $($m.hostname)" } else { $m.hostname }
    if (-not $WithDevice) {
        $sources.Add([PSCustomObject]@{ Label = $m.hostname; Desc = "collector $($m.hostname) (id=$($m.id))"; Filter = "preferredCollectorId -eq $($m.id)"; Device = $null })
    }
    Add-Tester $m $setupRole "named with -Collector"
}
foreach ($t in $WithCollector) {
    $m = Resolve-Collector -Token $t -All $allCollectors
    if ($m -is [string]) { $problems.Add($m); continue }
    if ($testerIds.Contains([int]$m.id)) { $problems.Add("'$($m.hostname)' (id=$($m.id)) is already one of the current collectors, so it cannot also be the one joining"); continue }
    if (-not (Test-CollectorUp $m)) { $problems.Add("joining collector '$($m.hostname)' (id=$($m.id)) is down - is it running and connected?"); continue }
    Add-Tester $m 'joining' 'joining collector'
}
$tgrp = $null
if ($ToGroup) {
    $tgrp = Resolve-CollectorGroup -Token $ToGroup -All $allGroups
    if ($tgrp -is [string]) {
        $problems.Add($tgrp); $tgrp = $null
    } elseif ($grp -and [int]$tgrp.id -eq [int]$grp.id) {
        $problems.Add("-ToGroup and -Group are both '$($grp.name)' - the devices are already there"); $tgrp = $null
    } else {
        $before = $testers.Count
        foreach ($c in @($allCollectors | Where-Object { $_.collectorGroupId -eq $tgrp.id } | Sort-Object hostname)) {
            Add-Tester $c 'destination' "in destination group '$($tgrp.name)'"
        }
        if ($testers.Count -eq $before) { $problems.Add("destination group '$($tgrp.name)' has no collectors up") }
    }
}
# -WithDevice: each device is its own source, and the collector it is on today is the baseline.
foreach ($t in $WithDevice) {
    $d = Resolve-Device $t
    if ($d -is [string]) { $problems.Add($d); continue }
    $now = @($allCollectors | Where-Object { $_.id -eq [int]$d.preferredCollectorId })
    # Already there: a device assigned to the setup group, or on one of the setup's collectors.
    $setupIds = @($testers | Where-Object Role -eq 'destination' | ForEach-Object { [int]$_.Collector.id })
    if (($grp -and [int]$d.preferredCollectorGroupId -eq [int]$grp.id) -or ($now.Count -and $setupIds -contains [int]$now[0].id)) {
        Write-Warning "Device '$($d.displayName)' (id=$($d.id)) is already monitored by $setupName - nothing to move; skipping it."
        continue
    }
    $nowName = if ($now.Count) { $now[0].hostname } else { 'no collector' }
    $sources.Add([PSCustomObject]@{ Label = $nowName; Desc = "device $($d.displayName) (id=$($d.id)), now on $nowName"; Filter = $null; Device = $d })
    if ($now.Count) { Add-Tester $now[0] 'current' "where '$($d.displayName)' is today" }
}
if ($WithDevice -and $sources.Count -eq 0 -and $problems.Count -eq 0) {
    $problems.Add("every -WithDevice device is already monitored by $setupName")
}
if ($WithDevice -and @($testers | Where-Object Role -eq 'destination').Count -eq 0 -and $problems.Count -eq 0) {
    $problems.Add("none of the setup's collectors is up, so there is nothing to test the -WithDevice devices from")
}
if ($problems.Count -gt 0) {
    $nl = [Environment]::NewLine
    Stop-WithMessage ("Cannot run; fix these first:" + $nl + (($problems | ForEach-Object { "  - $_" }) -join $nl))
}
if ($testers.Count -eq 0) { Stop-WithMessage "No collector to test from is up." }

foreach ($src in $sources) { Write-Host "Devices of:  $($src.Desc)" }
foreach ($role in 'current', 'joining', 'destination') {
    $label = @{ current = 'Current:    '; joining = 'Joining:    '; destination = 'Destination:' }[$role]
    $cs = @($testers | Where-Object Role -eq $role)
    if ($cs.Count) { Write-Host "$label $(($cs | ForEach-Object { $_.Collector.hostname }) -join ', ')" }
}
$current = @($testers | Where-Object Role -eq 'current')
if ($current.Count -eq 0) {
    Write-Host "Note: none of the current collectors is up, so there is no baseline: the verdicts cannot say whether a failure is new."
}

# A device that hosts a collector is linked by that collector's collectorDeviceId.
# Such hosts are monitored only from themselves and must not be cross-tested. Collect
# their device ids across ALL collectors (the host may belong to a collector elsewhere).
$collectorDeviceIds = [System.Collections.Generic.HashSet[int]]::new()
foreach ($c in $allCollectors) {
    if ($c.collectorDeviceId) { [void]$collectorDeviceIds.Add([int]$c.collectorDeviceId) }
}

# ── Discover the devices at each source ───────────────────────────────────────
# Group membership is preferredCollectorGroupId (what the device is assigned to);
# autoBalancedCollectorGroupId only reflects devices LM has actively placed and can be
# empty even for an autoBalance group with assigned devices. One query per source, unioned
# by id with the first source winning, so each device is tagged with where it came from.
$deviceSourceMap = @{}   # device id (string) -> source label
$allDevices      = [System.Collections.Generic.List[object]]::new()
$seenIds         = [System.Collections.Generic.HashSet[int]]::new()
foreach ($src in $sources) {
    $devs = if ($src.Device) { @($src.Device) } else { @(Get-LMDevice -Filter $src.Filter) }
    if ($sources.Count -gt 1) { Write-Host "  $($src.Desc): $($devs.Count) device(s)" }
    foreach ($d in $devs) {
        if ($seenIds.Add([int]$d.id)) {
            $allDevices.Add($d)
            $deviceSourceMap[[string]$d.id] = $src.Label
        }
    }
}
$collectorHosts = @($allDevices | Where-Object { $collectorDeviceIds.Contains([int]$_.id) })
$nonHosts       = @($allDevices | Where-Object { -not $collectorDeviceIds.Contains([int]$_.id) })
$dead           = @($nonHosts | Where-Object { $_.hostStatus -eq 'dead' })
$devices        = if ($IncludeDead) { $nonHosts } else { @($nonHosts | Where-Object { $_.hostStatus -ne 'dead' }) }

$skips = @()
if ($dead.Count -gt 0 -and -not $IncludeDead) { $skips += "$($dead.Count) dead" }
if ($collectorHosts.Count -gt 0)              { $skips += "$($collectorHosts.Count) collector host(s)" }
$msg = "Devices found: $($allDevices.Count)"
if ($skips) {
    $msg += " (skipped: " + ($skips -join ', ') + "; $($devices.Count) to test)"
} elseif ($IncludeDead -and $dead.Count -gt 0) {
    $msg += " ($($devices.Count) to test, incl. $($dead.Count) dead)"
} else {
    $msg += " ($($devices.Count) to test)"
}
Write-Host $msg

if ($collectorHosts.Count -gt 0) {
    Write-Host ""
    if ($grp -and $grp.autoBalance) {
        Write-Warning "$($collectorHosts.Count) collector host(s) are in auto-balance group '$($grp.name)' (id=$($grp.id))."
        Write-Warning "Collector hosts should be pinned to their own collector, not auto-balanced. Skipped:"
    } else {
        Write-Host "Skipped (collector host - monitored from itself, not cross-tested):"
    }
    foreach ($ch in ($collectorHosts | Sort-Object displayName)) {
        Write-Host "  - $($ch.displayName) ($($ch.name)) [id=$($ch.id)]"
    }
}

if ($dead.Count -gt 0) {
    Write-Host ""
    if ($IncludeDead) {
        Write-Host "Testing anyway (hostStatus 'dead' - down from its CURRENT collector; -IncludeDead set):"
    } else {
        Write-Host "Skipped (hostStatus 'dead' - down from its CURRENT collector; pass -IncludeDead to test):"
    }
    foreach ($dh in ($dead | Sort-Object displayName)) {
        Write-Host "  - $($dh.displayName) ($($dh.name)) [id=$($dh.id)] currentCollectorId=$($dh.preferredCollectorId)"
    }
}

if ($devices.Count -eq 0) { Stop-WithMessage "No testable devices (none assigned, all dead, or all collector hosts)." }

# ── Protocol detection from autoProperties (LM Active Discovery) ──────────────
# wmi/ssh/http/https are bare TCP connect checks -- no protocol handshake or
# credentials -- so a pass only means the port accepted a connection, not that the
# named protocol/service actually works (printed as a legend at run time too).
#   auto.snmp.operational == "true"                    -> snmp (real SNMP GetRequest)
#   135 in tcp ports, or auto.wmi.operational == "true" -> wmi  (really: TCP 135 open)
#   22  in auto.network.listening_tcp_ports            -> ssh  (really: TCP 22 open)
#   80  in tcp ports, or HTTP- (not HTTPS) datasource  -> http (really: TCP 80 open)
#   443 in tcp ports, or HTTPS/SSL_ datasource         -> https (really: TCP 443 open)
function Get-DeviceProtocols {
    param([object]$Device)

    # -Port replaces the built-in checks: just those TCP ports, on every device.
    if ($Port) { return [System.Collections.Generic.List[string]]@($Port | ForEach-Object { "tcp-$_" }) }

    $ap = @{}
    if ($Device.autoProperties) {
        foreach ($p in $Device.autoProperties) { $ap[$p.name] = $p.value }
    }
    $tcpRaw = [string]$ap['auto.network.listening_tcp_ports']
    $dsRaw  = [string]$ap['auto.activedatasources']
    $snmp   = [string]$ap['auto.snmp.operational']
    $wmi    = [string]$ap['auto.wmi.operational']
    $tcp    = if ($tcpRaw) { $tcpRaw -split ',' } else { @() }
    $ds     = if ($dsRaw)  { $dsRaw  -split ',' } else { @() }

    $protocols = [System.Collections.Generic.List[string]]::new()
    $protocols.Add('ping')
    if ($snmp -eq 'true') { $protocols.Add('snmp') }
    # auto.network.listening_tcp_ports showing 135 open and auto.wmi.operational are two
    # independent discovery signals that trigger the exact same tcpOk(ip, 135, ...) test
    # (see the Groovy below) -- squashed into one entry so a device with both flags set
    # doesn't get two protocol columns that always agree.
    if (($tcp -contains '135') -or ($wmi -eq 'true')) { $protocols.Add('tcp-135') }
    if ($tcp -contains '22')  { $protocols.Add('tcp-22') }

    $http  = ($tcp -contains '80')  -or @($ds | Where-Object { $_ -like 'HTTP*' -and $_ -notlike 'HTTPS*' }).Count
    $https = ($tcp -contains '443') -or @($ds | Where-Object { $_ -like 'HTTPS*' -or $_ -like 'SSL_*' }).Count
    if ($http)  { $protocols.Add('tcp-80') }
    if ($https) { $protocols.Add('tcp-443') }

    return $protocols
}

$deviceObjs = foreach ($dev in $devices) {
    [PSCustomObject]@{
        id          = $dev.id
        displayName = $dev.displayName
        ip          = $dev.name          # LM 'name' = the address used to reach the device
        hostStatus  = $dev.hostStatus
        protocols   = (Get-DeviceProtocols $dev)
        source      = $deviceSourceMap[[string]$dev.id]
    }
}
# Sorted once here (by displayName) so every downstream consumer -- the summary table,
# the Groovy device list, and the CSV rows the collectors return -- is alphabetical
# instead of "whatever order the LM API happened to return."
$deviceObjs = @($deviceObjs | Sort-Object displayName)

# ── Summary table ─────────────────────────────────────────────────────────────
if ($Port) { Write-Host "Testing only TCP port(s) $($Port -join ', ') (-Port replaces the built-in checks)." }
Write-Host "Protocol legend: wmi=135, ssh=22, http=80, https=443, winrm=5985/5986 -- these are bare TCP"
Write-Host "connect checks, NOT credential/protocol verification. A pass only means the"
Write-Host "port accepted a connection, not that the named protocol/service works."
Write-Host ""
# Purpose names for the ports people recognise; any other port shows as tcp-<n>.
$protoLabel = @{ 'tcp-135' = 'wmi'; 'tcp-22' = 'ssh'; 'tcp-80' = 'http'; 'tcp-443' = 'https'; 'tcp-5985' = 'winrm'; 'tcp-5986' = 'winrm-https' }
$cols = @(@{n='Device';e={$_.displayName}}, @{n='IP/Hostname';e={$_.ip}}, @{n='Status';e={$_.hostStatus}})
if ($sources.Count -gt 1) { $cols += @{n='Source';e={$_.source}} }
$cols += @{n='Protocols';e={ ($_.protocols | ForEach-Object { $protoLabel[$_] ?? $_ }) -join ', ' }}
$deviceObjs | Select-Object $cols | Format-Table -AutoSize | Out-Host

# ── Build the device list as a Groovy literal ─────────────────────────────────
function ConvertTo-GroovyString {
    param([string]$Value)
    '"' + (($Value -replace '\\', '\\') -replace '"', '\"') + '"'
}
function ConvertTo-DeviceGroovy {
    param([object]$D)
    $protos = '[' + (($D.protocols | ForEach-Object { ConvertTo-GroovyString $_ }) -join ', ') + ']'
    "[id: $($D.id), displayName: $(ConvertTo-GroovyString $D.displayName), " +
    "ip: $(ConvertTo-GroovyString $D.ip), hostStatus: $(ConvertTo-GroovyString $D.hostStatus), " +
    "protocols: $protos]"
}
$devicesGroovy = "[`n" +
    (($deviceObjs | ForEach-Object { '    ' + (ConvertTo-DeviceGroovy $_) }) -join ",`n") +
    "`n]"

# ── Groovy reachability script (single-quoted here-string: NOT expanded by PS) ─
# __DEVICES__ is substituted below. Do not interpolate PS variables in here.
$groovyTemplate = @'
// lm-collector-reach.groovy (built by lm-collector-reach.ps1)
//
// INTERPRETING RESULTS:
//   pass    - connection succeeded
//   FAIL    - connection refused or timed out
//   TIMEOUT - SNMP: port may be reachable but agent dropped the probe
//   (blank) - protocol not expected for this device (skipped)

import java.util.concurrent.*

def PING_TIMEOUT_MS = 1500
def TCP_TIMEOUT_MS  = 1000
def SNMP_TIMEOUT_MS = 2000

def devices = __DEVICES__

if (!devices) {
    println "No devices to test."
    return
}

def pingOk(ip, timeoutMs) {
    try {
        return java.net.InetAddress.getByName(ip).isReachable(timeoutMs)
    } catch (e) { return false }
}

def tcpOk(ip, port, timeoutMs) {
    try {
        def s = new java.net.Socket()
        s.connect(new java.net.InetSocketAddress(ip, port), timeoutMs)
        s.close()
        return true
    } catch (e) { return false }
}

// SNMP reachability probe: minimal SNMPv2c GetRequest (sysDescr, community "public")
// via raw UDP. Any response = port open. Timeout = unreachable, firewall dropping
// UDP 161, or agent silently dropping unknown communities. TIMEOUT != unreachable.
def snmpOk(ip, timeoutMs) {
    def pkt = "302902010104067075626c6963a01c020400000001020100020100300e300c06082b060102010101000500".decodeHex()
    try {
        def sock = new java.net.DatagramSocket()
        sock.setSoTimeout(timeoutMs)
        def addr = java.net.InetAddress.getByName(ip)
        sock.send(new java.net.DatagramPacket(pkt, pkt.length, addr, 161))
        sock.receive(new java.net.DatagramPacket(new byte[512], 512))
        sock.close()
        return true
    } catch (java.net.SocketTimeoutException e) {
        return false
    } catch (e) {
        return false
    }
}

def runTest(proto, ip, pingMs, tcpMs, snmpMs) {
    switch (proto) {
        case "ping":    return pingOk(ip, pingMs)     ? "pass" : "FAIL"
        case "snmp":    return snmpOk(ip, snmpMs)     ? "pass" : "TIMEOUT"
        default:
            // "tcp-<port>": a bare TCP connect to that port
            if (proto.startsWith("tcp-")) return tcpOk(ip, proto.substring(4) as int, tcpMs) ? "pass" : "FAIL"
            return "?"
    }
}

def protoOrder = ["ping", "snmp", "tcp-135", "tcp-22", "tcp-80", "tcp-443"]
def protoLabel = ["tcp-135": "wmi", "tcp-22": "ssh", "tcp-80": "http", "tcp-443": "https", "tcp-5985": "winrm", "tcp-5986": "winrm-https"]
def allProtos = devices.collectMany { it.protocols }.unique()
    .sort { a, b ->
        def ai = protoOrder.indexOf(a); def bi = protoOrder.indexOf(b)
        (ai < 0 ? 999 : ai) <=> (bi < 0 ? 999 : bi)
    }
def collectorHost = java.net.InetAddress.getLocalHost().getHostName()
println "Testing ${devices.size()} devices from ${collectorHost} (parallel)..."
println "Protocol legend: wmi=135, ssh=22, http=80, https=443, winrm=5985/5986 -- these are bare TCP connect"
println "checks, NOT credential/protocol verification. A pass only means the port accepted"
println "a connection, not that the named protocol/service works."

def pool    = Executors.newFixedThreadPool(Math.min(devices.size(), 20))
def futures = devices.collect { d ->
    pool.submit({
        def res = [:]
        allProtos.each { proto ->
            res[proto] = d.protocols.contains(proto)
                ? runTest(proto, d.ip, PING_TIMEOUT_MS, TCP_TIMEOUT_MS, SNMP_TIMEOUT_MS)
                : "-"
        }
        // Rows are joined with commas unquoted, so a comma in a name would shift the columns.
        return [id: d.id, name: d.displayName.replace(',', ' '), ip: d.ip.replace(',', ' '), res: res]
    } as Callable)
}
pool.shutdown()
pool.awaitTermination(__AWAIT__, TimeUnit.SECONDS)

def header = ["id", "device", "hostname"] + allProtos.collect { protoLabel[it] ?: it }
println header.join(",")

def failures = []
def timeouts = []
futures.eachWithIndex { f, i ->
    def r = f.get()
    def row = [r.id, r.name, r.ip] + allProtos.collect { proto ->
        def result = r.res[proto]
        if (result == "FAIL")    failures << "${r.name}  ${protoLabel[proto] ?: proto}"
        if (result == "TIMEOUT") timeouts << "${r.name}  ${protoLabel[proto] ?: proto}"
        result == "-" ? "" : result
    }
    println row.join(",")
}

println ""
// TIMEOUT is a distinct result from FAIL (see runTest()/snmpOk()), so a device with
// ONLY snmp timeouts never touches `failures` -- gate this whole block on either list,
// not just failures, or the SNMPv3 hint below silently never prints for exactly the
// devices that need it most.
if (failures || timeouts) {
    if (failures) {
        println "FAILURES — this collector cannot reach these:"
        failures.each { println "  - $it" }
        println ""
    }
    if (timeouts) {
        println "TIMEOUTS (${timeouts.size()}) — SNMP got no response:"
        timeouts.each { println "  - $it" }
        println ""
    }
    println "snmp TIMEOUT may mean wrong community, OR an SNMPv3-only device -- this probe only speaks SNMPv2c/\"public\", so EVERY v3-only device will show TIMEOUT regardless of reachability. If v3 is used anywhere in this portal, that is likely the biggest source of TIMEOUTs here, not a real network issue. Verify a specific device with the collector debug console: !snmpdiagnose version=v3 <host> (see collector-debug-notes.md)."
    println "wmi pass only confirms TCP 135 (RPC endpoint mapper) is open, not that WMI/credentials work; WMI also uses dynamic high ports (49152-65535)."
} else {
    println "All checks passed. This collector can reach all tested devices."
}
'@

# Each collector tests 20 devices at a time. When nothing answers, a device takes 1.5 s
# for ping, 2 s for snmp and 1 s per port; batches of 20 run back to back. The Groovy
# waits for the pool that long (at least 120 s), and polling waits a minute more.
$slowest = ($deviceObjs | ForEach-Object {
    ($_.protocols | ForEach-Object { @{ ping = 1.5; snmp = 2 }[$_] ?? 1 } | Measure-Object -Sum).Sum
} | Measure-Object -Maximum).Maximum
$awaitSeconds = [Math]::Max(120, [int][Math]::Ceiling([Math]::Ceiling($deviceObjs.Count / 20) * $slowest))
if (-not $WaitSeconds) { $WaitSeconds = [Math]::Max(180, $awaitSeconds + 60) }
$groovyScript = $groovyTemplate.Replace('__DEVICES__', $devicesGroovy).Replace('__AWAIT__', [string]$awaitSeconds)

# ── Output directory ──────────────────────────────────────────────────────────
if (-not $OutputDir) {
    $OutputDir = Join-Path ([System.IO.Path]::GetTempPath()) "lm-reach/$((($sources | ForEach-Object Label) -join '+') -replace '[\\/:*?"<>| ]', '_')-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
$null = New-Item -ItemType Directory -Force -Path $OutputDir
$OutputDir = (Resolve-Path $OutputDir).Path   # absolute, so the run output can show clean filenames
Write-Host "Output dir:  $OutputDir"

# ── Submit to all collectors, wait once, then retrieve ────────────────────────
# -IncludeResult times out before the Groovy pool.awaitTermination (120s), so we
# use the submit / wait / retrieve pattern instead.
Write-Host "Submitting to $($testers.Count) collector(s)..."
$jobs = foreach ($t in $testers) {
    $col = $t.Collector
    try {
        $r = Invoke-LMCollectorDebugCommand -Id $col.id -GroovyCommand $groovyScript -ErrorAction Stop
        $tag = @{ current = ''; joining = ' [joining]'; destination = ' [destination]' }[$t.Role]
        Write-Host "  -> $($col.hostname) (id=$($col.id))$tag"
        [PSCustomObject]@{
            Hostname    = $col.hostname
            Id          = $col.id
            SessionId   = $r.SessionId
            Role        = $t.Role
        }
    } catch {
        Write-Warning "  Submit failed for $($col.hostname) (id=$($col.id)): $($_.Exception.Message)"
    }
}
$jobs = @($jobs)
if ($jobs.Count -eq 0) {
    Stop-WithMessage ("No debug sessions were created. The most common cause is insufficient LM permissions: " +
           "running Collector Debug commands requires an account/API token whose role grants 'Manage' " +
           "rights on collectors (remote debug). Verify the credentials used to connect the LM session.")
}

# Parse the protocol matrix out of a saved collector result. The Groovy prints
# preamble ("Testing N devices..."), a CSV header (id,device,hostname,<protocols>),
# data rows, then a blank line and a FAILURES / all-passed footer. Extract just the
# header + data rows and hand them to ConvertFrom-Csv. (Fields are joined unquoted by
# the Groovy, so a comma inside a displayName/hostname would misalign columns — none
# do today, but that is the assumption.)
function ConvertFrom-ReachabilityText {
    param([string]$Text)
    $lines  = $Text -split "\r?\n"
    $header = $lines | Select-String -SimpleMatch 'id,device,hostname' | Select-Object -First 1
    if (-not $header) { return @() }
    $csv = [System.Collections.Generic.List[string]]::new()
    for ($i = $header.LineNumber - 1; $i -lt $lines.Count; $i++) {
        if ([string]::IsNullOrWhiteSpace($lines[$i])) { break }   # blank line ends the table
        $csv.Add($lines[$i])
    }
    if ($csv.Count -lt 2) { return @() }                          # header only, no data rows
    return $csv -join "`n" | ConvertFrom-Csv
}

# Poll and save each collector's result as soon as it is ready, instead of a fixed sleep.
Write-Host "Polling for results (up to ${WaitSeconds}s)..."
$pending  = [System.Collections.Generic.List[object]]::new()
$jobs | ForEach-Object { $pending.Add($_) }
$deadline = (Get-Date).AddSeconds($WaitSeconds)

# Successfully retrieved results, in completion order, for the cross-collector comparison.
$results = [System.Collections.Generic.List[object]]::new()

while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    foreach ($job in @($pending)) {
        $raw = Get-DebugText (Get-LMCollectorDebugResult -SessionId $job.SessionId -Id $job.Id)
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $text     = Remove-DebugEnvelope $raw
            $safeName = $job.Hostname -replace '[\\/:*?"<>|]', '_'
            $outFile  = Join-Path $OutputDir "${safeName}.csv"
            $text | Set-Content $outFile
            Write-Host "  saved $(Split-Path $outFile -Leaf)  ($($job.Hostname))"
            $results.Add([PSCustomObject]@{
                Hostname    = $job.Hostname
                OutFile     = $outFile
                Role        = $job.Role
                Rows        = @(ConvertFrom-ReachabilityText $text)
            })
            [void]$pending.Remove($job)
        }
    }
}

foreach ($job in $pending) {
    Write-Warning "  No output for $($job.Hostname) (session $($job.SessionId)) - timed out after ${WaitSeconds}s"
}

# ── Colour helper: green pass / red FAIL / yellow TIMEOUT ─────────────────────
# Honour -NoColor and the NO_COLOR convention, and skip colour when stdout is
# redirected. Colour is applied to the value token only, so it never shifts the
# column alignment computed from the plain text.
$script:useColor = -not $NoColor -and [string]::IsNullOrEmpty($env:NO_COLOR) -and -not [Console]::IsOutputRedirected
function Format-Cell {
    param([string]$Text, [string]$Value)
    if (-not $script:useColor) { return $Text }
    $esc = [char]27
    switch ($Value) {
        'pass'    { "$esc[32m$Text$esc[0m" }   # green
        'FAIL'    { "$esc[31m$Text$esc[0m" }   # red
        'TIMEOUT' { "$esc[33m$Text$esc[0m" }   # yellow
        default   { $Text }
    }
}

# A "hostname=value" cell, colour-coded by Format-Cell and padded to a fixed value
# width (8 = length of "(absent)", the longest value that appears: pass/FAIL/
# TIMEOUT/(absent)/-) so cells stay column-aligned across rows regardless of which
# value lands in which row -- a plain join would ragged-edge as soon as one row
# says TIMEOUT/(absent) and the next says pass.
function Format-CollectorCell {
    param([string]$Hostname, [string]$Value)
    Format-Cell "$Hostname=$($Value.PadRight(8))" $Value
}

$curResults = @($results | Where-Object Role -eq 'current' | Sort-Object Hostname)

# ── Comparison: do the current collectors agree? ──────────────────────────────
# Not a textual file diff. For every device+protocol, gather the result from each
# current collector that returned and flag the row when they disagree (e.g. one
# 'pass', another 'FAIL'). Works for any collector count - the odd one out of N is
# visible in the per-protocol line, not just an A-vs-B comparison. Joining collectors
# and moves get their own verdicts below.
# With -WithDevice the current collectors are each device's own, so comparing them with
# one another means nothing; the move verdict uses each as its device's baseline instead.
if ($curResults.Count -ge 2 -and -not $WithDevice) {
    Write-Host ""
    Write-Host "-- Comparison: do the current collectors agree? --"

    # Sorted by hostname: results arrive in completion order, so without this the
    # columns would shuffle run-to-run.
    $ordered = $curResults

    # Protocol columns = CSV headers minus the identity columns, in CSV order.
    $idCols    = 'id', 'device', 'hostname'
    $protoCols = @()
    foreach ($r in $ordered) {
        if ($r.Rows.Count -gt 0) {
            $protoCols = @($r.Rows[0].PSObject.Properties.Name | Where-Object { $_ -notin $idCols })
            break
        }
    }

    # Index each collector's rows by device id, and collect device ids in first-seen order.
    $byCollector = @{}
    $allIds      = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $ordered) {
        $map = @{}
        foreach ($row in $r.Rows) {
            $key = [string]$row.id
            $map[$key] = $row
            if (-not $allIds.Contains($key)) { $allIds.Add($key) }
        }
        $byCollector[$r.Hostname] = $map
    }

    # Resolve a label per id, then sort by label so the printed order is alphabetical by
    # device name instead of "whichever collector happened to report it first."
    $idsByLabel = foreach ($id in $allIds) {
        $label = $id
        foreach ($r in $ordered) {
            if ($byCollector[$r.Hostname].ContainsKey($id)) { $label = $byCollector[$r.Hostname][$id].device; break }
        }
        [PSCustomObject]@{ Id = $id; Label = $label }
    }
    $idsByLabel = @($idsByLabel | Sort-Object Label)

    $disagree = 0
    $agree    = 0
    foreach ($entry in $idsByLabel) {
        $id    = $entry.Id
        $label = $entry.Label

        $diffs = [System.Collections.Generic.List[string]]::new()
        foreach ($p in $protoCols) {
            $cells = foreach ($r in $ordered) {
                $row = $byCollector[$r.Hostname][$id]
                $v   = if ($row) { [string]$row.$p } else { '(absent)' }   # collector never reported this device
                if ([string]::IsNullOrEmpty($v)) { $v = '-' }              # protocol not tested for this device
                [PSCustomObject]@{ Collector = $r.Hostname; Value = $v }
            }
            $distinct = @($cells.Value | Select-Object -Unique)
            if ($distinct.Count -gt 1) {
                $detail = ($cells | ForEach-Object { Format-CollectorCell $_.Collector $_.Value }) -join '  '
                $diffs.Add(("    {0,-10} {1}" -f $p, $detail))
            }
        }

        if ($diffs.Count -gt 0) {
            $disagree++
            Write-Host ""
            Write-Host "  $label  [id=$id]"
            $diffs | ForEach-Object { Write-Host $_ }
        } else {
            $agree++
        }
    }

    Write-Host ""
    if ($disagree -eq 0) {
        Write-Host "All $agree device(s) agree across all $($ordered.Count) current collectors - no reachability gaps."
    } else {
        Write-Host "$disagree device(s) differ between the current collectors; $agree agree."
        Write-Host "Under auto-balance, which collector a device lands on decides whether it works."
    }
}

# Printed once when ping is the only check a device fails: ICMP is often blocked on the path
# (cloud networks such as Azure block it outbound by default) even where TCP gets through.
function Write-PingHint {
    Write-Host ""
    Write-Host "ping FAIL where the TCP checks pass usually means ICMP is blocked on the path (cloud"
    Write-Host "networks such as Azure block it by default), not that the device is unreachable. Ping"
    Write-Host "still matters if LM monitors the device with Ping, so check before dismissing it."
}

# Printed once after a verdict when any snmp result was a TIMEOUT.
function Write-SnmpV3Hint {
    Write-Host ""
    Write-Host "snmp TIMEOUT above may mean wrong community, OR an SNMPv3-only device -- this probe only"
    Write-Host "speaks SNMPv2c/`"public`", so EVERY v3-only device shows TIMEOUT regardless of reachability."
    Write-Host "If v3 is used anywhere in this portal, that is likely the biggest source of TIMEOUTs here,"
    Write-Host "not a real network issue. Verify a specific device with the collector debug console:"
    Write-Host "  !snmpdiagnose version=v3 <host>   (see collector-debug-notes.md)"
}

# ── What no current collector reaches ─────────────────────────────────────────
# The comparison above lists only disagreements, so a check that fails from EVERY current
# collector never shows there - and with one current collector there is nothing to compare
# at all. List those checks here. Not for -ToGroup / -WithDevice: their verdict marks them
# ("not reached from its current collectors either").
if ($curResults.Count -gt 0 -and -not $ToGroup -and -not $WithDevice) {
    $idCols = 'id', 'device', 'hostname'
    $curById = @{}
    foreach ($r in $curResults) {
        $m = @{}; foreach ($row in $r.Rows) { $m[[string]$row.id] = $row }; $curById[$r.Hostname] = $m
    }
    $ids = @($curResults.Rows | ForEach-Object { [string]$_.id } | Select-Object -Unique)
    $nobody = foreach ($id in $ids) {
        $any = @($curResults | ForEach-Object { $curById[$_.Hostname][$id] } | Where-Object { $_ })[0]
        foreach ($p in @($any.PSObject.Properties.Name | Where-Object { $_ -notin $idCols })) {
            # @(...): one collector would otherwise give a bare string, and $vals[0] its first letter.
            $vals = @(foreach ($r in $curResults) {
                $row = $curById[$r.Hostname][$id]
                if ($row) { [string]$row.$p } else { '(absent)' }
            })
            if (@($vals | Where-Object { $_ }).Count -eq 0) { continue }   # check not run for this device
            if ($vals -notcontains 'pass') {
                [PSCustomObject]@{ Device = $any.device; Id = $id; Check = $p; Vals = $vals }
            }
        }
    }
    $nobody = @($nobody | Sort-Object Device, Check)
    $who = if ($curResults.Count -eq 1) { $curResults[0].Hostname } else { 'any current collector' }
    Write-Host ""
    if ($nobody.Count -eq 0) {
        Write-Host "-- Every check passed from $(if ($curResults.Count -eq 1) { $who } else { 'at least one current collector' }). --"
    } else {
        Write-Host "-- Not reached from ${who}: $($nobody.Count) check(s) --"
        $wDev = ($nobody | ForEach-Object { "$($_.Device)  [id=$($_.Id)]".Length } | Measure-Object -Maximum).Maximum
        $wChk = ($nobody | ForEach-Object { $_.Check.Length } | Measure-Object -Maximum).Maximum
        foreach ($n in $nobody) {
            $detail = (0..($curResults.Count - 1) | ForEach-Object { Format-CollectorCell $curResults[$_].Hostname $n.Vals[$_] }) -join '  '
            Write-Host ("  {0}  {1}  {2}" -f "$($n.Device)  [id=$($n.Id)]".PadRight($wDev), $n.Check.PadRight($wChk), $detail)
        }
        if (@($nobody | Where-Object { $_.Check -eq 'snmp' -and $_.Vals -contains 'TIMEOUT' }).Count) { Write-SnmpV3Hint }
        if (@($nobody | Where-Object Check -eq 'ping').Count) { Write-PingHint }
    }
}

# ── Joining-collector verdict: would it reach what the current collectors already do? ──
# A "gap" is a device+protocol the joining collector does NOT reach but at least one current
# collector does. Devices the current collectors already cannot reach are not the joining
# collector's fault, so they are not counted against it.
$candResults = @($results | Where-Object Role -eq 'joining' | Sort-Object Hostname)
$incResults  = $curResults
if ($candResults.Count -gt 0 -and $incResults.Count -eq 0) {
    Write-Host ""
    Write-Host "No current collector returned results, so the joining-collector verdict has no baseline; see the CSVs."
}
if ($candResults.Count -gt 0 -and $incResults.Count -gt 0) {
    $idCols    = 'id', 'device', 'hostname'
    $protoCols = @()
    foreach ($r in $results) {
        if ($r.Rows.Count -gt 0) { $protoCols = @($r.Rows[0].PSObject.Properties.Name | Where-Object { $_ -notin $idCols }); break }
    }

    # Per device id: which protocols at least one incumbent reaches ('pass'), and a label.
    $incPass = @{}
    $labels  = @{}
    foreach ($r in $incResults) {
        foreach ($row in $r.Rows) {
            $id = [string]$row.id
            if (-not $labels.ContainsKey($id))  { $labels[$id]  = $row.device }
            if (-not $incPass.ContainsKey($id)) { $incPass[$id] = @{} }
            foreach ($p in $protoCols) { if ([string]$row.$p -eq 'pass') { $incPass[$id][$p] = $true } }
        }
    }

    $anySnmpTimeout = $false   # printed once after the loop, not per collector -- see the hint below

    foreach ($cand in $candResults) {
        Write-Host ""
        Write-Host "== Joining collector verdict: $($cand.Hostname) =="

        # First pass: collect the gap rows so column widths can be computed before printing.
        # Rows are sorted by device name so gaps print alphabetically instead of in
        # whatever order the collector happened to return them.
        $gaps = [System.Collections.Generic.List[object]]::new()
        foreach ($row in ($cand.Rows | Sort-Object device)) {
            $id = [string]$row.id
            if (-not $incPass.ContainsKey($id)) { continue }   # no incumbent baseline for this device
            foreach ($p in $protoCols) {
                if ($incPass[$id][$p]) {                        # an incumbent reaches it
                    $v = [string]$row.$p
                    if ($v -ne 'pass') {
                        $lbl = if ($labels.ContainsKey($id)) { $labels[$id] } else { $id }
                        if ($p -eq 'snmp' -and $v -eq 'TIMEOUT') { $anySnmpTimeout = $true }
                        $gaps.Add([PSCustomObject]@{
                            Proto = $p
                            Label = $lbl
                            IdTok = "[id=$id]"
                            Value = if ($v -eq '') { '-' } else { $v }
                        })
                    }
                }
            }
        }

        if ($gaps.Count -eq 0) {
            Write-Host "  Reaches everything the current collectors reach. Ready to add."
        } else {
            Write-Host "  $($gaps.Count) gap(s) - it would NOT reach these, but a current collector does:"
            # Second pass: pad each column to its widest value so everything lines up.
            $wProto = ($gaps | ForEach-Object { $_.Proto.Length } | Measure-Object -Maximum).Maximum
            $wLabel = ($gaps | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum
            $wIdTok = ($gaps | ForEach-Object { $_.IdTok.Length } | Measure-Object -Maximum).Maximum
            foreach ($g in $gaps) {
                Write-Host ("    {0}  {1}  {2}  joining={3}, current collector reaches it" -f `
                    $g.Proto.PadRight($wProto), $g.Label.PadRight($wLabel),
                    $g.IdTok.PadRight($wIdTok), (Format-Cell $g.Value $g.Value))
            }
            Write-Host "  Fix routing/firewall for these before adding it."
        }
    }
    if ($anySnmpTimeout) { Write-SnmpV3Hint }
}

# ── Move-readiness verdict ──────────────────────────────────────────────────────
# For each device, look only at the protocols it is actually expected to use
# (deviceObjs[...].protocols), and check every destination collector's result for each:
#   READY   - every destination collector that returned reaches it on every expected protocol
#   PARTIAL - at least one destination collector reaches it, but not all (auto-balance risk:
#             the device could land on a collector that fails it)
#   BLOCKED - no destination collector reaches it on at least one expected protocol
$tgtResults = @($results | Where-Object Role -eq 'destination' | Sort-Object Hostname)
$verdictById = @{}   # device id (string) -> READY / PARTIAL / BLOCKED, for -PassThru
if (($tgrp -or $WithDevice) -and $tgtResults.Count -gt 0) {
    $dest = if ($tgrp) { "$($tgrp.name) (id=$($tgrp.id))" } else { $setupName }
    Write-Host ""
    Write-Host "== Move verdict: $($devices.Count) device(s) from $(($sources | ForEach-Object Label | Select-Object -Unique) -join ', ') -> $dest =="

    $rowsById = @{}
    foreach ($r in $tgtResults) {
        foreach ($row in $r.Rows) { $rowsById[[string]$row.id] = $rowsById[[string]$row.id] ?? @{}; $rowsById[[string]$row.id][$r.Hostname] = $row }
    }
    # Baseline: which device+check at least one current collector reaches. A check nobody
    # reaches today is not something the move breaks, and the verdict says so.
    $curPass = @{}
    foreach ($r in $curResults) {
        foreach ($row in $r.Rows) {
            $k = [string]$row.id
            # -WithDevice: only the device's own collector counts as its baseline.
            if ($WithDevice -and $deviceSourceMap[$k] -ne $r.Hostname) { continue }
            if (-not $curPass.ContainsKey($k)) { $curPass[$k] = @{} }
            foreach ($prop in $row.PSObject.Properties) { if ([string]$prop.Value -eq 'pass') { $curPass[$k][$prop.Name] = $true } }
        }
    }

    $ready          = [System.Collections.Generic.List[object]]::new()
    $partial        = [System.Collections.Generic.List[object]]::new()
    $blocked        = [System.Collections.Generic.List[object]]::new()
    $anySnmpTimeout = $false   # printed once at the end, not per-device -- see the hint below
    $anyPingOnly    = $false   # a device whose only failing check is ping -- see Write-PingHint

    foreach ($d in $deviceObjs) {
        $id = [string]$d.id
        if (-not $rowsById.ContainsKey($id)) { continue }   # no destination collector reported this device at all

        $protoIssues = [System.Collections.Generic.List[object]]::new()
        $worst = 'ready'   # ready < partial < blocked
        foreach ($p in $d.protocols) {
            # $d.protocols holds the raw internal tokens (tcp-135, tcp-22, tcp-80, tcp-443);
            # the CSV/Rows columns use the Groovy-side labels ($protoLabel, defined above for
            # the device summary table) -- wmi, ssh, http, https. Without this translation
            # $row.$p misses those four columns entirely and silently reads as "always absent".
            $colName = $protoLabel[$p] ?? $p
            # @(...): one destination collector would otherwise give a bare string.
            $vals = @(foreach ($r in $tgtResults) {
                $row = $rowsById[$id][$r.Hostname]
                if ($row) { [string]$row.$colName } else { '(absent)' }
            })
            $numPass = @($vals | Where-Object { $_ -eq 'pass' }).Count
            if ($numPass -eq $tgtResults.Count) {
                continue   # this protocol is fine everywhere
            } elseif ($numPass -gt 0) {
                if ($worst -ne 'blocked') { $worst = 'partial' }
            } else {
                $worst = 'blocked'
            }
            if ($colName -eq 'snmp' -and $vals -contains 'TIMEOUT') { $anySnmpTimeout = $true }
            $nowOk = $curResults.Count -eq 0 -or ($curPass.ContainsKey($id) -and $curPass[$id][$colName])
            $protoIssues.Add([PSCustomObject]@{ Proto = $colName; Vals = $vals; NotNow = -not $nowOk })
        }

        if ($protoIssues.Count -gt 0 -and @($protoIssues | Where-Object Proto -ne 'ping').Count -eq 0) { $anyPingOnly = $true }
        $entry = [PSCustomObject]@{ Device = $d.displayName; Id = $d.id; Source = $d.source; Issues = $protoIssues }
        $verdictById[$id] = $worst.ToUpper()
        switch ($worst) {
            'ready'   { $ready.Add($entry) }
            'partial' { $partial.Add($entry) }
            'blocked' { $blocked.Add($entry) }
        }
    }

    # Two-pass print: measure the widest device label / id token / protocol name across
    # ALL entries first, so every column lines up instead of each row wrapping ragged
    # (matches the padding the joining-collector verdict above uses). Detail cells reuse
    # Format-CollectorCell for the same colour + padding as the comparison table above.
    function Write-MoveVerdictEntries {
        param([object[]]$Entries)
        $wLabel = ($Entries | ForEach-Object { $_.Device.Length } | Measure-Object -Maximum).Maximum
        $wIdTok = ($Entries | ForEach-Object { "[id=$($_.Id)]".Length } | Measure-Object -Maximum).Maximum
        $wProto = ($Entries.Issues | ForEach-Object { $_.Proto.Length } | Measure-Object -Maximum).Maximum
        foreach ($e in ($Entries | Sort-Object Device)) {
            $idTok = "[id=$($e.Id)]"
            $from = if ($WithDevice -or @($sources | ForEach-Object Label | Select-Object -Unique).Count -gt 1) { "  (from $($e.Source))" } else { '' }
            Write-Host ("  - {0}  {1}{2}" -f $e.Device.PadRight($wLabel), $idTok.PadRight($wIdTok), $from)
            foreach ($i in $e.Issues) {
                $detail = (0..($tgtResults.Count - 1) | ForEach-Object { Format-CollectorCell $tgtResults[$_].Hostname $i.Vals[$_] }) -join '  '
                $note   = if ($i.NotNow) { '  (not reached from its current collectors either)' } else { '' }
                Write-Host ("      {0}  {1}{2}" -f $i.Proto.PadRight($wProto), $detail, $note)
            }
        }
    }

    Write-Host ""
    Write-Host "READY:   $($ready.Count) device(s) - every collector that would monitor them reaches them; safe to move."
    if ($blocked.Count -gt 0) {
        Write-Host ""
        Write-Host "BLOCKED: $($blocked.Count) device(s) - NO collector that would monitor them reaches at least one expected check:"
        Write-MoveVerdictEntries $blocked
    }
    if ($partial.Count -gt 0) {
        Write-Host ""
        Write-Host "PARTIAL: $($partial.Count) device(s) - SOME collectors that would monitor them reach them, some don't."
        Write-Host "         Risky under auto-balance: the device could land on a collector that fails it."
        Write-MoveVerdictEntries $partial
    }
    if ($blocked.Count -eq 0 -and $partial.Count -eq 0) {
        Write-Host ""
        Write-Host "All devices are reachable from every collector that would monitor them. Safe to move."
    }
    if ($anySnmpTimeout) { Write-SnmpV3Hint }
    if ($anyPingOnly)    { Write-PingHint }
}

# ── -PassThru: one object per device, check and collector, down the pipeline ──
if ($PassThru) {
    $byId = @{}; foreach ($d in $deviceObjs) { $byId[[string]$d.id] = $d }
    foreach ($r in $results) {
        foreach ($row in $r.Rows) {
            $d = $byId[[string]$row.id]
            foreach ($p in $row.PSObject.Properties) {
                if ($p.Name -in 'id', 'device', 'hostname' -or [string]::IsNullOrEmpty($p.Value)) { continue }
                [PSCustomObject]@{
                    Device    = $row.device
                    DeviceId  = [int]$row.id
                    Address   = $row.hostname
                    Source    = if ($d) { $d.source } else { $null }
                    Check     = $p.Name
                    Collector = $r.Hostname
                    Role      = $r.Role
                    Result    = $p.Value
                    Verdict   = $verdictById[[string]$row.id]
                }
            }
        }
    }
}

Write-Host ""
Write-Host "Done. Results in: $OutputDir"
# difft is pairwise only, so suggest it just for the two-collector case.
if ($results.Count -eq 2) {
    Write-Host "Full text diff: difft '$($results[0].OutFile)' '$($results[1].OutFile)'"
}
