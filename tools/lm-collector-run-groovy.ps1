#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Run an arbitrary Groovy script on one or more LM collectors via Collector Debug,
    and print (and optionally save) each collector's output.

.DESCRIPTION
    A generic sibling to lm-collector-reachability-run-all.ps1. That script is
    purpose-built (it discovers a group's devices, builds a reachability matrix, and
    embeds one fixed Groovy script). This one keeps the proven submit / poll / collect
    core but runs ANY Groovy file you give it, against ANY collector(s) you name.

    Self-contained: uses ONLY the Logic.Monitor PowerShell module (one Connect-LMAccount
    connection). No elm, bash, jq or jinja2 required.

    Workflow:
      1. Load the Groovy source from -Script, or pick one interactively from the *.groovy
         files in the current directory.
      2. Resolve targets: collectors named with -Collector (id / hostname / description)
         and/or the collectors that -Device devices currently run on.
      3. Submit the Groovy to every target collector via Collector Debug.
      4. Poll, and print each collector's output as soon as it is ready. Optionally also
         save it to a file (-OutputDir per-collector, or -OutFile for a single target).

    The Groovy is sent verbatim - there is NO templating or variable substitution.

.PARAMETER Script
    Path to the .groovy file to run. If omitted, the *.groovy files in the current
    directory are listed and you are prompted to pick one. A non-.groovy extension is a
    warning, not an error (any text file is accepted).

.PARAMETER Collector
    One or more collectors to run on, by numeric id, hostname, or description. Accepts a
    comma-separated list or the parameter repeated. Collector hostnames are usually the
    'DOMAIN\HOSTNAME' or FQDN form, so a bare name is matched as an unambiguous substring.

