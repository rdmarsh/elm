#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Check whether devices currently monitored by one or more source collectors could
    be moved to a different collector group, and save each target collector's result
    as <hostname>.csv.

.DESCRIPTION
    Self-contained: uses ONLY the Logic.Monitor PowerShell module (one
    Connect-LMAccount connection). No elm, bash, jq, jinja2 or external template
    is required.

    This is the mirror image of lm-collector-reachability-run-all.ps1's -Candidate
    mode. That script asks "would a new collector reach everything an existing group
    already monitors?" This script asks the opposite question: "the devices sitting on
    these specific collectors right now — could the group I'm about to move them into
    actually reach them?"

    Workflow:
      1. Resolve the source collector(s) (by id or hostname) -- these are NOT
         resolved via group membership; they can be standalone collectors anywhere.
      2. Find active devices whose preferredCollectorId is one of the source
         collectors, skipping hostStatus 'dead'. Devices that are 'dead-collector'
         are KEPT -- the source collector is down but the device may still be
         reachable from the target group.
      3. Resolve the target collector group and its active collectors.
      4. Build a per-device protocol list from autoProperties (ping/snmp/wmi/
         port-135/ssh/http/https).
      5. Generate a Groovy reachability script and submit it to every active
         collector in the TARGET group via Collector Debug.
      6. Wait, retrieve each result, and save <hostname>.csv in OutputDir.
      7. Print a move-readiness verdict per device: READY (every target collector
         reaches it), PARTIAL (only some do -- risky under auto-balance, which may
         place the device on a collector that can't reach it), or BLOCKED (no
         target collector reaches it).

.PARAMETER SourceCollector
    One or more collectors (id or hostname) whose CURRENTLY MONITORED devices are the
    ones being checked for a move. Not required to belong to any particular group --
    it can be a standalone collector or one being retired. Alias: -source.

.PARAMETER GroupName
    Target collector group name (resolved to an id) -- the group the devices would
    move into. Alias: -group.

.PARAMETER GroupId
    Target collector group id. Alias: -id.

.PARAMETER OutputDir
    Directory for the per-collector CSV files. Defaults to a per-run directory under
    the system temp dir, e.g. <temp>/lm-move-readiness/<groupid>-<timestamp>.

.PARAMETER WaitSeconds
    Maximum seconds to poll for results before giving up. Polling saves each collector's
    result as soon as it is ready, so this is only a cap, not a fixed wait. Defaults to
    180 (the Groovy thread pool can await up to 120s for unreachable devices).

.PARAMETER IncludeDead
    Also test devices with hostStatus 'dead' (skipped by default). They are down from
    their current (source) collector, but may be reachable once moved to the target
    group -- testing reveals whether the move would actually fix them. Dead devices
    show 'dead' in the Status column so you can tell them apart.

.EXAMPLE
    ./lm-collector-move-readiness-run-all.ps1
    List collector groups (possible move targets) and exit.

.EXAMPLE
    ./lm-collector-move-readiness-run-all.ps1 -source legacy01,legacy02 -group "Consolidated Collectors"
    Check whether every device currently monitored by legacy01/legacy02 would be
    reachable from the active collectors in "Consolidated Collectors", i.e. whether
    it is safe to move those devices into that group.

.EXAMPLE
    ./lm-collector-move-readiness-run-all.ps1 -source 191 -id 42 -OutputDir ./results

.NOTES
    Prerequisite: Logic.Monitor module loaded and Connect-LMAccount already
    called for the target portal. There is no -profile flag -- the portal is
    whatever you connected to.
#>
[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(ParameterSetName = 'ByName')]
    [Alias('group')]
    [string]$GroupName,

    [Parameter(ParameterSetName = 'ById')]
    [Alias('id')]
    [int]$GroupId,

    # Collector(s) whose current devices are being checked for a move. Not validated as
    # mandatory at the parameter level (so the parameter-less 'List' mode still works);
    # checked by hand once the parameter set is known to be ByName/ById.
    [Alias('source')]
    [string[]]$SourceCollector,

    [string]$OutputDir,                 # defaults to a per-run dir under the system temp
    [int]$WaitSeconds   = 180,          # cap; polling returns as soon as results are ready
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

