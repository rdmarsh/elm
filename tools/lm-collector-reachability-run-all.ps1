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
    Collector group name (resolved to an id). Alias: -name.

.PARAMETER GroupId
    Collector group id. Alias: -id.

.PARAMETER OutputDir
    Directory for the per-collector CSV files. Defaults to the current directory.

.PARAMETER WaitSeconds
    Seconds to wait for the Groovy scripts to finish before retrieving results.
    Defaults to 140 (the Groovy thread pool awaits up to 120s).

.EXAMPLE
    ./lm-collector-reachability-run-all.ps1
    List auto-balance collector groups and exit.

.EXAMPLE
    ./lm-collector-reachability-run-all.ps1 -name "Acme Auto-Balance Group"

.EXAMPLE
    ./lm-collector-reachability-run-all.ps1 -id 191 -OutputDir ./results

.NOTES
    Prerequisite: Logic.Monitor module loaded and Connect-LMAccount already
    called for the target portal. There is no -profile flag — the portal is
    whatever you connected to.
#>
[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [Alias('name')]
    [string]$GroupName,

    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [Alias('id')]
    [int]$GroupId,

    [string]$OutputDir  = '.',
    [int]$WaitSeconds   = 140
)

$ErrorActionPreference = 'Stop'

# ── Preconditions ─────────────────────────────────────────────────────────────
if (-not (Get-Command Get-LMDevice -ErrorAction SilentlyContinue)) {
    throw "Logic.Monitor module not loaded. Establish an LM session first " +
          "(Connect-LMAccount, or your own connection wrapper), then re-run."
}

# ── No group specified — list auto-balance groups and exit ────────────────────
if ($PSCmdlet.ParameterSetName -eq 'List') {
    Write-Host "Usage: ./lm-collector-reachability-run-all.ps1 -id GROUP_ID | -name GROUP_NAME [-OutputDir DIR] [-WaitSeconds N]"
    Write-Host ""
    Write-Host "Auto-balance collector groups:"
    Write-Host ""
    Get-LMCollectorGroup |
        Where-Object { $_.autoBalance } |
        Select-Object id, name, numOfCollectors, autoBalanceInstanceCountThreshold |
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
    $group = Get-LMCollectorGroup | Where-Object { $_.id -eq $GroupId }
    $groupDesc = if ($group) { "$($group.name) (id=$GroupId)" } else { "id=$GroupId" }
}
Write-Host "Group:       $groupDesc"
if ($group -and -not $group.autoBalance) {
    Write-Warning "Group '$($group.name)' does not have autoBalance enabled."
}

# ── Collectors (fetched once; reused to detect collector-host devices) ─────────
$allCollectors = Get-LMCollector
$collectors    = $allCollectors | Where-Object { $_.collectorGroupId -eq $GroupId -and $_.status -eq 1 }
if (-not $collectors) { throw "No active collectors found in group $GroupId" }
Write-Host "Collectors:  $($collectors.Count) active"

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
$dead           = @($allDevices | Where-Object { $_.hostStatus -eq 'dead' })
$alive          = @($allDevices | Where-Object { $_.hostStatus -ne 'dead' })
$collectorHosts = @($alive | Where-Object { $collectorDeviceIds.Contains([int]$_.id) })
$devices        = @($alive | Where-Object { -not $collectorDeviceIds.Contains([int]$_.id) })

$skips = @()
if ($dead.Count -gt 0)           { $skips += "$($dead.Count) dead" }
if ($collectorHosts.Count -gt 0) { $skips += "$($collectorHosts.Count) collector host(s)" }
$msg = "Devices found: $($allDevices.Count)"
if ($skips) { $msg += " (skipped: " + ($skips -join ', ') + "; $($devices.Count) to test)" }
Write-Host $msg

if ($collectorHosts.Count -gt 0) {
    Write-Host ""
    Write-Host "Skipped (collector host - monitored from itself, not cross-tested):"
    foreach ($ch in ($collectorHosts | Sort-Object displayName)) {
        Write-Host "  - $($ch.displayName) ($($ch.name)) [id=$($ch.id)]"
    }
    if ($group -and $group.autoBalance) {
        Write-Warning ("$($collectorHosts.Count) collector host(s) are assigned to auto-balance group " +
                       "'$($group.name)' (id=$GroupId). Collector hosts should be pinned to their own " +
                       "collector, not auto-balanced - review their preferred collector group.")
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
$null = New-Item -ItemType Directory -Force -Path $OutputDir

# ── Submit to all collectors, wait once, then retrieve ────────────────────────
# -IncludeResult times out before the Groovy pool.awaitTermination (120s), so we
# use the submit / wait / retrieve pattern instead.
Write-Host "Submitting to $($collectors.Count) collectors..."
$jobs = foreach ($col in $collectors) {
    $r = Invoke-LMCollectorDebugCommand -Id $col.id -GroovyCommand $groovyScript
    Write-Host "  -> $($col.hostname) (id=$($col.id)) session=$($r.SessionId)"
    [PSCustomObject]@{
        Hostname  = $col.hostname
        Id        = $col.id
        SessionId = $r.SessionId
    }
}

Write-Host "Waiting ${WaitSeconds}s for Groovy scripts to complete..."
Start-Sleep -Seconds $WaitSeconds

Write-Host "Collecting results..."
foreach ($job in $jobs) {
    $result   = Get-LMCollectorDebugResult -SessionId $job.SessionId -Id $job.Id
    $safeName = $job.Hostname -replace '[\\/:*?"<>|]', '_'
    $outFile  = Join-Path $OutputDir "${safeName}.csv"

    # Get-LMCollectorDebugResult returns the command output TEXT directly (the module
    # does `Return $Response.output`) — NOT an object with an .output property. Handle a
    # plain string, an object that still carries .output, and string[], so the retrieval
    # is robust across module versions.
    $text = if ($result -is [string]) {
        $result
    } elseif ($result -and $result.PSObject.Properties['output']) {
        [string]$result.output
    } else {
        ($result | Out-String)
    }

    if (-not [string]::IsNullOrWhiteSpace($text)) {
        $text | Set-Content $outFile
        Write-Host "  Saved: $outFile"
    } else {
        Write-Warning "  No output for $($job.Hostname) (session $($job.SessionId)) - not ready or expired"
    }
}

Write-Host "Done. Results in: $(Resolve-Path $OutputDir)"