.PARAMETER Device
    One or more device names. Each is resolved to the collector it currently runs on
    (the device's preferredCollectorId) and the Groovy is run there. By default the script
    is sent verbatim - the collector has no device bound, so 'hostProps' is empty. Add
    -WithHostProps to run device-scoped scripts (see below).

.PARAMETER WithHostProps
    Only meaningful with -Device. Fetches each device's properties via the API and injects a
    'hostProps' binding into the Groovy (after its imports) so scripts that read
    hostProps.get('...') resolve against that device's properties. Each device becomes its own
    run (two devices on one collector run twice, named per device). NOTE: the REST API masks
    secret properties (passwords, tokens) as '********', so this confirms which properties are
    *set* but does not reveal secret values the way a real datasource run on the collector would.

.PARAMETER OutputDir
    If set, write each run's output to <OutputDir>/<label>.txt INSTEAD of echoing it to the
    screen (<label> is the collector hostname, or the device name with -WithHostProps). A
    per-run header and a "saved" line are still shown so you can follow progress. The
    directory is created if it does not exist.

.PARAMETER OutFile
    Single-target convenience: write the one collector's output to this file. If more than
    one target resolves, this is ignored with a warning and per-collector files are written
    to the file's parent directory instead.

.PARAMETER WaitSeconds
    Maximum seconds to poll for results before giving up. Polling prints each result as soon
    as it is ready, so this is a cap, not a fixed wait. Defaults to 180.

.PARAMETER NoColor
    Disable the ANSI colour on the per-collector header.

.EXAMPLE
    ./lm-collector-run-groovy.ps1 -Script hello.groovy -Collector 42
    Run hello.groovy on collector id 42 and print the output.

.EXAMPLE
    ./lm-collector-run-groovy.ps1 -Collector newedge02,newedge03
    Pick a *.groovy from the current directory and run it on two collectors (matched by
    substring), printing both outputs.

.EXAMPLE
    ./lm-collector-run-groovy.ps1 -Script probe.groovy -Device db-prod-01 -OutFile probe.txt
    Resolve db-prod-01 to its current collector, run probe.groovy there, and save the output.

.EXAMPLE
    ./lm-collector-run-groovy.ps1 -Script credential-check.groovy -Device db-prod-01 -WithHostProps
    Run a device-scoped script (one that reads hostProps) against db-prod-01's properties on its
    collector. Secret property values come back masked as '********'.

.EXAMPLE
    ./lm-collector-run-groovy.ps1 -Script probe.groovy -Collector a,b -OutputDir ./out
    Run on collectors a and b; screen output plus out/<a>.txt and out/<b>.txt.

.NOTES
    Prerequisite: the Logic.Monitor module loaded and Connect-LMAccount already called for
    the target portal. There is no -profile flag - the portal is whatever you connected to.

    Collector Debug (running Groovy on a collector) requires a Manage-level API token; a
    read-only token returns "Access denied. Your API credentials do not have sufficient
    permissions."

    Collector Debug returns nothing until the script finishes, then wraps the result in a
    "returns <n> / output:" envelope - which is non-empty even when the script printed nothing,
    so completion is always detected. That envelope is stripped from what you see and save, so
    you get only the script's own stdout (an empty result if it printed nothing).

    Unless -OutputDir is set, each run's Groovy output goes to the pipeline (success stream)
    while status lines, the per-run header and "saved" notices go to the host, so they do not
    pollute a pipe. You can therefore pipe results, e.g.
        ./lm-collector-run-groovy.ps1 -Script probe.groovy -Collector 42 | Select-String ERROR
    With -OutputDir the output is written to files instead of the pipeline/screen.
#>
[CmdletBinding()]
param(
    [string]$Script,                    # path to the .groovy file; omitted -> interactive picker

    [string[]]$Collector,               # collectors by id / hostname / description
    [string[]]$Device,                  # device names; resolved to their current collector
    [switch]$WithHostProps,             # for -Device: inject the device's hostProps into the Groovy

    [string]$OutputDir,                 # also save <hostname>.txt per collector here
    [string]$OutFile,                   # single-target convenience: save the one output here
    [int]$WaitSeconds = 180,            # poll cap; output is printed as soon as it is ready

    [switch]$NoColor                    # disable the per-collector header colour
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
# a multi-line "ensure you are logged in" error.
$lmStatus = Get-LMAccountStatus
if ($null -eq $lmStatus -or $lmStatus -is [string]) {
    Stop-WithMessage ("Not connected to a LogicMonitor portal. Run Connect-LMAccount " +
                      "(or your connection wrapper) first, then re-run.")
}

if (-not $Collector -and -not $Device) {
    Stop-WithMessage ("Nothing to target. Pass -Collector <id|name[,...]> and/or " +
                      "-Device <name[,...]> to choose where the Groovy runs.")
}

# ── Load Groovy source (explicit path, or interactive picker) ─────────────────
if ($Script) {
    if (Test-Path -LiteralPath $Script -PathType Container) {
        $inDir = @(Get-ChildItem -LiteralPath $Script -File -Filter *.groovy -ErrorAction SilentlyContinue | Sort-Object Name)
        $listing = if ($inDir.Count) {
            "  .groovy files in it: " + (($inDir | ForEach-Object { $_.Name }) -join ', ')
        } else {
            "  (it contains no *.groovy files)"
        }
        Stop-WithMessage "'$Script' is a directory, not a file - point -Script at a file inside it.`n$listing"
    }
    if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) {
        Stop-WithMessage "Groovy script not found: $Script"
    }
    if ([System.IO.Path]::GetExtension($Script) -ne '.groovy') {
        Write-Warning "'$Script' does not end in .groovy - sending its contents anyway."
    }
    $scriptPath = $Script
} else {
    $candidates = @(Get-ChildItem -File -Filter *.groovy | Sort-Object Name)
    if ($candidates.Count -eq 0) {
        Stop-WithMessage ("No *.groovy files in the current directory. Pass -Script <path> " +
                          "to point at one explicitly.")
    }
    Write-Host "Groovy scripts in $(Get-Location):"
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $candidates[$i].Name)
    }
    $sel = $null
    while ($null -eq $sel) {
        $answer = Read-Host "Select a script (1-$($candidates.Count))"
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $candidates.Count) {
            $sel = [int]$answer
        } else {
            Write-Host "Enter a number between 1 and $($candidates.Count)." -ForegroundColor Yellow
        }
    }
    $scriptPath = $candidates[$sel - 1].FullName
}
$groovyScript = Get-Content -LiteralPath $scriptPath -Raw
if ([string]::IsNullOrWhiteSpace($groovyScript)) {
    Stop-WithMessage "Groovy file is empty: $scriptPath - nothing to run."
}
Write-Host "Script:      $scriptPath"