# ── No group specified — list groups and exit ──────────────────────────────────
if ($PSCmdlet.ParameterSetName -eq 'List') {
    if ($SourceCollector) {
        Write-Warning "-SourceCollector requires a target group (-id or -group); ignoring it and listing groups."
    }
    Write-Host "Usage: ./lm-collector-move-readiness-run-all.ps1 -SourceCollector ID|NAME[,ID|NAME...] -id GROUP_ID | -group GROUP_NAME [-OutputDir DIR] [-WaitSeconds N] [-IncludeDead]"
    Write-Host ""
    # -BatchSize 1000 forces full pagination (older module versions can default to 50).
    $allGroups = Get-LMCollectorGroup -BatchSize 1000
    Write-Host "Collector groups: $($allGroups.Count) total"
    $allGroups |
        Select-Object id, name, numOfCollectors, autoBalance |
        Sort-Object id |
        Format-Table -AutoSize
    return
}

if (-not $SourceCollector) {
    throw "-SourceCollector is required (one or more collector ids/hostnames whose devices are being checked for a move)."
}

# ── Resolve target group ────────────────────────────────────────────────────────
if ($PSCmdlet.ParameterSetName -eq 'ByName') {
    $group = Get-LMCollectorGroup -Name $GroupName
    if (-not $group) { throw "Collector group '$GroupName' not found" }
    $GroupId   = $group.id
    $groupDesc = "$($group.name) (id=$GroupId)"
} else {
    $group = Get-LMCollectorGroup -BatchSize 1000 | Where-Object { $_.id -eq $GroupId }
    $groupDesc = if ($group) { "$($group.name) (id=$GroupId)" } else { "id=$GroupId" }
}
Write-Host "Target group: $groupDesc"

# ── Collectors (fetched once; reused to resolve source/target and detect collector hosts) ──
# -BatchSize 1000 forces full pagination — missing collectors here would both drop active
# target collectors from the run and leave gaps in the collector-host (collectorDeviceId) set.
$allCollectors    = Get-LMCollector -BatchSize 1000
$targetCollectors = $allCollectors | Where-Object { $_.collectorGroupId -eq $GroupId -and $_.status -eq 1 }
if (-not $targetCollectors) { throw "No active collectors found in target group $GroupId" }
Write-Host "Target collectors: $($targetCollectors.Count) active"
if (@($targetCollectors).Count -eq 1) {
    Write-Host "Note: only 1 active collector in the target group - no cross-collector comparison, but the move verdict still applies."
}

# ── Resolve source collector(s) ─────────────────────────────────────────────────
# Devices are discovered from these by preferredCollectorId, NOT by group membership --
# a source collector need not belong to any group at all. Unlike -Candidate resolution in
# the reachability script, a source collector is not required to be active: it may be the
# very collector being retired, and its devices are what we are trying to relocate.
$sourceErrors = [System.Collections.Generic.List[string]]::new()
$sourceCols   = [System.Collections.Generic.List[object]]::new()
foreach ($c in $SourceCollector) {
    if ($c -match '^\d+$') {
        $exact = @($allCollectors | Where-Object { $_.id -eq [int]$c })
    } else {
        $exact = @($allCollectors | Where-Object { $_.hostname -eq $c -or $_.description -eq $c })
    }
    if ($exact.Count -eq 1) {
        $m = $exact[0]
    } elseif ($exact.Count -gt 1) {
        $sourceErrors.Add("'$c' matched $($exact.Count) collectors exactly - use the numeric id"); continue
    } elseif ($c -match '^\d+$') {
        $sourceErrors.Add("collector id $c not found"); continue
    } else {
        $partial = @($allCollectors | Where-Object { $_.hostname -like "*$c*" -or $_.description -like "*$c*" })
        if ($partial.Count -eq 1) {
            $m = $partial[0]
            Write-Host "Source collector '$c' resolved to '$($m.hostname)' (id=$($m.id)) by partial match."
        } elseif ($partial.Count -gt 1) {
            $names = ($partial | ForEach-Object { "$($_.hostname) (id=$($_.id))" }) -join ', '
            $sourceErrors.Add("'$c' matched no collector exactly and $($partial.Count) partially ($names) - use the exact hostname or numeric id"); continue
        } else {
            $sourceErrors.Add("'$c' not found - no collector hostname/description contains it"); continue
        }
    }
    $sourceCols.Add($m)
}
if ($sourceErrors.Count -gt 0) {
    $nl = [Environment]::NewLine
    throw ("Source collector(s) could not be resolved; aborting:" + $nl +
           (($sourceErrors | ForEach-Object { "  - $_" }) -join $nl) + $nl +
           "Collector hostnames are case-insensitive but must match exactly. Get-LMCollector lists hostnames/ids.")
}
Write-Host "Source collectors: $($sourceCols.Count)"
foreach ($sc in $sourceCols) {
    $statusNote = if ($sc.status -ne 1) { " [inactive]" } else { "" }
    Write-Host "  - $($sc.hostname) (id=$($sc.id))$statusNote"
}

