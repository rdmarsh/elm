#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Run a Groovy script, a PowerShell script, or any Collector Debug command on one or more
    LM collectors via Collector Debug, and print (and optionally save) each collector's output.

.DESCRIPTION
    A generic sibling to lm-collector-reach.ps1. That script is purpose-built (it discovers
    devices, builds a reachability matrix, and embeds one fixed Groovy script). This one keeps
    the proven submit / poll / collect core but runs ANY script or debug command you give it,
    against ANY collector(s) you name.

    Self-contained: uses ONLY the Logic.Monitor PowerShell module (one Connect-LMAccount
    connection). No elm, bash, jq or jinja2 required.

    Workflow:
      1. Load the script from -Script (.groovy, or .ps1 for PowerShell), or pick one
         interactively from the *.groovy / *.ps1 files in the current directory. With
         -Command, send that debug command instead; with -Interactive, prompt for commands.
      2. Resolve targets: collectors named with -Collector (id / hostname / description),
         every active collector in each -Group, and/or the collectors that -Device devices
         currently run on.
      3. Submit the script (or -Command) to every target collector via Collector Debug.
      4. Poll, and print each collector's output as soon as it is ready. Optionally also
         save it to a file (-OutputDir per-collector, or -OutFile for a single target).

    The script is sent verbatim - there is NO templating or variable substitution.

    PowerShell scripts run only on Windows collectors (the collector runs them with its own
    Windows PowerShell); Linux collectors are skipped with a warning. Groovy runs on both.

.PARAMETER Command
    A Collector Debug command to send as-is instead of a script file - the same text you
    would type in the portal's debug window, e.g. '!wmi h=10.0.0.5 SELECT Caption FROM
    Win32_OperatingSystem', '!ping 10.0.0.5' or '!tlist'. Must start with '!', or be the
    console's own 'help' / 'help !command'. Cannot be
    combined with -Script or -WithHostProps. Quote it in single quotes so PowerShell leaves
    it alone.

.PARAMETER Interactive
    Open a prompt instead of running one thing: each debug command you type runs on every
    target collector and each one's output is shown, then it prompts again. 'help' lists the
    commands; 'exit' (or Ctrl+C) quits. Cannot be combined with -Script, -Command,
    -WithHostProps, -OutputDir or -OutFile.

.PARAMETER Script
    Path to the script to run. A .ps1 file is sent as PowerShell (!posh); anything else is
    sent as Groovy (!groovy), with a warning if it does not end in .groovy. If omitted, the
    *.groovy and *.ps1 files in the current directory are listed and you are prompted to pick
    one. Example scripts live in tools/groovy/.

.PARAMETER Collector
    One or more collectors to run on, by numeric id, hostname, or description. Accepts a
    comma-separated list or the parameter repeated. Collector hostnames are usually the
    'DOMAIN\HOSTNAME' or FQDN form, so a bare name is matched as an unambiguous substring.

.PARAMETER Group
    One or more collector groups, by numeric id or exact name (case-insensitive). Runs on
    every active collector in each group; each result header names the group. Handy for
    "which group can reach this device?" with -Command.