# ── Collector list (fetched once) ─────────────────────────────────────────────
# -BatchSize 1000 forces full pagination (older module versions can default to 50).
$allCollectors = Get-LMCollector -BatchSize 1000

# Resolve one collector token to a collector object: numeric -> id; otherwise exact
# hostname/description (case-insensitive), then an unambiguous substring match so a bare
# name like 'newedge03' still resolves from 'CORP\NEWEDGE03' or an FQDN. Returns $null
# (after a warning) when it cannot resolve unambiguously, so the caller can skip it.
function Resolve-Collector {
    param([string]$Token, [object[]]$All)

    if ($Token -match '^\d+$') {
        $exact = @($All | Where-Object { $_.id -eq [int]$Token })
        if ($exact.Count -eq 1) { return $exact[0] }
        Write-Warning "Collector id $Token not found."
        return $null
    }

    $exact = @($All | Where-Object { $_.hostname -eq $Token -or $_.description -eq $Token })
    if ($exact.Count -eq 1) { return $exact[0] }
    if ($exact.Count -gt 1) {
        Write-Warning "'$Token' matched $($exact.Count) collectors exactly - use the numeric id."
        return $null
    }

    $partial = @($All | Where-Object { $_.hostname -like "*$Token*" -or $_.description -like "*$Token*" })
    if ($partial.Count -eq 1) {
        Write-Host "Collector '$Token' resolved to '$($partial[0].hostname)' (id=$($partial[0].id)) by partial match."
        return $partial[0]
    }
    if ($partial.Count -gt 1) {
        $names = ($partial | ForEach-Object { "$($_.hostname) (id=$($_.id))" }) -join ', '
        Write-Warning "'$Token' matched no collector exactly and $($partial.Count) partially ($names) - use the exact hostname or numeric id."
        return $null
    }
    Write-Warning "'$Token' not found - no collector hostname/description matches it."
    return $null
}