# A device that hosts a collector is linked by that collector's collectorDeviceId.
# Such hosts are monitored only from themselves and must not be cross-tested. Collect
# their device ids across ALL collectors (the host may belong to a collector elsewhere).
$collectorDeviceIds = [System.Collections.Generic.HashSet[int]]::new()
foreach ($c in $allCollectors) {
    if ($c.collectorDeviceId) { [void]$collectorDeviceIds.Add([int]$c.collectorDeviceId) }
}

# ── Discover devices currently on the source collector(s) ─────────────────────
# A device has exactly one preferredCollectorId, so querying per source collector and
# unioning by id (first-seen wins) cannot double-count -- but the LM PS module's -Filter
# is queried once per source anyway (rather than attempting an OR expression) to match the
# per-field query pattern already used elsewhere in this repo, and it lets each device be
# tagged with which source collector it came from for the report below.
$sourceHostnameById = @{}
foreach ($sc in $sourceCols) { $sourceHostnameById[[int]$sc.id] = $sc.hostname }

$deviceSourceMap = @{}   # device id (string) -> source collector hostname
$allDevices      = [System.Collections.Generic.List[object]]::new()
$seenIds         = [System.Collections.Generic.HashSet[int]]::new()
foreach ($sc in $sourceCols) {
    $devs = @(Get-LMDevice -Filter "preferredCollectorId -eq $($sc.id)")
    Write-Host "  $($sc.hostname) (id=$($sc.id)): $($devs.Count) device(s)"
    foreach ($d in $devs) {
        if ($seenIds.Add([int]$d.id)) {
            $allDevices.Add($d)
            $deviceSourceMap[[string]$d.id] = $sc.hostname
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
    Write-Host "Skipped (collector host - monitored from itself, not cross-tested):"
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

if ($devices.Count -eq 0) { throw "No testable devices found on the given source collector(s) (none assigned, all dead, or all collector hosts)." }

# ── Protocol detection from autoProperties (LM Active Discovery) ──────────────
#   auto.snmp.operational == "true"                  -> snmp
#   135 in auto.network.listening_tcp_ports          -> port-135
#   auto.wmi.operational  == "true"                  -> wmi
#   22  in auto.network.listening_tcp_ports          -> ssh
#   80  in tcp ports, or HTTP- (not HTTPS) datasource -> http
#   443 in tcp ports, or HTTPS/SSL_ datasource        -> https
function Get-DeviceProtocols {
    param([object]$Device)

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
    if ($snmp -eq 'true')     { $protocols.Add('snmp') }
    if ($tcp -contains '135') { $protocols.Add('tcp-135') }
    if ($wmi -eq 'true')      { $protocols.Add('wmi') }
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
        source      = $deviceSourceMap[[string]$dev.id]
        protocols   = (Get-DeviceProtocols $dev)
    }
}

# ── Summary table ─────────────────────────────────────────────────────────────
$protoLabel = @{ 'tcp-135' = 'port-135'; 'wmi' = 'wmi'; 'tcp-22' = 'ssh'; 'tcp-80' = 'http'; 'tcp-443' = 'https' }
$deviceObjs |
    Select-Object @{n='Device';e={$_.displayName}},
                  @{n='IP/Hostname';e={$_.ip}},
                  @{n='Source';e={$_.source}},
                  @{n='Status';e={$_.hostStatus}},
                  @{n='Protocols';e={ ($_.protocols | ForEach-Object { $protoLabel[$_] ?? $_ }) -join ', ' }} |
    Format-Table -AutoSize | Out-Host

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
// lm-collector-move-readiness-check.groovy
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
        case "tcp-135": return tcpOk(ip, 135, tcpMs)  ? "pass" : "FAIL"
        case "wmi":     return tcpOk(ip, 135, tcpMs)  ? "pass" : "FAIL"
        case "tcp-22":  return tcpOk(ip,  22, tcpMs)  ? "pass" : "FAIL"
        case "tcp-80":  return tcpOk(ip,  80, tcpMs)  ? "pass" : "FAIL"
        case "tcp-443": return tcpOk(ip, 443, tcpMs)  ? "pass" : "FAIL"
        default:        return "?"
    }
}

