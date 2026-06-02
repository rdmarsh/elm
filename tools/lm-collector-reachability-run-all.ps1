#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Run an LM collector reachability check across every active collector in a
    collector group, and save each collector's result as <hostname>.csv.

.DESCRIPTION
    Self-contained: uses ONLY the Logic.Monitor PowerShell module (one
    Connect-LMAccount connection). No elm, bash, jq, jinja2 or external template
    is required — device discovery, the protocol matrix, and the Groovy script
    are all built in PowerShell.

    Workflow:
      1. Resolve the collector group (by name or id).
      2. Find active devices assigned to the group (preferredCollectorGroupId),
         skipping hostStatus 'dead'. Devices that are 'dead-collector' are KEPT —
         the collector is down but the device may be reachable from a new one.
      3. Build a per-device protocol list from autoProperties (ping/snmp/wmi/
         port-135/ssh/http/https).
      4. Generate a Groovy reachability script and submit it to every active
         collector in the group via Collector Debug.
      5. Wait, retrieve each result, and save <hostname>.csv in OutputDir.

    Diff the resulting CSV files to find reachability gaps between collectors.

.PARAMETER GroupName
    Collector group name (resolved to an id). Alias: -group.

.PARAMETER GroupId
    Collector group id. Alias: -id.

.PARAMETER OutputDir
    Directory for the per-collector CSV files. Defaults to a per-run directory under
    the system temp dir, e.g. <temp>/lm-reachability/<groupid>-<timestamp>.

.PARAMETER WaitSeconds
    Maximum seconds to poll for results before giving up. Polling saves each collector's
    result as soon as it is ready, so this is only a cap, not a fixed wait. Defaults to
    180 (the Groovy thread pool can await up to 120s for unreachable devices).

.PARAMETER IncludeDead
    Also test devices with hostStatus 'dead' (skipped by default). They are down from
    their current collector, but may be reachable from another collector in the group —
    testing reveals relocate candidates. Dead devices show 'dead' in the Status column so
    you can tell them apart, and their ids let you find their rows in the CSV.

.PARAMETER Candidate
    One or more collectors (id or hostname) that are NOT in the group, tested against the
    group's device list. Use this to vet a freshly built collector before moving it in:
    "will it reach everything this group monitors?" Each candidate is submitted the same
    device list as the group's own collectors, then a per-candidate verdict lists any
    device+protocol the candidate fails to reach but an in-group collector does reach.
    Alias: -collector. Requires a group (-id/-group) to define the devices.

.EXAMPLE
    ./lm-collector-reachability-run-all.ps1
    List auto-balance collector groups and exit.

.EXAMPLE
    ./lm-collector-reachability-run-all.ps1 -group "Acme Auto-Balance Group"

.EXAMPLE
    ./lm-collector-reachability-run-all.ps1 -id 191 -OutputDir ./results

.EXAMPLE
    ./lm-collector-reachability-run-all.ps1 -id 191 -Candidate newedge02
    Test new collector 'newedge02' (not yet in group 191) against group 191's devices and
    report whether it would reach everything the group's existing collectors reach.

.NOTES
    Prerequisite: Logic.Monitor module loaded and Connect-LMAccount already
    called for the target portal. There is no -profile flag — the portal is
    whatever you connected to.
#>
[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [Alias('group')]
    [string]$GroupName,

    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [Alias('id')]
    [int]$GroupId,

    [string]$OutputDir,                 # defaults to a per-run dir under the system temp
    [int]$WaitSeconds   = 180,          # cap; polling returns as soon as results are ready
    [switch]$IncludeDead,               # also test hostStatus:dead devices (flagged in output)

    # Extra collector(s) NOT in the group, tested against the group's device list.
    # Answers "I built a new collector - will it reach everything this group monitors
    # before I add it?" Accepts collector ids or hostnames. Submitted alongside the
    # group's own collectors; a per-candidate verdict is printed at the end.
    [Alias('collector')]
    [string[]]$Candidate,

    [switch]$NoColor                    # disable ANSI colour in the comparison/verdict output
)

$ErrorActionPreference = 'Stop'

# ── Preconditions ─────────────────────────────────────────────────────────────
if (-not (Get-Command Get-LMDevice -ErrorAction SilentlyContinue)) {
    throw "Logic.Monitor module not loaded. Establish an LM session first " +
          "(Connect-LMAccount, or your own connection wrapper), then re-run."
}