# ── Helpers for -WithHostProps (inject a device's hostProps into the Groovy) ──
# Quote a value as a Groovy single-quoted string literal. Groovy un-escapes \, ', \n inside
# single quotes, so backslashes/quotes are escaped and newlines normalised. ($ is NOT special
# in a single-quoted Groovy string, so values containing $ need no escaping.)
function ConvertTo-GroovyString {
    param([string]$Value)
    if ($null -eq $Value) { return "''" }
    $e = $Value.Replace('\', '\\').Replace("'", "\'").Replace("`r", '').Replace("`n", '\n')
    return "'$e'"
}

# Build a device's effective property map. Prefer the authoritative per-device endpoint
# (Get-LMDeviceProperty); fall back to the property collections on the device object.
function Get-DeviceHostPropMap {
    param([object]$Device)
    $map = [ordered]@{}
    $props = $null
    try { $props = @(Get-LMDeviceProperty -Id $Device.id -ErrorAction Stop) } catch { $props = $null }
    if ($props -and $props.Count) {
        foreach ($p in $props) { if ($p.name) { $map[[string]$p.name] = [string]$p.value } }
        return $map
    }
    foreach ($coll in 'systemProperties', 'autoProperties', 'inheritedProperties', 'customProperties') {
        foreach ($p in @($Device.$coll)) { if ($p.name) { $map[[string]$p.name] = [string]$p.value } }
    }
    return $map
}

# Insert 'hostProps = [ ... ]' into the Groovy. Two requirements:
#   * Groovy requires imports before any other statement, so the assignment goes AFTER the
#     last leading import/package line, not at the very top.
#   * It is a BINDING variable (no 'def'), so methods in the script (e.g. a printprop helper
#     that calls hostProps.get(...)) can see it - a script-local 'def' would be invisible to them.
function Add-HostProps {
    param([string]$Groovy, [System.Collections.IDictionary]$Props)
    $pairs = foreach ($k in $Props.Keys) { (ConvertTo-GroovyString $k) + ': ' + (ConvertTo-GroovyString $Props[$k]) }
    $mapLiteral = if ($pairs) { "hostProps = [`n    " + ($pairs -join ",`n    ") + "`n]" } else { "hostProps = [:]" }
    $banner = "// hostProps injected by lm-collector-run-groovy.ps1 -WithHostProps (binding var; secret values may be masked as ********)"
    $lines = $Groovy -split "`r?`n"
    $insertAt = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].TrimStart()
        if ($t -like 'import *' -or $t -like 'package *') { $insertAt = $i + 1 }
    }
    if ($insertAt -ge $lines.Count) {        # script is only imports/package (degenerate)
        return ($Groovy.TrimEnd() + "`n`n" + $banner + "`n" + $mapLiteral + "`n")
    }
    $head = if ($insertAt -gt 0) { (($lines[0..($insertAt - 1)]) -join "`n") + "`n" } else { '' }
    $tail = ($lines[$insertAt..($lines.Count - 1)]) -join "`n"
    return $head + $banner + "`n" + $mapLiteral + "`n`n" + $tail
}

# ── Resolve submissions (one entry = one Groovy run on one collector) ──────────
# A submission carries its own Script so -WithHostProps device runs can differ per device.
# Self-contained collector runs are de-duped by collector id; device runs by device id.
$submissions    = [System.Collections.Generic.List[object]]::new()
$seenCollectors = [System.Collections.Generic.HashSet[int]]::new()
$seenDevices    = [System.Collections.Generic.HashSet[int]]::new()

if ($WithHostProps -and -not $Device) {
    Write-Warning "-WithHostProps only applies to -Device targets; it has no effect on -Collector runs."
}

function Add-Submission {
    param([string]$Label, [object]$Col, [string]$Body, [string]$Why)
    if ($Col.status -ne 1) {
        Write-Warning "Collector '$($Col.hostname)' (id=$($Col.id)) is not active (status=$($Col.status)) - skipping ($Why)."
        return
    }
    $submissions.Add([PSCustomObject]@{
        Label             = $Label
        CollectorHostname = $Col.hostname
        CollectorId       = [int]$Col.id
        Script            = $Body
    })
}

foreach ($token in $Collector) {
    $col = Resolve-Collector -Token $token -All $allCollectors
    if (-not $col) { continue }
    if (-not $seenCollectors.Add([int]$col.id)) { continue }   # this script already runs there
    Add-Submission -Label $col.hostname -Col $col -Body $groovyScript -Why "named with -Collector"
}