def protoOrder = ["ping", "snmp", "tcp-135", "wmi", "tcp-22", "tcp-80", "tcp-443"]
def protoLabel = ["tcp-135": "port-135", "wmi": "wmi", "tcp-22": "ssh", "tcp-80": "http", "tcp-443": "https"]
def allProtos = devices.collectMany { it.protocols }.unique()
    .sort { a, b ->
        def ai = protoOrder.indexOf(a); def bi = protoOrder.indexOf(b)
        (ai < 0 ? 999 : ai) <=> (bi < 0 ? 999 : bi)
    }
def collectorHost = java.net.InetAddress.getLocalHost().getHostName()
println "Testing ${devices.size()} devices from ${collectorHost} (parallel)..."

def pool    = Executors.newFixedThreadPool(Math.min(devices.size(), 20))
def futures = devices.collect { d ->
    pool.submit({
        def res = [:]
        allProtos.each { proto ->
            res[proto] = d.protocols.contains(proto)
                ? runTest(proto, d.ip, PING_TIMEOUT_MS, TCP_TIMEOUT_MS, SNMP_TIMEOUT_MS)
                : "-"
        }
        return [id: d.id, name: d.displayName, ip: d.ip, res: res]
    } as Callable)
}
pool.shutdown()
pool.awaitTermination(120, TimeUnit.SECONDS)

def header = ["id", "device", "hostname"] + allProtos.collect { protoLabel[it] ?: it }
println header.join(",")

def failures = []
futures.eachWithIndex { f, i ->
    def r = f.get()
    def row = [r.id, r.name, r.ip] + allProtos.collect { proto ->
        def result = r.res[proto]
        if (result == "FAIL") failures << "${r.name}  ${protoLabel[proto] ?: proto}"
        result == "-" ? "" : result
    }
    println row.join(",")
}

println ""
if (failures) {
    println "FAILURES — investigate before moving these devices to this collector:"
    failures.each { println "  - $it" }
    println ""
    println "snmp TIMEOUT may mean wrong community rather than unreachable — check snmp.community in LM."
    println "port-135/wmi pass only confirms TCP 135 (RPC endpoint mapper); WMI uses dynamic high ports (49152-65535) too."
} else {
    println "All checks passed. This collector can reach all tested devices."
}
'@

$groovyScript = $groovyTemplate.Replace('__DEVICES__', $devicesGroovy)