# ── No group specified — list auto-balance groups and exit ────────────────────
if ($PSCmdlet.ParameterSetName -eq 'List') {
    if ($Candidate) {
        Write-Warning "-Candidate requires a group (-id or -group) to define the device list; ignoring it and listing groups."
    }
    Write-Host "Usage: ./lm-collector-reachability-run-all.ps1 -id GROUP_ID | -group GROUP_NAME [-Candidate ID|NAME ...] [-OutputDir DIR] [-WaitSeconds N] [-IncludeDead]"
    Write-Host ""
    # -BatchSize 1000 forces full pagination (older module versions can default to 50).
    $allGroups   = Get-LMCollectorGroup -BatchSize 1000
    $multiGroups = @($allGroups | Where-Object { $_.numOfCollectors -gt 1 })
    Write-Host "Collector groups with more than 1 collector: $($multiGroups.Count) of $($allGroups.Count) total"
    Write-Host "(reachability matters whenever >1 collector could monitor a device - auto-balance or not)"
    Write-Host ""
    $multiGroups |
        Select-Object id, name, numOfCollectors, autoBalance |
        Sort-Object id |
        Format-Table -AutoSize
    return
}

# ── Resolve group ─────────────────────────────────────────────────────────────
if ($PSCmdlet.ParameterSetName -eq 'ByName') {
    $group = Get-LMCollectorGroup -Name $GroupName
    if (-not $group) { throw "Collector group '$GroupName' not found" }
    $GroupId   = $group.id
    $groupDesc = "$($group.name) (id=$GroupId)"
} else {
    $group = Get-LMCollectorGroup -BatchSize 1000 | Where-Object { $_.id -eq $GroupId }
    $groupDesc = if ($group) { "$($group.name) (id=$GroupId)" } else { "id=$GroupId" }
}
Write-Host "Group:       $groupDesc"

# ── Collectors (fetched once; reused to detect collector-host devices) ─────────
# -BatchSize 1000 forces full pagination — missing collectors here would both drop active
# collectors from the run and leave gaps in the collector-host (collectorDeviceId) set.
$allCollectors = Get-LMCollector -BatchSize 1000
$collectors    = $allCollectors | Where-Object { $_.collectorGroupId -eq $GroupId -and $_.status -eq 1 }
if (-not $collectors) { throw "No active collectors found in group $GroupId" }
Write-Host "Collectors:  $($collectors.Count) active"
if (@($collectors).Count -eq 1 -and -not $Candidate) {
    Write-Host "Note: only 1 active collector in this group - results have nothing to compare against."
}

# ── Candidate collector(s): extra collectors NOT in the group ──────────────────
# Tested against THIS group's device list, so you can check a freshly built collector
# before moving it in. Device discovery and collector-host detection still come from
# the group; the candidate just gets the same device list submitted to it.
$candidateCols = @()
if ($Candidate) {
    # You explicitly asked to vet a candidate, so any -Candidate entry that cannot be
    # used as one is a hard error: collect every problem and throw BEFORE the (expensive)
    # device discovery, rather than silently degrading into a plain group run.
    $groupColIds = @($collectors | ForEach-Object { [int]$_.id })
    $candErrors  = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $Candidate) {
        # Resolve: numeric -> id; otherwise exact hostname/description (case-insensitive),
        # then fall back to a partial (substring) match so an FQDN like 'newedge03.example.com'
        # still resolves from 'newedge03'. A partial match is only accepted if it is
        # unambiguous; multiple matches list candidates and ask for the exact name/id.
        if ($c -match '^\d+$') {
            $exact = @($allCollectors | Where-Object { $_.id -eq [int]$c })
        } else {
            $exact = @($allCollectors | Where-Object { $_.hostname -eq $c -or $_.description -eq $c })
        }
        if ($exact.Count -eq 1) {
            $m = $exact[0]
        } elseif ($exact.Count -gt 1) {
            $candErrors.Add("'$c' matched $($exact.Count) collectors exactly - use the numeric id"); continue
        } elseif ($c -match '^\d+$') {
            $candErrors.Add("collector id $c not found (it must be installed and connected to LM, just not in the group)"); continue
        } else {
            $partial = @($allCollectors | Where-Object { $_.hostname -like "*$c*" -or $_.description -like "*$c*" })
            if ($partial.Count -eq 1) {
                $m = $partial[0]
                Write-Host "Candidate '$c' resolved to '$($m.hostname)' (id=$($m.id)) by partial match."
            } elseif ($partial.Count -gt 1) {
                $names = ($partial | ForEach-Object { "$($_.hostname) (id=$($_.id))" }) -join ', '
                $candErrors.Add("'$c' matched no collector exactly and $($partial.Count) partially ($names) - use the exact hostname or numeric id"); continue
            } else {
                $candErrors.Add("'$c' not found - no collector hostname/description contains it (the collector must be installed and connected to LM, just not yet in the group)"); continue
            }
        }
        if ($groupColIds -contains [int]$m.id) {
            $candErrors.Add("'$($m.hostname)' (id=$($m.id)) is already in group $GroupId - it is an incumbent, not a candidate")
            continue
        }
        if ($m.status -ne 1) { $candErrors.Add("'$($m.hostname)' (id=$($m.id)) is not active (status=$($m.status) - is the collector running and connected?)"); continue }
        $candidateCols += $m
    }
    if ($candErrors.Count -gt 0) {
        $nl = [Environment]::NewLine
        throw ("Candidate collector(s) could not be used as candidates; aborting:" + $nl +
               (($candErrors | ForEach-Object { "  - $_" }) -join $nl) + $nl +
               "Collector hostnames are case-insensitive but must match exactly. Run with no -Candidate " +
               "to see the group, or Get-LMCollector to list collector hostnames/ids.")
    }
    Write-Host "Candidates:  $($candidateCols.Count) (not in the group; tested against its devices)"
    foreach ($cc in $candidateCols) { Write-Host "  + $($cc.hostname) (id=$($cc.id))" }
}