foreach ($name in $Device) {
    # Resolve by the human-facing displayName first, then by the address-level name. Both use
    # -Filter (the parameter the reference script proves works across module versions) rather
    # than -Name, whose presence varies and would raise a binding error -ErrorAction can't suppress.
    $dev = Get-LMDevice -Filter "displayName -eq `"$name`"" -ErrorAction SilentlyContinue
    if (-not $dev) { $dev = Get-LMDevice -Filter "name -eq `"$name`"" -ErrorAction SilentlyContinue }
    $dev = @($dev)
    if ($dev.Count -eq 0) { Write-Warning "Device '$name' not found - skipping."; continue }
    if ($dev.Count -gt 1) { Write-Warning "Device '$name' matched $($dev.Count) devices - skipping (be more specific)."; continue }
    $d = $dev[0]
    if (-not $seenDevices.Add([int]$d.id)) { continue }
    # preferredCollectorId is the collector currently assigned to a device (elm-notes.yaml).
    $colId = $d.preferredCollectorId
    if (-not $colId) { Write-Warning "Device '$name' (id=$($d.id)) has no preferredCollectorId - skipping."; continue }
    $col = @($allCollectors | Where-Object { $_.id -eq [int]$colId })
    if ($col.Count -ne 1) { Write-Warning "Device '$name' points at collector id $colId, which was not found - skipping."; continue }

    if ($WithHostProps) {
        $props = Get-DeviceHostPropMap -Device $d
        $body  = Add-HostProps -Groovy $groovyScript -Props $props
        Write-Host "Device '$($d.displayName)' (id=$($d.id)) on collector '$($col[0].hostname)' (id=$($col[0].id)) - injected $($props.Count) hostProps."
        Add-Submission -Label $d.displayName -Col $col[0] -Body $body -Why "device '$name' (-WithHostProps)"
    } else {
        # No hostProps wanted: de-dupe self-contained runs by collector, same as -Collector.
        if (-not $seenCollectors.Add([int]$col[0].id)) {
            Write-Host "Device '$($d.displayName)' runs on collector '$($col[0].hostname)' (id=$($col[0].id)) - already targeted, skipping duplicate run."
            continue
        }
        Write-Host "Device '$($d.displayName)' (id=$($d.id)) runs on collector '$($col[0].hostname)' (id=$($col[0].id))."
        Add-Submission -Label $col[0].hostname -Col $col[0] -Body $groovyScript -Why "current collector of device '$name'"
    }
}

if ($submissions.Count -eq 0) {
    Stop-WithMessage "No active targets resolved from -Collector / -Device. Nothing to run."
}
Write-Host "Targets:     $($submissions.Count) run(s)"

# ── Output destination ────────────────────────────────────────────────────────
# -OutFile is single-target only; with multiple targets fall back to per-collector files
# in its parent directory so no output is silently dropped.
if ($OutFile -and $submissions.Count -gt 1) {
    $OutputDir = Split-Path -Parent $OutFile
    if (-not $OutputDir) { $OutputDir = '.' }
    Write-Warning "-OutFile is for a single target but $($submissions.Count) resolved; writing per-run files to '$OutputDir' instead."
    $OutFile = $null
}
# -OutputDir takes precedence over -OutFile when both are given, so the per-collector
# files are the single source of truth and nothing is written twice.
if ($OutputDir -and $OutFile) {
    Write-Warning "-OutputDir and -OutFile both set; -OutputDir wins (per-collector files), -OutFile ignored."
    $OutFile = $null
}
if ($OutputDir) {
    $null = New-Item -ItemType Directory -Force -Path $OutputDir
    $OutputDir = (Resolve-Path $OutputDir).Path   # absolute, so the run output shows clean filenames
    Write-Host "Output dir:  $OutputDir"
}

# ── Submit to every target ────────────────────────────────────────────────────
# Invoke-LMCollectorDebugCommand submits the Groovy and returns a SessionId; results are
# retrieved separately because -IncludeResult would time out before a long Groovy finishes.
Write-Host "Submitting $($submissions.Count) run(s)..."
$jobs = foreach ($s in $submissions) {
    $tag = if ($s.Label -ne $s.CollectorHostname) { " ($($s.Label))" } else { "" }
    try {
        $r = Invoke-LMCollectorDebugCommand -Id $s.CollectorId -GroovyCommand $s.Script -ErrorAction Stop
        Write-Host "  -> $($s.CollectorHostname) (id=$($s.CollectorId))$tag"
        [PSCustomObject]@{
            Label             = $s.Label
            CollectorHostname = $s.CollectorHostname
            CollectorId       = $s.CollectorId
            SessionId         = $r.SessionId
        }
    } catch {
        Write-Warning "  Submit failed for $($s.CollectorHostname) (id=$($s.CollectorId))${tag}: $($_.Exception.Message)"
    }
}
$jobs = @($jobs)
if ($jobs.Count -eq 0) {
    throw ("No debug sessions were created. The most common cause is insufficient LM permissions: " +
           "running Collector Debug commands requires an account/API token whose role grants 'Manage' " +
           "rights on collectors (remote debug). Verify the credentials used to connect the LM session.")
}

