<#
.SYNOPSIS
    vacate - read-only handover audit. Finds personal traces before you hand over a computer.
.DESCRIPTION
    Phase 1 is an audit only. It never deletes, moves, or changes anything, never reads file
    contents, and never uses the network.

    vacate.ps1 scan [-Redact] [-BudgetSeconds <n>] [-Elevated] [-AllowRoot]
    vacate.ps1 rules list [-Platform windows|macos|linux]
    vacate.ps1 rules show <id>
    vacate.ps1 rules validate
    vacate.ps1 report -Run <dir>
    vacate.ps1 checklist -Run <dir>
    vacate.ps1 plan -Run <dir>
    vacate.ps1 clean -Run <dir> [-Steps n,n] [-ExportDone n,n] [-Execute -Confirm <MACHINENAME>]
    vacate.ps1 undo -Run <dir> [-Execute -Confirm <MACHINENAME>]
    vacate.ps1 version
.NOTES
    For devices you own or are authorised to hand over. Not for destroying evidence, defeating a
    legal hold, or falsifying records.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(Position = 1)][string]$SubCommand,
    [Parameter(Position = 2)][string]$Id,
    [string]$Run,
    [ValidateSet('windows', 'macos', 'linux')][string]$Platform,
    [ValidateRange(1, 3600)][int]$BudgetSeconds = 120,
    [switch]$Redact,
    [switch]$Elevated,
    [switch]$AllowRoot,
    [int[]]$Steps = @(),
    [int[]]$ExportDone = @(),
    [switch]$Execute,
    [string]$Confirm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'src/Vacate/Vacate.psm1') -Force
$m = Get-Module Vacate

function Write-VacateUsage {
    Write-Output 'Usage:'
    Write-Output '  vacate.ps1 scan [-Redact] [-BudgetSeconds <n>] [-Elevated] [-AllowRoot]'
    Write-Output '  vacate.ps1 rules list [-Platform windows|macos|linux]'
    Write-Output '  vacate.ps1 rules show <id>'
    Write-Output '  vacate.ps1 rules validate'
    Write-Output '  vacate.ps1 report -Run <dir>'
    Write-Output '  vacate.ps1 checklist -Run <dir>'
    Write-Output '  vacate.ps1 plan -Run <dir>      (cleanup plan; advice only, changes nothing)'
    Write-Output '  vacate.ps1 clean -Run <dir> [-Steps n,n] [-ExportDone n,n] [-Execute -Confirm <MACHINENAME>]'
    Write-Output '  vacate.ps1 undo -Run <dir> [-Execute -Confirm <MACHINENAME>]'
    Write-Output '  vacate.ps1 version'
    Write-Output 'scan, rules, report, checklist and plan only read. clean and undo are dry runs unless'
    Write-Output '-Execute -Confirm <MACHINENAME> is given, and clean only moves items to the Recycle Bin/Trash.'
}

