<#
.SYNOPSIS
    vacate - read-only handover audit. Finds personal traces before you hand over a computer.
.DESCRIPTION
    Phase 1 is an audit only. It never deletes, moves, or changes anything.
    Commands: scan, rules list|show|validate, report, checklist, version.
.NOTES
    Owner: Claude. Commands other than 'version' are wired up as their modules land.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src/Vacate/Vacate.psm1') -Force

switch ($Command) {
    'version' {
        $v = & (Get-Module Vacate) { $script:VacateToolVersion }
        Write-Output "vacate $v"
        exit 0
    }
    default {
        Write-Output 'Usage: vacate.ps1 <scan|rules|report|checklist|version>'
        Write-Output 'Phase 1: only "version" is wired so far. See PROGRESS.md.'
        if ($Command -eq 'help') { exit 0 }
        exit 2
    }
}