# Get-LMCollectorDebugResult returns the command output TEXT directly (the module does
# `Return $Response.output`) - NOT an object with an .output property - and `output` stays
# empty until the Groovy completes, so non-empty output means "done". Handle a plain
# string, an object that still carries .output, and string[], for robustness across
# module versions.
function Get-DebugText($result) {
    if ($result -is [string]) { return $result }
    if ($result -and $result.PSObject.Properties['output']) { return [string]$result.output }
    return ($result | Out-String)
}

# Collector Debug wraps every result in a 2-line envelope before the script's own output:
#     returns <n>
#     output:
#     <the script's stdout...>
# Strip that leading envelope so callers get only the script's output (no added metadata).
# Anchored at the start and matched defensively, so a result in a different shape - or the
# script's own text that happens to contain 'output:' later - is left untouched. NOTE: the
# completion check must run on the RAW text (the envelope is non-empty even when the script
# printed nothing), so only strip the value that is displayed/saved, never the done-check.
function Remove-DebugEnvelope([string]$Text) {
    return ($Text -replace '^\s*returns\s+-?\d+\r?\noutput:\r?\n?', '')
}

# ── Colour gate for the per-collector header ──────────────────────────────────
# Honour -NoColor and the NO_COLOR convention, and skip colour when stdout is redirected.
$script:useColor = -not $NoColor -and [string]::IsNullOrEmpty($env:NO_COLOR) -and -not [Console]::IsOutputRedirected

# ── Poll, and print each result as soon as it is ready ────────────────────────
Write-Host "Polling for results (up to ${WaitSeconds}s)..."
$pending  = [System.Collections.Generic.List[object]]::new()
$jobs | ForEach-Object { $pending.Add($_) }
$deadline = (Get-Date).AddSeconds($WaitSeconds)

while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    foreach ($job in @($pending)) {
        # Check completion on the RAW result (the envelope is non-empty even for a script that
        # printed nothing); strip the envelope only from the value shown/saved.
        $raw = Get-DebugText (Get-LMCollectorDebugResult -SessionId $job.SessionId -Id $job.CollectorId)
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $text = Remove-DebugEnvelope $raw
            $header = if ($job.Label -ne $job.CollectorHostname) {
                "==== $($job.Label) @ $($job.CollectorHostname) (id=$($job.CollectorId)) ===="
            } else {
                "==== $($job.CollectorHostname) (id=$($job.CollectorId)) ===="
            }
            Write-Host ""
            if ($script:useColor) {
                $esc = [char]27
                Write-Host "$esc[36m$header$esc[0m"   # cyan
            } else {
                Write-Host $header
            }
            if ($OutputDir) {
                # Saving to per-run files: write to disk only, do NOT echo the content to the
                # screen. The header above and the "saved" line below are the on-screen record.
                $safeName = $job.Label -replace '[\\/:*?"<>|]', '_'
                $dest     = Join-Path $OutputDir "${safeName}.txt"
                $text | Set-Content $dest
                Write-Host "  saved $dest"
            } else {
                # No -OutputDir: emit the output to the success stream so it can be piped/captured
                # (the header/notices stay on the host stream). -OutFile also keeps a copy on disk.
                Write-Output $text
                if ($OutFile) {
                    $text | Set-Content $OutFile
                    Write-Host "  saved $OutFile"
                }
            }
            [void]$pending.Remove($job)
        }
    }
}

foreach ($job in $pending) {
    Write-Warning "No output for $($job.Label) on $($job.CollectorHostname) (session $($job.SessionId)) - timed out after ${WaitSeconds}s"
}

Write-Host ""
Write-Host "Done. $($jobs.Count - $pending.Count) of $($jobs.Count) run(s) returned results."