.PARAMETER Device
    One or more devices, by id or name (display name, or the address LM uses). Each is
    resolved to the collector it currently runs on (the device's preferredCollectorId) and
    the script is run there. By default the script
    is sent verbatim - the collector has no device bound, so 'hostProps' is empty. Add
    -WithHostProps to run device-scoped scripts (see below).

.PARAMETER WithHostProps
    Only meaningful with -Device, and Groovy only. Loads the device's properties ON THE COLLECTOR via
    CollectorDb.getInstance().getHost(name).getProperties() and binds them as 'hostProps' so
    your script - including helper methods that call hostProps.get(...) - can read them. (Sent
    as a raw !groovy via -DebugCommand and assigned WITHOUT 'def', because the module's own
    -GroovyCommand preamble uses a script-local 'def hostProps' that methods cannot see.) Each
    device becomes its own run (two devices on one collector run twice, named per device).
    Because the collector reads its own host database, the values are the real ones it uses to
    monitor. Caution: output can contain sensitive values in clear text, so prefer -OutputDir
    to a file you control rather than leaving it on screen or in a pipe.

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
    ./lm-collector-debug.ps1 -Group "Site A" -Interactive
    A debug prompt on every collector in the group: type '!ping 10.0.0.5' and see each
    collector's answer, then the next command.

.EXAMPLE
    ./lm-collector-debug.ps1 -Script groovy/hello.groovy -Collector 42
    Run hello.groovy on collector id 42 and print the output.

.EXAMPLE
    ./lm-collector-debug.ps1 -Script services.ps1 -Group "Site A"
    Run a PowerShell script on every active Windows collector in a group (Linux ones are
    skipped with a warning).

.EXAMPLE
    ./lm-collector-debug.ps1 -Collector newedge02,newedge03
    Pick a *.groovy or *.ps1 from the current directory and run it on two collectors (matched by
    substring), printing both outputs.

.EXAMPLE
    ./lm-collector-debug.ps1 -Script probe.groovy -Device db-prod-01 -OutFile probe.txt
    Resolve db-prod-01 to its current collector, run probe.groovy there, and save the output.

.EXAMPLE
    ./lm-collector-debug.ps1 -Script credential-check.groovy -Device db-prod-01 -WithHostProps
    Run a device-scoped script (one that reads hostProps) against db-prod-01's properties on its
    collector. The collector loads the host's real properties. Caution: output can contain
    sensitive values in clear text, so save to a file you control (-OutputDir) rather than to screen.

.EXAMPLE
    ./lm-collector-debug.ps1 -Group "Site A","Site B" -Command '!wmi h=10.0.0.5 SELECT Caption FROM Win32_OperatingSystem'
    Send one WMI query from every active collector in two groups, to see which group can
    monitor the device (for auto-balance, pick a group where every collector answers).

.EXAMPLE
    ./lm-collector-debug.ps1 -Script probe.groovy -Collector a,b -OutputDir ./out
    Run on collectors a and b; screen output plus out/<a>.txt and out/<b>.txt.

.NOTES
    Prerequisite: the Logic.Monitor module loaded and Connect-LMAccount already called for
    the target portal. There is no -profile flag - the portal is whatever you connected to.

    Collector Debug (running scripts or commands on a collector) requires a Manage-level API token; a
    read-only token returns "Access denied. Your API credentials do not have sufficient
    permissions."

    Collector Debug returns nothing until the script finishes, then wraps the result in a
    "returns <n> / output:" envelope - which is non-empty even when the script printed nothing,
    so completion is always detected. That envelope is stripped from what you see and save, so
    you get only the script's own stdout (an empty result if it printed nothing).

    Unless -OutputDir is set, each run's output goes to the pipeline (success stream)
    while status lines, the per-run header and "saved" notices go to the host, so they do not
    pollute a pipe. You can therefore pipe results, e.g.
        ./lm-collector-debug.ps1 -Script probe.groovy -Collector 42 | Select-String ERROR
    With -OutputDir the output is written to files instead of the pipeline/screen.
#>
[CmdletBinding()]
param(
    [string]$Script,                    # .groovy or .ps1 file; omitted -> interactive picker
    [string]$Command,                   # a debug command (e.g. '!wmi h=...') sent as-is instead
    [switch]$Interactive,               # prompt for debug commands, run each on every target

    [string[]]$Collector,               # collectors by id / hostname / description
    [string[]]$Group,                   # collector groups by id / name; all active collectors
    [string[]]$Device,                  # device names; resolved to their current collector
    [switch]$WithHostProps,             # for -Device: load the device's real hostProps on the collector

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

if (-not $Collector -and -not $Group -and -not $Device) {
    Show-Usage ("./lm-collector-debug.ps1 [-Script FILE | -Command '!...' | -Interactive] " +
                "-Collector ID|NAME[,...] | -Group ID|NAME[,...] | -Device NAME[,...] " +
                "[-WithHostProps] [-OutputDir DIR | -OutFile FILE] [-WaitSeconds N]")
}

# The debug console takes '!command ...' or its own 'help' / 'help !command'.
function Test-DebugCommand([string]$Text) {
    $t = $Text.TrimStart()
    return $t.StartsWith('!') -or $t -match '^help(\s|$)'
}

# ── Load the script (explicit path, or interactive picker), -Command, or -Interactive ──
# Script files the picker and the directory hint offer: Groovy, and PowerShell (.ps1) other
# than this script itself.
function Get-ScriptFiles([string]$Dir) {
    @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.groovy', '.ps1' -and $_.FullName -ne $PSCommandPath } |
        Sort-Object Name)
}

if ($Interactive) {
    if ($Script -or $Command)     { Stop-WithMessage "-Interactive takes commands at its prompt; leave out -Script and -Command." }
    if ($WithHostProps)           { Stop-WithMessage "-WithHostProps only applies to Groovy scripts, not -Interactive." }
    if ($OutputDir -or $OutFile)  { Stop-WithMessage "-Interactive shows output on screen; leave out -OutputDir and -OutFile." }
} elseif ($Command) {
    if ($Script)        { Stop-WithMessage "Pass -Script or -Command, not both." }
    if ($WithHostProps) { Stop-WithMessage "-WithHostProps only applies to Groovy scripts, not -Command." }
    if (-not (Test-DebugCommand $Command)) {
        Stop-WithMessage "Debug commands start with '!' (e.g. '!wmi h=10.0.0.5 SELECT Caption FROM Win32_OperatingSystem'), or are 'help'."
    }
} elseif ($Script) {
    if (Test-Path -LiteralPath $Script -PathType Container) {
        $inDir = Get-ScriptFiles $Script
        $listing = if ($inDir.Count) {
            "  scripts in it: " + (($inDir | ForEach-Object { $_.Name }) -join ', ')
        } else {
            "  (it contains no *.groovy or *.ps1 files)"
        }
        Stop-WithMessage "'$Script' is a directory, not a file - point -Script at a file inside it.`n$listing"
    }
    if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) {
        Stop-WithMessage "Script not found: $Script"
    }
    if ([System.IO.Path]::GetExtension($Script) -notin '.groovy', '.ps1') {
        Write-Warning "'$Script' ends in neither .groovy nor .ps1 - sending its contents as Groovy anyway."
    }
    $scriptPath = $Script
} else {
    $candidates = Get-ScriptFiles (Get-Location).Path
    if ($candidates.Count -eq 0) {
        Stop-WithMessage ("No *.groovy or *.ps1 files in the current directory. Pass -Script <path> " +
                          "to point at one explicitly.")
    }
    Write-Host "Scripts in $(Get-Location):"
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
# A .ps1 is PowerShell, sent with -PoshCommand; everything else is Groovy.
$isPosh = -not $Command -and -not $Interactive -and [System.IO.Path]::GetExtension($scriptPath) -eq '.ps1'
if ($isPosh -and $WithHostProps) {
    Stop-WithMessage "-WithHostProps only applies to Groovy scripts; '$scriptPath' is PowerShell."
}
if ($Interactive) {
    Write-Host "Mode:        interactive"
} elseif ($Command) {
    Write-Host "Command:     $Command"
} else {
    $scriptText = Get-Content -LiteralPath $scriptPath -Raw
    if ([string]::IsNullOrWhiteSpace($scriptText)) {
        Stop-WithMessage "Script file is empty: $scriptPath - nothing to run."
    }
    Write-Host ("Script:      $scriptPath" + $(if ($isPosh) { " (PowerShell)" } else { "" }))
}

# ── Collector list (fetched once) ─────────────────────────────────────────────
# -BatchSize 1000 forces full pagination (older module versions can default to 50).
$allCollectors = Get-LMCollector -BatchSize 1000

# ── Resolve submissions (one entry = one script run on one collector) ──────────
# A submission carries its own HostName so -WithHostProps device runs can each load a
# different device's hostProps. Self-contained collector runs de-dupe by collector id;
# device runs by device id. With -WithHostProps the submit step wraps the script (see
# Build-HostPropsGroovy) so the collector loads that host's real properties via
# CollectorDb.getHost(name).getProperties() and binds them as hostProps - no client-side
# injection, so the values are the genuine ones the collector holds.
$submissions    = [System.Collections.Generic.List[object]]::new()
$seenCollectors = [System.Collections.Generic.HashSet[int]]::new()
$seenDevices    = [System.Collections.Generic.HashSet[int]]::new()

if ($WithHostProps -and -not $Device) {
    Write-Warning "-WithHostProps only applies to -Device targets; it has no effect on -Collector runs."
}

function Add-Submission {
    param([string]$Label, [object]$Col, [string]$HostName, [string]$Why, [string]$GroupName = '')
    if (-not (Test-CollectorUp $Col)) {
        Write-Warning "Collector '$($Col.hostname)' (id=$($Col.id)) is down - skipping ($Why)."
        return
    }
    # PowerShell only runs on Windows collectors (platform is 'windows' or 'linux').
    if ($isPosh -and $Col.platform -and $Col.platform -ne 'windows') {
        Write-Warning "Collector '$($Col.hostname)' (id=$($Col.id)) runs on $($Col.platform), which cannot run PowerShell - skipping ($Why)."
        return
    }
    $submissions.Add([PSCustomObject]@{
        Label             = $Label
        CollectorHostname = $Col.hostname
        CollectorId       = [int]$Col.id
        HostName          = $HostName   # device name for -CommandHostName; '' for plain runs
        GroupName         = $GroupName  # set for -Group runs; shown in the result header
    })
}

foreach ($token in $Collector) {
    $col = Resolve-Collector -Token $token -All $allCollectors
    if ($col -is [string]) { Write-Warning "$col - skipping."; continue }
    if (-not $seenCollectors.Add([int]$col.id)) { continue }   # this script already runs there
    Add-Submission -Label $col.hostname -Col $col -HostName '' -Why "named with -Collector"
}

if ($Group) {
    # -BatchSize 1000 forces full pagination (older module versions can default to 50).
    $allGroups = @(Get-LMCollectorGroup -BatchSize 1000)
}
foreach ($token in $Group) {
    $g = Resolve-CollectorGroup -Token $token -All $allGroups
    if ($g -is [string]) { Write-Warning "$g - skipping."; continue }
    $g = @($g)
    $members = @($allCollectors | Where-Object { $_.collectorGroupId -eq $g[0].id } | Sort-Object hostname)
    if ($members.Count -eq 0) { Write-Warning "Collector group '$($g[0].name)' (id=$($g[0].id)) has no collectors - skipping."; continue }
    Write-Host "Group '$($g[0].name)' (id=$($g[0].id)): $($members.Count) collector(s)."
    foreach ($col in $members) {
        if (-not $seenCollectors.Add([int]$col.id)) { continue }
        Add-Submission -Label $col.hostname -Col $col -HostName '' -Why "in group '$($g[0].name)'" -GroupName $g[0].name
    }
}

foreach ($name in $Device) {
    $d = Resolve-Device $name
    if ($d -is [string]) { Write-Warning "$d - skipping."; continue }
    if (-not $seenDevices.Add([int]$d.id)) { continue }
    # preferredCollectorId is the collector currently assigned to a device (elm-notes.yaml).
    $colId = $d.preferredCollectorId
    if (-not $colId) { Write-Warning "Device '$name' (id=$($d.id)) has no preferredCollectorId - skipping."; continue }
    $col = @($allCollectors | Where-Object { $_.id -eq [int]$colId })
    if ($col.Count -ne 1) { Write-Warning "Device '$name' points at collector id $colId, which was not found - skipping."; continue }

    if ($WithHostProps) {
        # Pass the device's name (the key CollectorDb.getHost expects) so the collector loads
        # this host's real hostProps. Each device is its own run (named per device).
        Write-Host "Device '$($d.displayName)' (id=$($d.id)) on collector '$($col[0].hostname)' (id=$($col[0].id)) - loading hostProps for host '$($d.name)'."
        Add-Submission -Label $d.displayName -Col $col[0] -HostName $d.name -Why "device '$name' (-WithHostProps)"
    } else {
        # No hostProps wanted: de-dupe self-contained runs by collector, same as -Collector.
        if (-not $seenCollectors.Add([int]$col[0].id)) {
            Write-Host "Device '$($d.displayName)' runs on collector '$($col[0].hostname)' (id=$($col[0].id)) - already targeted, skipping duplicate run."
            continue
        }
        Write-Host "Device '$($d.displayName)' (id=$($d.id)) runs on collector '$($col[0].hostname)' (id=$($col[0].id))."
        Add-Submission -Label $col[0].hostname -Col $col[0] -HostName '' -Why "current collector of device '$name'"
    }
}

if ($submissions.Count -eq 0) {
    Stop-WithMessage "No targets that are up, from -Collector / -Group / -Device. Nothing to run."
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

# Build a raw !groovy payload that loads a device's REAL hostProps on the collector and binds
# it so the user script - including any method that reads hostProps - can see it. Sent via
# -DebugCommand (raw passthrough), NOT -GroovyCommand: the module's -GroovyCommand preamble
# assigns hostProps with 'def' (a script-local), which methods cannot see (confirmed: main body
# saw 107 entries, a method saw 0). A binding assignment (no 'def') overrides the collector's
# default empty hostProps binding, so methods resolve the loaded value. Groovy requires imports
# first, so the user's import/package lines are hoisted above the assignment.
function Build-HostPropsGroovy {
    param([string]$Groovy, [string]$HostName)
    $esc = $HostName.Replace('\', '\\').Replace("'", "\'")
    $imports = [System.Collections.Generic.List[string]]::new()
    $body    = [System.Collections.Generic.List[string]]::new()
    foreach ($ln in ($Groovy -split "`r?`n")) {
        $t = $ln.TrimStart()
        if ($t -like 'import *' -or $t -like 'package *') { $imports.Add($ln) } else { $body.Add($ln) }
    }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('!groovy')
    [void]$sb.AppendLine('import com.santaba.agent.collector3.CollectorDb')
    foreach ($imp in $imports) { [void]$sb.AppendLine($imp) }
    # Binding assignment (no 'def') so methods see it; if the host cannot be loaded, leave the
    # collector's default hostProps in place and say why rather than failing the whole script.
    [void]$sb.AppendLine("try { hostProps = CollectorDb.getInstance().getHost('$esc').getProperties() }")
    [void]$sb.AppendLine("catch (Throwable _e) { println 'WARN: could not load hostProps for host ${esc}: ' + _e.message }")
    foreach ($b in $body) { [void]$sb.AppendLine($b) }
    return $sb.ToString()
}

# ── Colour gate for the per-collector header ──────────────────────────────────
# Honour -NoColor and the NO_COLOR convention, and skip colour when stdout is redirected.
$script:useColor = -not $NoColor -and [string]::IsNullOrEmpty($env:NO_COLOR) -and -not [Console]::IsOutputRedirected

# ── One round: submit to every target, then print each result as soon as it is ready ──
# Invoke-LMCollectorDebugCommand submits and returns a SessionId; results are retrieved
# separately because -IncludeResult would time out before a long script finishes. With
# -DebugCommand every target gets that raw command (-Command, and each line typed at the
# -Interactive prompt); without it each target gets the loaded script. Sets
# $script:sessions to how many sessions were created. It returns nothing on purpose: a
# PowerShell function returns everything it writes to the success stream, and that stream
# carries the collectors' output (so it can be piped), so a return value would swallow it.
function Invoke-DebugRound {
    param([string]$DebugCommand)

    $jobs = foreach ($s in $submissions) {
        $tag = if ($s.Label -ne $s.CollectorHostname) { " ($($s.Label))" } else { "" }
        try {
            if ($DebugCommand) {
                # Raw debug command, exactly as typed in the portal's debug window.
                $r = Invoke-LMCollectorDebugCommand -Id $s.CollectorId -DebugCommand $DebugCommand -ErrorAction Stop
            } elseif ($s.HostName) {
                # Device run: send a raw !groovy via -DebugCommand that binds the device's real
                # hostProps (see Build-HostPropsGroovy). We do NOT use -GroovyCommand/-CommandHostName
                # because the module's preamble binds hostProps with 'def', which methods can't see.
                $payload = Build-HostPropsGroovy -Groovy $scriptText -HostName $s.HostName
                $r = Invoke-LMCollectorDebugCommand -Id $s.CollectorId -DebugCommand $payload -ErrorAction Stop
            } elseif ($isPosh) {
                $r = Invoke-LMCollectorDebugCommand -Id $s.CollectorId -PoshCommand $scriptText -ErrorAction Stop
            } else {
                $r = Invoke-LMCollectorDebugCommand -Id $s.CollectorId -GroovyCommand $scriptText -ErrorAction Stop
            }
            if (-not $Interactive) { Write-Host "  -> $($s.CollectorHostname) (id=$($s.CollectorId))$tag" }
            [PSCustomObject]@{
                Label             = $s.Label
                CollectorHostname = $s.CollectorHostname
                CollectorId       = $s.CollectorId
                GroupName         = $s.GroupName
                SessionId         = $r.SessionId
            }
        } catch {
            Write-Warning "  Submit failed for $($s.CollectorHostname) (id=$($s.CollectorId))${tag}: $($_.Exception.Message)"
        }
    }
    $jobs = @($jobs)
    if ($jobs.Count -eq 0) {
        Write-Warning ("No debug sessions were created. The most common cause is insufficient LM permissions: " +
                       "running Collector Debug commands requires an account/API token whose role grants 'Manage' " +
                       "rights on collectors (remote debug). Verify the credentials used to connect the LM session.")
        $script:sessions = 0
        return
    }
    $script:sessions = $jobs.Count

    if (-not $Interactive) { Write-Host "Polling for results (up to ${WaitSeconds}s)..." }
    $pending  = [System.Collections.Generic.List[object]]::new()
    $jobs | ForEach-Object { $pending.Add($_) }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    # Short commands answer in a second or two; scripts take longer. Check often at first.
    $delay = 1

    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $delay
        $delay = [Math]::Min($delay * 2, 5)
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
                if ($job.GroupName) { $header = $header -replace ' ====$', " - group '$($job.GroupName)' ====" }
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
                } elseif ($Interactive) {
                    Write-Host $text
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
    if (-not $Interactive) {
        Write-Host ""
        Write-Host "Done. $($jobs.Count - $pending.Count) of $($jobs.Count) run(s) returned results."
    }
}

# ── Interactive: a prompt that runs each command on every target ──────────────
if ($Interactive) {
    Write-Host ""
    Write-Host "Type a debug command; it runs on the $($submissions.Count) collector(s) above and each one's"
    Write-Host "output is shown. 'help' lists the commands, 'help !ping' explains one. 'exit' quits."
    while ($true) {
        $line = Read-Host 'debug'
        if ($null -eq $line) { break }                                   # end of input
        $line = $line.Trim()
        if (-not $line) {
            if ([Console]::IsInputRedirected) { break }                  # piped input ran out
            continue
        }
        if ($line -in 'exit', 'quit') { break }
        if (-not (Test-DebugCommand $line)) {
            Write-Host "Debug commands start with '!' (e.g. !ping 10.0.0.5), or are 'help'." -ForegroundColor Yellow
            continue
        }
        Invoke-DebugRound -DebugCommand $line
    }
    exit 0
}

Write-Host "Submitting $($submissions.Count) run(s)..."
Invoke-DebugRound -DebugCommand $Command
if ($script:sessions -eq 0) { exit 1 }