# A device that hosts a collector is linked by that collector's collectorDeviceId.
# Such hosts are monitored only from themselves and must not be cross-tested. Collect
# their device ids across ALL collectors (the host may belong to a collector elsewhere).
$collectorDeviceIds = [System.Collections.Generic.HashSet[int]]::new()
foreach ($c in $allCollectors) {
    if ($c.collectorDeviceId) { [void]$collectorDeviceIds.Add([int]$c.collectorDeviceId) }
}

# ── Discover member devices ───────────────────────────────────────────────────
# Group membership is preferredCollectorGroupId (what the device is assigned to).
# autoBalancedCollectorGroupId only reflects devices LM has actively placed and
# can be empty even for an autoBalance group with assigned devices.
$allDevices     = Get-LMDevice -Filter "preferredCollectorGroupId -eq $GroupId"
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
    if ($group -and $group.autoBalance) {
        Write-Warning "$($collectorHosts.Count) collector host(s) are in auto-balance group '$($group.name)' (id=$GroupId)."
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

if ($devices.Count -eq 0) { throw "No testable devices in group $GroupId (none assigned, all dead, or all collector hosts)." }

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
        protocols   = (Get-DeviceProtocols $dev)
    }
}

# ── Summary table ─────────────────────────────────────────────────────────────
$protoLabel = @{ 'tcp-135' = 'port-135'; 'wmi' = 'wmi'; 'tcp-22' = 'ssh'; 'tcp-80' = 'http'; 'tcp-443' = 'https' }
$deviceObjs |
    Select-Object @{n='Device';e={$_.displayName}},
                  @{n='IP/Hostname';e={$_.ip}},
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
// lm-collector-reachability-check.groovy
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
    println "FAILURES — investigate before adding this collector to the group:"
    failures.each { println "  - $it" }
    println ""
    println "snmp TIMEOUT may mean wrong community rather than unreachable — check snmp.community in LM."
    println "port-135/wmi pass only confirms TCP 135 (RPC endpoint mapper); WMI uses dynamic high ports (49152-65535) too."
} else {
    println "All checks passed. Collector appears ready to join the auto-balance group."
}
'@

$groovyScript = $groovyTemplate.Replace('__DEVICES__', $devicesGroovy)
Write-Host "Groovy script ready ($($groovyScript.Length) chars)"

