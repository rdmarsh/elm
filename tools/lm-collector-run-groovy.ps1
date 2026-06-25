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
    (the device's preferredCollectorId) and that collector is added to the targets.

.PARAMETER OutputDir
    If set, also write each collector's output to <OutputDir>/<hostname>.txt (in addition
    to the screen). The directory is created if it does not exist.

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
    ./lm-collector-run-groovy.ps1 -Script probe.groovy -Collector a,b -OutputDir ./out
    Run on collectors a and b; screen output plus out/<a>.txt and out/<b>.txt.

.NOTES
    Prerequisite: the Logic.Monitor module loaded and Connect-LMAccount already called for
    the target portal. There is no -profile flag - the portal is whatever you connected to.

    Collector Debug (running Groovy on a collector) requires a Manage-level API token; a
    read-only token returns "Access denied. Your API credentials do not have sufficient
    permissions."

    Your Groovy MUST print something (e.g. end it with `println "done"`). Collector Debug
    returns an empty result until the script finishes, and a script that completes without
    printing is indistinguishable from one still running - it will appear to "time out" and
    warn "No output" after -WaitSeconds. Print at least one line so completion is detected.

    Each collector's Groovy output goes to the pipeline (success stream); status lines, the
    per-collector header and "saved" notices go to the host, so they do not pollute a pipe.
    You can therefore pipe results, e.g.
        ./lm-collector-run-groovy.ps1 -Script probe.groovy -Collector 42 | Select-String ERROR
#>
[CmdletBinding()]
param(
    [string]$Script,                    # path to the .groovy file; omitted -> interactive picker

    [string[]]$Collector,               # collectors by id / hostname / description
    [string[]]$Device,                  # device names; resolved to their current collector

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

# ── Resolve targets (union of -Collector and -Device collectors, de-duped by id) ──
$targets    = [System.Collections.Generic.List[object]]::new()
$seenIds    = [System.Collections.Generic.HashSet[int]]::new()

function Add-Target {
    param([object]$Col, [string]$Why)
    if ($Col.status -ne 1) {
        Write-Warning "Collector '$($Col.hostname)' (id=$($Col.id)) is not active (status=$($Col.status)) - skipping ($Why)."
        return
    }
    if ($seenIds.Add([int]$Col.id)) {
        $targets.Add([PSCustomObject]@{ Hostname = $Col.hostname; Id = [int]$Col.id })
    }
}

foreach ($token in $Collector) {
    $col = Resolve-Collector -Token $token -All $allCollectors
    if ($col) { Add-Target -Col $col -Why "named with -Collector" }
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
    # preferredCollectorId is the collector currently assigned to a device (elm-notes.yaml).
    $colId = $d.preferredCollectorId
    if (-not $colId) { Write-Warning "Device '$name' (id=$($d.id)) has no preferredCollectorId - skipping."; continue }
    $col = @($allCollectors | Where-Object { $_.id -eq [int]$colId })
    if ($col.Count -ne 1) { Write-Warning "Device '$name' points at collector id $colId, which was not found - skipping."; continue }
    Write-Host "Device '$($d.displayName)' (id=$($d.id)) runs on collector '$($col[0].hostname)' (id=$($col[0].id))."
    Add-Target -Col $col[0] -Why "current collector of device '$name'"
}

if ($targets.Count -eq 0) {
    Stop-WithMessage "No active target collectors resolved from -Collector / -Device. Nothing to run."
}
Write-Host "Targets:     $($targets.Count) collector(s)"

# ── Output destination ────────────────────────────────────────────────────────
# -OutFile is single-target only; with multiple targets fall back to per-collector files
# in its parent directory so no output is silently dropped.
if ($OutFile -and $targets.Count -gt 1) {
    $OutputDir = Split-Path -Parent $OutFile
    if (-not $OutputDir) { $OutputDir = '.' }
    Write-Warning "-OutFile is for a single target but $($targets.Count) resolved; writing per-collector files to '$OutputDir' instead."
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
Write-Host "Submitting to $($targets.Count) collector(s)..."
$jobs = foreach ($t in $targets) {
    try {
        $r = Invoke-LMCollectorDebugCommand -Id $t.Id -GroovyCommand $groovyScript -ErrorAction Stop
        Write-Host "  -> $($t.Hostname) (id=$($t.Id))"
        [PSCustomObject]@{ Hostname = $t.Hostname; Id = $t.Id; SessionId = $r.SessionId }
    } catch {
        Write-Warning "  Submit failed for $($t.Hostname) (id=$($t.Id)): $($_.Exception.Message)"
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
        $text = Get-DebugText (Get-LMCollectorDebugResult -SessionId $job.SessionId -Id $job.Id)
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $header = "==== $($job.Hostname) (id=$($job.Id)) ===="
            Write-Host ""
            if ($script:useColor) {
                $esc = [char]27
                Write-Host "$esc[36m$header$esc[0m"   # cyan
            } else {
                Write-Host $header
            }
            # The actual Groovy output goes to the success stream so it can be piped/captured;
            # the header above and the "saved" notice below stay on the host stream.
            Write-Output $text

            if ($OutputDir) {
                $safeName = $job.Hostname -replace '[\\/:*?"<>|]', '_'
                $dest     = Join-Path $OutputDir "${safeName}.txt"
                $text | Set-Content $dest
                Write-Host "  saved $dest"
            } elseif ($OutFile) {
                $text | Set-Content $OutFile
                Write-Host "  saved $OutFile"
            }
            [void]$pending.Remove($job)
        }
    }
}

foreach ($job in $pending) {
    Write-Warning "No output for $($job.Hostname) (session $($job.SessionId)) - timed out after ${WaitSeconds}s"
}

Write-Host ""
Write-Host "Done. $($jobs.Count - $pending.Count) of $($jobs.Count) collector(s) returned results."