try {
    switch ($Command) {
        'version' {
            Write-Output ('vacate ' + (& $m { $script:VacateToolVersion }))
            exit 0
        }
        'scan' {
            $runDir = & $m { param($B, $R, $E, $A, $T) Invoke-VacateScan -BudgetSeconds $B -Redact:$R -Elevated:$E -AllowRoot:$A -ToolRoot $T } $BudgetSeconds $Redact.IsPresent $Elevated.IsPresent $AllowRoot.IsPresent $here
            $rep = & $m { param($D) ConvertFrom-VacateJson -Json ([IO.File]::ReadAllText([IO.Path]::Combine($D, 'report.json'))) } $runDir
            $s = $rep.summary
            Write-Output ('Scan finished: {0} traces, {1} rules ran, {2} skipped, {3} failed, {4} not applicable.' -f $s.tracesFound, $s.rulesRun, $s.rulesSkipped, $s.rulesFailed, $s.rulesNotApplicable)
            if (-not $rep.scan.complete) { Write-Output 'WARNING: the scan did not finish (time budget). The report is incomplete.' }
            Write-Output ('Report: ' + [IO.Path]::Combine($runDir, 'report.html'))
            Write-Output ('Next: build a cleanup plan with  vacate.ps1 plan -Run ' + $runDir)
            if (-not $rep.scan.redacted) { Write-Output 'The report lists where your private data is. Treat it like a password; use -Redact to share.' }
            exit 0
        }
        'rules' {
            switch ($SubCommand) {
                'list' {
                    $rules = & $m { param($P) if ($P) { Get-VacateRule -Platform $P } else { Get-VacateRule } } $Platform
                    foreach ($r in $rules) {
                        $v = 'unverified'; if ($r.verified) { $v = 'verified' }
                        Write-Output ('{0,-45} {1,-8} {2,-18} {3}' -f $r.id, ((@($r.platforms)) -join ','), $r.category, $v)
                    }
                    Write-Output ('{0} rules' -f @($rules).Count)
                    exit 0
                }
                'show' {
                    if (-not $Id) { Write-Output 'rules show needs a rule id.'; exit 2 }
                    $rules = @(& $m { param($I) Get-VacateRule -Id $I } $Id)
                    if ($rules.Count -eq 0) { Write-Output "No rule with id '$Id'."; exit 1 }
                    foreach ($r in $rules) { Write-Output ($r | ConvertTo-Json -Depth 6) }
                    exit 0
                }
                'validate' {
                    $res = & $m { Test-VacateRuleCatalog }
                    foreach ($e in $res.Errors) { Write-Output ('INVALID {0}: {1}' -f [IO.Path]::GetFileName($e.File), ($e.Problems -join '; ')) }
                    Write-Output ('{0} files, {1} valid, {2} invalid; windows={3} macos={4} linux={5}; unverified={6}' -f $res.Files, $res.Valid, $res.Invalid, $res.ByPlatform.windows, $res.ByPlatform.macos, $res.ByPlatform.linux, $res.Unverified)
                    if ($res.Passed) { exit 0 } else { exit 1 }
                }
                default { Write-VacateUsage; exit 2 }
            }
        }
        { $_ -eq 'report' -or $_ -eq 'checklist' } {
            if (-not $Run) { Write-Output "$Command needs -Run <dir>."; exit 2 }
            $written = & $m { param($D, $W) Export-VacateRun -Run $D -What $W } $Run $Command
            foreach ($w in $written) { Write-Output ('Wrote ' + $w) }
            exit 0
        }
        'plan' {
            if (-not $Run) { Write-Output 'plan needs -Run <dir>.'; exit 2 }
            $written = & $m { param($D) Invoke-VacatePlan -Run $D } $Run
            $pj = & $m { param($D) ConvertFrom-VacateJson -Json ([IO.File]::ReadAllText([IO.Path]::Combine($D, 'plan.json'))) } ([IO.Path]::GetFullPath($Run))
            $ps = $pj.summary
            Write-Output ('Plan: {0} steps cover {1} traces; {2} with guidance, {3} without.' -f $ps.steps, $ps.tracesCovered, $ps.withGuidance, ($ps.noGuidance + $ps.ruleMissing))
            foreach ($w in $written) { Write-Output ('Wrote ' + $w) }
            Write-Output 'vacate changed nothing. The plan is advice; you do each step yourself.'
            exit 0
        }
        'clean' {
            if (-not $Run) { Write-Output 'clean needs -Run <dir>.'; exit 2 }
            $r = & $m { param($D, $S, $X, $E, $C, $T) Invoke-VacateClean -Run $D -Steps $S -ExportDone $X -Execute:$E -ConfirmMachine $C -ToolRoot $T } ([IO.Path]::GetFullPath($Run)) $Steps $ExportDone $Execute.IsPresent $Confirm $here
            $s = $r.summary
            if ($r.mode -ceq 'execute') {
                Write-Output ('Moved {0} items to the Recycle Bin/Trash; {1} refused, {2} failed, {3} not eligible; {4} still present after a re-scan.' -f $s.moved, $s.refused, $s.failed, $s.notEligible, $s.stillPresent)
                Write-Output 'Undo with: vacate.ps1 undo -Run <dir> -Execute -Confirm <MACHINENAME>'
            }
            else {
                Write-Output ('Dry run, nothing moved: {0} would move, {1} refused, {2} not eligible. See clean-preview.md in the run folder.' -f $s.wouldMove, $s.refused, $s.notEligible)
            }
            exit 0
        }
        'undo' {
            if (-not $Run) { Write-Output 'undo needs -Run <dir>.'; exit 2 }
            $r = & $m { param($D, $E, $C) Invoke-VacateUndo -Run $D -Execute:$E -ConfirmMachine $C } ([IO.Path]::GetFullPath($Run)) $Execute.IsPresent $Confirm
            $s = $r.summary
            Write-Output ('Undo ({0}): {1} restored, {2} would restore, {3} failed.' -f $r.mode, $s.restored, $s.wouldRestore, $s.failed)
            exit 0
        }
        'help' { Write-VacateUsage; exit 0 }
        default { Write-VacateUsage; exit 2 }
    }
}
catch {
    Write-Output ('vacate: ' + $_.Exception.Message)
    exit 1
}