# ── Output directory ──────────────────────────────────────────────────────────
if (-not $OutputDir) {
    $OutputDir = Join-Path ([System.IO.Path]::GetTempPath()) "lm-move-readiness/$GroupId-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
$null = New-Item -ItemType Directory -Force -Path $OutputDir
$OutputDir = (Resolve-Path $OutputDir).Path   # absolute, so the run output can show clean filenames
Write-Host "Output dir:  $OutputDir"

# ── Submit to every active TARGET group collector, wait once, then retrieve ────
# -IncludeResult times out before the Groovy pool.awaitTermination (120s), so we
# use the submit / wait / retrieve pattern instead.
Write-Host "Submitting to $($targetCollectors.Count) target collector(s)..."
$jobs = foreach ($col in $targetCollectors) {
    try {
        $r = Invoke-LMCollectorDebugCommand -Id $col.id -GroovyCommand $groovyScript -ErrorAction Stop
        Write-Host "  -> $($col.hostname) (id=$($col.id))"
        [PSCustomObject]@{
            Hostname  = $col.hostname
            Id        = $col.id
            SessionId = $r.SessionId
        }
    } catch {
        Write-Warning "  Submit failed for $($col.hostname) (id=$($col.id)): $($_.Exception.Message)"
    }
}
$jobs = @($jobs)
if ($jobs.Count -eq 0) {
    throw ("No debug sessions were created. The most common cause is insufficient LM permissions: " +
           "running Collector Debug commands requires an account/API token whose role grants 'Manage' " +
           "rights on collectors (remote debug). Verify the credentials used to connect the LM session.")
}

# Get-LMCollectorDebugResult returns the command output TEXT directly (the module does
# `Return $Response.output`) — NOT an object with an .output property — and `output` stays
# empty until the Groovy completes, so non-empty output means "done". Handle a plain
# string, an object that still carries .output, and string[], for robustness across
# module versions.
function Get-DebugText($result) {
    if ($result -is [string]) { return $result }
    if ($result -and $result.PSObject.Properties['output']) { return [string]$result.output }
    return ($result | Out-String)
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
        $text = Get-DebugText (Get-LMCollectorDebugResult -SessionId $job.SessionId -Id $job.Id)
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $safeName = $job.Hostname -replace '[\\/:*?"<>|]', '_'
            $outFile  = Join-Path $OutputDir "${safeName}.csv"
            $text | Set-Content $outFile
            Write-Host "  saved $(Split-Path $outFile -Leaf)  ($($job.Hostname))"
            $results.Add([PSCustomObject]@{
                Hostname = $job.Hostname
                OutFile  = $outFile
                Rows     = @(ConvertFrom-ReachabilityText $text)
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

# ── Cross-collector comparison: do the target group's OWN collectors agree? ───
# Not a textual file diff. For every device+protocol, gather the result from each
# target collector that returned and flag the row when collectors disagree (e.g. one
# 'pass', another 'FAIL'). This matters here because the target group may be
# auto-balance -- if its collectors disagree, which one a device lands on decides
# whether it works.
if ($results.Count -ge 2) {
    Write-Host ""
    Write-Host "-- Comparison: reachability gaps between target collectors --"

    $ordered = @($results | Sort-Object Hostname)

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
        Write-Host "All $agree device(s) agree across all $($results.Count) target collectors."
    } else {
        Write-Host "$disagree device(s) differ between target collectors; $agree agree."
        Write-Host "Under auto-balance, which collector a device lands on decides whether it works - see the move verdict below."
    }
} elseif ($results.Count -eq 1) {
    Write-Host ""
    Write-Host "Only one target collector returned results - nothing to cross-compare."
}

# ── Move-readiness verdict ──────────────────────────────────────────────────────
# For each device, look only at the protocols it is actually expected to use
# (deviceObjs[...].protocols), and check every target collector's result for each:
#   READY   - every target collector that returned reaches it on every expected protocol
#   PARTIAL - at least one target collector reaches it, but not all (auto-balance risk:
#             the device could land on a collector that fails it)
#   BLOCKED - no target collector reaches it on at least one expected protocol
if ($results.Count -gt 0) {
    Write-Host ""
    Write-Host "== Move verdict: $($devices.Count) device(s) from $($sourceCols.Count) source collector(s) -> $groupDesc =="

    $rowsById = @{}
    foreach ($r in $results) {
        foreach ($row in $r.Rows) { $rowsById[[string]$row.id] = $rowsById[[string]$row.id] ?? @{}; $rowsById[[string]$row.id][$r.Hostname] = $row }
    }

    $ready   = [System.Collections.Generic.List[object]]::new()
    $partial = [System.Collections.Generic.List[object]]::new()
    $blocked = [System.Collections.Generic.List[object]]::new()

    foreach ($d in $deviceObjs) {
        $id = [string]$d.id
        if (-not $rowsById.ContainsKey($id)) { continue }   # no target collector reported this device at all

        $protoIssues = [System.Collections.Generic.List[object]]::new()
        $worst = 'ready'   # ready < partial < blocked
        foreach ($p in $d.protocols) {
            # $d.protocols holds the raw internal tokens (tcp-135, tcp-22, tcp-80, tcp-443);
            # the CSV/Rows columns use the Groovy-side labels ($protoLabel, defined above for
            # the device summary table) -- port-135, ssh, http, https. Without this translation
            # $row.$p misses those four columns entirely and silently reads as "always absent".
            $colName = $protoLabel[$p] ?? $p
            $vals = foreach ($r in $results) {
                $row = $rowsById[$id][$r.Hostname]
                if ($row) { [string]$row.$colName } else { '(absent)' }
            }
            $numPass = @($vals | Where-Object { $_ -eq 'pass' }).Count
            if ($numPass -eq $results.Count) {
                continue   # this protocol is fine everywhere
            } elseif ($numPass -gt 0) {
                if ($worst -ne 'blocked') { $worst = 'partial' }
            } else {
                $worst = 'blocked'
            }
            $protoIssues.Add([PSCustomObject]@{ Proto = $colName; Vals = $vals })
        }

        $entry = [PSCustomObject]@{ Device = $d.displayName; Id = $d.id; Source = $d.source; Issues = $protoIssues }
        switch ($worst) {
            'ready'   { $ready.Add($entry) }
            'partial' { $partial.Add($entry) }
            'blocked' { $blocked.Add($entry) }
        }
    }

    # Two-pass print: measure the widest device label / id token / protocol name across
    # ALL entries first, so every column lines up instead of each row wrapping ragged
    # (matches the padding lm-collector-reachability-run-all.ps1 uses for its candidate
    # verdict). Detail cells reuse Format-CollectorCell for the same colour + padding as
    # the comparison table above.
    function Write-MoveVerdictEntries {
        param([object[]]$Entries)
        $wLabel = ($Entries | ForEach-Object { $_.Device.Length } | Measure-Object -Maximum).Maximum
        $wIdTok = ($Entries | ForEach-Object { "[id=$($_.Id)]".Length } | Measure-Object -Maximum).Maximum
        $wProto = ($Entries.Issues | ForEach-Object { $_.Proto.Length } | Measure-Object -Maximum).Maximum
        foreach ($e in ($Entries | Sort-Object Device)) {
            $idTok = "[id=$($e.Id)]"
            Write-Host ("  - {0}  {1}  (from {2})" -f $e.Device.PadRight($wLabel), $idTok.PadRight($wIdTok), $e.Source)
            foreach ($i in $e.Issues) {
                $detail = (0..($results.Count - 1) | ForEach-Object { Format-CollectorCell $results[$_].Hostname $i.Vals[$_] }) -join '  '
                Write-Host ("      {0}  {1}" -f $i.Proto.PadRight($wProto), $detail)
            }
        }
    }

    Write-Host ""
    Write-Host "READY:   $($ready.Count) device(s) - every target collector reaches them; safe to move."
    if ($blocked.Count -gt 0) {
        Write-Host ""
        Write-Host "BLOCKED: $($blocked.Count) device(s) - NO target collector reaches at least one expected protocol:"
        Write-MoveVerdictEntries $blocked
    }
    if ($partial.Count -gt 0) {
        Write-Host ""
        Write-Host "PARTIAL: $($partial.Count) device(s) - SOME target collectors reach them, some don't."
        Write-Host "         Risky if the target group is auto-balance: the device could land on a collector that fails it."
        Write-MoveVerdictEntries $partial
    }
    if ($blocked.Count -eq 0 -and $partial.Count -eq 0) {
        Write-Host ""
        Write-Host "All devices are reachable from every active collector in the target group. Safe to move."
    }
}

Write-Host ""
Write-Host "Done. Results in: $OutputDir"
# difft is pairwise only, so suggest it just for the two-collector case.
if ($results.Count -eq 2) {
    Write-Host "Full text diff: difft '$($results[0].OutFile)' '$($results[1].OutFile)'"
}