# ── Output directory ──────────────────────────────────────────────────────────
if (-not $OutputDir) {
    $OutputDir = Join-Path ([System.IO.Path]::GetTempPath()) "lm-reachability/$GroupId-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
$null = New-Item -ItemType Directory -Force -Path $OutputDir

# ── Submit to all collectors, wait once, then retrieve ────────────────────────
# -IncludeResult times out before the Groovy pool.awaitTermination (120s), so we
# use the submit / wait / retrieve pattern instead.
# Submission targets = the group's own collectors plus any candidates, each tagged.
$targets = @()
$targets += $collectors    | ForEach-Object { [PSCustomObject]@{ Collector = $_; IsCandidate = $false } }
$targets += $candidateCols | ForEach-Object { [PSCustomObject]@{ Collector = $_; IsCandidate = $true  } }

Write-Host "Submitting to $($targets.Count) collector(s)..."
$jobs = foreach ($t in $targets) {
    $col = $t.Collector
    try {
        $r = Invoke-LMCollectorDebugCommand -Id $col.id -GroovyCommand $groovyScript -ErrorAction Stop
        $tag = if ($t.IsCandidate) { ' [candidate]' } else { '' }
        Write-Host "  -> $($col.hostname) (id=$($col.id))$tag session=$($r.SessionId)"
        [PSCustomObject]@{
            Hostname    = $col.hostname
            Id          = $col.id
            SessionId   = $r.SessionId
            IsCandidate = $t.IsCandidate
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
            Write-Host "  Saved: $outFile  ($($job.Hostname))"
            $results.Add([PSCustomObject]@{
                Hostname    = $job.Hostname
                OutFile     = $outFile
                IsCandidate = $job.IsCandidate
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

# ── Cross-collector comparison: surface reachability gaps ─────────────────────
# Not a textual file diff. For every device+protocol, gather the result from each
# collector that returned and flag the row when collectors disagree (e.g. one
# 'pass', another 'FAIL'). Works for any collector count - the odd one out of N is
# visible in the per-protocol line, not just an A-vs-B comparison.
if ($results.Count -ge 2) {
    Write-Host ""
    Write-Host "-- Comparison: reachability gaps between collectors --"

    # Fixed column order: incumbents first (sorted by hostname), then any candidate(s)
    # on the right. Results arrive in completion order, so without this the columns would
    # shuffle run-to-run.
    $ordered = @(@($results | Where-Object { -not $_.IsCandidate } | Sort-Object Hostname) +
                 @($results | Where-Object {      $_.IsCandidate } | Sort-Object Hostname))

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

    $disagree = 0
    $agree    = 0
    foreach ($id in $allIds) {
        # Device label from the first collector that reported this id.
        $label = $id
        foreach ($r in $ordered) {
            if ($byCollector[$r.Hostname].ContainsKey($id)) { $label = $byCollector[$r.Hostname][$id].device; break }
        }

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
                $detail = ($cells | ForEach-Object { Format-Cell "$($_.Collector)=$($_.Value)" $_.Value }) -join '  '
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
        Write-Host "All $agree device(s) agree across all $($results.Count) collectors - no reachability gaps."
    } else {
        Write-Host "$disagree device(s) differ between collectors; $agree agree."
        Write-Host "Investigate the gaps above before relying on auto-balance to move them."
    }
} elseif ($results.Count -eq 1) {
    Write-Host ""
    Write-Host "Only one collector returned results - nothing to compare."
}

# ── Candidate verdict: would the new collector(s) reach what the group already does? ──
# A candidate "gap" is a device+protocol the candidate does NOT reach but at least one
# incumbent (already-in-group) collector does. Devices the whole group already cannot
# reach are not the candidate's fault, so they are not counted against it.
$candResults = @($results | Where-Object { $_.IsCandidate } | Sort-Object Hostname)
$incResults  = @($results | Where-Object { -not $_.IsCandidate })
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

    foreach ($cand in $candResults) {
        Write-Host ""
        Write-Host "== Candidate verdict: $($cand.Hostname) =="

        # First pass: collect the gap rows so column widths can be computed before printing.
        $gaps = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $cand.Rows) {
            $id = [string]$row.id
            if (-not $incPass.ContainsKey($id)) { continue }   # no incumbent baseline for this device
            foreach ($p in $protoCols) {
                if ($incPass[$id][$p]) {                        # an incumbent reaches it
                    $v = [string]$row.$p
                    if ($v -ne 'pass') {
                        $lbl = if ($labels.ContainsKey($id)) { $labels[$id] } else { $id }
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
            Write-Host "  Reaches everything the group's collectors reach. Ready to add to the group."
        } else {
            Write-Host "  $($gaps.Count) gap(s) - the candidate would NOT reach these, but a group collector does:"
            # Second pass: pad each column to its widest value so everything lines up.
            $wProto = ($gaps | ForEach-Object { $_.Proto.Length } | Measure-Object -Maximum).Maximum
            $wLabel = ($gaps | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum
            $wIdTok = ($gaps | ForEach-Object { $_.IdTok.Length } | Measure-Object -Maximum).Maximum
            foreach ($g in $gaps) {
                Write-Host ("    {0}  {1}  {2}  candidate={3}, group reaches it" -f `
                    $g.Proto.PadRight($wProto), $g.Label.PadRight($wLabel),
                    $g.IdTok.PadRight($wIdTok), (Format-Cell $g.Value $g.Value))
            }
            Write-Host "  Fix routing/firewall for these before moving the candidate into the group."
        }
    }
}

Write-Host ""
Write-Host "Done. Results in: $(Resolve-Path $OutputDir)"
# difft is pairwise only, so suggest it just for the two-collector case.
if ($results.Count -eq 2) {
    Write-Host "Full text diff: difft '$($results[0].OutFile)' '$($results[1].OutFile)'"
}
